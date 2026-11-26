-- Checks for supabase_migration_v11_3_temp.sql (우리사이 온도 + self missions). Run on a scratch copy AFTER the migration
-- (as postgres). Everything is rolled back. Each check prints a NOTICE starting with PASS or FAIL.
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
create or replace function pg_temp.u(n int) returns uuid language sql as $$ select ('f1000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create or replace function pg_temp.a(v int[]) returns smallint[] language sql as $$ select v::smallint[] $$;
create temp table t_v(k text primary key, v jsonb);
-- fixtures written "as" a user, so the id-stamping triggers fill sender_id / target_id / user_id like the app would
create or replace function pg_temp.dm(p_id text, p_code text, p_target text, p_sender int, p_acc boolean, p_acc_at timestamptz, p_created timestamptz)
returns void language plpgsql as $$ begin
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.u(p_sender), 'role', 'authenticated')::text, true);
  insert into public.daily_missions(id, couple_code, target_role, title, message, accepted, accepted_at, created_at)
  values (p_id, p_code, p_target, 't', 'm', p_acc, p_acc_at, p_created);
  perform set_config('request.jwt.claims', '{}', true);
end $$;
create or replace function pg_temp.gr(p_code text, p_role text, p_day date, p_uid int) returns void language plpgsql as $$ begin
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.u(p_uid), 'role', 'authenticated')::text, true);
  insert into private.gratitude_sends(couple_code, sender_role, sent_on) values (p_code, p_role, p_day);
  perform set_config('request.jwt.claims', '{}', true);
end $$;
grant all on t_v to anon, authenticated;
grant execute on all functions in schema pg_temp to anon, authenticated;
-- shape: only status/days_left/next_on/last; last only total/measured_on/areas; area only key/label/temp/why/todo
create or replace function pg_temp.shape_ok(v jsonb) returns boolean language sql as $$
  select (select array_agg(k order by k) from jsonb_object_keys(v) k) = array['days_left', 'last', 'next_on', 'status']
    and (jsonb_typeof(v->'last') = 'null' or (
      (select array_agg(k order by k) from jsonb_object_keys(v->'last') k) = array['areas', 'measured_on', 'total']
      and jsonb_array_length(v->'last'->'areas') = 4
      and (select bool_and((select array_agg(k order by k) from jsonb_object_keys(e) k) = array['cite', 'key', 'label', 'temp', 'todo', 'why'])
             from jsonb_array_elements(v->'last'->'areas') e)))
    and not (v::text ~* '"(answers|mine|partner|round|grat|missions?|done|miss|self|source|secret|warmth_temp)" *:') $$;
create or replace function pg_temp.temps(v jsonb) returns numeric[] language sql as $$
  select array[(v->'last'->>'total')::numeric] || array(select (e->>'temp')::numeric from jsonb_array_elements(v->'last'->'areas') e) $$;
grant execute on all functions in schema pg_temp to authenticated;

-- ---------- privileges / settings ----------
select pg_temp.ok('gratitude_senders: RLS on, no grants',
  (select relrowsecurity from pg_class where oid = 'private.gratitude_senders'::regclass)
  and not exists (select 1 from information_schema.role_table_grants where table_schema = 'private' and table_name = 'gratitude_senders' and grantee in ('anon', 'authenticated', 'PUBLIC')));
select pg_temp.ok('4 new tables in private: RLS on, no policies',
  (select count(*) from pg_class where oid in ('private.temp_config'::regclass, 'private.temp_answers'::regclass,
     'private.temp_measurements'::regclass, 'private.self_missions'::regclass) and relrowsecurity) = 4
  and (select count(*) from pg_policies where schemaname = 'private' and tablename in ('temp_config', 'temp_answers', 'temp_measurements', 'self_missions')) = 0);
select pg_temp.ok('no table grants to anon / authenticated / PUBLIC on the 4 tables',
  not exists (select 1 from information_schema.role_table_grants where table_schema = 'private'
    and table_name in ('temp_config', 'temp_answers', 'temp_measurements', 'self_missions') and grantee in ('anon', 'authenticated', 'PUBLIC')));
select pg_temp.ok('no usage on schema private for anon / authenticated',
  not has_schema_privilege('anon', 'private', 'USAGE') and not has_schema_privilege('authenticated', 'private', 'USAGE'));
select pg_temp.ok('old 예보 objects gone',
  to_regclass('public.forecast_answers') is null and to_regproc('public.my_forecast') is null and to_regproc('public.submit_forecast') is null);
create temp table t_fn as select p.oid from pg_proc p where p.oid in ('public.my_temp()'::regprocedure, 'public.submit_temp(smallint[])'::regprocedure,
  'public.create_self_mission()'::regprocedure, 'public.my_self_missions()'::regprocedure, 'public.accept_self_mission(text)'::regprocedure);
