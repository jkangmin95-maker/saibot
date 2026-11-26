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
select pg_temp.ok('forecast_answers: authenticated has no table privilege (no direct SELECT)',
  not exists (select 1 from information_schema.role_table_grants where table_schema = 'public' and table_name = 'forecast_answers' and grantee = 'authenticated'));
select pg_temp.ok('no row policies on forecast_answers, old policy helper gone',
  (select count(*) from pg_policies where tablename = 'forecast_answers') = 0
  and to_regprocedure('public.forecast_answered(text, integer)') is null);
select pg_temp.ok('2 functions: SECURITY DEFINER, search_path=public, pg_temp',
  (select count(*) from pg_proc where oid in ('public.my_forecast(integer)'::regprocedure, 'public.submit_forecast(integer, smallint[])'::regprocedure)
     and prosecdef and array_to_string(proconfig, ',') = 'search_path=public, pg_temp') = 2);
select pg_temp.ok('execute: authenticated yes, anon no, PUBLIC no (both)',
  (select bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE') and not has_function_privilege('anon', p.oid, 'EXECUTE')
     and not exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0))
   from pg_proc p where p.oid in ('public.my_forecast(integer)'::regprocedure, 'public.submit_forecast(integer, smallint[])'::regprocedure)));
select pg_temp.ok('no function or policy touches secret_emotions / 비밀방',
  not exists (select 1 from pg_proc where proname in ('my_forecast', 'submit_forecast') and (prosrc ilike '%secret%' or prosrc ilike '%sai_chat%')));
select pg_temp.ok('no view added for forecast (nothing to make security_invoker)',
  not exists (select 1 from pg_views where viewname ilike '%forecast%'));

-- ---------- fixtures: couple C1 (u1,u2), couple C2 (u3,u4), u5 without couple ----------
insert into auth.users(id) values
  ('f1000000-0000-0000-0000-000000000001'), ('f1000000-0000-0000-0000-000000000002'),
  ('f1000000-0000-0000-0000-000000000003'), ('f1000000-0000-0000-0000-000000000004'),
  ('f1000000-0000-0000-0000-000000000005'), ('f1000000-0000-0000-0000-000000000006');
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
select pg_temp.raises('my_forecast(null) -> bad_round', 'select public.my_forecast(null)', 'bad_round');
select pg_temp.raises('my_forecast(0) -> bad_round', 'select public.my_forecast(0)', 'bad_round');
select pg_temp.raises('my_forecast(1001) -> bad_round', 'select public.my_forecast(1001)', 'bad_round');
select pg_temp.raises('submit round null -> bad_round', 'select public.submit_forecast(null, array[0,0,0,0,0,0,0,0,0,0]::smallint[])', 'bad_round');
select pg_temp.raises('round 0 -> bad_round', 'select public.submit_forecast(0, array[0,0,0,0,0,0,0,0,0,0]::smallint[])', 'bad_round');
-- shape helper: a ready reply has exactly round/status/weather/lines, no arrays, and round is its only number
create or replace function pg_temp.ready_shape(v jsonb) returns boolean language sql as $$
  select (select array_agg(k order by k) from jsonb_object_keys(v) k) = array['lines', 'round', 'status', 'weather']
     and v->>'status' = 'ready'
     and (select array_agg(k order by k) from jsonb_object_keys(v->'weather') k) = array['emoji', 'key', 'label']
     and (select array_agg(k order by k) from jsonb_object_keys(v->'lines') k) = array['action', 'grow', 'strength']
     and (select count(*) from jsonb_path_query(v, 'strict $.** ? (@.type() == "array")')) = 0
     and (select count(*) from jsonb_path_query(v, 'strict $.** ? (@.type() == "number")')) = 1
     and not (v ?| array['mine', 'partner', 'answers', 'total', 'score', 'warmth_temp', 'gratitude_days', 'missions_done', 'me_done', 'partner_done']) $$;
