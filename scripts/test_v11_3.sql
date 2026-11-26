-- Checks for supabase_migration_v11_3_forecast.sql. Run on a scratch copy AFTER the migration (as postgres).
-- Everything is rolled back. Each check prints a NOTICE starting with PASS or FAIL.
\set ON_ERROR_STOP 0
begin;
create or replace function pg_temp.ok(p_label text, p_ok boolean) returns void language plpgsql as $$
begin raise notice '% %', case when coalesce(p_ok, false) then 'PASS' else 'FAIL' end, p_label; end $$;
create or replace function pg_temp.raises(p_label text, p_sql text, p_expect text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise notice 'FAIL % (no error)', p_label;
exception when others then
  raise notice '% % (got: %)', case when position(p_expect in sqlerrm) > 0 then 'PASS' else 'FAIL' end, p_label, sqlerrm;
end $$;
create or replace function pg_temp.as_user(p_uid text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true) $$;
create temp table t_v(k text primary key, v jsonb);
grant all on t_v to anon, authenticated;
grant execute on all functions in schema pg_temp to anon, authenticated;

-- ---------- privileges / settings ----------
select pg_temp.ok('forecast_answers: RLS on',
  (select relrowsecurity from pg_class where oid = 'public.forecast_answers'::regclass));
select pg_temp.ok('forecast_answers: anon has no privilege at all',
  not exists (select 1 from information_schema.role_table_grants where table_schema = 'public' and table_name = 'forecast_answers' and grantee in ('anon', 'PUBLIC')));
select pg_temp.ok('forecast_answers: authenticated has SELECT only',
  (select array_agg(privilege_type::text order by privilege_type) from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'forecast_answers' and grantee = 'authenticated') = array['SELECT']);
select pg_temp.ok('only one policy, SELECT, to authenticated',
  (select count(*) from pg_policies where tablename = 'forecast_answers') = 1
  and (select cmd = 'SELECT' and roles = '{authenticated}' from pg_policies where tablename = 'forecast_answers'));
select pg_temp.ok('3 functions: SECURITY DEFINER, search_path=public, pg_temp',
  (select count(*) from pg_proc where oid in ('public.my_forecast(integer)'::regprocedure, 'public.submit_forecast(integer, smallint[])'::regprocedure,
     'public.forecast_answered(text, integer)'::regprocedure) and prosecdef and array_to_string(proconfig, ',') = 'search_path=public, pg_temp') = 3);
select pg_temp.ok('execute: authenticated yes, anon no, PUBLIC no (all 3)',
  (select bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE') and not has_function_privilege('anon', p.oid, 'EXECUTE')
     and not exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0))
   from pg_proc p where p.oid in ('public.my_forecast(integer)'::regprocedure, 'public.submit_forecast(integer, smallint[])'::regprocedure,
     'public.forecast_answered(text, integer)'::regprocedure)));
select pg_temp.ok('no function or policy touches secret_emotions / 비밀방',
  not exists (select 1 from pg_proc where proname in ('my_forecast', 'submit_forecast', 'forecast_answered') and (prosrc ilike '%secret%' or prosrc ilike '%sai_chat%'))
  and not exists (select 1 from pg_policies where tablename = 'forecast_answers' and qual ilike '%secret%'));
select pg_temp.ok('no view added for forecast (nothing to make security_invoker)',
  not exists (select 1 from pg_views where viewname ilike '%forecast%'));

-- ---------- fixtures: couple C1 (u1,u2), couple C2 (u3,u4), u5 without couple ----------
insert into auth.users(id) values
  ('f1000000-0000-0000-0000-000000000001'), ('f1000000-0000-0000-0000-000000000002'),
  ('f1000000-0000-0000-0000-000000000003'), ('f1000000-0000-0000-0000-000000000004'),
  ('f1000000-0000-0000-0000-000000000005');
insert into public.couples(code, user_a, user_b, name_a, name_b, warmth_temp) values
  ('FC-C1', 'f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000002', '지수', '민준', 39.4),
  ('FC-C2', 'f1000000-0000-0000-0000-000000000003', 'f1000000-0000-0000-0000-000000000004', '하나', '도윤', 37.5);
