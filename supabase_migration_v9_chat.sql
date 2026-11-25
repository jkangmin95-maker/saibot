-- 우리사이 v9: natural Saibot chat (public.sai_chat) + faster, more reliable generate_mission
--
-- Why: generate_mission called gemini-3.5-flash-lite with default "thinking", which often took
-- 9-12s (and Gemini also returns 503 "high demand" at times). The curl timeout was 7s and the
-- statement_timeout 8s, so the call errored, the function returned null, and the app silently
-- showed preset text every time.
--
-- Fix:
--   * thinkingLevel = minimal (about 1-2s); try gemini-3.5-flash-lite, then gemini-3.1-flash-lite,
--     flash-lite again, then gemini-3.5-flash (its free tier is only ~20 requests/day, so it is the last resort).
--     On 2026-11-25 flash-lite was often timing out / 503 "high demand".
--   * statement_timeout 24s for both RPCs (each Gemini attempt is capped at 8s, no new attempt after 12s).
--   * New public.sai_chat(couple_code, messages jsonb): answers the user's actual message with
--     recent turns as context, and suggests missions only when it fits.
-- Safeguards: caller must be authenticated AND a member of couple_code; last message <= 500 chars,
-- at most 10 turns of context, each <= 500 chars; daily caps per couple (Asia/Seoul day):
-- 60 chat calls + 30 mission calls. The Gemini key is only read from Vault
-- (secret 'urisai_gemini_api_key') inside SECURITY DEFINER functions and is never returned.
-- Safe to run more than once.

create extension if not exists http with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists public.sai_chat_usage (
  couple_code text not null,
  day date not null,
  call_count integer not null default 0,
  primary key (couple_code, day)
);
alter table public.sai_chat_usage enable row level security;
revoke all on table public.sai_chat_usage from public, anon, authenticated;

