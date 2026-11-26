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
     'paywall_on', 'new_pay_code', 'set_couple_paid', 'consent_secret_report', 'record_secret_topic', 'secret_topic', 'sai_chat')));
select pg_temp.ok('no v11 function (incl. sai_chat) reads secret_emotions or uses EXECUTE',
  not exists (select 1 from pg_proc where proname in ('get_paywall_config', 'request_pay_code', 'my_report', 'log_event',
    'paywall_on', 'new_pay_code', 'set_couple_paid', 'consent_secret_report', 'record_secret_topic', 'secret_topic', 'sai_chat')
    and (prosrc ilike '%secret_emotions%' or prosrc ~* '\mexecute\M')));

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
  '{"enabled": true, "price_krw": 4900, "checkout_url": "https://example.imweb.me/shop_view/?idx=1", "unlock_eta": "평일 밤 10시 전", "report_consent": false}'::jsonb);
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
  (private.set_couple_paid(' ' || lower((select v from t_v where k = 'code')), true, 'manual', 'imweb-1001')->>'paid')::boolean);
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


-- 4) 속마음 리포트: consent, write-time topic keys, thresholds, no raw text ----------------------
-- Gemini stand-in: record the request body, answer 500 (rolled back with everything else; fake key)
insert into vault.secrets(name, secret) values ('urisai_gemini_api_key', 'local-fake-key');
create temp table t_http(n serial, body text);
grant all on t_http to anon, authenticated;
grant usage, select on sequence t_http_n_seq to anon, authenticated;
create or replace function extensions.http(r extensions.http_request) returns extensions.http_response language plpgsql as $$
begin insert into pg_temp.t_http(body) values (r.content); return (500, 'application/json', null, '{}')::extensions.http_response; end $$;
create or replace function pg_temp.chat(p_code text, p_text text) returns jsonb language sql as $$
  select public.sai_chat(p_code, jsonb_build_array(jsonb_build_object('role', 'user', 'text', p_text))) $$;
create or replace function pg_temp.last_sys() returns text language sql as $$
  select body::jsonb #>> '{systemInstruction,parts,0,text}' from pg_temp.t_http order by n desc limit 1 $$;
create or replace function pg_temp.tags(p_uid text) returns integer language sql as $$
  select count(*)::integer from private.secret_topic_tags where author_user = p_uid::uuid $$;
grant execute on all functions in schema pg_temp to anon, authenticated;

select pg_temp.ok('v11 secret tables: no grants, RLS on, no policies',
  not exists (select 1 from information_schema.role_table_grants where table_schema = 'private'
              and table_name in ('secret_report_consents', 'secret_topic_tags') and grantee in ('anon', 'authenticated', 'PUBLIC'))
  and (select bool_and(relrowsecurity) from pg_class where oid in ('private.secret_report_consents'::regclass, 'private.secret_topic_tags'::regclass))
  and not exists (select 1 from pg_policies where schemaname = 'private' and tablename in ('secret_report_consents', 'secret_topic_tags')));
select pg_temp.ok('secret_topic_tags has no text column (only id, couple_code, author_user, topic, created_at)',
  (select array_agg(column_name::text order by column_name::text) from information_schema.columns
   where table_schema = 'private' and table_name = 'secret_topic_tags') = array['author_user', 'couple_code', 'created_at', 'id', 'topic']);
