-- Checks for supabase_migration_v9_1_review.sql. Run on a scratch copy AFTER the migration.
-- Everything is rolled back. Expected results are in each label.
\set ON_ERROR_STOP 0
begin;
insert into auth.users(id) values
 ('a1111111-1111-1111-1111-111111111111'),('b2222222-2222-2222-2222-222222222222'),('c3333333-3333-3333-3333-333333333333');
create temp table t_c(code text);
grant all on t_c to authenticated;

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a1111111-1111-1111-1111-111111111111","role":"authenticated"}',true);
insert into t_c select public.create_couple('A')->>'code';
insert into public.secret_emotions(couple_code, author_role, raw_text) select code, 'A', 'secret' from t_c;
insert into public.daily_missions(id,couple_code,target_role,title,message) select 'm-rev-1', code, 'B', 't', 'm' from t_c;
insert into public.daily_missions(id,couple_code,target_role,title,message) select 'm-rev-2', code, 'A', 't', 'm' from t_c;

select set_config('request.jwt.claims','{"sub":"b2222222-2222-2222-2222-222222222222","role":"authenticated"}',true);
select 'B joins' t, public.join_couple((select code from t_c), 'B')->>'role' = 'B' ok;
savepoint s1;
select 'B reads secret_emotions (expect permission denied)' t, count(*) from public.secret_emotions;
rollback to savepoint s1;
savepoint s2;
select 'B accepts mission meant for A (expect not_your_mission)' t, public.accept_mission('m-rev-2');
rollback to savepoint s2;
select 'B accepts m-rev-1 (expect 38.7 / 1)' t, r->>'warmth_temp' temp, r->>'completed_count' cnt from (select public.accept_mission('m-rev-1') r) x;
select 'B accepts m-rev-1 again (expect unchanged 38.7 / 1)' t, r->>'warmth_temp' temp, r->>'completed_count' cnt from (select public.accept_mission('m-rev-1') r) x;
select 'mission accepted (expect t, has accepted_at)' t, accepted, accepted_at is not null from public.daily_missions where id = 'm-rev-1';

select set_config('request.jwt.claims','{"sub":"c3333333-3333-3333-3333-333333333333","role":"authenticated"}',true);
savepoint s3;
select 'outsider accepts (expect mission_not_found)' t, public.accept_mission('m-rev-2');
rollback to savepoint s3;

reset role;
set local role anon;
savepoint s4;
select 'anon accept_mission (expect permission denied)' t, public.accept_mission('m-rev-2');
rollback to savepoint s4;
reset role;

-- global Gemini cap: pretend 1000 attempts already happened today
insert into private.gemini_usage(day, attempts) values ((timezone('Asia/Seoul', now()))::date, 1000)
  on conflict (day) do update set attempts = 1000;
select 'gemini_json at cap (expect null, no new attempt)' t, private.gemini_json('{}'::jsonb) is null ok,
  (select attempts from private.gemini_usage where day = (timezone('Asia/Seoul', now()))::date) attempts;
update private.gemini_usage set attempts = 0;
select 'gemini_json under cap (expect a JSON object or null from Gemini)' t, private.gemini_json('{"contents":[]}'::jsonb) r;
select 'attempts after one call (expect 1 on success)' t, attempts from private.gemini_usage where day = (timezone('Asia/Seoul', now()))::date;
rollback;
