-- Checks for supabase_migration_v11_paywall.sql. Run on a scratch copy AFTER v10 + v11 (as postgres).
-- Everything is rolled back. Each check prints a NOTICE starting with PASS or FAIL.
\set ON_ERROR_STOP 0
begin;
insert into auth.users(id) values
 ('a1000000-0000-0000-0000-000000000011'),('b2000000-0000-0000-0000-000000000022'),('c3000000-0000-0000-0000-000000000033');
create temp table t_v(k text primary key, v text);
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
create or replace function pg_temp.as_user(p_uid text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true) $$;
grant execute on all functions in schema pg_temp to anon, authenticated;

-- 1) privileges / shape ---------------------------------------------------------------
select pg_temp.ok('v11 tables: no grants to anon/authenticated/PUBLIC',
  not exists (select 1 from information_schema.role_table_grants where table_schema = 'private'
              and table_name in ('paywall_config', 'couple_entitlements') and grantee in ('anon', 'authenticated', 'PUBLIC')));
select pg_temp.ok('v11 tables: RLS on', (select bool_and(relrowsecurity) from pg_class
  where oid in ('private.paywall_config'::regclass, 'private.couple_entitlements'::regclass)));
select pg_temp.ok('v11 tables: no policies', not exists (select 1 from pg_policies where schemaname = 'private'
  and tablename in ('paywall_config', 'couple_entitlements')));
select pg_temp.ok('anon cannot execute get_paywall_config / request_pay_code / my_report',
  not has_function_privilege('anon', 'public.get_paywall_config()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.request_pay_code()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.my_report()', 'EXECUTE'));
select pg_temp.ok('authenticated can execute the 3 v11 RPCs',
  has_function_privilege('authenticated', 'public.get_paywall_config()', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.request_pay_code()', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.my_report()', 'EXECUTE'));