select pg_temp.ok('5 public functions: SECURITY DEFINER, search_path=public, pg_temp',
  (select count(*) from pg_proc p join t_fn using (oid) where prosecdef and array_to_string(proconfig, ',') = 'search_path=public, pg_temp') = 5);
select pg_temp.ok('execute: authenticated yes, anon no, PUBLIC no (all 5)',
  (select bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE') and not has_function_privilege('anon', p.oid, 'EXECUTE')
     and not exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0))
   from pg_proc p join t_fn using (oid)));
select pg_temp.ok('private helpers: no EXECUTE for anon / authenticated / PUBLIC',
  (select bool_and(not has_function_privilege('authenticated', p.oid, 'EXECUTE') and not has_function_privilege('anon', p.oid, 'EXECUTE'))
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'private' and p.proname in ('temp_areas_json', 'self_mission_json')));
select pg_temp.ok('no function reads secret_emotions; none writes couples; only the one-time snapshot reads warmth_temp',
  not exists (select 1 from pg_proc where proname in ('my_temp', 'submit_temp', 'create_self_mission', 'my_self_missions', 'accept_self_mission', 'send_secret_mission', 'temp_areas_json', 'self_mission_json', 'stamp_mission_ids', 'stamp_gratitude_user')
    and (prosrc ilike '%secret_emotions%' or prosrc ~* 'update\s+public\.couples'))
  and (select array_agg(proname::text) from pg_proc where prosrc ilike '%warmth_temp%' and proname in ('my_temp', 'submit_temp', 'create_self_mission', 'my_self_missions', 'accept_self_mission', 'send_secret_mission', 'temp_areas_json', 'self_mission_json', 'stamp_mission_ids', 'stamp_gratitude_user', 'temp_take_floor_snapshot')) = array['temp_take_floor_snapshot']);
select pg_temp.ok('mission_sources: private, RLS on, no grants',
  (select relrowsecurity from pg_class where oid = 'private.mission_sources'::regclass)
  and not exists (select 1 from information_schema.role_table_grants where table_schema = 'private' and table_name = 'mission_sources' and grantee in ('anon', 'authenticated', 'PUBLIC')));
select pg_temp.ok('send_secret_mission: SECURITY DEFINER, pinned path, authenticated only',
  (select prosecdef and array_to_string(proconfig, ',') = 'search_path=public, pg_temp' and has_function_privilege('authenticated', oid, 'EXECUTE')
     and not has_function_privilege('anon', oid, 'EXECUTE') from pg_proc where oid = 'public.send_secret_mission(text, text, text, text)'::regprocedure));
select pg_temp.ok('only submit_temp inserts into temp_measurements',
  (select array_agg(proname::text) from pg_proc where prosrc ilike '%into private.temp_measurements%') = array['submit_temp']);
select pg_temp.ok('config: one row with the default weights',
  (select row(base, span, grat_step, grat_cap, mission_step, mission_cap, miss_step, miss_cap, grace_days, interval_days)::text from private.temp_config)
   = '(32.0,10.0,0.2,1.5,0.3,1.5,0.1,0.5,3,14)');

-- ---------- fixtures ----------
-- C1 (u1,u2): base case.  C2 (u3,u4): other couple.  u5: no couple.  C3..C6: scoring.  u6: re-pair later.  u20: alone
insert into auth.users(id) select pg_temp.u(n) from generate_series(1, 24) n;
-- couples that "existed at migration time": C1 (39.4) and C9 (44.9 -> capped 42.0). Re-take the one-time snapshot for them.
insert into public.couples(code, user_a, user_b, name_a, name_b, warmth_temp, created_at) values
  ('TC-C1', pg_temp.u(1), pg_temp.u(2), '지수', '민준', 39.4, now() - interval '100 days'),
  ('TC-C9', pg_temp.u(21), pg_temp.u(22), null, null, 44.9, now() - interval '100 days');
update private.temp_config set floor_snapshot_at = null where id = 1;
select pg_temp.ok('snapshot: taken for the 2 existing couples', private.temp_take_floor_snapshot() = 2);
select pg_temp.ok('snapshot: C1 39.4 (u1,u2), C9 capped at 42.0',
  (select floor from private.temp_floor_snapshot where couple_code = 'TC-C1' and member_1 = pg_temp.u(1) and member_2 = pg_temp.u(2)) = 39.4
  and (select floor from private.temp_floor_snapshot where couple_code = 'TC-C9') = 42.0);
-- couples created after the migration
insert into public.couples(code, user_a, user_b, name_a, name_b, warmth_temp, created_at) values
  ('TC-C10', pg_temp.u(23), pg_temp.u(24), null, null, 44.0, now() - interval '100 days'),
  ('TC-C2', pg_temp.u(3), pg_temp.u(4), '하나', '도윤', 30.0, now() - interval '100 days'),
  ('TC-C3', pg_temp.u(7), pg_temp.u(8), null, null, 44.9, now() - interval '100 days'),
  ('TC-C4', pg_temp.u(9), pg_temp.u(10), null, null, 30.0, now() - interval '100 days'),
  ('TC-C5', pg_temp.u(11), pg_temp.u(12), null, null, 30.0, now() - interval '100 days'),
  ('TC-C6', pg_temp.u(13), pg_temp.u(14), null, null, 30.0, now() - interval '100 days'),
  ('TC-C7', pg_temp.u(15), pg_temp.u(16), null, null, 30.0, now() - interval '100 days'),
  ('TC-C8', pg_temp.u(20), null, null, null, 37.5, now() - interval '100 days');
