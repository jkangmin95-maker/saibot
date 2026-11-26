-- Checks for supabase_migration_v11_1_imweb.sql. Run on a scratch copy AFTER v10 + v11 + v11.1 (as postgres).
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
grant execute on all functions in schema pg_temp to anon, authenticated, service_role;
create temp table t_v(k text primary key, v text);
grant all on t_v to service_role;

-- 1) privileges / shape -----------------------------------------------------------------------------
select pg_temp.ok('v11.1 tables: no grants to anon/authenticated/service_role/PUBLIC',
  not exists (select 1 from information_schema.role_table_grants where table_schema = 'private'
    and table_name in ('imweb_oauth', 'imweb_order_items') and grantee in ('anon', 'authenticated', 'service_role', 'PUBLIC')));
select pg_temp.ok('v11.1 tables: RLS on, no policies',
  (select bool_and(relrowsecurity) from pg_class where oid in ('private.imweb_oauth'::regclass, 'private.imweb_order_items'::regclass))
  and not exists (select 1 from pg_policies where schemaname = 'private' and tablename like 'imweb%'));
select pg_temp.ok('poller RPCs: service_role only',
  (select bool_and(has_function_privilege('service_role', f, 'EXECUTE')
     and not has_function_privilege('anon', f, 'EXECUTE') and not has_function_privilege('authenticated', f, 'EXECUTE'))
   from unnest(array['public.imweb_poll_lease(integer)', 'public.imweb_poll_save_tokens(uuid,text,text,text)',
     'public.imweb_poll_apply(uuid,bigint,text,text,text)', 'public.imweb_poll_finish(uuid,text)']) f));
select pg_temp.ok('PUBLIC has no EXECUTE on poller RPCs', not exists (
  select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  where p.proname like 'imweb_poll_%' and a.grantee = 0 and a.privilege_type = 'EXECUTE'));