grant execute on all functions in schema pg_temp to authenticated;
-- expected lines
create temp table t_x(k text primary key, v jsonb);
insert into t_x values
  ('partly_ac_ok', '{"round": 1, "status": "ready", "weather": {"key": "partly", "label": "구름 조금", "emoji": "🌤️"}, "lines": {"strength": "마음을 행동으로 먼저 보여 줘요", "grow": "서운한 순간을 오래 붙잡지 않는 일", "action": "서운한 순간이 오면 \"그럴 수 있지\"를 먼저 말해 보기"}}'),
  ('sunny_ac_ok', '{"round": 1, "status": "ready", "weather": {"key": "sunny", "label": "맑음", "emoji": "☀️"}, "lines": {"strength": "마음을 행동으로 먼저 보여 줘요", "grow": "서운한 순간을 오래 붙잡지 않는 일", "action": "서운한 순간이 오면 \"그럴 수 있지\"를 먼저 말해 보기"}}');
grant all on t_x to authenticated;

insert into t_v values ('u1_submit', public.submit_forecast(1, array[0,1,0,0,2,0,1,0,0,0]::smallint[]));
select pg_temp.ok('u1 after submit: exactly {round, status: waiting}',
  (select v = '{"round": 1, "status": "waiting"}'::jsonb from t_v where k = 'u1_submit'));
insert into t_v values ('u1_again', public.submit_forecast(1, array[2,2,2,2,2,2,2,2,2,2]::smallint[]));
select pg_temp.raises('member: direct SELECT denied', 'select count(*) from public.forecast_answers', 'permission denied');
select pg_temp.raises('UPDATE denied', $q$update public.forecast_answers set answers = array[2,2,2,2,2,2,2,2,2,2]::smallint[]$q$, 'permission denied');
select pg_temp.raises('DELETE denied', 'delete from public.forecast_answers', 'permission denied');

-- ---------- u2 (partner) before answering ----------
select pg_temp.as_user('f1000000-0000-0000-0000-000000000002');
select pg_temp.raises('partner: direct SELECT denied (cannot peek)', 'select * from public.forecast_answers', 'permission denied');
select pg_temp.ok('partner before answering: exactly {round, status: not_started} (nothing about u1''s answers)',
  public.my_forecast(1) = '{"round": 1, "status": "not_started"}'::jsonb);
insert into t_v values ('u2_submit', public.submit_forecast(1, array[2,2,1,2,2,1,2,2,2,1]::smallint[]));
select pg_temp.ok('u2 ready reply: only round/status/weather/lines, no answers/totals/signals, no arrays, round only number',
  (select pg_temp.ready_shape(v) from t_v where k = 'u2_submit'));
-- 19 answer points + warmth 39.4 (+4) + gratitude 3 days in 14 (+3) + missions 2 accepted in 14 (+3) = 29 -> 구름 조금
-- themes: 감사 .375+.25, 그럴 수 있지 .417, 고정관념 .5, 행동 .625+.25 -> strength 행동, grow 그럴 수 있지
select pg_temp.ok('u2 ready: 29 -> 🌤️ 구름 조금, strength 행동, grow/action 그럴 수 있지 (signals counted in 14-day window only)',
  (select v = (select v from t_x where k = 'partly_ac_ok') from t_v where k = 'u2_submit'));

select pg_temp.as_user('f1000000-0000-0000-0000-000000000001');
select pg_temp.ok('u1 sees the same result (repeat submit changed nothing)',
  public.my_forecast(1) = (select v from t_x where k = 'partly_ac_ok'));
select pg_temp.ok('u1 ready reply shape: no answers/totals keys', pg_temp.ready_shape(public.my_forecast(1)));
select pg_temp.ok('round 2 is separate: not_started', public.my_forecast(2) = '{"round": 2, "status": "not_started"}'::jsonb);

-- ---------- other couple ----------
select pg_temp.as_user('f1000000-0000-0000-0000-000000000003');
select pg_temp.raises('other couple: direct SELECT denied', 'select * from public.forecast_answers where couple_code = ''FC-C1''', 'permission denied');
select public.submit_forecast(1, array[1,1,1,1,1,1,1,1,1,1]::smallint[]);
select pg_temp.ok('C2 my_forecast does not see C1: waiting',
  public.my_forecast(1) = '{"round": 1, "status": "waiting"}'::jsonb);
