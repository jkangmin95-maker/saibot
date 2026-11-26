-- Checks for supabase_migration_v10_4_gratitude.sql. Run on a scratch copy AFTER the migration (as postgres).
-- Everything is rolled back. Each check prints a NOTICE starting with PASS or FAIL.
\set ON_ERROR_STOP 0
begin;
insert into auth.users(id) values
 ('a1000000-0000-0000-0000-000000000001'),('b2000000-0000-0000-0000-000000000002'),
 ('c3000000-0000-0000-0000-000000000003'),('d4000000-0000-0000-0000-000000000004');
insert into public.couples(code, user_a, user_b, name_a, name_b, warmth_temp, completed_count) values
 ('T-X', 'a1000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000002', '지수', '민준', 40.0, 3),
 ('T-Y', 'd4000000-0000-0000-0000-000000000004', null, '하나', null, 37.5, 0);

create temp table t_v(k text primary key, v jsonb);
grant all on t_v to anon, authenticated;

create or replace function pg_temp.ok(p_label text, p_ok boolean) returns void language plpgsql as $$
begin raise notice '% %', case when coalesce(p_ok, false) then 'PASS' else 'FAIL' end, p_label; end $$;
create or replace function pg_temp.raises(p_label text, p_sql text, p_expect text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise notice 'FAIL % (no error)', p_label;
exception when others then
  raise notice '% % (got: %)', case when position(p_expect in sqlerrm) > 0 then 'PASS' else 'FAIL' end, p_label, sqlerrm;
end $$;
create or replace function pg_temp.temp_of(p_code text) returns numeric language sql as $$ select warmth_temp from public.couples where code = p_code $$;
grant execute on all functions in schema pg_temp to anon, authenticated;

-- 1) privileges / shape ------------------------------------------------------------
select pg_temp.ok('anon has no USAGE on schema private', not has_schema_privilege('anon', 'private', 'USAGE'));
select pg_temp.ok('authenticated has no USAGE on schema private', not has_schema_privilege('authenticated', 'private', 'USAGE'));
select pg_temp.ok('no table grants on private.gratitude_sends for anon/authenticated/PUBLIC',
  not exists (select 1 from information_schema.role_table_grants where table_schema = 'private' and table_name = 'gratitude_sends'
              and grantee in ('anon', 'authenticated', 'PUBLIC')));
select pg_temp.ok('RLS on private.gratitude_sends', (select relrowsecurity from pg_class where oid = 'private.gratitude_sends'::regclass));
select pg_temp.ok('no policies on private.gratitude_sends', not exists (select 1 from pg_policies where schemaname = 'private' and tablename = 'gratitude_sends'));
select pg_temp.ok('table stores only couple_code, sender_role, sent_on (no text, no timestamp)',
  (select array_agg(column_name::text order by ordinal_position) from information_schema.columns
    where table_schema = 'private' and table_name = 'gratitude_sends') = array['couple_code', 'sender_role', 'sent_on']);
select pg_temp.ok('send_gratitude is SECURITY DEFINER', (select prosecdef from pg_proc where oid = 'public.send_gratitude()'::regprocedure));
select pg_temp.ok('send_gratitude pins search_path',
  (select coalesce(array_to_string(proconfig, ','), '') like '%search_path=public, pg_temp%' from pg_proc where oid = 'public.send_gratitude()'::regprocedure));
select pg_temp.ok('anon cannot execute send_gratitude', not has_function_privilege('anon', 'public.send_gratitude()', 'EXECUTE'));
select pg_temp.ok('PUBLIC has no EXECUTE on send_gratitude',
  not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
              where p.oid = 'public.send_gratitude()'::regprocedure and a.grantee = 0));
select pg_temp.ok('authenticated can execute send_gratitude', has_function_privilege('authenticated', 'public.send_gratitude()', 'EXECUTE'));
select pg_temp.ok('send_gratitude takes no arguments (couple comes from auth.uid())', (select pronargs = 0 from pg_proc where oid = 'public.send_gratitude()'::regprocedure));
select pg_temp.ok('send_gratitude never touches secret_emotions', (select prosrc not like '%secret_emotions%' from pg_proc where oid = 'public.send_gratitude()'::regprocedure));

-- 2) who may call ------------------------------------------------------------------
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.raises('anon send_gratitude denied', 'select public.send_gratitude()', 'permission denied');
select pg_temp.raises('anon select private.gratitude_sends denied', 'select count(*) from private.gratitude_sends', 'permission denied');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select pg_temp.raises('authenticated without uid -> not_authenticated', 'select public.send_gratitude()', 'not_authenticated');
select set_config('request.jwt.claims', '{"sub":"c3000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select pg_temp.raises('user without a couple -> couple_not_found', 'select public.send_gratitude()', 'couple_not_found');
select pg_temp.raises('authenticated select private.gratitude_sends denied', 'select count(*) from private.gratitude_sends', 'permission denied');
select pg_temp.raises('authenticated insert private.gratitude_sends denied',
  'insert into private.gratitude_sends values (''T-X'', ''A'', current_date)', 'permission denied');

-- 3) A: first send today -> +0.3 base +0.2 bonus (1 gratitude > 0 서운함) ------------------
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into t_v values ('a1', public.send_gratitude());
insert into t_v values ('a2', public.send_gratitude());
reset role;
select pg_temp.ok('A first call: first_today=true', ((select v from t_v where k = 'a1') ->> 'first_today')::boolean);
select pg_temp.ok('A first call: streak 1', ((select v from t_v where k = 'a1') ->> 'streak')::int = 1);
select pg_temp.ok('A second call same day: streak still 1', ((select v from t_v where k = 'a2') ->> 'streak')::int = 1);
select pg_temp.ok('A first call: 40.0 -> 40.5 (+0.3 +0.2 bonus)', pg_temp.temp_of('T-X') = 40.5 and ((select v from t_v where k = 'a1') ->> 'warmth_temp')::numeric = 40.5);
select pg_temp.ok('A second call same day: first_today=false, bump 0',
  not ((select v from t_v where k = 'a2') ->> 'first_today')::boolean and ((select v from t_v where k = 'a2') ->> 'bump')::numeric = 0);