-- private.gemini_json(body): POST body to Gemini, trying two models. Returns the parsed JSON
-- object from the first candidate, or null. Never raises.
create or replace function private.gemini_json(p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, vault, extensions
as $fn$
declare
  v_key text;
  v_model text;
  v_resp extensions.http_response;
  v_text text;
  v_parsed jsonb;
  v_started timestamptz := clock_timestamp();
begin
  select decrypted_secret into v_key
  from vault.decrypted_secrets
  where name = 'urisai_gemini_api_key'
  limit 1;
  if v_key is null or length(v_key) = 0 then
    return null;
  end if;

  -- 503 "high demand" usually comes back fast, so flash-lite gets a second try.
  foreach v_model in array array['gemini-3.5-flash-lite', 'gemini-3.1-flash-lite', 'gemini-3.5-flash-lite', 'gemini-3.5-flash'] loop
    -- stay inside the 24s statement_timeout (each attempt <= 8s)
    exit when clock_timestamp() - v_started > interval '12 seconds';
    begin
      perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '8');
      perform extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT', '3');
      select * into v_resp
      from extensions.http((
        'POST',
        'https://generativelanguage.googleapis.com/v1beta/models/' || v_model || ':generateContent',
        array[extensions.http_header('x-goog-api-key', v_key)],
        'application/json',
        p_body::text
      )::extensions.http_request);

      if v_resp.status = 200 and v_resp.content is not null then
        v_text := btrim(coalesce(v_resp.content::jsonb #>> '{candidates,0,content,parts,0,text}', ''));
        v_text := regexp_replace(v_text, '^```(?:json)?\s*', '');
        v_text := regexp_replace(v_text, '\s*```$', '');
        if length(v_text) > 0 then
          v_parsed := v_text::jsonb;
          if jsonb_typeof(v_parsed) = 'object' then
            return v_parsed;
          end if;
        end if;
      end if;
    exception when others then
      -- timeout / 503 / bad JSON: try the next model
      null;
    end;
  end loop;
  return null;
exception when others then
  return null;
end;
$fn$;
revoke all on function private.gemini_json(jsonb) from public, anon, authenticated;

-- private.couple_context(code): names and recent mission titles for the prompt
create or replace function private.couple_context(p_code text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  c public.couples;
  v_me text;
  v_partner text;
  v_recent text;
begin
  select * into c from public.couples where code = p_code limit 1;
  if not found then return ''; end if;
  if c.user_a = auth.uid() then
    v_me := c.name_a; v_partner := c.name_b;
  else
    v_me := c.name_b; v_partner := c.name_a;
  end if;
  select string_agg(t, ', ') into v_recent from (
    select left(title, 40) as t from public.daily_missions
    where couple_code = p_code order by created_at desc limit 8
  ) s;
  return '[커플 정보] 나: ' || coalesce(nullif(left(v_me, 20), ''), '나')
      || ' / 연인: ' || coalesce(nullif(left(v_partner, 20), ''), '연인')
      || ' / 최근 보낸 미션: ' || coalesce(v_recent, '없음');
exception when others then
  return '';
end;
$fn$;
revoke all on function private.couple_context(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- public.sai_chat(couple_code, messages)
-- messages: [{"role":"user"|"bot","text":"..."}...], oldest first, last one is the user's new message.
-- Returns {"reply": text, "missions": [{"title","message"}, ...0-2]} or null (app then uses presets).
-- ---------------------------------------------------------------------------
create or replace function public.sai_chat(couple_code text, messages jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, vault, extensions
set statement_timeout = '24s'
as $fn$
#variable_conflict use_column
declare
  v_code text;
  v_count integer;
  v_today date := (timezone('Asia/Seoul', now()))::date;
  v_msgs jsonb;
  v_n integer;
  v_last text;
  v_contents jsonb := '[]'::jsonb;
  v_item jsonb;
  v_role text;
  v_text text;
  v_prev_role text := '';
  v_i integer := 0;
  v_sys text;
  v_out jsonb;
  v_reply text;
  v_missions jsonb := '[]'::jsonb;
  v_m jsonb;
begin
  if couple_code is null or length(btrim(couple_code)) = 0 or length(couple_code) > 32 then
    return null;
  end if;
  v_code := btrim(couple_code);
  if auth.uid() is null or not public.is_couple_member(v_code) then
    return null;
  end if;
  if messages is null or jsonb_typeof(messages) <> 'array' then
    return null;
  end if;

  v_n := jsonb_array_length(messages);
  if v_n = 0 then return null; end if;
  if messages -> (v_n - 1) ->> 'role' is distinct from 'user' then return null; end if;
  v_last := btrim(coalesce(messages -> (v_n - 1) ->> 'text', ''));
  if length(v_last) = 0 or length(v_last) > 500 then return null; end if;

  -- keep the last 10 turns
  select coalesce(jsonb_agg(e order by ord), '[]'::jsonb) into v_msgs
  from jsonb_array_elements(messages) with ordinality as t(e, ord)
  where ord > greatest(v_n - 10, 0);

  insert into public.sai_chat_usage as u(couple_code, day, call_count)
  values (v_code, v_today, 1)
  on conflict on constraint sai_chat_usage_pkey
  do update set call_count = u.call_count + 1
  where u.call_count < 60
  returning u.call_count into v_count;
  if v_count is null then
    return null;
  end if;

  -- build Gemini contents: must start with a user turn, roles must alternate
  for v_item in select e from jsonb_array_elements(v_msgs) as t(e) loop
    v_i := v_i + 1;
    v_role := case when v_item->>'role' = 'user' then 'user' else 'model' end;
    v_text := left(btrim(coalesce(v_item->>'text', '')), 500);
    continue when length(v_text) = 0;
    continue when v_prev_role = '' and v_role = 'model';
    if v_i = jsonb_array_length(v_msgs) then
      v_text := private.couple_context(v_code) || E'\n[지금 메시지] ' || v_text;
    end if;
    if v_role = v_prev_role then
      v_contents := jsonb_set(
        v_contents,
        array[(jsonb_array_length(v_contents) - 1)::text, 'parts', '0', 'text'],
        to_jsonb((v_contents -> -1 #>> '{parts,0,text}') || E'\n' || v_text));
    else
      v_contents := v_contents || jsonb_build_array(jsonb_build_object(
        'role', v_role, 'parts', jsonb_build_array(jsonb_build_object('text', v_text))));
    end if;
    v_prev_role := v_role;
  end loop;
  if jsonb_array_length(v_contents) = 0 then return null; end if;

  v_sys :=
    '너는 커플 관계 코칭 앱 ''우리사이''의 AI 친구 ''사이봇''이야. 지금 대화하는 사람은 ''나''이고, 이 비밀방 대화는 연인에게 절대 보이지 않아.' || E'\n' ||
    '역할:' || E'\n' ||
    '- 상대가 방금 한 말에 직접, 구체적으로 반응해. 상대가 쓴 단어와 상황을 짚어서 말해. 뻔한 위로 문구나 템플릿 같은 말 금지.' || E'\n' ||
    '- 친한 언니/형처럼 따뜻하고 자연스러운 한국어. 반말 금지, 항상 부드러운 해요체(~요). 1~3문장, 짧게. 이모지는 가끔 하나 정도.' || E'\n' ||
    '- 인사·잡담·질문이면 그에 맞게 자연스럽게 대답하고, 필요하면 오늘 연인과 있었던 일을 가볍게 물어봐.' || E'\n' ||
    '- 서운함·아쉬움·바람이 드러나면 공감한 뒤, 연인에게 ''오늘의 미션''으로 슬쩍 보낼 다정한 행동 제안을 2개 만들어.' || E'\n' ||
    '- 정보가 부족하면 미션 없이 한 가지만 부드럽게 되물어.' || E'\n' ||
    '- 이전 대화 흐름을 기억하고 같은 말을 반복하지 마.' || E'\n' ||
    '미션 규칙: 미션 message는 앱이 연인에게 보내는 오늘의 추천 문구야. 나의 서운함이 풀리도록 연인이 나에게 해 줄 행동을 제안해.' || E'\n' ||
    '- 연인에게 직접 말하는 형식: "상대방에게 ~해 주세요", "오늘은 상대방과 ~해 보세요". 나를 가리킬 땐 이름이 아니라 ''상대방''이라고 써.' || E'\n' ||
    '- 연인이 불만을 들었다는 사실이나 과거의 잘못(늦음, 폰, 말투 등)을 절대 언급하지 마. ''늦었으니'', ''서운'', ''화나'' 같은 말 금지. 그냥 앱이 추천하는 기분 좋은 미션처럼 보여야 해.' || E'\n' ||
    '- 예: 늦어서 서운했다면 → "오늘은 출발할 때 상대방에게 ''지금 출발!'' 한 줄 먼저 보내 주세요."' || E'\n' ||
    '- 오늘 바로 할 수 있는 구체적인 행동 1개를 1~2문장의 해요체로. 두 미션은 서로 다른 행동이어야 하고 최근 보낸 미션과 겹치지 마.' || E'\n' ||
    '- title은 15자 이내.' || E'\n' ||
    '출력: 반드시 JSON 하나만. {"reply":"나에게 하는 답","missions":[{"title":"...","message":"..."}]} 미션이 필요 없으면 "missions":[].';

  v_out := private.gemini_json(jsonb_build_object(
    'systemInstruction', jsonb_build_object('parts', jsonb_build_array(jsonb_build_object('text', v_sys))),
    'contents', v_contents,
    'generationConfig', jsonb_build_object(
      'temperature', 1.0,
      'topP', 0.95,
      'maxOutputTokens', 800,
      'responseMimeType', 'application/json',
      'thinkingConfig', jsonb_build_object('thinkingLevel', 'minimal')
    )
  ));
  if v_out is null then return null; end if;

  v_reply := btrim(coalesce(v_out->>'reply', ''));
  if length(v_reply) = 0 then return null; end if;

  if jsonb_typeof(v_out->'missions') = 'array' then
    for v_m in select e from jsonb_array_elements(v_out->'missions') as t(e) limit 3 loop
      if jsonb_typeof(v_m) = 'object' and length(btrim(coalesce(v_m->>'message', ''))) > 0 then
        v_missions := v_missions || jsonb_build_array(jsonb_build_object(
          'title', left(coalesce(nullif(btrim(v_m->>'title'), ''), '오늘의 다정함 미션'), 40),
          'message', left(btrim(v_m->>'message'), 300)));
      end if;
    end loop;
  end if;

  return jsonb_build_object('reply', left(v_reply, 600), 'missions', v_missions);
exception when others then
  return null;
end;
$fn$;

comment on function public.sai_chat(text, jsonb) is
  'v9 Saibot chat. Members only. 60 calls/day per couple. Returns {reply,missions[]} or null. Key from vault.';
revoke all on function public.sai_chat(text, jsonb) from public, anon;
grant execute on function public.sai_chat(text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- public.generate_mission (same signature/return as v8, used by older app versions)
-- now: thinkingLevel minimal, model retries, 24s statement_timeout, couple context.
-- ---------------------------------------------------------------------------
create or replace function public.generate_mission(feeling text, couple_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, vault, extensions
set statement_timeout = '24s'
as $fn$
#variable_conflict use_column
declare
  v_code text;
  v_count integer;
  v_parsed jsonb;
  v_today date := (timezone('Asia/Seoul', now()))::date;
begin
  if feeling is null or length(btrim(feeling)) = 0 or length(feeling) > 500 then
    return null;
  end if;
  if couple_code is null or length(btrim(couple_code)) = 0 or length(couple_code) > 32 then
    return null;
  end if;
  v_code := btrim(couple_code);
  if auth.uid() is null or not public.is_couple_member(v_code) then
    return null;
  end if;

  insert into public.mission_gen_usage as u(couple_code, day, call_count)
  values (v_code, v_today, 1)
  on conflict on constraint mission_gen_usage_pkey
  do update set call_count = u.call_count + 1
  where u.call_count < 30
  returning u.call_count into v_count;
  if v_count is null then
    return null;
  end if;

  v_parsed := private.gemini_json(jsonb_build_object(
    'contents', jsonb_build_array(jsonb_build_object('role', 'user', 'parts', jsonb_build_array(jsonb_build_object('text',
      '당신은 커플 관계 코칭 AI ''사이봇''입니다. 한 사람이 연인에게 서운하거나 아쉬운 마음을 비밀로 털어놓았습니다.' || E'\n' ||
      private.couple_context(v_code) || E'\n' ||
      '털어놓은 말: ' || btrim(feeling) || E'\n' ||
      '반드시 다음 JSON만 출력하세요: {"empathy":"...","title":"...","message":"..."}' || E'\n' ||
      '1) empathy: 털어놓은 사람이 쓴 말과 상황을 구체적으로 짚어 공감하는 1~2문장(본인만 봄). 뻔한 템플릿 금지.' || E'\n' ||
      '2) title: 상대방에게 보낼 데일리 미션 제목(15자 이내).' || E'\n' ||
      '3) message: 앱이 연인에게 보내는 오늘의 추천 미션 1~2문장, 해요체. "상대방에게 ~해 주세요" 형식으로 연인에게 직접 말하고, 털어놓은 사람은 이름 대신 ''상대방''이라고 부르세요. 불만·서운함·과거의 잘못은 절대 언급하지 말고, 마음이 풀리는 방향의 오늘 할 수 있는 구체적인 다정한 행동. 최근 보낸 미션과 겹치지 않게.'
    )))),
    'generationConfig', jsonb_build_object(
      'temperature', 1.0,
      'maxOutputTokens', 600,
      'responseMimeType', 'application/json',
      'thinkingConfig', jsonb_build_object('thinkingLevel', 'minimal')
    )
  ));

  if v_parsed is null or coalesce(v_parsed->>'empathy', '') = '' or coalesce(v_parsed->>'message', '') = '' then
    return null;
  end if;
  return jsonb_build_object(
    'empathy', left(v_parsed->>'empathy', 500),
    'title', left(coalesce(nullif(v_parsed->>'title', ''), '오늘의 다정함 미션'), 40),
    'message', left(v_parsed->>'message', 500)
  );
exception when others then
  return null;
end;
$fn$;

revoke all on function public.generate_mission(text, text) from public, anon;
grant execute on function public.generate_mission(text, text) to authenticated;

revoke all on vault.decrypted_secrets from public, anon, authenticated;
revoke all on vault.secrets from public, anon, authenticated;

notify pgrst, 'reload schema';
