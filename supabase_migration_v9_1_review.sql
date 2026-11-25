-- 우리사이 v9.1 (engineering review hardening). Run AFTER the v9.1 app (index.html) is deployed.
-- Safe to run more than once. Does not touch existing rows. Rollback: supabase_migration_v9_1_review_down.sql
--
-- 1) secret_emotions: members could SELECT each other's raw grievance text through the REST API
--    (policy emotions_member_select). The app never reads this table, so reading is removed.
-- 2) public.accept_mission(id): accepts a mission and bumps warmth/count atomically on the server.
--    Before, each phone wrote absolute warmth_temp/completed_count values it computed locally,
--    so two accepts at once lost an increment and any member could set any temperature.
-- 3) private.gemini_json: project-wide cap of 1000 Gemini HTTP attempts per Asia/Seoul day on top of the
--    per-couple caps (email sign-up is still enabled in Supabase Auth, so accounts are cheap to make).

begin;

-- 1) ---------------------------------------------------------------------------
drop policy if exists "emotions_member_select" on public.secret_emotions;
revoke select on public.secret_emotions from authenticated;

-- 2) ---------------------------------------------------------------------------
create or replace function public.accept_mission(p_id text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $fn$
declare
  v_uid uuid := auth.uid();
  m public.daily_missions;
  c public.couples;
  v_role text;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into m from public.daily_missions where id = p_id for update;
  if not found then raise exception 'mission_not_found' using errcode = 'P0002'; end if;
  select * into c from public.couples where code = m.couple_code for update;
  if c.user_a = v_uid then v_role := 'A';
  elsif c.user_b = v_uid then v_role := 'B';
  else raise exception 'mission_not_found' using errcode = 'P0002';
  end if;
  if m.target_role <> v_role then
    raise exception 'not_your_mission' using errcode = 'P0001';
  end if;
  if not m.accepted then
    update public.daily_missions set accepted = true, accepted_at = now() where id = p_id;
    update public.couples
      set warmth_temp = least(45.0, warmth_temp + 1.2), completed_count = completed_count + 1
      where code = c.code;
  end if;
  return public.my_couple();
end
$fn$;
revoke all on function public.accept_mission(text) from public, anon;
grant execute on function public.accept_mission(text) to authenticated;

-- Step 2b (later, once no phone runs v9 or older, i.e. a few days after v9.1 is live):
-- members should no longer write warmth/count directly.
--   revoke update (warmth_temp, completed_count) on public.couples from authenticated;

-- 3) ---------------------------------------------------------------------------
create table if not exists private.gemini_usage (
  day date primary key,
  attempts integer not null default 0
);
revoke all on table private.gemini_usage from public, anon, authenticated;

-- private.gemini_json(body): POST body to Gemini, trying up to four models (v9.1: with a global daily cap). Returns the parsed JSON
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
  v_ok integer;
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
    -- v9.1: project-wide cap on Gemini HTTP attempts per Asia/Seoul day (protects the free quota
    -- from someone scripting many accounts). Each retry counts as one attempt.
    v_ok := null;
    insert into private.gemini_usage as g(day, attempts)
    values ((timezone('Asia/Seoul', now()))::date, 1)
    on conflict (day) do update set attempts = g.attempts + 1
    where g.attempts < 1000
    returning g.attempts into v_ok;
    exit when v_ok is null;
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

commit;

notify pgrst, 'reload schema';