select pg_temp.ok('imweb_seed_tokens / set_couple_paid: not executable by API roles',
  not has_function_privilege('service_role', 'private.imweb_seed_tokens(text,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'private.imweb_seed_tokens(text,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'private.imweb_seed_tokens(text,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'private.set_couple_paid(text,boolean,text,text)', 'EXECUTE'));
select pg_temp.ok('all v11.1 functions SECURITY DEFINER with pinned search_path',
  (select count(*) = 5 and bool_and(prosecdef and exists (select 1 from unnest(proconfig) c where c like 'search_path=%'))
   from pg_proc where proname in ('imweb_poll_lease', 'imweb_poll_save_tokens', 'imweb_poll_apply', 'imweb_poll_finish', 'imweb_seed_tokens')));
select pg_temp.ok('paid_source accepts imweb', (select pg_get_constraintdef(oid) like '%imweb%' from pg_constraint
  where conname = 'couple_entitlements_paid_source_check'));

-- service_role cannot read tokens / order log directly
set local role service_role;
select pg_temp.raises('service_role cannot select imweb_oauth', 'select * from private.imweb_oauth', 'permission denied');
select pg_temp.raises('service_role cannot select imweb_order_items', 'select * from private.imweb_order_items', 'permission denied');
select pg_temp.raises('service_role cannot seed tokens', 'select private.imweb_seed_tokens(''a'', ''b'')', 'permission denied');
select pg_temp.ok('not seeded -> lease null', public.imweb_poll_lease() is null);
reset role;
set local role authenticated;
select pg_temp.raises('authenticated cannot take the lease', 'select public.imweb_poll_lease()', 'permission denied');
reset role;
set local role anon;
select pg_temp.raises('anon cannot apply', 'select public.imweb_poll_apply(null, 1, ''x'', ''paid'', ''UR-AAAAAA'')', 'permission denied');
reset role;

-- 2) fixtures: two couples with codes -----------------------------------------------------------------
insert into public.couples(code) values ('T1CPL'), ('T2CPL');
insert into private.couple_entitlements(couple_code, pay_code) values ('T1CPL', 'UR-ABC234'), ('T2CPL', 'UR-XYZ789');
select pg_temp.raises('seed needs a refresh token', 'select private.imweb_seed_tokens(''a'', '''')', 'refresh_token_required');
select pg_temp.ok('owner seeds tokens', private.imweb_seed_tokens('acc-0', 'ref-0'));
select pg_temp.ok('seed again', private.imweb_seed_tokens('acc-1', 'ref-1'));
select pg_temp.ok('seed again replaces the pair (one row)', (select count(*) = 1 and bool_and(refresh_token = 'ref-1') from private.imweb_oauth));

-- 3) lease ---------------------------------------------------------------------------------------------
set local role service_role;
insert into t_v select 'lease', (public.imweb_poll_lease())->>'lease';
select pg_temp.ok('lease returns tokens', (select v is not null from t_v where k = 'lease'));
select pg_temp.ok('second lease while held -> null', public.imweb_poll_lease() is null);
select pg_temp.ok('apply with wrong lease -> no_lease',
  public.imweb_poll_apply(gen_random_uuid(), 1001, 'OI1001', 'paid', 'UR-ABC234') = 'no_lease');

-- 4) token CAS ----------------------------------------------------------------------------------------
select pg_temp.ok('save with stale refresh token -> false',
  not public.imweb_poll_save_tokens((select v::uuid from t_v where k = 'lease'), 'ref-0', 'acc-x', 'ref-x'));
select pg_temp.ok('save with current refresh token -> true',
  public.imweb_poll_save_tokens((select v::uuid from t_v where k = 'lease'), 'ref-1', 'acc-2', 'ref-2'));
select pg_temp.ok('save with wrong lease -> false',
  not public.imweb_poll_save_tokens(gen_random_uuid(), 'ref-2', 'acc-3', 'ref-3'));
select pg_temp.ok('save without new refresh keeps the old one',
  public.imweb_poll_save_tokens((select v::uuid from t_v where k = 'lease'), 'ref-2', 'acc-4', null));
reset role;
select pg_temp.ok('stored pair is acc-4 / ref-2', (select access_token = 'acc-4' and refresh_token = 'ref-2' from private.imweb_oauth));
set local role service_role;

-- 5) apply: paid / duplicate / unknown / no_code / bad input --------------------------------------------
create or replace function pg_temp.ap(p_order bigint, p_item text, p_action text, p_code text) returns text language sql as $$
  select public.imweb_poll_apply((select v::uuid from t_v where k = 'lease'), p_order, p_item, p_action, p_code) $$;
grant execute on function pg_temp.ap(bigint, text, text, text) to service_role;
select pg_temp.ok('paid -> unlocked', pg_temp.ap(1001, 'OI1001', 'paid', ' ur-abc234 ') = 'unlocked');
reset role;
select pg_temp.ok('entitlement paid, source imweb, ref = orderNo',
  (select report_paid and paid_source = 'imweb' and payment_ref = '1001' and paid_at is not null
   from private.couple_entitlements where pay_code = 'UR-ABC234'));
insert into t_v select 'paid_at', paid_at::text from private.couple_entitlements where pay_code = 'UR-ABC234';
set local role service_role;
select pg_temp.ok('same paid again -> unchanged (duplicate)', pg_temp.ap(1001, 'OI1001', 'paid', 'UR-ABC234') = 'unchanged');
select pg_temp.ok('unknown code -> unknown_code', pg_temp.ap(1002, 'OI1002', 'paid', 'UR-ZZZZZZ') = 'unknown_code');
select pg_temp.ok('unknown code again -> unchanged', pg_temp.ap(1002, 'OI1002', 'paid', 'UR-ZZZZZZ') = 'unchanged');
select pg_temp.ok('no_code -> no_code, then unchanged',
  pg_temp.ap(1003, 'OI1003', 'no_code', null) = 'no_code' and pg_temp.ap(1003, 'OI1003', 'no_code', null) = 'unchanged');
select pg_temp.ok('no_code on a paid item never downgrades it', pg_temp.ap(1001, 'OI1001', 'no_code', null) = 'unchanged');
select pg_temp.ok('bad code format -> bad_input', pg_temp.ap(1004, 'OI1004', 'paid', 'UR-AB''; --') = 'bad_input');
select pg_temp.ok('bad action -> bad_input', pg_temp.ap(1004, 'OI1004', 'delete', 'UR-ABC234') = 'bad_input');
select pg_temp.ok('paid without code -> bad_input', pg_temp.ap(1004, 'OI1004', 'paid', null) = 'bad_input');
select pg_temp.ok('order_no 0 -> bad_input', pg_temp.ap(0, 'x', 'paid', 'UR-ABC234') = 'bad_input');
reset role;
select pg_temp.ok('other couple untouched', (select not report_paid from private.couple_entitlements where pay_code = 'UR-XYZ789'));
select pg_temp.ok('unknown/no_code/bad input changed no entitlement',
  (select count(*) = 1 from private.couple_entitlements where report_paid));
set local role service_role;

-- 6) revoke rules ---------------------------------------------------------------------------------------
select pg_temp.ok('revoke for an order never seen paid -> recorded, couple stays paid',
  pg_temp.ap(1005, 'OI1005', 'revoke', 'UR-ABC234') = 'recorded');
reset role;
select pg_temp.ok('... still paid via 1001', (select report_paid and payment_ref = '1001' from private.couple_entitlements where pay_code = 'UR-ABC234'));
set local role service_role;
select pg_temp.ok('second paid order for same code -> unlocked (ref moves to 1006)', pg_temp.ap(1006, 'OI1006', 'paid', 'UR-ABC234') = 'unlocked');
reset role;
select pg_temp.ok('paid_at kept from first payment', (select paid_at::text = (select v from t_v where k = 'paid_at') and payment_ref = '1006'
  from private.couple_entitlements where pay_code = 'UR-ABC234'));
set local role service_role;
select pg_temp.ok('refund 1006 while 1001 still paid -> repointed', pg_temp.ap(1006, 'OI1006', 'revoke', null) = 'repointed');
reset role;
select pg_temp.ok('... still paid, ref back to 1001', (select report_paid and payment_ref = '1001' from private.couple_entitlements where pay_code = 'UR-ABC234'));
set local role service_role;
select pg_temp.ok('refund 1001 -> revoked', pg_temp.ap(1001, 'OI1001', 'revoke', 'UR-ABC234') = 'revoked');
reset role;
select pg_temp.ok('... couple locked, paid fields cleared', (select not report_paid and paid_at is null and paid_source is null and payment_ref is null
  from private.couple_entitlements where pay_code = 'UR-ABC234'));
set local role service_role;
select pg_temp.ok('refund again -> unchanged', pg_temp.ap(1001, 'OI1001', 'revoke', 'UR-ABC234') = 'unchanged');
select pg_temp.ok('cancel request rejected -> paid again -> unlocked', pg_temp.ap(1001, 'OI1001', 'paid', 'UR-ABC234') = 'unlocked');
reset role;
-- manual unlock of couple 2 is not undone by an imweb refund of an order that did not unlock it
select private.set_couple_paid('UR-XYZ789', true, 'manual', 'admin');
set local role service_role;
select pg_temp.ok('paid order for manually-unlocked code -> unlocked (source imweb)', pg_temp.ap(1007, 'OI1007', 'paid', 'UR-XYZ789') = 'unlocked');
reset role;
select private.set_couple_paid('UR-XYZ789', true, 'manual', 'admin-again');
set local role service_role;
select pg_temp.ok('refund of 1007 after a later manual unlock -> recorded (manual kept)', pg_temp.ap(1007, 'OI1007', 'revoke', null) = 'recorded');
reset role;
select pg_temp.ok('... couple 2 still paid manually', (select report_paid and paid_source = 'manual' from private.couple_entitlements where pay_code = 'UR-XYZ789'));
select pg_temp.ok('order log holds only order no / item / code / state', (select count(*) = 6 from private.imweb_order_items)
  and (select array_agg(column_name::text order by ordinal_position) = array['order_no','item_key','pay_code','state','first_seen_at','updated_at']
       from information_schema.columns where table_schema = 'private' and table_name = 'imweb_order_items'));

-- 7) finish ---------------------------------------------------------------------------------------------
set local role service_role;
select pg_temp.ok('finish with bad status text is sanitized', public.imweb_poll_finish((select v::uuid from t_v where k = 'lease'), 'Bad <x>'));
reset role;
select pg_temp.ok('... lease cleared, status invalid_status', (select lease_id is null and last_status = 'invalid_status' and last_ok_at is null from private.imweb_oauth));
set local role service_role;
insert into t_v select 'lease2', (public.imweb_poll_lease())->>'lease';
select pg_temp.ok('lease can be taken again after finish', (select v is not null from t_v where k = 'lease2'));
select pg_temp.ok('apply with released old lease -> no_lease', pg_temp.ap(1008, 'OI1008', 'paid', 'UR-ABC234') = 'no_lease');
select pg_temp.ok('finish ok sets last_ok_at', public.imweb_poll_finish((select v::uuid from t_v where k = 'lease2'), 'ok'));
reset role;
select pg_temp.ok('... last_ok_at set', (select last_ok_at is not null and last_status = 'ok' from private.imweb_oauth));
-- expired lease can be stolen
update private.imweb_oauth set lease_id = gen_random_uuid(), lease_until = now() - interval '1 second';
set local role service_role;
select pg_temp.ok('expired lease can be taken over', public.imweb_poll_lease() is not null);
reset role;
select pg_temp.raises('paid_source check still rejects junk', 'update private.couple_entitlements set paid_source = ''stripe''', 'violates check');
rollback;