select pg_temp.ok('snapshot is one-time: a second call adds nothing (new couples get no floor row)',
  private.temp_take_floor_snapshot() = 0 and (select count(*) from private.temp_floor_snapshot) = 2);
select pg_temp.ok('temp_floor_snapshot: RLS on, no grants',
  (select relrowsecurity from pg_class where oid = 'private.temp_floor_snapshot'::regclass)
  and not exists (select 1 from information_schema.role_table_grants where table_schema = 'private' and table_name = 'temp_floor_snapshot' and grantee in ('anon', 'authenticated', 'PUBLIC'))
  and not has_function_privilege('authenticated', 'private.temp_take_floor_snapshot()', 'EXECUTE'));

-- ---------- anon ----------
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.raises('anon: select private.temp_answers denied', 'select count(*) from private.temp_answers', 'permission denied');
select pg_temp.raises('anon: submit_temp denied', 'select public.submit_temp(pg_temp.a(array[0,0,0,0,0,0,0,0,0,0]))', 'permission denied');
select pg_temp.raises('anon: my_temp denied', 'select public.my_temp()', 'permission denied');
select pg_temp.raises('anon: my_self_missions denied', 'select public.my_self_missions()', 'permission denied');
reset role;

set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select pg_temp.raises('no uid: submit -> not_authenticated', 'select public.submit_temp(pg_temp.a(array[0,0,0,0,0,0,0,0,0,0]))', 'not_authenticated');
select pg_temp.as_user(pg_temp.u(5)::text);
select pg_temp.raises('non-member: submit -> couple_not_found', 'select public.submit_temp(pg_temp.a(array[0,0,0,0,0,0,0,0,0,0]))', 'couple_not_found');
select pg_temp.raises('non-member: my_temp -> couple_not_found', 'select public.my_temp()', 'couple_not_found');
select pg_temp.as_user(pg_temp.u(20)::text);
select pg_temp.raises('no partner yet: my_temp -> partner_not_joined', 'select public.my_temp()', 'partner_not_joined');
select pg_temp.raises('no partner yet: submit -> partner_not_joined', 'select public.submit_temp(pg_temp.a(array[0,0,0,0,0,0,0,0,0,0]))', 'partner_not_joined');

-- ---------- direct table access is closed for members ----------
select pg_temp.as_user(pg_temp.u(1)::text);
select pg_temp.raises('member: SELECT temp_answers denied', 'select * from private.temp_answers', 'permission denied');
select pg_temp.raises('member: SELECT temp_measurements denied', 'select * from private.temp_measurements', 'permission denied');
select pg_temp.raises('member: INSERT temp_measurements denied (cannot set a temperature)', $q$insert into private.temp_measurements values ('TC-C1', 1, 'f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000002', 45, array[45,45,45,45])$q$, 'permission denied');
select pg_temp.raises('member: UPDATE temp_config denied', 'update private.temp_config set base = 40', 'permission denied');
select pg_temp.raises('member: SELECT self_missions denied', 'select * from private.self_missions', 'permission denied');
select pg_temp.raises('member: call private.temp_areas_json denied', 'select private.temp_areas_json(array[1,2,3,4]::numeric[])', 'permission denied');

-- ---------- input validation ----------
select pg_temp.raises('9 answers -> bad_answers', 'select public.submit_temp(pg_temp.a(array[0,0,0,0,0,0,0,0,0]))', 'bad_answers');
select pg_temp.raises('value 3 -> bad_answers', 'select public.submit_temp(pg_temp.a(array[0,0,0,0,0,0,0,0,0,3]))', 'bad_answers');
select pg_temp.raises('value -1 -> bad_answers', 'select public.submit_temp(pg_temp.a(array[0,0,0,0,0,0,0,0,0,-1]))', 'bad_answers');
select pg_temp.raises('null inside -> bad_answers', 'select public.submit_temp(array[0,0,0,0,0,0,0,0,0,null]::smallint[])', 'bad_answers');
select pg_temp.raises('null array -> bad_answers', 'select public.submit_temp(null)', 'bad_answers');
select pg_temp.raises('2-D -> bad_answers', 'select public.submit_temp(array[[0,0,0,0,0],[0,0,0,0,0]]::smallint[])', 'bad_answers');

-- ---------- first measurement in C1: no activity ----------
select pg_temp.ok('C1 before: not_started, last null, days_left 0',
  public.my_temp() = '{"status": "not_started", "days_left": 0, "next_on": null, "last": null}'::jsonb);