select pg_temp.ok('anon/authenticated cannot execute set_couple_paid / paywall_on / new_pay_code',
  not has_function_privilege('authenticated', 'private.set_couple_paid(text,boolean,text,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'private.set_couple_paid(text,boolean,text,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'private.paywall_on()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'private.new_pay_code()', 'EXECUTE'));
select pg_temp.ok('v11 functions are SECURITY DEFINER with search_path pinned',
  (select bool_and(p.prosecdef and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))
   from pg_proc p where p.proname in ('get_paywall_config', 'request_pay_code', 'my_report', 'log_event',
     'paywall_on', 'new_pay_code', 'set_couple_paid')));
select pg_temp.ok('no v11 function reads secret_emotions or uses EXECUTE',
  not exists (select 1 from pg_proc where proname in ('get_paywall_config', 'request_pay_code', 'my_report', 'log_event',
    'paywall_on', 'new_pay_code', 'set_couple_paid') and (prosrc ilike '%secret_emotions%' or prosrc ~* '\mexecute\M')));

-- 2) flag defaults to OFF ---------------------------------------------------------------
select pg_temp.ok('config row exists, enabled=false, price/link/eta null',
  (select count(*) = 1 and bool_and(not enabled and price_krw is null and checkout_url is null and unlock_eta is null) from private.paywall_config));
select pg_temp.raises('second config row rejected', 'insert into private.paywall_config(id) values (false)', 'violates check');
select pg_temp.raises('http (not https) link rejected', 'update private.paywall_config set checkout_url = ''http://x.imweb.me/p''', 'violates check');
select pg_temp.raises('javascript: link rejected', 'update private.paywall_config set checkout_url = ''javascript:alert(1)''', 'violates check');
select pg_temp.raises('link with quote rejected', 'update private.paywall_config set checkout_url = ''https://a.b/"onx''', 'violates check');
select pg_temp.raises('unlock_eta with tag rejected', 'update private.paywall_config set unlock_eta = ''<b>x</b>''', 'violates check');
select pg_temp.raises('price 0 rejected', 'update private.paywall_config set price_krw = 0', 'violates check');

-- couple: U1 (A) creates, U2 (B) joins later. U3 outsider.
set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
insert into t_v select 'c1', public.create_couple('지수')->>'code';
select pg_temp.ok('flag off: get_paywall_config -> enabled false only', public.get_paywall_config() = '{"enabled": false}'::jsonb);
select pg_temp.ok('flag off: my_report -> enabled false only', public.my_report() = '{"enabled": false}'::jsonb);
select pg_temp.raises('flag off: request_pay_code -> paywall_off', 'select public.request_pay_code()', 'paywall_off');
select pg_temp.raises('authenticated cannot read private.paywall_config', 'select * from private.paywall_config', 'permission denied');
select pg_temp.raises('authenticated cannot call set_couple_paid', 'select private.set_couple_paid(''UR-AAAAAA'')', 'permission denied');
reset role;
update private.paywall_config set enabled = true;
set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('enabled but price/link/eta blank -> still off', public.get_paywall_config() = '{"enabled": false}'::jsonb
  and public.my_report() = '{"enabled": false}'::jsonb);
reset role;
update private.paywall_config set price_krw = 4900, checkout_url = 'https://example.imweb.me/shop_view/?idx=1';
set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('eta still blank -> still off', public.get_paywall_config() = '{"enabled": false}'::jsonb);
reset role;
update private.paywall_config set unlock_eta = '평일 밤 10시 전';
set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('all filled -> enabled with values', public.get_paywall_config() =
  '{"enabled": true, "price_krw": 4900, "checkout_url": "https://example.imweb.me/shop_view/?idx=1", "unlock_eta": "평일 밤 10시 전"}'::jsonb);
select pg_temp.ok('partner not joined -> partner_joined false, nothing else',
  public.my_report() = '{"enabled": true, "partner_joined": false}'::jsonb);
select pg_temp.raises('partner not joined -> request_pay_code refused', 'select public.request_pay_code()', 'partner_not_joined');
select pg_temp.as_user('b2000000-0000-0000-0000-000000000022');
select pg_temp.ok('U2 joins as B', public.join_couple((select v from t_v where k = 'c1'), '민준')->>'role' = 'B');
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('no missions -> ready false, no way_key, no report',
  (public.my_report()->>'ready')::boolean = false and public.my_report()->'way_key' = 'null'::jsonb and public.my_report()->'report' = 'null'::jsonb);
reset role;

-- missions: B accepted 2 행동형 missions from A, B sent A 2 연락 + 1 말투 missions. Secret row with a marker.
insert into public.daily_missions(id, couple_code, target_role, title, message, accepted, accepted_at) values
 ('t11-1', (select v from t_v where k = 'c1'), 'B', '말없이 5초 꼭 안아주기', '만나자마자 5초만 안아 주세요.', true, now()),
 ('t11-2', (select v from t_v where k = 'c1'), 'B', '함께 걷는 10분 산책', '오늘 저녁 잠깐 걸어요.', true, now()),
 ('t11-3', (select v from t_v where k = 'c1'), 'A', '점심 연락 한 번', '점심에 연락 한 번 먼저 해 주세요.', false, null),
 ('t11-4', (select v from t_v where k = 'c1'), 'A', '답장 먼저 보내기', '바빠도 답장 한 줄만요.', true, now()),
 ('t11-5', (select v from t_v where k = 'c1'), 'A', '말투 한 톤 낮추기', '오늘은 단답 대신 한 문장 더.', false, null);
insert into public.secret_emotions(couple_code, author_role, raw_text) values
 ((select v from t_v where k = 'c1'), 'B', 'SECRET_MARKER_XYZ 비밀 원문');

set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('A: ready, partner_name 민준, way_key penguin, unpaid, no pay_code, no report',
  (select (r->>'ready')::boolean and r->>'partner_name' = '민준' and r->>'way_key' = 'penguin'
     and not (r->>'paid')::boolean and r->'pay_code' = 'null'::jsonb and r->'report' = 'null'::jsonb from (select public.my_report() r) x));
select pg_temp.ok('A unpaid: no topics anywhere in the response', position('topics' in public.my_report()::text) = 0);
insert into t_v select 'code', public.request_pay_code()->>'pay_code';
select pg_temp.ok('pay code format UR-XXXXXX', (select v from t_v where k = 'code') ~ '^UR-[A-HJ-NP-Z2-9]{6}$');
select pg_temp.ok('A asks again -> same code', public.request_pay_code()->>'pay_code' = (select v from t_v where k = 'code'));
select pg_temp.as_user('b2000000-0000-0000-0000-000000000022');
select pg_temp.ok('B gets the same couple code', public.request_pay_code()->>'pay_code' = (select v from t_v where k = 'code'));
select pg_temp.ok('B report shows code, unpaid', (select r->>'pay_code' = (select v from t_v where k = 'code') and not (r->>'paid')::boolean from (select public.my_report() r) x));
select pg_temp.as_user('c3000000-0000-0000-0000-000000000033');
insert into t_v select 'c3', public.create_couple('다른')->>'code';
select pg_temp.ok('outsider: report is only about own couple (no partner, no code)',
  public.my_report() = '{"enabled": true, "partner_joined": false}'::jsonb);
select pg_temp.raises('outsider cannot get a pay code (not joined)', 'select public.request_pay_code()', 'partner_not_joined');
reset role;
select pg_temp.ok('one entitlement row for the couple only', (select count(*) = 1 from private.couple_entitlements));

-- admin unlock
select pg_temp.raises('set_couple_paid unknown code -> pay_code_not_found', 'select private.set_couple_paid(''UR-ZZZZZZ'')', 'pay_code_not_found');
select pg_temp.ok('admin marks paid (lowercase/space tolerant)',
  (private.set_couple_paid(' ' || lower((select v from t_v where k = 'code')), true, 'manual', 'imweb-1001')->>'report_paid')::boolean);
set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('A paid: topics [contact, tone] and mission_key contact',
  (select (r->>'paid')::boolean and r->'report'->'topics' = '["contact", "tone"]'::jsonb and r->'report'->>'mission_key' = 'contact'
   from (select public.my_report() r) x));
select pg_temp.ok('report has no mission text / no secret text',
  (select position('안아' in t) = 0 and position('연락 한 번' in t) = 0 and position('SECRET_MARKER' in t) = 0 and position('비밀 원문' in t) = 0
   from (select public.my_report()::text t) x));
select pg_temp.as_user('b2000000-0000-0000-0000-000000000022');
select pg_temp.ok('B paid too (one payment per couple); B view is about 지수',
  (select (r->>'paid')::boolean and r->>'partner_name' = '지수' from (select public.my_report() r) x));
select pg_temp.ok('B: A accepted nothing -> not ready, no report', (select not (r->>'ready')::boolean and r->'report' = 'null'::jsonb from (select public.my_report() r) x));
select pg_temp.ok('B report has no secret text', position('SECRET_MARKER' in public.my_report()::text) = 0);
select pg_temp.raises('authenticated still cannot read secret_emotions', 'select raw_text from public.secret_emotions', 'permission denied');
select pg_temp.raises('authenticated cannot read couple_entitlements', 'select * from private.couple_entitlements', 'permission denied');

-- log_event
select pg_temp.ok('new events accepted', public.log_event('paywall_view') and public.log_event('paywall_click')
  and public.log_event('report_teaser_view') and public.log_event('report_teaser_click') and public.log_event('paywall_checkout_open')
  and public.log_event('pay_code_copy') and public.log_event('report_view'));
select pg_temp.ok('v10 events still accepted', public.log_event('combo_view') and public.log_event('quiz_start'));
select pg_temp.ok('unknown event rejected', not public.log_event('paywall_hack'));
reset role;
select pg_temp.ok('paywall events stored with couple_code', (select count(*) = 7 from private.funnel_events
  where couple_code = (select v from t_v where k = 'c1') and (event like 'pay%' or event like 'report%')));

-- undo + flag off again
select pg_temp.ok('admin can undo paid', not (private.set_couple_paid((select v from t_v where k = 'code'), false)->>'report_paid')::boolean);
select pg_temp.ok('undo clears paid_at / source / ref', (select paid_at is null and paid_source is null and payment_ref is null from private.couple_entitlements));
update private.paywall_config set enabled = false;
set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('flag off again -> my_report enabled false only (code hidden)', public.my_report() = '{"enabled": false}'::jsonb);
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.raises('anon get_paywall_config denied', 'select public.get_paywall_config()', 'permission denied');
select pg_temp.raises('anon my_report denied', 'select public.my_report()', 'permission denied');
reset role;
rollback;