-- signals for C1: gratitude 3 days inside the window + 1 outside, missions 2 accepted inside, 1 accepted outside, 1 not accepted
insert into private.gratitude_sends(couple_code, sender_role, sent_on) values
  ('FC-C1', 'A', (now() at time zone 'Asia/Seoul')::date), ('FC-C1', 'B', (now() at time zone 'Asia/Seoul')::date),
  ('FC-C1', 'A', (now() at time zone 'Asia/Seoul')::date - 5), ('FC-C1', 'A', (now() at time zone 'Asia/Seoul')::date - 20),
  ('FC-C2', 'A', (now() at time zone 'Asia/Seoul')::date);
insert into public.daily_missions(id, couple_code, target_role, title, message, accepted, accepted_at, created_at) values
  ('fm1', 'FC-C1', 'A', 't', 'm', true, now() - interval '1 day', now() - interval '2 days'),
  ('fm2', 'FC-C1', 'B', 't', 'm', true, now() - interval '3 days', now() - interval '4 days'),
  ('fm3', 'FC-C1', 'B', 't', 'm', true, now() - interval '30 days', now() - interval '31 days'),
  ('fm4', 'FC-C1', 'A', 't', 'm', false, null, now() - interval '1 day');

-- ---------- anon ----------
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.raises('anon: select forecast_answers denied', 'select count(*) from public.forecast_answers', 'permission denied');
select pg_temp.raises('anon: submit_forecast denied', 'select public.submit_forecast(1, array[0,0,0,0,0,0,0,0,0,0]::smallint[])', 'permission denied');
select pg_temp.raises('anon: my_forecast denied', 'select public.my_forecast(1)', 'permission denied');
select pg_temp.raises('anon: forecast_answered denied', 'select public.forecast_answered(''FC-C1'', 1)', 'permission denied');
reset role;

set local role authenticated;
-- ---------- no uid / non-member ----------
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select pg_temp.raises('no uid: submit -> not_authenticated', 'select public.submit_forecast(1, array[0,0,0,0,0,0,0,0,0,0]::smallint[])', 'not_authenticated');
select pg_temp.as_user('f1000000-0000-0000-0000-000000000005');
select pg_temp.raises('non-member: submit -> couple_not_found', 'select public.submit_forecast(1, array[0,0,0,0,0,0,0,0,0,0]::smallint[])', 'couple_not_found');
select pg_temp.raises('non-member: my_forecast -> couple_not_found', 'select public.my_forecast(1)', 'couple_not_found');

-- ---------- u1 answers first ----------
select pg_temp.as_user('f1000000-0000-0000-0000-000000000001');
select pg_temp.raises('direct INSERT denied', $q$insert into public.forecast_answers(couple_code, user_id, answers) values ('FC-C1', 'f1000000-0000-0000-0000-000000000001', array[0,0,0,0,0,0,0,0,0,0]::smallint[])$q$, 'permission denied');
select pg_temp.raises('9 answers -> bad_answers', 'select public.submit_forecast(1, array[0,0,0,0,0,0,0,0,0]::smallint[])', 'bad_answers');
select pg_temp.raises('value 3 -> bad_answers', 'select public.submit_forecast(1, array[0,0,0,0,0,0,0,0,0,3]::smallint[])', 'bad_answers');
select pg_temp.raises('null inside -> bad_answers', 'select public.submit_forecast(1, array[0,0,0,0,0,0,0,0,0,null]::smallint[])', 'bad_answers');
select pg_temp.raises('2-D array -> bad_answers', 'select public.submit_forecast(1, array[[0,0,0,0,0],[0,0,0,0,0]]::smallint[])', 'bad_answers');
select pg_temp.raises('round 0 -> bad_round', 'select public.submit_forecast(0, array[0,0,0,0,0,0,0,0,0,0]::smallint[])', 'bad_round');
insert into t_v values ('u1_submit', public.submit_forecast(1, array[0,1,0,0,2,0,1,0,0,0]::smallint[]));
select pg_temp.ok('u1 after submit: me_done, partner not, not ready, no answers in reply',
  (select v = '{"round": 1, "me_done": true, "partner_done": false, "ready": false}'::jsonb from t_v where k = 'u1_submit'));