insert into t_v values ('u1_submit', public.submit_temp(pg_temp.a(array[0,1,0,0,2,0,1,0,0,0])));
select pg_temp.ok('u1 after submit: waiting, nothing else',
  (select v = '{"status": "waiting", "days_left": 0, "next_on": null, "last": null}'::jsonb from t_v where k = 'u1_submit'));
select public.submit_temp(pg_temp.a(array[2,2,2,2,2,2,2,2,2,2]));
select pg_temp.as_user(pg_temp.u(2)::text);
select pg_temp.ok('partner before answering: not_started, no hint of u1''s answers',
  public.my_temp() = '{"status": "not_started", "days_left": 0, "next_on": null, "last": null}'::jsonb);
-- a member raises warmth_temp directly (still allowed by the old column grant) right before finishing
update public.couples set warmth_temp = 45.0 where code = 'TC-C1';
select pg_temp.ok('member could write warmth_temp 45.0 directly', (select warmth_temp from public.couples where code = 'TC-C1') = 45.0);
insert into t_v values ('u2_submit', public.submit_temp(pg_temp.a(array[2,2,1,2,2,1,2,2,2,1])));
-- u1 [0,1,0,0,2,0,1,0,0,0] -> pts [2,1,2,2,0,2,1,2,2,2]; u2 [2,2,1,2,2,1,2,2,2,1] -> [0,0,1,0,0,1,0,0,0,1]; sum 19/40
-- areas: 고마움 3/8 -> 35.75, 그럴수있지 5/12 -> 36.17, 고정관념 6/12 -> 37.0, 책임 5/8 -> 38.25 ; total 32 + 4.75 = 36.75 -> 36.8
select pg_temp.ok('scoring: areas 35.8 / 36.2 / 37.0 / 38.3 (answers only, no activity)',
  (select (pg_temp.temps(v))[2:5] = array[35.8, 36.2, 37.0, 38.3]::numeric[] from t_v where k = 'u2_submit'));
select pg_temp.ok('first measurement floor from snapshot: answers give 36.8, snapshot 39.4 -> total 39.4 (edited warmth 45.0 ignored)',
  (select (pg_temp.temps(v))[1] = 39.4 from t_v where k = 'u2_submit'));
reset role;
select pg_temp.ok('warmth_temp not written by measuring (still the edited 45.0)', (select warmth_temp from public.couples where code = 'TC-C1') = 45.0);
-- C9: existing couple, snapshot capped 42.0, all-worst answers (32.0) -> 42.0.  C10: new couple, warmth 44.0, no floor -> 32.0
set local role authenticated;
select pg_temp.as_user(pg_temp.u(21)::text); select public.submit_temp(pg_temp.a(array[2,2,2,2,2,2,2,2,2,2]));
select pg_temp.as_user(pg_temp.u(22)::text);
select pg_temp.ok('floor capped at 42.0 (snapshot of 44.9)', (pg_temp.temps(public.submit_temp(pg_temp.a(array[2,2,2,2,2,2,2,2,2,2]))))[1] = 42.0);
select pg_temp.as_user(pg_temp.u(23)::text); select public.submit_temp(pg_temp.a(array[2,2,2,2,2,2,2,2,2,2]));
select pg_temp.as_user(pg_temp.u(24)::text);
select pg_temp.ok('new couple (after migration, warmth 44.0): no floor -> 32.0', (pg_temp.temps(public.submit_temp(pg_temp.a(array[2,2,2,2,2,2,2,2,2,2]))))[1] = 32.0);
select pg_temp.as_user(pg_temp.u(1)::text);
select pg_temp.ok('result: status done, days_left 14, next_on = today + 14 (KST)',
  (select v->>'status' = 'done' and (v->>'days_left')::int = 14
     and v->>'next_on' = to_char((now() at time zone 'Asia/Seoul')::date + 14, 'YYYY-MM-DD') from t_v where k = 'u2_submit'));
select pg_temp.ok('result shape: no answers / counts / round / source keys', (select pg_temp.shape_ok(v) from t_v where k = 'u2_submit'));
select pg_temp.ok('no arrays of numbers anywhere except area objects (no answer arrays)',
  (select count(*) from jsonb_path_query((select v from t_v where k = 'u2_submit'), 'strict $.** ? (@.type() == "array")')) = 1);
select pg_temp.ok('areas in order with labels + 긍정학개론 why/todo',
  (select string_agg(e->>'label', ',') = '고마움,그럴 수 있지,고정관념 내려놓기,책임'
      and bool_and(length(e->>'why') > 10 and length(e->>'todo') > 5)
     from jsonb_array_elements((select v->'last'->'areas' from t_v where k = 'u2_submit')) e));