select pg_temp.as_user('f1000000-0000-0000-0000-000000000005');
select pg_temp.raises('non-member: direct SELECT denied', 'select * from public.forecast_answers', 'permission denied');
reset role;
select pg_temp.ok('stored rows: 3 (C1 x2, C2 x1)', (select count(*) from public.forecast_answers) = 3);

-- ---------- threshold: one level table, 34 = 맑음, 33 = 구름 조금 (C3: warmth 37.5, no signals) ----------
insert into auth.users(id) values ('f1000000-0000-0000-0000-000000000007'), ('f1000000-0000-0000-0000-000000000008');
insert into public.couples(code, user_a, user_b, warmth_temp) values
  ('FC-C3', 'f1000000-0000-0000-0000-000000000007', 'f1000000-0000-0000-0000-000000000008', 37.5);
set local role authenticated;
select pg_temp.as_user('f1000000-0000-0000-0000-000000000007');
select public.submit_forecast(1, array[0,0,0,0,0,0,0,0,1,2]::smallint[]);  -- 17
select public.submit_forecast(2, array[0,0,0,0,0,0,0,0,1,2]::smallint[]);  -- 17
select pg_temp.as_user('f1000000-0000-0000-0000-000000000008');
select pg_temp.ok('total 34 -> ☀️ 맑음', public.submit_forecast(1, array[0,0,0,0,0,0,0,0,1,2]::smallint[])->'weather' = '{"key": "sunny", "label": "맑음", "emoji": "☀️"}'::jsonb);  -- 17
select pg_temp.ok('total 33 -> 🌤️ 구름 조금', public.submit_forecast(2, array[0,0,0,0,0,0,0,0,2,2]::smallint[])->'weather' = '{"key": "partly", "label": "구름 조금", "emoji": "🌤️"}'::jsonb);  -- 16
select public.submit_forecast(3, array[2,2,2,2,2,2,2,2,2,2]::smallint[]);
select pg_temp.as_user('f1000000-0000-0000-0000-000000000007');
select pg_temp.ok('all-worst answers (total 0), no signals -> still 🌤️ 구름 조금 (no lower level)',
  public.submit_forecast(3, array[2,2,2,2,2,2,2,2,2,2]::smallint[])->'weather'->>'key' = 'partly');
select pg_temp.ok('my_forecast source has no 흐림/비/폭풍 level',
  (select prosrc not like '%흐림%' and prosrc not like '%cloudy%' and prosrc not like '%''비''%' and prosrc not like '%폭풍%' from pg_proc where proname = 'my_forecast'));
reset role;

-- ---------- re-pair: u2 leaves C1, u6 takes the B seat. u2's old row stays in the table ----------
update public.couples set user_b = 'f1000000-0000-0000-0000-000000000006' where code = 'FC-C1';
set local role authenticated;
select pg_temp.as_user('f1000000-0000-0000-0000-000000000006');
select pg_temp.ok('new partner: old partner''s row not counted -> not_started',
  public.my_forecast(1) = '{"round": 1, "status": "not_started"}'::jsonb);
select pg_temp.as_user('f1000000-0000-0000-0000-000000000001');
select pg_temp.ok('u1 after re-pair: old partner''s row ignored -> waiting',
  public.my_forecast(1) = '{"round": 1, "status": "waiting"}'::jsonb);
select pg_temp.as_user('f1000000-0000-0000-0000-000000000006');
insert into t_v values ('u6_submit', public.submit_forecast(1, array[1,0,1,0,1,0,1,0,1,0]::smallint[]));
-- u1 + u6 = 31 + 10 = 41 -> 맑음 (u1 + u2 would be 29 -> 구름 조금), so u2's row is not used
select pg_temp.ok('after new partner answers: result from u1 + u6 only (☀️ 맑음, not u2''s 구름 조금)',
  (select v = (select v from t_x where k = 'sunny_ac_ok') from t_v where k = 'u6_submit'));
select pg_temp.as_user('f1000000-0000-0000-0000-000000000002');
select pg_temp.raises('old partner (no couple now): my_forecast -> couple_not_found', 'select public.my_forecast(1)', 'couple_not_found');
reset role;
rollback;