insert into t_v values ('u1_again', public.submit_forecast(1, array[2,2,2,2,2,2,2,2,2,2]::smallint[]));
select pg_temp.ok('u1 sees only own row (1)', (select count(*) from public.forecast_answers) = 1);
select pg_temp.raises('UPDATE denied', $q$update public.forecast_answers set answers = array[2,2,2,2,2,2,2,2,2,2]::smallint[]$q$, 'permission denied');
select pg_temp.raises('DELETE denied', 'delete from public.forecast_answers', 'permission denied');

-- ---------- u2 (partner) before answering ----------
select pg_temp.as_user('f1000000-0000-0000-0000-000000000002');
select pg_temp.ok('partner who has not answered sees 0 rows (cannot peek)', (select count(*) from public.forecast_answers) = 0);
select pg_temp.ok('partner my_forecast: partner_done true, not ready, no answers',
  public.my_forecast(1) = '{"round": 1, "me_done": false, "partner_done": true, "ready": false}'::jsonb);
insert into t_v values ('u2_submit', public.submit_forecast(1, array[2,2,1,2,2,1,2,2,2,1]::smallint[]));
select pg_temp.ok('u2 after submit: ready with both answer arrays (mine = u2)',
  (select v->>'ready' = 'true' and v->'mine' = '[2,2,1,2,2,1,2,2,2,1]'::jsonb and v->'partner' = '[0,1,0,0,2,0,1,0,0,0]'::jsonb from t_v where k = 'u2_submit'));
select pg_temp.ok('signals: warmth 39.4, gratitude_days 3 (14 KST days), missions_done 2 (accepted, 14 days)',
  (select (v->>'warmth_temp')::numeric = 39.4 and (v->>'gratitude_days')::int = 3 and (v->>'missions_done')::int = 2 from t_v where k = 'u2_submit'));
select pg_temp.ok('u2 now sees both rows of C1', (select count(*) from public.forecast_answers) = 2);

select pg_temp.as_user('f1000000-0000-0000-0000-000000000001');
select pg_temp.ok('u1 repeat submit changed nothing (first answers kept)',
  (select public.my_forecast(1)->'mine') = '[0,1,0,0,2,0,1,0,0,0]'::jsonb);
select pg_temp.ok('u1 my_forecast ready, mine/partner swapped vs u2',
  (select v->'mine' = '[0,1,0,0,2,0,1,0,0,0]'::jsonb and v->'partner' = '[2,2,1,2,2,1,2,2,2,1]'::jsonb from (select public.my_forecast(1) v) s));
select pg_temp.ok('round 2 is separate (not done)', public.my_forecast(2)->>'me_done' = 'false');

-- ---------- other couple ----------
select pg_temp.as_user('f1000000-0000-0000-0000-000000000003');
select pg_temp.ok('other couple member sees 0 rows of C1 before answering', (select count(*) from public.forecast_answers) = 0);
select public.submit_forecast(1, array[1,1,1,1,1,1,1,1,1,1]::smallint[]);
select pg_temp.ok('other couple member after answering sees only own row (C2)',
  (select count(*) = 1 and bool_and(couple_code = 'FC-C2') from public.forecast_answers));
select pg_temp.ok('other couple: forecast_answered on C1 is false', public.forecast_answered('FC-C1', 1) = false);
select pg_temp.ok('C2 my_forecast does not see C1: partner_done false',
  public.my_forecast(1) = '{"round": 1, "me_done": true, "partner_done": false, "ready": false}'::jsonb);
select pg_temp.as_user('f1000000-0000-0000-0000-000000000005');
select pg_temp.ok('non-member sees 0 rows', (select count(*) from public.forecast_answers) = 0);
reset role;
select pg_temp.ok('stored rows: 3 (C1 x2, C2 x1)', (select count(*) from public.forecast_answers) = 3);
rollback;
