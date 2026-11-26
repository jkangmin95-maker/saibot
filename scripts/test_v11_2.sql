-- Checks for supabase_migration_v11_2_book_click_paywall.sql. Run on a scratch copy AFTER the migration (as postgres).
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
delete from private.book_clicks;
delete from private.book_clicks;
-- privileges / settings identical to v10.5
select pg_temp.ok('log_book_click: SECURITY DEFINER, search_path public, pg_temp',
  (select prosecdef and array_to_string(proconfig, ',') = 'search_path=public, pg_temp' from pg_proc where oid = 'public.log_book_click(text)'::regprocedure));
select pg_temp.ok('execute: authenticated yes, anon no, PUBLIC no',
  has_function_privilege('authenticated', 'public.log_book_click(text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.log_book_click(text)', 'EXECUTE')
  and not exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where p.oid = 'public.log_book_click(text)'::regprocedure and a.grantee = 0));
select pg_temp.ok('book_clicks: RLS on, no grants, columns unchanged',
  (select relrowsecurity from pg_class where oid = 'private.book_clicks'::regclass)
  and not exists (select 1 from information_schema.role_table_grants where table_schema = 'private' and table_name = 'book_clicks' and grantee in ('anon', 'authenticated', 'PUBLIC'))
  and (select array_agg(column_name::text order by ordinal_position) from information_schema.columns where table_schema = 'private' and table_name = 'book_clicks') = array['link_key', 'day', 'clicks']);
set local role anon;
select pg_temp.raises('anon paywall click denied', 'select public.log_book_click(''paywall'')', 'permission denied');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select pg_temp.raises('no uid -> not_authenticated', 'select public.log_book_click(''paywall'')', 'not_authenticated');
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select public.log_book_click('paywall'); select public.log_book_click('paywall'); select public.log_book_click('card'); select public.log_book_click('settings');
select pg_temp.raises('unknown key still rejected', 'select public.log_book_click(''shop'')', 'bad_key');
reset role;
select pg_temp.ok('paywall counted separately (2), card 1, settings 1',
  (select jsonb_object_agg(link_key, clicks) from private.book_clicks) = '{"card": 1, "settings": 1, "paywall": 2}'::jsonb);
rollback;
