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
--   rows of a former partner under the same couple code are never read. Bad round (null / outside 1..1000) -> 'bad_round'.
--   Output (scored here, on the server):
--     {"round", "status": "not_started" | "waiting"}                       (me not done / me done, partner not)
--     {"round", "status": "ready", "weather": {key, label, emoji}, "lines": {strength, grow, action}}
--   Never returned: either person's answers, totals, warmth, mission or gratitude counts.
--   Scoring inputs: both answer arrays + couples.warmth_temp + counts of accepted daily_missions and private.gratitude_sends
--   in the 14 KST days ending at the later answer. Nothing here reads public.secret_emotions or any 비밀방 table.
-- * Rule: answer points (option 0/1/2 -> 2/1/0, both people, 0..40) + warmth >= 38.5 +4, gratitude days >= 3 +3,
--   accepted missions >= 2 +3. Weather from one level table in my_forecast: >= 34 맑음 ☀️, else 구름 조금 🌤️.
--   Theme ratio = points / max (+0.25 감사 if gratitude days >= 3, +0.25 행동 if missions >= 2). Highest = strength,
--   lowest of the rest = grow + its action. Ties: 감사, 그럴 수 있지, 고정관념, 행동.
-- * No dynamic SQL. No Gemini call.

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
  mine public.forecast_answers;
  theirs public.forecast_answers;
  v_ref timestamptz;
  v_day date;
  v_grat integer := 0;
  v_done integer := 0;
  -- question i (1..10) -> theme: 1 감사, 2 그럴 수 있지, 3 고정관념 내려놓기, 4 책임·행동 (order = app FORECAST_QS)
  v_map constant integer[] := array[1, 1, 2, 2, 2, 3, 3, 3, 4, 4];
  v_strength constant text[] := array[
    '고마운 걸 고맙다고 말하는 힘이 있어요',
    '작은 일은 "그럴 수 있지" 하고 넘기는 여유가 있어요',
    '서로 다른 생각을 그대로 인정해 줘요',
    '마음을 행동으로 먼저 보여 줘요'];
  v_grow constant text[] := array[
    '고마움을 말로 꺼내는 일',
    '서운한 순간을 오래 붙잡지 않는 일',
    '"당연히 이래야지"를 내려놓는 일',
    '내가 먼저 바꿀 수 있는 걸 찾는 일'];
  v_action constant text[] := array[
    '자기 전에 오늘 고마웠던 일 하나를 말로 전해 보기',
    '서운한 순간이 오면 "그럴 수 있지"를 먼저 말해 보기',
    '"당연히"라는 말이 나오면 "그럴 수도 있지"로 바꿔 말해 보기',
    '연인에게 바라는 것 하나를 내가 먼저 해 보기'];
  v_pts integer[] := array[0, 0, 0, 0];
  v_max integer[] := array[0, 0, 0, 0];
  v_ratio numeric[] := array[0, 0, 0, 0];
  v_total integer := 0;
  v_p integer;
  v_strong integer := 1;
  v_low integer;
  w record;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.couples where user_a = v_uid or user_b = v_uid order by created_at limit 1;
  if not found then raise exception 'couple_not_found' using errcode = 'P0002'; end if;
  if p_round is null or p_round not between 1 and 1000 then raise exception 'bad_round' using errcode = '22023'; end if;
  -- only the CURRENT two members of the couple (a former partner's rows are never read)
  v_partner := case when c.user_a = v_uid then c.user_b else c.user_a end;
  select * into mine from public.forecast_answers where couple_code = c.code and user_id = v_uid and round = p_round;
  if v_partner is not null then
    select * into theirs from public.forecast_answers where couple_code = c.code and user_id = v_partner and round = p_round;
  end if;
  if mine.user_id is null then return jsonb_build_object('round', p_round, 'status', 'not_started'); end if;
  if theirs.user_id is null then return jsonb_build_object('round', p_round, 'status', 'waiting'); end if;

  -- signals (counts only, never returned): 14 days ending at the later answer
  v_ref := greatest(mine.created_at, theirs.created_at);
  v_day := (v_ref at time zone 'Asia/Seoul')::date;
  select count(*) into v_grat from private.gratitude_sends
   where couple_code = c.code and sent_on > v_day - 14 and sent_on <= v_day;
  select count(*) into v_done from public.daily_missions
   where couple_code = c.code and accepted and accepted_at > v_ref - interval '14 days' and accepted_at <= v_ref;

  -- answer points: option 0/1/2 -> 2/1/0, both people summed (0..40)
  for i in 1..10 loop
    v_p := (2 - mine.answers[i]) + (2 - theirs.answers[i]);
    v_total := v_total + v_p;
    v_pts[v_map[i]] := v_pts[v_map[i]] + v_p;
    v_max[v_map[i]] := v_max[v_map[i]] + 4;
  end loop;
  v_total := v_total + case when c.warmth_temp >= 38.5 then 4 else 0 end
                     + case when v_grat >= 3 then 3 else 0 end
                     + case when v_done >= 2 then 3 else 0 end;
  for k in 1..4 loop v_ratio[k] := v_pts[k]::numeric / v_max[k]; end loop;
  if v_grat >= 3 then v_ratio[1] := v_ratio[1] + 0.25; end if;
  if v_done >= 2 then v_ratio[4] := v_ratio[4] + 0.25; end if;
  -- strongest theme; ties -> 감사, 그럴 수 있지, 고정관념, 행동 order
  for k in 2..4 loop if v_ratio[k] > v_ratio[v_strong] then v_strong := k; end if; end loop;
  -- weakest of the others
  for k in 1..4 loop
    if k <> v_strong and (v_low is null or v_ratio[k] < v_ratio[v_low]) then v_low := k; end if;
  end loop;
  -- weather levels: the ONLY place thresholds live. Highest min_total that the total reaches wins.
  -- To add a level later, add one row: (min_total, key, label, emoji).
  select lv.key, lv.label, lv.emoji into w
    from (values (34, 'sunny', '맑음', '☀️'),
                 (0, 'partly', '구름 조금', '🌤️')) as lv(min_total, key, label, emoji)
   where v_total >= lv.min_total
   order by lv.min_total desc
   limit 1;
  return jsonb_build_object('round', p_round, 'status', 'ready',
    'weather', jsonb_build_object('key', w.key, 'label', w.label, 'emoji', w.emoji),
    'lines', jsonb_build_object('strength', v_strength[v_strong], 'grow', v_grow[v_low], 'action', v_action[v_low]));
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