select pg_temp.ok('consent_secret_report: authenticated only; record_secret_topic / secret_topic not callable by API roles',
  has_function_privilege('authenticated', 'public.consent_secret_report()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.consent_secret_report()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'private.record_secret_topic(text,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'private.record_secret_topic(text,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'private.secret_topic(text)', 'EXECUTE'));
select pg_temp.ok('sai_chat still SECURITY DEFINER, same search_path, authenticated only',
  (select prosecdef and proconfig @> array['search_path=public, vault, extensions'] from pg_proc where proname = 'sai_chat')
  and has_function_privilege('authenticated', 'public.sai_chat(text,jsonb)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.sai_chat(text,jsonb)', 'EXECUTE'));
select pg_temp.ok('keyword mapping: one fixed key per message, else default (same key as the app)',
  private.secret_topic('답장이 늦어서 서운해') = 'contact' and private.secret_topic('주말 데이트 계획은 맨날 나만 짜') = 'date'
  and private.secret_topic('유튜브만 봐') = 'phone' and private.secret_topic('말투가 차가워') = 'tone'
  and private.secret_topic('오늘 날씨 좋다') = 'default' and private.secret_topic(null) = 'default');
select pg_temp.raises('topic key other no longer accepted (one key: default)',
  'insert into private.secret_topic_tags(couple_code, author_user, topic) select code, user_a, ''other'' from public.couples limit 1', 'violates check');

-- flag ON, B has NOT confirmed yet: B's messages leave nothing
set local role authenticated;
select pg_temp.as_user('b2000000-0000-0000-0000-000000000022');
select pg_temp.chat((select v from t_v where k = 'c1'), '주말 데이트 계획 PRECONSENT_MARKER 매번 나만 짜');
select pg_temp.chat((select v from t_v where k = 'c1'), '데이트 코스도 맨날 나만 찾아');
select pg_temp.chat((select v from t_v where k = 'c1'), '약속도 맨날 내가 잡아');
select pg_temp.ok('flag ON: sai_chat system text = new sentence + consent/topic note, old sentence gone',
  (select position('여기 쓴 문장은 연인에게 절대 보이지 않아.' in s) > 0 and position('[확인했어요]를 누른 뒤에 쓴 글은' in s) > 0
     and position('주제' in s) > 0 and position('이 비밀방 대화는' in s) = 0 from (select pg_temp.last_sys() s) x));
reset role;
select pg_temp.ok('before [확인했어요]: no topic rows for B', pg_temp.tags('b2000000-0000-0000-0000-000000000022') = 0);

-- consent while the flag is OFF is ignored, and messages while OFF are never used
update private.paywall_config set enabled = false;
set local role authenticated;
select pg_temp.as_user('b2000000-0000-0000-0000-000000000022');
select pg_temp.ok('flag OFF: consent_secret_report -> enabled false only', public.consent_secret_report() = '{"enabled": false}'::jsonb);
reset role;
select pg_temp.ok('flag OFF: no consent row stored', not exists (select 1 from private.secret_report_consents));
update private.paywall_config set enabled = true;
set local role authenticated;
select pg_temp.as_user('b2000000-0000-0000-0000-000000000022');
select pg_temp.ok('flag ON: B confirms', public.consent_secret_report() = '{"enabled": true, "consented": true}'::jsonb);
select pg_temp.ok('B confirms again -> same answer (first time kept)', public.consent_secret_report() = '{"enabled": true, "consented": true}'::jsonb);
reset role;
update private.paywall_config set enabled = false;
set local role authenticated;
select pg_temp.as_user('b2000000-0000-0000-0000-000000000022');
select pg_temp.chat((select v from t_v where k = 'c1'), '데이트 계획 FLAGOFF_MARKER 맨날 나만');
select pg_temp.chat((select v from t_v where k = 'c1'), '주말 약속도 맨날 나만');
select pg_temp.chat((select v from t_v where k = 'c1'), '데이트 코스 또 나만');
select pg_temp.ok('flag OFF: sai_chat system text is the exact v9.1 sentence, no report note',
  (select position('지금 대화하는 사람은 ''나''이고, 이 비밀방 대화는 연인에게 절대 보이지 않아.' || E'\n' || '역할:' in s) > 0
     and position('[확인했어요]' in s) = 0 and position('리포트' in s) = 0 from (select pg_temp.last_sys() s) x));
reset role;
select pg_temp.ok('flag OFF: consented B messages leave nothing', pg_temp.tags('b2000000-0000-0000-0000-000000000022') = 0);
update private.paywall_config set enabled = true;
select pg_temp.ok('one consent row (B, c1), nothing for A', (select count(*) = 1 and bool_and(user_id = 'b2000000-0000-0000-0000-000000000022')
  from private.secret_report_consents));

-- rows that pre-date B's consent (planted by admin) must never be used
insert into private.secret_topic_tags(couple_code, author_user, topic, created_at)
  select (select v from t_v where k = 'c1'), 'b2000000-0000-0000-0000-000000000022', 'affection', now() - interval '2 days' from generate_series(1, 5);

-- flag ON + consented: B writes 2 date messages -> still below the 3-entry minimum
set local role authenticated;
select pg_temp.as_user('b2000000-0000-0000-0000-000000000022');
select pg_temp.chat((select v from t_v where k = 'c1'), '주말 데이트 계획 SECRET_CHAT_MARKER 매번 나만 짜서 서운해');
select pg_temp.chat((select v from t_v where k = 'c1'), '데이트 코스도 맨날 나만 찾아');
reset role;
select pg_temp.ok('after consent: B messages stored as keys (2 date)', (select count(*) = 2 and bool_and(topic = 'date')
  from private.secret_topic_tags where author_user = 'b2000000-0000-0000-0000-000000000022' and created_at >= now()));
select pg_temp.ok('no raw text stored anywhere in the topic table',
  not exists (select 1 from private.secret_topic_tags t where row_to_json(t)::text ~ 'MARKER|데이트|서운'));
set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('A paid, B has 2 consented entries (< 3): topics are missions only, pre-consent affection ignored',
  public.my_report()->'report'->'topics' = '["contact", "tone"]'::jsonb);
select pg_temp.ok('B has 2 consented entries: posts_ready false (pay gate line)', (public.my_report()->>'posts_ready')::boolean = false);
reset role;
select pg_temp.ok('... no snapshot yet', not exists (select 1 from private.report_snapshots));
set local role authenticated;
select pg_temp.as_user('b2000000-0000-0000-0000-000000000022');
select pg_temp.chat((select v from t_v where k = 'c1'), '유튜브만 보고 있어');
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('3rd entry: conditions met (3 entries, date x2) -> first report uses 비밀방 keys right away',
  public.my_report()->'report'->'topics' = '["contact", "date", "tone"]'::jsonb and (public.my_report()->>'posts_ready')::boolean);
reset role;
select pg_temp.ok('... and it is frozen for A (one snapshot row, keys only)',
  (select count(*) = 1 and bool_and(viewer_user = 'a1000000-0000-0000-0000-000000000011' and topics = '["contact", "date", "tone"]'::jsonb)
   from private.report_snapshots));
update private.secret_topic_tags set created_at = created_at - interval '1 day'
  where author_user = 'b2000000-0000-0000-0000-000000000022' and created_at >= now();
update private.secret_report_consents set consented_at = consented_at - interval '1 day'
  where user_id = 'b2000000-0000-0000-0000-000000000022';
set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('B has 3 consented entries: date (2) joins TOP 3, phone (1 < 2) and affection (pre-consent) do not',
  public.my_report()->'report'->'topics' = '["contact", "date", "tone"]'::jsonb);
select pg_temp.ok('A report: keys only, no counts, no raw text, no markers',
  (select position('MARKER' in t) = 0 and position('유튜브' in t) = 0 and position('서운해' in t) = 0 and position('"n"' in t) = 0
     and jsonb_typeof(r->'report'->'topics'->0) = 'string' from (select public.my_report() r, public.my_report()::text t) x));
select pg_temp.ok('A report keys unchanged (no new fields leak)', (select array_agg(k order by k) from jsonb_object_keys(public.my_report()) k)
  = array['enabled', 'paid', 'partner_joined', 'partner_name', 'pay_code', 'posts_ready', 'ready', 'report', 'way_key']
  and (select array_agg(k order by k) from jsonb_object_keys(public.my_report()->'report') k) = array['mission_key', 'topics']);
-- A's own messages count only for B's view, never for A's
select pg_temp.ok('A confirms', (public.consent_secret_report()->>'consented')::boolean);
select pg_temp.chat((select v from t_v where k = 'c1'), '말투가 차가워 A_MARKER');
select pg_temp.chat((select v from t_v where k = 'c1'), '단답만 해');
select pg_temp.chat((select v from t_v where k = 'c1'), '짜증 섞인 말투');
select pg_temp.ok('A own tone messages do not change A view', public.my_report()->'report'->'topics' = '["contact", "date", "tone"]'::jsonb);
-- partner can't get raw text through any path
select pg_temp.as_user('b2000000-0000-0000-0000-000000000022');
select pg_temp.ok('B views: my_report / consent / config contain no raw text',
  (select position('MARKER' in t) = 0 and position('차가워' in t) = 0 and position('단답' in t) = 0
   from (select public.my_report()::text || public.consent_secret_report()::text || public.get_paywall_config()::text t) x));
select pg_temp.raises('B cannot read secret_topic_tags', 'select * from private.secret_topic_tags', 'permission denied');
select pg_temp.raises('B cannot read secret_report_consents', 'select * from private.secret_report_consents', 'permission denied');
select pg_temp.raises('B cannot call record_secret_topic', 'select private.record_secret_topic(''x'', ''y'')', 'permission denied');
select pg_temp.raises('B cannot read secret_emotions', 'select raw_text from public.secret_emotions', 'permission denied');
-- outsider: consent goes to own couple only; chatting with someone else's code stores nothing
select pg_temp.as_user('c3000000-0000-0000-0000-000000000033');
select pg_temp.ok('outsider confirms (own couple)', (public.consent_secret_report()->>'consented')::boolean);
select pg_temp.ok('outsider sai_chat on c1 code -> null', pg_temp.chat((select v from t_v where k = 'c1'), '연락 연락 연락') is null);
reset role;
select pg_temp.ok('outsider: consent row is for own couple, no topic rows on c1',
  (select couple_code = (select v from t_v where k = 'c3') from private.secret_report_consents where user_id = 'c3000000-0000-0000-0000-000000000033')
  and not exists (select 1 from private.secret_topic_tags where author_user = 'c3000000-0000-0000-0000-000000000033'));
select pg_temp.ok('topic rows: B 3 consented (+5 planted pre-consent), A 3; nothing from flag-off or pre-consent chats',
  pg_temp.tags('b2000000-0000-0000-0000-000000000022') = 8 and pg_temp.tags('a1000000-0000-0000-0000-000000000011') = 3
  and (select count(*) = 5 from private.secret_topic_tags where created_at < now() - interval '36 hours'));
-- unpaid couple: no topics at all
select private.set_couple_paid((select v from t_v where k = 'code'), false);
set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('unpaid again: no topics anywhere', position('topics' in public.my_report()::text) = 0);
reset role;
select private.set_couple_paid((select v from t_v where k = 'code'), true);

-- 5) weekly refresh, withdraw, 30-day pass, AI cap (v11 owner decisions 2026-11-26) -----------------------------
-- weekly: B writes 3 more tone + 2 affection; A's frozen report does not move until the snapshot is 7 days old
set local role authenticated;
select pg_temp.as_user('b2000000-0000-0000-0000-000000000022');
select pg_temp.chat((select v from t_v where k = 'c1'), '말투가 너무 차가워');
select pg_temp.chat((select v from t_v where k = 'c1'), '단답만 해서 서운');
select pg_temp.chat((select v from t_v where k = 'c1'), '짜증 섞인 말투');
select pg_temp.chat((select v from t_v where k = 'c1'), '표현을 안 해');
select pg_temp.chat((select v from t_v where k = 'c1'), '애정 표현이 부족해');
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('weekly: new 비밀방 keys within 7 days do not change A report',
  public.my_report()->'report'->'topics' = '["contact", "date", "tone"]'::jsonb);
reset role;
update private.report_snapshots set made_at = now() - interval '6 days 23 hours';
set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('weekly: snapshot 6d23h old -> still frozen', public.my_report()->'report'->'topics' = '["contact", "date", "tone"]'::jsonb);
reset role;
update private.report_snapshots set made_at = now() - interval '7 days';
set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('weekly: snapshot 7 days old -> recomputed (tone 1+3=4, then the 2s in key order: contact, affection)',
  public.my_report()->'report'->'topics' = '["tone", "contact", "affection"]'::jsonb);
reset role;
select pg_temp.ok('... and frozen again from now', (select made_at = now() and topics = '["tone", "contact", "affection"]'::jsonb
  from private.report_snapshots where viewer_user = 'a1000000-0000-0000-0000-000000000011'));

-- withdraw consent (B turns [확인했어요] off)
select pg_temp.ok('withdraw_secret_report: authenticated only',
  has_function_privilege('authenticated', 'public.withdraw_secret_report()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.withdraw_secret_report()', 'EXECUTE'));
set local role authenticated;
select pg_temp.as_user('b2000000-0000-0000-0000-000000000022');
select pg_temp.ok('B config says report_consent true before withdrawing', (public.get_paywall_config()->>'report_consent')::boolean);
select pg_temp.ok('B withdraws', public.withdraw_secret_report() = '{"consented": false}'::jsonb);
select pg_temp.ok('B config says report_consent false', (public.get_paywall_config()->>'report_consent')::boolean = false);
select pg_temp.chat((select v from t_v where k = 'c1'), '연락이 없어 WITHDRAWN_MARKER');
select pg_temp.chat((select v from t_v where k = 'c1'), '답장이 늦어');
select pg_temp.chat((select v from t_v where k = 'c1'), '카톡 읽씹');
reset role;
select pg_temp.ok('after withdraw: B consent gone, B consented keys gone (planted pre-consent rows only), no new keys',
  not exists (select 1 from private.secret_report_consents where user_id = 'b2000000-0000-0000-0000-000000000022')
  and pg_temp.tags('b2000000-0000-0000-0000-000000000022') = 0);
select pg_temp.ok('after withdraw: A frozen report built on B keys deleted, A own consent untouched',
  not exists (select 1 from private.report_snapshots where viewer_user = 'a1000000-0000-0000-0000-000000000011')
  and exists (select 1 from private.secret_report_consents where user_id = 'a1000000-0000-0000-0000-000000000011'));
set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('after withdraw: A sees missions only, posts_ready false',
  public.my_report()->'report'->'topics' = '["contact", "tone"]'::jsonb and (public.my_report()->>'posts_ready')::boolean = false);
select pg_temp.as_user('b2000000-0000-0000-0000-000000000022');
select pg_temp.ok('B confirms again', (public.consent_secret_report()->>'consented')::boolean);
select pg_temp.chat((select v from t_v where k = 'c1'), '데이트 계획 맨날 나만');
reset role;
select pg_temp.ok('re-confirm: only posts after it are kept', pg_temp.tags('b2000000-0000-0000-0000-000000000022') = 1);
set local role authenticated;
select pg_temp.as_user('c3000000-0000-0000-0000-000000000033');
select pg_temp.ok('outsider withdraw touches only own couple', public.withdraw_secret_report() = '{"consented": false}'::jsonb);
reset role;
select pg_temp.ok('... B and A consents still there', (select count(*) = 2 from private.secret_report_consents
  where couple_code = (select v from t_v where k = 'c1')));

-- 30-day pass
select pg_temp.ok('v11 pass tables: no grants, RLS on, no policies',
  not exists (select 1 from information_schema.role_table_grants where table_schema = 'private'
              and table_name in ('couple_passes', 'report_snapshots', 'secret_ai_usage') and grantee in ('anon', 'authenticated', 'PUBLIC'))
  and (select bool_and(relrowsecurity) from pg_class where oid in ('private.couple_passes'::regclass, 'private.report_snapshots'::regclass, 'private.secret_ai_usage'::regclass))
  and not exists (select 1 from pg_policies where schemaname = 'private' and tablename in ('couple_passes', 'report_snapshots', 'secret_ai_usage')));
select pg_temp.ok('helper functions not callable by API roles',
  not has_function_privilege('authenticated', 'private.recompute_paid_until(text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'private.take_secret_ai_call()', 'EXECUTE')
  and not has_function_privilege('anon', 'private.take_secret_ai_call()', 'EXECUTE'));
select pg_temp.ok('couple_entitlements has paid_until, no report_paid', exists (select 1 from information_schema.columns
  where table_schema = 'private' and table_name = 'couple_entitlements' and column_name = 'paid_until')
  and not exists (select 1 from information_schema.columns where table_schema = 'private' and table_name = 'couple_entitlements' and column_name = 'report_paid'));
select private.set_couple_paid((select v from t_v where k = 'code'), false);
create or replace function pg_temp.until() returns timestamptz language sql as $$ select paid_until from private.couple_entitlements
  where pay_code = (select v from pg_temp.t_v where k = 'code') $$;
select pg_temp.ok('lock now: paid_until null', pg_temp.until() is null);
select pg_temp.ok('manual unlock -> paid, paid_until = now + 30 days',
  (private.set_couple_paid((select v from t_v where k = 'code'))->>'paid')::boolean and pg_temp.until() = now() + interval '30 days');
select private.set_couple_paid((select v from t_v where k = 'code'), true, 'portone', 'ORD-1');
select pg_temp.ok('second order stacks: now + 60 days', pg_temp.until() = now() + interval '60 days');
select private.set_couple_paid((select v from t_v where k = 'code'), true, 'portone', 'ORD-1');
select pg_temp.ok('same source + ref again is a no-op', pg_temp.until() = now() + interval '60 days'
  and (select count(*) = 1 from private.couple_passes where ref = 'ORD-1'));
select pg_temp.ok('refund of ORD-1 takes back its 30 days only',
  (private.set_couple_paid((select v from t_v where k = 'code'), false, 'portone', 'ORD-1')->>'paid')::boolean
  and pg_temp.until() = now() + interval '30 days');
select pg_temp.ok('admin view shows the newest active pass (manual)', (select paid_source = 'manual' and payment_ref is null
  from private.couple_entitlements where pay_code = (select v from t_v where k = 'code')));
select pg_temp.ok('refund of an unknown ref changes nothing', (private.set_couple_paid((select v from t_v where k = 'code'), false, 'portone', 'NOPE')->>'paid')::boolean
  and pg_temp.until() = now() + interval '30 days');
-- replay: P1 40 days ago (ended 10 days ago), P2 20 days ago (stacked: ends in 20 days), P3 now (stacked: ends in 50 days)
select private.set_couple_paid((select v from t_v where k = 'code'), false);
insert into private.couple_passes(couple_code, source, ref, paid_at) values
  ((select v from t_v where k = 'c1'), 'portone', 'P1', now() - interval '40 days'),
  ((select v from t_v where k = 'c1'), 'portone', 'P2', now() - interval '20 days');
select private.recompute_paid_until((select v from t_v where k = 'c1'));
select pg_temp.ok('replay: P1 (-40d) + P2 (-20d) -> ends in 20 days', pg_temp.until() = now() + interval '20 days');
select private.set_couple_paid((select v from t_v where k = 'code'), true, 'portone', 'P3');
select pg_temp.ok('P3 now stacks -> ends in 50 days', pg_temp.until() = now() + interval '50 days');
select private.set_couple_paid((select v from t_v where k = 'code'), false, 'portone', 'P1');
select pg_temp.ok('refund P1 -> P2 alone ends in 10 days, P3 stacks -> 40 days', pg_temp.until() = now() + interval '40 days');
select private.set_couple_paid((select v from t_v where k = 'code'), false, 'portone', 'P3');
select pg_temp.ok('refund P3 too -> 10 days left', pg_temp.until() = now() + interval '10 days');
select private.set_couple_paid((select v from t_v where k = 'code'), true, 'portone', 'P3');
select pg_temp.ok('re-paid P3 (same ref) comes back -> 40 days', pg_temp.until() = now() + interval '40 days'
  and (select count(*) = 1 from private.couple_passes where ref = 'P3'));
-- expiry
select private.set_couple_paid((select v from t_v where k = 'code'), false);
insert into private.couple_passes(couple_code, source, paid_at) values ((select v from t_v where k = 'c1'), 'manual', now() - interval '30 days');
select private.recompute_paid_until((select v from t_v where k = 'c1'));
set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('pass bought exactly 30 days ago: expired -> unpaid, no topics, code kept',
  (select not (r->>'paid')::boolean and r->'report' = 'null'::jsonb and position('topics' in r::text) = 0
     and r->>'pay_code' = (select v from t_v where k = 'code') from (select public.my_report() r) x)
  and (public.request_pay_code()->>'paid')::boolean = false);
reset role;
select private.set_couple_paid((select v from t_v where k = 'code'));
set local role authenticated;
select pg_temp.as_user('b2000000-0000-0000-0000-000000000022');
select pg_temp.ok('buy again after expiry -> now + 30 days, both members paid',
  (public.my_report()->>'paid')::boolean and (public.request_pay_code()->>'paid')::boolean);
reset role;
select pg_temp.ok('... paid_until = now + 30 days (expired pass does not stack)', pg_temp.until() = now() + interval '30 days');

-- 비밀방 AI cap (per user per KST day, one constant)
select pg_temp.ok('cap constant is 20', private.secret_ai_daily_cap() = 20);
reset role;
update private.secret_ai_usage set call_count = 19 where user_id = 'a1000000-0000-0000-0000-000000000011';
select pg_temp.ok('A usage row is keyed by the KST day', exists (select 1 from private.secret_ai_usage
  where user_id = 'a1000000-0000-0000-0000-000000000011' and day = (timezone('Asia/Seoul', now()))::date));
insert into t_v select 'http_before', (select count(*) from t_http);
set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('20th call of the day still goes to Gemini (stub -> null)', pg_temp.chat((select v from t_v where k = 'c1'), '연락이 늦어 서운해') is null);
insert into t_v select 'http_20', (select count(*) from t_http);
select pg_temp.ok('21st call -> {"capped": true} exactly', pg_temp.chat((select v from t_v where k = 'c1'), '말투가 차가워 CAP_MARKER') = '{"capped": true}'::jsonb);
select pg_temp.ok('generate_mission is capped too (null)', public.generate_mission('연락이 늦어 서운해', (select v from t_v where k = 'c1')) is null);
reset role;
select pg_temp.ok('capped calls make no Gemini request', (select count(*) from t_http) = (select v::bigint from t_v where k = 'http_20')
  and (select v::bigint from t_v where k = 'http_20') > (select v::bigint from t_v where k = 'http_before'));
select pg_temp.ok('capped call stores no topic key, user counter stays at 20', pg_temp.tags('a1000000-0000-0000-0000-000000000011') = 4
  and (select call_count = 20 from private.secret_ai_usage where user_id = 'a1000000-0000-0000-0000-000000000011'));
set local role authenticated;
select pg_temp.as_user('b2000000-0000-0000-0000-000000000022');
select pg_temp.ok('partner is not capped by A', pg_temp.chat((select v from t_v where k = 'c1'), '오늘 좀 서운했어') is distinct from '{"capped": true}'::jsonb);
reset role;
update private.paywall_config set enabled = false;
set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('cap applies with the paywall flag off too', pg_temp.chat((select v from t_v where k = 'c1'), '안녕') = '{"capped": true}'::jsonb);
reset role;
update private.paywall_config set enabled = true;
update private.secret_ai_usage set day = day - 1 where user_id = 'a1000000-0000-0000-0000-000000000011';
set local role authenticated;
select pg_temp.as_user('a1000000-0000-0000-0000-000000000011');
select pg_temp.ok('next KST day: A can talk again', pg_temp.chat((select v from t_v where k = 'c1'), '안녕') is distinct from '{"capped": true}'::jsonb);
reset role;
select pg_temp.ok('usage table holds only user / day / count', (select array_agg(column_name::text order by ordinal_position)
  = array['user_id', 'day', 'call_count'] from information_schema.columns where table_schema = 'private' and table_name = 'secret_ai_usage'));

-- undo + flag off again
select pg_temp.ok('admin can undo paid', not (private.set_couple_paid((select v from t_v where k = 'code'), false)->>'paid')::boolean);
select pg_temp.ok('undo clears paid_until / paid_at / source / ref', (select paid_until is null and paid_at is null and paid_source is null and payment_ref is null
  from private.couple_entitlements where pay_code = (select v from t_v where k = 'code')));
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