select pg_temp.as_user(pg_temp.u(1)::text);
select pg_temp.ok('u1 sees the same result (repeat submit changed nothing)',
  public.my_temp() = (select v from t_v where k = 'u2_submit'));

-- ---------- 14-day limit ----------
select pg_temp.raises('measured today: submit -> too_soon', 'select public.submit_temp(pg_temp.a(array[0,0,0,0,0,0,0,0,0,0]))', 'too_soon');
reset role;
update private.temp_measurements set measured_at = measured_at - interval '13 days' where couple_code = 'TC-C1';
set local role authenticated;
select pg_temp.as_user(pg_temp.u(1)::text);
select pg_temp.ok('13 days later: done, days_left 1', (public.my_temp()->>'days_left')::int = 1 and public.my_temp()->>'status' = 'done');
select pg_temp.raises('13 days later: submit -> too_soon', 'select public.submit_temp(pg_temp.a(array[0,0,0,0,0,0,0,0,0,0]))', 'too_soon');
reset role;
update private.temp_measurements set measured_at = measured_at - interval '1 day' where couple_code = 'TC-C1';
select pg_temp.ok('limit check is server-side only: still 1 measurement row', (select count(*) from private.temp_measurements where couple_code = 'TC-C1') = 1);
set local role authenticated;
select pg_temp.as_user(pg_temp.u(1)::text);
select pg_temp.ok('14 days later: not_started again, last result still shown, days_left 0',
  public.my_temp()->>'status' = 'not_started' and (public.my_temp()->>'days_left')::int = 0 and (pg_temp.temps(public.my_temp()))[1] = 39.4);

-- ---------- second measurement: activity since the last one ----------
reset role;
select pg_temp.gr('TC-C1', 'A', (now() at time zone 'Asia/Seoul')::date, 1), pg_temp.gr('TC-C1', 'B', (now() at time zone 'Asia/Seoul')::date, 2),
  pg_temp.gr('TC-C1', 'A', (now() at time zone 'Asia/Seoul')::date - 3, 1),
  pg_temp.gr('TC-C1', 'A', (now() at time zone 'Asia/Seoul')::date - 20, 1);  -- before the last measurement: not counted
insert into private.gratitude_sends(couple_code, sender_role, sent_on) values ('TC-C1', 'B', (now() at time zone 'Asia/Seoul')::date - 1); -- legacy row (no sender recorded): not counted
select pg_temp.ok('gratitude sender recorded by trigger (u1 today), none for the legacy row',
  (select user_id from private.gratitude_senders where couple_code = 'TC-C1' and sender_role = 'A' and sent_on = (now() at time zone 'Asia/Seoul')::date) = pg_temp.u(1)
  and not exists (select 1 from private.gratitude_senders where couple_code = 'TC-C1' and sent_on = (now() at time zone 'Asia/Seoul')::date - 1));
select pg_temp.dm('tm1', 'TC-C1', 'A', 2, true, now() - interval '1 day', now() - interval '2 days'),
  pg_temp.dm('tm2', 'TC-C1', 'B', 1, true, now() - interval '3 days', now() - interval '4 days'),
  pg_temp.dm('tm3', 'TC-C1', 'B', 1, true, now() - interval '30 days', now() - interval '31 days'),  -- before window
  pg_temp.dm('tm4', 'TC-C1', 'A', 2, false, null, now() - interval '5 days'),   -- delivered, not done past 3 days: -0.1
  pg_temp.dm('tm5', 'TC-C1', 'A', 2, false, null, now() - interval '1 day');    -- still open (inside grace): nothing
insert into public.daily_missions(id, couple_code, target_role, title, message, accepted, accepted_at, created_at)
  values ('tm6', 'TC-C1', 'A', 't', 'm', true, now() - interval '1 day', now() - interval '2 days');  -- no sender (service/legacy): not counted
select pg_temp.ok('trigger stamped ids: tm1 sender u2 -> target u1; tm6 no sender',
  (select (sender_id, target_id) = (pg_temp.u(2), pg_temp.u(1)) from public.daily_missions where id = 'tm1')
  and (select sender_id is null from public.daily_missions where id = 'tm6'));
set local role authenticated;
select pg_temp.as_user(pg_temp.u(1)::text);
select public.submit_temp(pg_temp.a(array[0,1,0,0,2,0,1,0,0,0]));
select pg_temp.as_user(pg_temp.u(2)::text);
insert into t_v values ('c1_r2', public.submit_temp(pg_temp.a(array[2,2,1,2,2,1,2,2,2,1])));
-- same answers; gratitude 3 days -> +0.6 (고마움), missions 2 done -> +0.6, 1 missed -> -0.1 (책임); total 36.75 + 1.1 = 37.85
select pg_temp.ok('activity: total 37.9, 고마움 36.4 (+0.6), 책임 38.8 (+0.6 -0.1), others unchanged',
  (select pg_temp.temps(v) = array[37.9, 36.4, 36.2, 37.0, 38.8]::numeric[] from t_v where k = 'c1_r2'));
