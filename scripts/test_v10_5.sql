-- Checks for supabase_migration_v10_5_book_clicks.sql. Run on a scratch copy AFTER the migration (as postgres).
-- Everything is rolled back. Each check prints a NOTICE starting with PASS or FAIL.
\set ON_ERROR_STOP 0
begin;
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
grant execute on all functions in schema pg_temp to anon, authenticated;
delete from private.book_clicks; delete from private.book_click_caps;

-- 1) shape / privileges
select pg_temp.ok('RLS on private.book_clicks', (select relrowsecurity from pg_class where oid = 'private.book_clicks'::regclass));
select pg_temp.ok('RLS on private.book_click_caps', (select relrowsecurity from pg_class where oid = 'private.book_click_caps'::regclass));
select pg_temp.ok('no policies on either table', not exists (select 1 from pg_policies where schemaname = 'private' and tablename in ('book_clicks', 'book_click_caps')));
select pg_temp.ok('no table grants for anon/authenticated/PUBLIC',
  not exists (select 1 from information_schema.role_table_grants where table_schema = 'private' and table_name in ('book_clicks', 'book_click_caps')
              and grantee in ('anon', 'authenticated', 'PUBLIC')));
select pg_temp.ok('book_clicks stores only link_key, day, clicks (no user id)',
  (select array_agg(column_name::text order by ordinal_position) from information_schema.columns
    where table_schema = 'private' and table_name = 'book_clicks') = array['link_key', 'day', 'clicks']);
select pg_temp.ok('book_click_caps has no uuid column and no link key',
  not exists (select 1 from information_schema.columns where table_schema = 'private' and table_name = 'book_click_caps' and (data_type = 'uuid' or column_name like '%key%')));
select pg_temp.ok('log_book_click is SECURITY DEFINER', (select prosecdef from pg_proc where oid = 'public.log_book_click(text)'::regprocedure));
select pg_temp.ok('log_book_click pins search_path',
  (select coalesce(array_to_string(proconfig, ','), '') like '%search_path=public, pg_temp%' from pg_proc where oid = 'public.log_book_click(text)'::regprocedure));
select pg_temp.ok('anon cannot execute log_book_click', not has_function_privilege('anon', 'public.log_book_click(text)', 'EXECUTE'));
select pg_temp.ok('PUBLIC cannot execute log_book_click',
  not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where p.oid = 'public.log_book_click(text)'::regprocedure and a.grantee = 0));
select pg_temp.ok('authenticated can execute log_book_click', has_function_privilege('authenticated', 'public.log_book_click(text)', 'EXECUTE'));

-- 2) who may call
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.raises('anon log_book_click denied', 'select public.log_book_click(''card'')', 'permission denied');
select pg_temp.raises('anon select private.book_clicks denied', 'select count(*) from private.book_clicks', 'permission denied');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select pg_temp.raises('authenticated without uid -> not_authenticated', 'select public.log_book_click(''card'')', 'not_authenticated');
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select pg_temp.raises('bad key rejected', 'select public.log_book_click(''x'')', 'bad_key');
select pg_temp.raises('null key rejected', 'select public.log_book_click(null)', 'bad_key');
select pg_temp.raises('authenticated select private.book_clicks denied', 'select count(*) from private.book_clicks', 'permission denied');
select pg_temp.raises('authenticated insert private.book_clicks denied', 'insert into private.book_clicks values (''card'', current_date, 999)', 'permission denied');
select pg_temp.raises('authenticated select private.book_click_caps denied', 'select count(*) from private.book_click_caps', 'permission denied');

-- 3) counting: A clicks card 3x, settings 1x
insert into t_v values ('c1', to_jsonb(public.log_book_click('card')));
select public.log_book_click('card'); select public.log_book_click('card'); select public.log_book_click('settings');
-- B clicks card once
select set_config('request.jwt.claims', '{"sub":"b2000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select public.log_book_click('card');
reset role;
select pg_temp.ok('first call returns true', (select v from t_v where k = 'c1')::boolean);
select pg_temp.ok('card counted 4 today (A 3 + B 1)', (select clicks from private.book_clicks where link_key = 'card' and day = (now() at time zone 'Asia/Seoul')::date) = 4);
select pg_temp.ok('settings counted 1 today', (select clicks from private.book_clicks where link_key = 'settings' and day = (now() at time zone 'Asia/Seoul')::date) = 1);
select pg_temp.ok('day is the KST date', (select bool_and(day = (now() at time zone 'Asia/Seoul')::date) from private.book_clicks));
select pg_temp.ok('cap rows: one per person, no raw uid stored',
  (select count(*) from private.book_click_caps) = 2 and not exists (select 1 from private.book_click_caps where k like '%a1000000%' or k like '%b2000000%'));

-- 4) per-person daily cap of 20 (A already used 4)
insert into private.book_click_caps values ('old-row', (now() at time zone 'Asia/Seoul')::date - 1, 5);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select public.log_book_click('settings') from generate_series(1, 16);
insert into t_v values ('over', to_jsonb(public.log_book_click('settings')));
select public.log_book_click('card') from generate_series(1, 10);
reset role;
select pg_temp.ok('21st call returns false', not (select v from t_v where k = 'over')::boolean);
select pg_temp.ok('A capped: settings = 1 + 16 = 17, card still 4',
  (select clicks from private.book_clicks where link_key = 'settings') = 17 and (select clicks from private.book_clicks where link_key = 'card') = 4);
select pg_temp.ok('yesterday cap rows are cleaned up', not exists (select 1 from private.book_click_caps where k = 'old-row'));
-- B still counts
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"b2000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
insert into t_v values ('b2', to_jsonb(public.log_book_click('card')));
reset role;
select pg_temp.ok('other person not affected by A cap', (select v from t_v where k = 'b2')::boolean and (select clicks from private.book_clicks where link_key = 'card') = 5);
rollback;
