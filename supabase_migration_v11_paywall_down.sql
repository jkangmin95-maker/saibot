-- Rollback for supabase_migration_v11_paywall.sql. Deletes the paywall config, every couple's 결제 확인 코드 / 30-day passes,
-- every 비밀방 [확인했어요] record, every stored 비밀방 topic key, frozen report and 비밀방 AI usage counter.
-- Also restores the exact v9 public.generate_mission (v11 added the per-user AI cap to it).
-- Restores the exact v9.1 public.sai_chat body and the v10 log_event (v10 events only). v10 tables and data are untouched.
begin;
-- exact v9.1 sai_chat (copied verbatim from supabase_migration_v9_chat.sql; v9.1 did not change it)
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

drop function if exists public.consent_secret_report();
drop function if exists public.my_report();
drop function if exists public.request_pay_code();
-- exact v9 generate_mission (copied verbatim from supabase_migration_v9_chat.sql; v9.1 did not change it)
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
drop function if exists public.withdraw_secret_report();
drop function if exists private.take_secret_ai_call();
drop function if exists private.secret_ai_daily_cap();
drop function if exists private.recompute_paid_until(text);
drop function if exists public.get_paywall_config();
drop function if exists private.set_couple_paid(text, boolean, text, text);
drop function if exists private.new_pay_code();
drop function if exists private.record_secret_topic(text, text);
drop function if exists private.secret_topic(text);
drop function if exists private.paywall_on();
drop table if exists private.secret_ai_usage;
drop table if exists private.report_snapshots;
drop table if exists private.couple_passes;
drop table if exists private.secret_topic_tags;
drop table if exists private.secret_report_consents;
drop table if exists private.couple_entitlements;
drop table if exists private.paywall_config;
create or replace function public.log_event(p_event text)
returns boolean language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare c public.couples; v_n integer;
begin
  if p_event is null or p_event not in ('combo_view', 'combo_share_request', 'combo_shared',
      'quiz_start', 'quiz_finish', 'challenge_sent', 'quiz_kakao_start') then
    return false;
  end if;
  c := private.my_couple_row();
  if c.code is not null then
    select count(*) into v_n from private.funnel_events
      where couple_code = c.code and event = p_event and created_at > now() - interval '1 day';
    if v_n >= 200 then return false; end if;
  end if;
  begin
    perform private.bump_usage('event', 20000);
  exception when others then
    return false;
  end;
  insert into private.funnel_events(event, couple_code) values (p_event, c.code);
  return true;
end $$;
revoke all on function public.log_event(text) from public;
grant execute on function public.log_event(text) to anon, authenticated;
commit;
notify pgrst, 'reload schema';