reset role;
select pg_temp.ok('C1 has 2 measurement rows (round 1, 2)', (select array_agg(round order by round) from private.temp_measurements where couple_code = 'TC-C1') = array[1, 2]);

-- ---------- caps + clamp: C3 all best + lots of activity ----------
select pg_temp.gr('TC-C3', r, (now() at time zone 'Asia/Seoul')::date - d, case r when 'A' then 7 else 8 end)
  from generate_series(0, 9) d, (values ('A'), ('B')) v(r);
select pg_temp.dm('c3d' || n, 'TC-C3', 'A', 8, true, now() - interval '1 hour', now() - interval '2 hours') from generate_series(1, 10) n;
set local role authenticated;
select pg_temp.as_user(pg_temp.u(7)::text); select public.submit_temp(pg_temp.a(array[0,0,0,0,0,0,0,0,0,0]));
select pg_temp.as_user(pg_temp.u(8)::text);
insert into t_v values ('c3', public.submit_temp(pg_temp.a(array[0,0,0,0,0,0,0,0,0,0])));
select pg_temp.ok('caps: all best + 20 gratitude + 10 missions -> 고마움 43.5 (cap 1.5), 책임 43.5, total 45.0 (clamp)',
  (select pg_temp.temps(v) = array[45.0, 43.5, 42.0, 42.0, 43.5]::numeric[] from t_v where k = 'c3'));
select pg_temp.ok('warmth_temp 44.9 not used, not changed', (select warmth_temp from public.couples where code = 'TC-C3') = 44.9);
reset role;

-- ---------- low result shown as-is + penalty cap: C4 all worst, 10 missed missions ----------
select pg_temp.dm('c4d' || n, 'TC-C4', 'B', 9, false, null, now() - interval '10 days') from generate_series(1, 10) n;
set local role authenticated;
select pg_temp.as_user(pg_temp.u(9)::text); select public.submit_temp(pg_temp.a(array[2,2,2,2,2,2,2,2,2,2]));
select pg_temp.as_user(pg_temp.u(10)::text);
insert into t_v values ('c4', public.submit_temp(pg_temp.a(array[2,2,2,2,2,2,2,2,2,2])));
select pg_temp.ok('low as-is + penalty cap 0.5: total 31.5, 책임 31.5, others 32.0',
  (select pg_temp.temps(v) = array[31.5, 32.0, 32.0, 32.0, 31.5]::numeric[] from t_v where k = 'c4'));
reset role;

-- ---------- 비밀방 writes alone change nothing; source indistinguishable ----------
-- C5: 1 couple mission done + 1 couple mission missed + lots of 비밀방 rows.  C6: same, but both missions are self missions.
-- C7: same answers, nothing at all, but 50 secret_emotions rows.
insert into public.secret_emotions(couple_code, author_role, raw_text, created_at)
  select c, 'A', '서운해', now() - interval '1 day' from generate_series(1, 50) n, (values ('TC-C5'), ('TC-C7')) v(c);
select pg_temp.dm('c5a', 'TC-C5', 'A', 12, true, now() - interval '1 day', now() - interval '2 days'),
  pg_temp.dm('c5b', 'TC-C5', 'B', 11, false, null, now() - interval '6 days');
insert into private.self_missions(id, couple_code, user_id, title, message, accepted, accepted_at, created_at, created_on) values
  ('c6a', 'TC-C6', pg_temp.u(13), 't', 'm', true, now() - interval '1 day', now() - interval '2 days', current_date - 2),
  ('c6b', 'TC-C6', pg_temp.u(14), 't', 'm', false, null, now() - interval '6 days', current_date - 6),
  ('c6x', 'TC-C6', pg_temp.u(6), 't', 'm', true, now() - interval '1 day', now() - interval '2 days', current_date - 2); -- not a member: ignored
set local role authenticated;
select pg_temp.as_user(pg_temp.u(11)::text); select public.submit_temp(pg_temp.a(array[1,1,1,1,1,1,1,1,1,1]));
select pg_temp.as_user(pg_temp.u(12)::text); insert into t_v values ('c5', public.submit_temp(pg_temp.a(array[1,1,1,1,1,1,1,1,1,1])));
select pg_temp.as_user(pg_temp.u(13)::text); select public.submit_temp(pg_temp.a(array[1,1,1,1,1,1,1,1,1,1]));
select pg_temp.as_user(pg_temp.u(14)::text); insert into t_v values ('c6', public.submit_temp(pg_temp.a(array[1,1,1,1,1,1,1,1,1,1])));
select pg_temp.as_user(pg_temp.u(15)::text); select public.submit_temp(pg_temp.a(array[1,1,1,1,1,1,1,1,1,1]));
select pg_temp.as_user(pg_temp.u(16)::text); insert into t_v values ('c7', public.submit_temp(pg_temp.a(array[1,1,1,1,1,1,1,1,1,1])));
select pg_temp.ok('completed vs uncompleted: 1 done +0.3, 1 missed -0.1 -> 책임 37.2, total 37.2',
  (select pg_temp.temps(v) = array[37.2, 37.0, 37.0, 37.0, 37.2]::numeric[] from t_v where k = 'c5'));
