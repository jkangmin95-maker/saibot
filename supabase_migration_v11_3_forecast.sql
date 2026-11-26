-- 우리사이 v11.3: 무료 "우리 사이 예보" (두 사람이 따로 푸는 10문항). Run AFTER supabase_migration_v10_4_gratitude.sql
-- (uses private.gratitude_sends). Safe to run more than once. Rollback: supabase_migration_v11_3_forecast_down.sql
-- Tests: scripts/test_v11_3.sql (scripts/run_local_sql_tests_v11_3.sh)
--
-- What is stored: one row per (couple, user, round): 10 answers, each 0/1/2 (option index). Nothing else.
--
-- Security model
-- * public.forecast_answers: RLS on, no policies, nothing granted to anon/authenticated/PUBLIC (no direct SELECT either).
-- * Writes only through public.submit_forecast(int, smallint[]): SECURITY DEFINER, search_path pinned (public, pg_temp),
--   authenticated only. The couple and user come from auth.uid(), so nobody can answer for someone else or another couple.
--   One answer per user per round (a repeat call changes nothing).
-- * public.my_forecast(int): the caller's couple only, and only the rows of its CURRENT two members (couples.user_a/user_b):
--   rows of a former partner under the same couple code are never returned or counted. Returns the partner's answers
--   only when both answered. Bad round (null / outside 1..1000) -> 'bad_round', same as submit_forecast.
--   Signals for the result: couples.warmth_temp, accepted daily_missions and private.gratitude_sends counts in the 14 KST
--   days ending at the later answer. Counts only. Nothing here reads public.secret_emotions or any 비밀방 table.
-- * No dynamic SQL. No Gemini call. The weather/lines are computed in the app from these values (fixed rules).

begin;

create table if not exists public.forecast_answers (
  couple_code text not null references public.couples(code) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  round integer not null default 1 check (round between 1 and 1000),
  answers smallint[] not null check (
    array_ndims(answers) = 1 and cardinality(answers) = 10 and array_position(answers, null) is null
    and answers <@ array[0, 1, 2]::smallint[]),
  created_at timestamptz not null default now(),
  primary key (couple_code, user_id, round)
);
alter table public.forecast_answers enable row level security;
-- No direct table access for the API roles: no policies, no grants. Reads/writes go through the two RPCs below.
revoke all on table public.forecast_answers from public, anon, authenticated;
grant all on table public.forecast_answers to service_role;
-- (an earlier draft of this file had a select policy + helper; remove them if present)
drop policy if exists "forecast_member_select" on public.forecast_answers;
drop function if exists public.forecast_answered(text, integer);

create or replace function public.my_forecast(p_round integer default 1)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  c public.couples;
  v_partner uuid;
  v_role text;
  mine public.forecast_answers;
  theirs public.forecast_answers;
  v_ref timestamptz;
  v_day date;
  v_grat integer := 0;
  v_done integer := 0;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.couples where user_a = v_uid or user_b = v_uid order by created_at limit 1;
  if not found then raise exception 'couple_not_found' using errcode = 'P0002'; end if;
  if p_round is null or p_round not between 1 and 1000 then raise exception 'bad_round' using errcode = '22023'; end if;
  v_role := case when c.user_a = v_uid then 'A' else 'B' end;
  v_partner := case when v_role = 'A' then c.user_b else c.user_a end;
  select * into mine from public.forecast_answers where couple_code = c.code and user_id = v_uid and round = p_round;
  if v_partner is not null then
    select * into theirs from public.forecast_answers where couple_code = c.code and user_id = v_partner and round = p_round;
  end if;
  if mine.user_id is null or theirs.user_id is null then
    return jsonb_build_object('round', p_round, 'me_done', mine.user_id is not null,
      'partner_done', theirs.user_id is not null, 'ready', false);
  end if;
  v_ref := greatest(mine.created_at, theirs.created_at);
  v_day := (v_ref at time zone 'Asia/Seoul')::date;
  select count(*) into v_grat from private.gratitude_sends
   where couple_code = c.code and sent_on > v_day - 14 and sent_on <= v_day;
  select count(*) into v_done from public.daily_missions
   where couple_code = c.code and accepted and accepted_at > v_ref - interval '14 days' and accepted_at <= v_ref;
  return jsonb_build_object('round', p_round, 'me_done', true, 'partner_done', true, 'ready', true,
    'mine', to_jsonb(mine.answers), 'partner', to_jsonb(theirs.answers),
    'warmth_temp', c.warmth_temp, 'gratitude_days', v_grat, 'missions_done', v_done);
end
$fn$;
revoke all on function public.my_forecast(integer) from public, anon, authenticated;
grant execute on function public.my_forecast(integer) to authenticated;

create or replace function public.submit_forecast(p_round integer, p_answers smallint[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_code text;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select code into v_code from public.couples where user_a = v_uid or user_b = v_uid order by created_at limit 1;
  if v_code is null then raise exception 'couple_not_found' using errcode = 'P0002'; end if;
  if p_round is null or p_round not between 1 and 1000 then raise exception 'bad_round' using errcode = '22023'; end if;
  if p_answers is null or array_ndims(p_answers) is distinct from 1 or cardinality(p_answers) <> 10
     or array_position(p_answers, null) is not null or not (p_answers <@ array[0, 1, 2]::smallint[]) then
    raise exception 'bad_answers' using errcode = '22023';
  end if;
  insert into public.forecast_answers(couple_code, user_id, round, answers)
  values (v_code, v_uid, p_round, p_answers)
  on conflict do nothing;
  return public.my_forecast(p_round);
end
$fn$;
revoke all on function public.submit_forecast(integer, smallint[]) from public, anon, authenticated;
grant execute on function public.submit_forecast(integer, smallint[]) to authenticated;

commit;
notify pgrst, 'reload schema';