select pg_temp.ok('A second call same day: one row, temp unchanged',
  (select count(*) from private.gratitude_sends where couple_code = 'T-X') = 1 and pg_temp.temp_of('T-X') = 40.5);
select pg_temp.ok('row is (T-X, A, today in Asia/Seoul)',
  exists (select 1 from private.gratitude_sends where couple_code = 'T-X' and sender_role = 'A' and sent_on = (now() at time zone 'Asia/Seoul')::date));
select pg_temp.ok('completed_count unchanged (missions only)', (select completed_count from public.couples where code = 'T-X') = 3);

-- 4) B: 2 서운함 signals this week, 2 gratitude -> no bonus, +0.3 ------------------------------
insert into public.daily_missions(id, couple_code, target_role, title, message, created_at) values
  ('t-m1', 'T-X', 'B', 't', 'm', now()), ('t-m2', 'T-X', 'A', 't', 'm', now() - interval '2 days'),
  ('t-m-old', 'T-X', 'A', 't', 'm', now() - interval '9 days');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b2000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
insert into t_v values ('b1', public.send_gratitude());
reset role;
select pg_temp.ok('B first call: own row (per person, not per couple)', ((select v from t_v where k = 'b1') ->> 'first_today')::boolean
  and (select count(*) from private.gratitude_sends where couple_code = 'T-X') = 2);
select pg_temp.ok('B: gratitude 2 = 서운함 2 (9-day-old one ignored) -> +0.3 only (40.8)', pg_temp.temp_of('T-X') = 40.8);

-- 5) next KST day: A again -> new row; 3 gratitude > 2 서운함 -> +0.5 ------------------------
update private.gratitude_sends set sent_on = sent_on - 1 where couple_code = 'T-X' and sender_role = 'A';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into t_v values ('a3', public.send_gratitude());
reset role;
select pg_temp.ok('A next day: allowed again (3 rows)', ((select v from t_v where k = 'a3') ->> 'first_today')::boolean
  and (select count(*) from private.gratitude_sends where couple_code = 'T-X') = 3);
select pg_temp.ok('A next day: 3 gratitude > 2 서운함 -> +0.5 (41.3)', pg_temp.temp_of('T-X') = 41.3);
select pg_temp.ok('A next day: streak 2 (yesterday + today)', ((select v from t_v where k = 'a3') ->> 'streak')::int = 2);
select pg_temp.ok('B streak counts only B''s own days (1)', ((select v from t_v where k = 'b1') ->> 'streak')::int = 1);
-- gap: A's rows become today, yesterday, and 3 days ago -> streak 2; then fill the gap -> 4
insert into private.gratitude_sends values ('T-X', 'A', (now() at time zone 'Asia/Seoul')::date - 3);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into t_v values ('a4', public.send_gratitude());
reset role;
select pg_temp.ok('streak stops at a gap (2)', ((select v from t_v where k = 'a4') ->> 'streak')::int = 2 and not ((select v from t_v where k = 'a4') ->> 'first_today')::boolean);
insert into private.gratitude_sends values ('T-X', 'A', (now() at time zone 'Asia/Seoul')::date - 2);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into t_v values ('a5', public.send_gratitude());
reset role;
select pg_temp.ok('gap filled -> streak 4, temp unchanged by repeat call', ((select v from t_v where k = 'a5') ->> 'streak')::int = 4 and pg_temp.temp_of('T-X') = 41.3);
delete from private.gratitude_sends where couple_code = 'T-X' and sender_role = 'A' and sent_on < (now() at time zone 'Asia/Seoul')::date - 1;
select pg_temp.ok('서운함 never lowers temperature (only ever increased)', pg_temp.temp_of('T-X') >= 40.0);

-- 6) other couple isolated + cap 45.0 ---------------------------------------------------
update public.couples set warmth_temp = 44.9 where code = 'T-Y';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"d4000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
insert into t_v values ('d1', public.send_gratitude());
reset role;
select pg_temp.ok('D: capped at 45.0, bump reported 0.1', pg_temp.temp_of('T-Y') = 45.0 and ((select v from t_v where k = 'd1') ->> 'bump')::numeric = 0.1);
select pg_temp.ok('D: couple T-X untouched', pg_temp.temp_of('T-X') = 41.3 and (select count(*) from private.gratitude_sends where couple_code = 'T-X') = 3);
select pg_temp.ok('D: row recorded under own couple only', (select count(*) from private.gratitude_sends where couple_code = 'T-Y' and sender_role = 'A') = 1);
select pg_temp.ok('response carries no text fields',
  (select bool_and(k in ('sent_today', 'first_today', 'bump', 'warmth_temp', 'completed_count', 'streak')) from jsonb_object_keys((select v from t_v where k = 'd1')) k));
rollback;
