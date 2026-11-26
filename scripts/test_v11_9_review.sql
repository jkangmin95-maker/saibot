-- Checks for supabase_migration_v11_9_review.sql (+ temp_scale, prompt_encoding). Scratch DB only, as postgres. Rolled back.
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
create or replace function pg_temp.u(n int) returns uuid language sql as $$ select ('f9000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create or replace function pg_temp.as_user(n int) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', pg_temp.u(n), 'role', 'authenticated')::text, true) $$;
grant execute on all functions in schema pg_temp to anon, authenticated;
create temp table t_v(k text primary key, v jsonb);
grant all on t_v to anon, authenticated;

-- privileges
select pg_temp.ok('review_users: private, RLS on, no grants to anon/authenticated/PUBLIC',
  (select relrowsecurity from pg_class where oid = 'private.review_users'::regclass)
  and not exists (select 1 from information_schema.role_table_grants where table_schema = 'private' and table_name = 'review_users' and grantee in ('anon', 'authenticated', 'PUBLIC')));
select pg_temp.ok('am_reviewer/review_reset: SECURITY DEFINER, authenticated yes, anon no, PUBLIC no; is_reviewer not callable by clients',
  (select bool_and(prosecdef and has_function_privilege('authenticated', p.oid, 'EXECUTE') and not has_function_privilege('anon', p.oid, 'EXECUTE')
     and not exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0))
   from pg_proc p where p.oid in ('public.am_reviewer()'::regprocedure, 'public.review_reset(text)'::regprocedure))
  and not has_function_privilege('authenticated', 'private.is_reviewer(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'private.is_reviewer(uuid)', 'EXECUTE'));

insert into auth.users(id) select pg_temp.u(n) from generate_series(1, 4) n;
insert into public.couples(code, user_a, user_b, name_a, name_b, warmth_temp, created_at) values
  ('RV-1', pg_temp.u(1), pg_temp.u(2), '오너', '짝', 37.5, now() - interval '40 days'),
  ('RV-2', pg_temp.u(3), pg_temp.u(4), '남1', '남2', 37.5, now() - interval '40 days');
insert into private.review_users(user_id) values (pg_temp.u(1));
insert into private.self_missions(id, couple_code, user_id, title, message, created_on) values
  ('rv-s1', 'RV-1', pg_temp.u(1), 't', 'm', (now() at time zone 'Asia/Seoul')::date),
  ('rv-s0', 'RV-1', pg_temp.u(1), 't', 'm', (now() at time zone 'Asia/Seoul')::date - 1),
  ('rv-s2', 'RV-1', pg_temp.u(2), 't', 'm', (now() at time zone 'Asia/Seoul')::date),
  ('rv-s3', 'RV-2', pg_temp.u(3), 't', 'm', (now() at time zone 'Asia/Seoul')::date);
insert into private.secret_ai_usage(user_id, day, call_count) values
  (pg_temp.u(1), (now() at time zone 'Asia/Seoul')::date, 20), (pg_temp.u(3), (now() at time zone 'Asia/Seoul')::date, 20);
insert into private.gratitude_sends(couple_code, sender_role, sent_on) values
  ('RV-1', 'A', (now() at time zone 'Asia/Seoul')::date), ('RV-1', 'B', (now() at time zone 'Asia/Seoul')::date),
  ('RV-1', 'A', (now() at time zone 'Asia/Seoul')::date - 1), ('RV-2', 'A', (now() at time zone 'Asia/Seoul')::date);
insert into private.temp_measurements(couple_code, round, member_1, member_2, total, areas, measured_at) values
  ('RV-1', 1, least(pg_temp.u(1), pg_temp.u(2)), greatest(pg_temp.u(1), pg_temp.u(2)), 38.0, array[38,38,38,38]::numeric[], now() - interval '1 day'),
  ('RV-2', 1, least(pg_temp.u(3), pg_temp.u(4)), greatest(pg_temp.u(3), pg_temp.u(4)), 38.0, array[38,38,38,38]::numeric[], now() - interval '1 day');
insert into private.temp_answers(couple_code, user_id, partner_id, round, answers) values
  ('RV-1', pg_temp.u(2), pg_temp.u(1), 2, array[0,0,0,0,0,0,0,0,0,0]::smallint[]);

-- anon
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.raises('anon: am_reviewer denied', 'select public.am_reviewer()', 'permission denied');
select pg_temp.raises('anon: review_reset denied', 'select public.review_reset(''temp'')', 'permission denied');
select pg_temp.raises('anon: review_users denied', 'select count(*) from private.review_users', 'permission denied');
reset role;

-- non-reviewer (u3 of RV-2, and u2 = owner's partner)
set local role authenticated;
select pg_temp.as_user(3);
select pg_temp.ok('non-reviewer: am_reviewer() = false', public.am_reviewer() = false);
select pg_temp.raises('non-reviewer: review_reset(mission) refused', 'select public.review_reset(''mission'')', 'not_reviewer');
select pg_temp.raises('non-reviewer: review_reset(temp) refused', 'select public.review_reset(''temp'')', 'not_reviewer');
select pg_temp.as_user(2);
select pg_temp.ok('owner''s partner is not a reviewer', public.am_reviewer() = false);
select pg_temp.raises('owner''s partner: review_reset(gratitude) refused', 'select public.review_reset(''gratitude'')', 'not_reviewer');
select pg_temp.raises('owner''s partner: cannot read review_users', 'select count(*) from private.review_users', 'permission denied');
select pg_temp.raises('client cannot call private.is_reviewer', 'select private.is_reviewer(''f9000000-0000-0000-0000-000000000002''::uuid)', 'permission denied');

-- reviewer
select pg_temp.as_user(1);
select pg_temp.ok('reviewer: am_reviewer() = true', public.am_reviewer() = true);
select pg_temp.raises('reviewer: unknown reset refused', 'select public.review_reset(''everything'')', 'bad_reset');
select pg_temp.raises('reviewer: null reset refused', 'select public.review_reset(null)', 'bad_reset');
insert into t_v select 'm', public.review_reset('mission');
insert into t_v select 'g', public.review_reset('gratitude');
select pg_temp.as_user(1);
select set_config('t.st_before', (public.my_temp()->>'status'), true);
insert into t_v select 't', public.review_reset('temp');
insert into t_v select 'st', public.my_temp();
reset role;
select pg_temp.ok('mission: only the reviewer''s own self mission of today is gone (yesterday + partner + other couple kept)',
  (select (v->>'rows')::int from t_v where k = 'm') = 1
  and not exists (select 1 from private.self_missions where id = 'rv-s1')
  and (select count(*) from private.self_missions where id in ('rv-s0', 'rv-s2', 'rv-s3')) = 3);
select pg_temp.ok('mission: reviewer''s AI counter of today cleared, other user''s kept',
  not exists (select 1 from private.secret_ai_usage where user_id = pg_temp.u(1))
  and exists (select 1 from private.secret_ai_usage where user_id = pg_temp.u(3) and call_count = 20));
select pg_temp.ok('gratitude: only the reviewer''s role today is gone (partner, yesterday, other couple kept)',
  (select (v->>'rows')::int from t_v where k = 'g') = 1
  and not exists (select 1 from private.gratitude_sends where couple_code = 'RV-1' and sender_role = 'A' and sent_on = (now() at time zone 'Asia/Seoul')::date)
  and (select count(*) from private.gratitude_sends) = 3);
select pg_temp.ok('temp: before reset my_temp said done (14-day wait)', current_setting('t.st_before', true) = 'done');
select pg_temp.ok('temp: after reset my_temp says not_started, last result still shown',
  (select v->>'status' from t_v where k = 'st') = 'not_started' and (select (v#>>'{last,total}')::numeric from t_v where k = 'st') = 38.0);
select pg_temp.ok('temp: own pair measurement moved back >= 14 days, other couple untouched, unfinished next-round answers removed',
  (select measured_at < now() - interval '14 days' from private.temp_measurements where couple_code = 'RV-1' and round = 1)
  and (select measured_at > now() - interval '2 days' from private.temp_measurements where couple_code = 'RV-2' and round = 1)
  and not exists (select 1 from private.temp_answers where couple_code = 'RV-1' and round = 2));
-- the reviewer can now really measure again (both answer)
set local role authenticated;
select pg_temp.as_user(1);
select public.submit_temp(array[2,2,2,2,2,2,2,2,2,2]::smallint[]);
select pg_temp.as_user(2);
insert into t_v select 'r2', public.submit_temp(array[2,2,2,2,2,2,2,2,2,2]::smallint[]);
reset role;
select pg_temp.ok('temp: second measurement saved as round 2', (select count(*) from private.temp_measurements where couple_code = 'RV-1') = 2
  and (select v->>'status' from t_v where k = 'r2') = 'done');
select pg_temp.ok('temp scale: worst answers both + no activity = config base (30.0 new / 32.0 old)',
  (select total from private.temp_measurements where couple_code = 'RV-1' and round = 2) = (select base from private.temp_config where id = 1));
-- non-reviewer still blocked by the 14-day wait
set local role authenticated;
select pg_temp.as_user(3);
select pg_temp.raises('non-reviewer: 14-day wait unchanged (too_soon)', 'select public.submit_temp(array[0,0,0,0,0,0,0,0,0,0]::smallint[])', 'too_soon');
reset role;
rollback;
