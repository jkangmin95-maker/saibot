-- v11.9 owner review mode (owner-only test shortcuts). Security review before apply. Down: supabase_migration_v11_9_review_down.sql
-- * Allowlist by auth user id in private.review_users (schema private: not exposed, RLS on, nothing granted).
--   Seeding the owner is a separate one-line insert run by hand at apply time (no user id in this repo, no secret in any URL).
-- * public.am_reviewer(): true only for an allowlisted caller. The app shows the owner buttons only then (also with ?review=1).
-- * public.review_reset(p_what): allowlisted caller only, touches only the caller's own couple / own rows, today only.
--     'mission'   : delete the caller's own self mission of today + the caller's 비밀방 AI counter of today
--                   (per-user 20/day). The couple cap (sai_chat 60/day, mission_gen 30/day) and the project-wide
--                   Gemini cap (private.gemini_json, 1000 attempts/day) stay as they are.
--     'gratitude' : delete the caller's own gratitude day of today (private.gratitude_sends, senders cascade).
--     'temp'      : end the 14-day wait for the caller's current pair: the pair's latest measurement gets
--                   measured_at moved back by interval_days (+1 min); unfinished answers of the next round are removed.
--                   The partner still has to answer (a measurement always needs both).
-- * No change to any existing function, table, grant or limit for anyone else.
set client_encoding = 'UTF8';

create table if not exists private.review_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table private.review_users enable row level security;
revoke all on table private.review_users from public, anon, authenticated;

create or replace function private.is_reviewer(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = private, pg_temp
as $$
  select p_uid is not null and exists (select 1 from private.review_users r where r.user_id = p_uid)
$$;
revoke all on function private.is_reviewer(uuid) from public, anon, authenticated;

create or replace function public.am_reviewer()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$ select private.is_reviewer(auth.uid()) $$;
revoke all on function public.am_reviewer() from public, anon;
grant execute on function public.am_reviewer() to authenticated;

create or replace function public.review_reset(p_what text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  c public.couples;
  v_role text;
  v_partner uuid;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_days integer;
  v_round integer;
  v_n integer := 0;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not private.is_reviewer(v_uid) then raise exception 'not_reviewer' using errcode = '42501'; end if;
  if p_what is null or p_what not in ('mission', 'gratitude', 'temp') then
    raise exception 'bad_reset' using errcode = '22023';
  end if;
  select * into c from public.couples where user_a = v_uid or user_b = v_uid order by created_at limit 1;
  if not found then raise exception 'couple_not_found' using errcode = 'P0002'; end if;
  v_role := case when c.user_a = v_uid then 'A' else 'B' end;
  v_partner := case when v_role = 'A' then c.user_b else c.user_a end;

  if p_what = 'mission' then
    delete from private.self_missions s where s.couple_code = c.code and s.user_id = v_uid and s.created_on = v_today;
    get diagnostics v_n = row_count;
    delete from private.secret_ai_usage u where u.user_id = v_uid and u.day = v_today;
  elsif p_what = 'gratitude' then
    delete from private.gratitude_sends g where g.couple_code = c.code and g.sender_role = v_role and g.sent_on = v_today;
    get diagnostics v_n = row_count;
  else
    if v_partner is null then raise exception 'partner_not_joined' using errcode = 'P0001'; end if;
    perform 1 from public.couples where code = c.code for update;
    select interval_days into v_days from private.temp_config where id = 1;
    update private.temp_measurements m
       set measured_at = least(m.measured_at, now() - make_interval(days => coalesce(v_days, 14)) - interval '1 minute')
     where m.couple_code = c.code and m.member_1 = least(v_uid, v_partner) and m.member_2 = greatest(v_uid, v_partner)
       and m.round = (select max(x.round) from private.temp_measurements x where x.couple_code = c.code
                       and x.member_1 = least(v_uid, v_partner) and x.member_2 = greatest(v_uid, v_partner));
    get diagnostics v_n = row_count;
    select coalesce(max(round), 0) + 1 into v_round from private.temp_measurements where couple_code = c.code;
    delete from private.temp_answers a where a.couple_code = c.code and a.round = v_round
       and a.user_id in (v_uid, v_partner);
  end if;
  return jsonb_build_object('ok', true, 'what', p_what, 'rows', v_n);
end
$$;
revoke all on function public.review_reset(text) from public, anon;
grant execute on function public.review_reset(text) to authenticated;