select pg_temp.ok('source-indistinguishable: self missions give exactly the same reply as couple missions',
  (select v from t_v where k = 'c5') = (select v from t_v where k = 'c6'));
select pg_temp.ok('비밀방 alone changes nothing: 50 secret_emotions -> plain answer-only 37.0 everywhere',
  (select pg_temp.temps(v) = array[37.0, 37.0, 37.0, 37.0, 37.0]::numeric[] from t_v where k = 'c7'));

-- ---------- self missions ----------
reset role;
insert into t_v select 'c2_before', jsonb_build_array(completed_count, warmth_temp) from public.couples where code = 'TC-C2';
set local role authenticated;
select pg_temp.as_user(pg_temp.u(3)::text);
select pg_temp.raises('self mission without a fresh 비밀방 mission -> no_recent_mission', 'select public.create_self_mission()', 'no_recent_mission');
-- a plain couple mission (direct insert, not via 비밀방) is NOT enough
insert into public.daily_missions(id, couple_code, target_role, title, message) values ('m-1764000000001', 'TC-C2', 'B', '직접', '직접 넣은 미션');
select pg_temp.raises('direct (non-비밀방) mission -> still no_recent_mission (source checked)', 'select public.create_self_mission()', 'no_recent_mission');
select pg_temp.raises('send_secret_mission without 사이봇 use today -> no_saibot_use', $q$select public.send_secret_mission('m-1764000000002', '신호', '오늘의 커플 추천 팁', '도윤에게')$q$, 'no_saibot_use');
reset role;
insert into public.sai_chat_usage(couple_code, day, call_count) values ('TC-C2', (now() at time zone 'Asia/Seoul')::date, 1);
set local role authenticated;
select pg_temp.as_user(pg_temp.u(3)::text);
select pg_temp.raises('send_secret_mission bad id -> bad_mission', $q$select public.send_secret_mission('x1', '신호', '', '도윤에게')$q$, 'bad_mission');
select pg_temp.raises('send_secret_mission empty title -> bad_mission', $q$select public.send_secret_mission('m-1764000000003', ' ', '', '도윤에게')$q$, 'bad_mission');
select pg_temp.raises('send_secret_mission 601-char message -> bad_mission', format('select public.send_secret_mission(%L, %L, %L, %L)', 'm-1764000000004', 't', '', repeat('가', 601)), 'bad_mission');
insert into t_v values ('ssm', public.send_secret_mission('m-1764000000002', '신호', '오늘의 커플 추천 팁', '도윤에게'));
select pg_temp.ok('send_secret_mission: mission for partner (B)', (select v->>'target_role' = 'B' from t_v where k = 'ssm'));
insert into t_v values ('sm1', public.create_self_mission());
select pg_temp.ok('self mission id is a uuid', (select (v->>'id') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' from t_v where k = 'sm1'));
select pg_temp.ok('self mission: same keys as a daily_missions row, target_role = writer (A), not accepted',
  (select (select array_agg(k order by k) from jsonb_object_keys(v) k) = array['accepted', 'accepted_at', 'badge', 'couple_code', 'created_at', 'id', 'message', 'target_role', 'title']
      and v->>'target_role' = 'A' and v->>'badge' = '오늘의 커플 추천 팁' and not (v->>'accepted')::boolean from t_v where k = 'sm1'));
select pg_temp.ok('second call same day -> the same mission (one per day)', public.create_self_mission() = (select v from t_v where k = 'sm1'));
select pg_temp.ok('writer sees it in my_self_missions', jsonb_array_length(public.my_self_missions()) = 1);
select pg_temp.as_user(pg_temp.u(4)::text);
select pg_temp.ok('partner: my_self_missions is empty', public.my_self_missions() = '[]'::jsonb);
select pg_temp.ok('partner: not in daily_missions feed (only the two couple missions)',
  (select array_agg(id order by id) from public.daily_missions where couple_code = 'TC-C2') = array['m-1764000000001', 'm-1764000000002']);
select pg_temp.ok('partner: 비밀방 mission row has the same columns/shape as a direct one (source not visible)',
  (select count(distinct (select array_agg(k order by k) from jsonb_object_keys(to_jsonb(d)) k)) = 1 and bool_and(d.badge = '오늘의 커플 추천 팁')
     from public.daily_missions d where couple_code = 'TC-C2'));
select pg_temp.raises('partner: mission_sources not readable', 'select * from private.mission_sources', 'permission denied');
select pg_temp.raises('partner: create_self_mission -> no_recent_mission (partner did not send)', 'select public.create_self_mission()', 'no_recent_mission');
select pg_temp.raises('partner cannot accept it', format('select public.accept_self_mission(%L)', (select v->>'id' from t_v where k = 'sm1')), 'mission_not_found');
reset role;
select pg_temp.ok('partner: completed_count unchanged', (select jsonb_build_array(completed_count, warmth_temp) from public.couples where code = 'TC-C2') = (select v from t_v where k = 'c2_before'));
set local role authenticated;
select pg_temp.as_user(pg_temp.u(1)::text);
select pg_temp.raises('other couple cannot accept it', format('select public.accept_self_mission(%L)', (select v->>'id' from t_v where k = 'sm1')), 'mission_not_found');
select pg_temp.ok('other couple: my_self_missions empty', public.my_self_missions() = '[]'::jsonb);
select pg_temp.as_user(pg_temp.u(3)::text);
select pg_temp.ok('writer accepts: accepted true',
  (public.accept_self_mission((select v->>'id' from t_v where k = 'sm1'))->>'accepted')::boolean);
reset role;
select pg_temp.ok('accept: no completed_count / warmth change',
  (select jsonb_build_array(completed_count, warmth_temp) from public.couples where code = 'TC-C2') = (select v from t_v where k = 'c2_before'));
set local role authenticated;
select pg_temp.raises('accept bad id -> mission_not_found', 'select public.accept_self_mission(''nope'')', 'mission_not_found');
select pg_temp.raises('accept null -> mission_not_found', 'select public.accept_self_mission(null)', 'mission_not_found');
-- partner's measurement reply is the same shape whether missions came from 비밀방 or self (no source key)
select public.submit_temp(pg_temp.a(array[1,1,1,1,1,1,1,1,1,1]));
select pg_temp.as_user(pg_temp.u(4)::text);
insert into t_v values ('c2', public.submit_temp(pg_temp.a(array[1,1,1,1,1,1,1,1,1,1])));
select pg_temp.ok('C2: self mission done counted like any mission (책임 37.3, total 37.3) and shape has no source',
  (select pg_temp.temps(v) = array[37.3, 37.0, 37.0, 37.0, 37.3]::numeric[] and pg_temp.shape_ok(v) from t_v where k = 'c2'));

-- ---------- re-pair: u2 leaves C1, u6 takes the B seat ----------
reset role;
update public.couples set user_b = pg_temp.u(6) where code = 'TC-C1';
update private.temp_measurements set measured_at = measured_at - interval '14 days' where couple_code = 'TC-C1';
set local role authenticated;
select pg_temp.as_user(pg_temp.u(1)::text);
select public.submit_temp(pg_temp.a(array[0,0,0,0,0,0,0,0,0,0]));  -- u1 answers round 3 with u2 as partner? no: u6 is the partner now
reset role;
update public.couples set user_b = pg_temp.u(2) where code = 'TC-C1';  -- (back to u2 for a moment: u1's open answer was for u6)
set local role authenticated;
select pg_temp.as_user(pg_temp.u(2)::text);
select pg_temp.ok('answer given for another partner is not used: u2 sees not_started',
  public.my_temp()->>'status' = 'not_started');
reset role;
update public.couples set user_b = pg_temp.u(6) where code = 'TC-C1';
set local role authenticated;
select pg_temp.as_user(pg_temp.u(6)::text);
select pg_temp.ok('new partner u6: old pair''s measurements not shown (last null), can measure now',
  public.my_temp() = '{"status": "not_started", "days_left": 0, "next_on": null, "last": null}'::jsonb);
select pg_temp.as_user(pg_temp.u(1)::text);
select pg_temp.ok('u1 with new partner: waiting (own answer for u6), old result hidden', public.my_temp()->>'status' = 'waiting' and public.my_temp()->'last' = 'null'::jsonb);
select pg_temp.as_user(pg_temp.u(6)::text);
insert into t_v values ('u6', public.submit_temp(pg_temp.a(array[0,0,0,0,0,0,0,0,0,0])));
reset role;
select pg_temp.ok('re-pair: u2''s gratitude/missions not inherited (고마움 42.6 = u1''s 3 days only, 책임 42.0, total 42.6)',
  (select pg_temp.temps(v) = array[42.6, 42.6, 42.0, 42.0, 42.0]::numeric[] from t_v where k = 'u6'));
select pg_temp.ok('u1 + u6 measured: round 3 row with u1/u6 only, status done', (select v->>'status' = 'done' from t_v where k = 'u6')
  and (select count(*) from private.temp_measurements where couple_code = 'TC-C1' and round = 3 and pg_temp.u(6) in (member_1, member_2)) = 1);
set local role authenticated;
select pg_temp.as_user(pg_temp.u(2)::text);
select pg_temp.raises('old partner (no couple now): my_temp -> couple_not_found', 'select public.my_temp()', 'couple_not_found');
select pg_temp.raises('old partner: my_self_missions -> couple_not_found', 'select public.my_self_missions()', 'couple_not_found');
reset role;
rollback;
