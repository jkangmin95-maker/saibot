-- Idempotent schema + grants for the 우리사이 PWA (anon REST access)

create table if not exists public.couples (
  code text primary key,
  warmth_temp numeric(4,1) not null default 37.5,
  completed_count integer not null default 2,
  created_at timestamptz not null default now()
);

create table if not exists public.daily_missions (
  id text primary key,
  couple_code text not null references public.couples(code) on delete cascade,
  target_role text not null check (target_role in ('A', 'B')),
  title text not null,
  message text not null,
  badge text not null default '오늘의 커플 추천 팁',
  accepted boolean not null default false,
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.secret_emotions (
  id uuid primary key default gen_random_uuid(),
  couple_code text not null references public.couples(code) on delete cascade,
  author_role text not null check (author_role in ('A', 'B')),
  raw_text text not null,
  translated_mission_id text,
  created_at timestamptz not null default now()
);

alter table public.couples enable row level security;
alter table public.daily_missions enable row level security;
alter table public.secret_emotions enable row level security;

drop policy if exists "couples_anon_all" on public.couples;
drop policy if exists "missions_anon_all" on public.daily_missions;
drop policy if exists "emotions_anon_insert" on public.secret_emotions;

create policy "couples_anon_all" on public.couples for all using (true) with check (true);
create policy "missions_anon_all" on public.daily_missions for all using (true) with check (true);
create policy "emotions_anon_insert" on public.secret_emotions for insert with check (true);

grant usage on schema public to anon, authenticated, service_role;
grant select, insert, update, delete on public.couples to anon, authenticated, service_role;
grant select, insert, update, delete on public.daily_missions to anon, authenticated, service_role;
grant select, insert, update, delete on public.secret_emotions to anon, authenticated, service_role;

-- App uses REST polling, not postgres_changes. Publication add is optional and
-- ignored if the table is already a member.
do $$
begin
  begin
    alter publication supabase_realtime add table public.couples;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.daily_missions;
  exception when duplicate_object then null;
  end;
end $$;


-- AI mission RPC (Approach A). The Gemini API key is stored in Supabase Vault
-- under the name urisai_gemini_api_key and is NEVER written to this file.
-- To set or rotate it (as the postgres role, from a secret env var):
--   select vault.create_secret(:'gemkey', 'urisai_gemini_api_key', 'Gemini key for public.generate_mission');
--   -- or vault.update_secret(id, :'gemkey', name, description, key_id) for an existing row.
-- Model: gemini-3.5-flash-lite. Daily cap: 30 calls per couple_code (Asia/Seoul date).
-- Input cap: feeling <= 500 chars, couple_code <= 32 chars.
-- Returns jsonb {empathy,title,message} or null on any error / cap / missing key.

create extension if not exists http with schema extensions;

create table if not exists public.mission_gen_usage (
  couple_code text not null,
  day date not null,
  call_count integer not null default 0,
  primary key (couple_code, day)
);

alter table public.mission_gen_usage enable row level security;
revoke all on table public.mission_gen_usage from public, anon, authenticated;

create or replace function public.generate_mission(feeling text, couple_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, vault, extensions
as $fn$
#variable_conflict use_column
declare
  v_key text;
  v_code text;
  v_count integer;
  v_body text;
  v_resp extensions.http_response;
  v_text text;
  v_parsed jsonb;
  v_today date := (timezone('Asia/Seoul', now()))::date;
begin
  if feeling is null or length(btrim(feeling)) = 0 then
    return null;
  end if;
  if length(feeling) > 500 then
    return null;
  end if;
  if couple_code is null or length(btrim(couple_code)) = 0 or length(couple_code) > 32 then
    return null;
  end if;

  v_code := btrim(couple_code);

  insert into public.mission_gen_usage as u(couple_code, day, call_count)
  values (v_code, v_today, 1)
  on conflict on constraint mission_gen_usage_pkey
  do update set call_count = u.call_count + 1
  where u.call_count < 30
  returning u.call_count into v_count;

  if v_count is null then
    return null;
  end if;

  select decrypted_secret into v_key
  from vault.decrypted_secrets
  where name = 'urisai_gemini_api_key'
  limit 1;

  if v_key is null or length(v_key) = 0 then
    return null;
  end if;

  v_body := jsonb_build_object(
    'contents', jsonb_build_array(
      jsonb_build_object(
        'parts', jsonb_build_array(
          jsonb_build_object(
            'text',
            '당신은 커플 관계 코칭 AI ''사이봇''입니다. 한 사람이 연인에게 서운하거나 아쉬운 마음을 비밀로 털어놓았습니다.' || E'\n' ||
            '감정: ' || btrim(feeling) || E'\n' ||
            '반드시 다음 JSON만 출력하세요(설명, 코드블록 금지): {"empathy":"...","title":"...","message":"..."}' || E'\n' ||
            '규칙:' || E'\n' ||
            '1) 따뜻한 자연스러운 한국어.' || E'\n' ||
            '2) empathy는 털어놓은 사람에게 공감하는 2문장(이 문구는 본인만 봄).' || E'\n' ||
            '3) title은 상대방에게 보낼 데일리 미션 제목(15자 이내).' || E'\n' ||
            '4) message는 상대방이 보게 될 미션 문구 2문장. 상대가 불만을 말했다는 사실이나 구체적인 서운함은 절대 드러내지 마세요. 자연스럽고 구체적인 다정한 행동 제안이어야 합니다.' || E'\n' ||
            '5) 매번 다른 표현과 구체적인 미션을 만드세요. 진부한 반복을 피하세요.'
          )
        )
      )
    ),
    'generationConfig', jsonb_build_object(
      'temperature', 0.95,
      'maxOutputTokens', 512,
      'responseMimeType', 'application/json'
    )
  )::text;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '7');
  perform extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT', '4');

  select * into v_resp
  from extensions.http((
    'POST',
    'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent',
    array[
      extensions.http_header('x-goog-api-key', v_key)
    ],
    'application/json',
    v_body
  )::extensions.http_request);

  if v_resp.status is distinct from 200 or v_resp.content is null then
    return null;
  end if;

  begin
    v_text := (v_resp.content::jsonb #>> '{candidates,0,content,parts,0,text}');
  exception when others then
    return null;
  end;

  if v_text is null or length(btrim(v_text)) = 0 then
    return null;
  end if;

  v_text := btrim(v_text);
  v_text := regexp_replace(v_text, '^```(?:json)?\s*', '');
  v_text := regexp_replace(v_text, '\s*```$', '');

  begin
    v_parsed := v_text::jsonb;
  exception when others then
    return null;
  end;

  if coalesce(v_parsed->>'empathy', '') = '' or coalesce(v_parsed->>'message', '') = '' then
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

comment on function public.generate_mission(text, text) is
  'Returns {empathy,title,message} from Gemini, or null on error/quota/cap. Key is read from vault. Daily cap 30 calls per couple_code.';

revoke all on function public.generate_mission(text, text) from public;
grant execute on function public.generate_mission(text, text) to anon, authenticated;

revoke all on vault.decrypted_secrets from public, anon, authenticated;
revoke all on vault.secrets from public, anon, authenticated;
