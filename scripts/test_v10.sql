-- Checks for supabase_migration_v10_share_quiz.sql. Run on a scratch copy AFTER the migration (as postgres).
-- Everything is rolled back. Each check prints a NOTICE starting with PASS or FAIL.
\set ON_ERROR_STOP 0
begin;
insert into auth.users(id) values
 ('a1000000-0000-0000-0000-000000000001'),('b2000000-0000-0000-0000-000000000002'),('c3000000-0000-0000-0000-000000000003');

create temp table t_v(k text primary key, v text);
grant all on t_v to anon, authenticated;

create or replace function pg_temp.ok(p_label text, p_ok boolean) returns void language plpgsql as $$
begin raise notice '% %', case when p_ok then 'PASS' else 'FAIL' end, p_label; end $$;
-- expect a call to raise; p_expect is a substring of the error message
create or replace function pg_temp.raises(p_label text, p_sql text, p_expect text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise notice 'FAIL % (no error)', p_label;
exception when others then
  raise notice '% % (got: %)', case when position(p_expect in sqlerrm) > 0 then 'PASS' else 'FAIL' end, p_label, sqlerrm;
end $$;
grant execute on all functions in schema pg_temp to anon, authenticated;

-- 1) privileges -------------------------------------------------------------------
select pg_temp.ok('anon has no USAGE on schema private', not has_schema_privilege('anon', 'private', 'USAGE'));
select pg_temp.ok('authenticated has no USAGE on schema private', not has_schema_privilege('authenticated', 'private', 'USAGE'));
select pg_temp.ok('no table privilege for anon/authenticated on any private v10 table',
  not exists (select 1 from information_schema.role_table_grants
              where table_schema = 'private' and grantee in ('anon', 'authenticated', 'PUBLIC')));
select pg_temp.ok('RLS on for all v10 tables',
  (select bool_and(relrowsecurity) from pg_class where oid in ('private.share_consents'::regclass, 'private.quizzes'::regclass,
    'private.quiz_challenges'::regclass, 'private.anon_usage'::regclass, 'private.funnel_events'::regclass)));
select pg_temp.ok('no policies on v10 tables', not exists (select 1 from pg_policies where schemaname = 'private'
  and tablename in ('share_consents', 'quizzes', 'quiz_challenges', 'anon_usage', 'funnel_events')));
select pg_temp.ok('anon cannot execute consent RPCs',
  not has_function_privilege('anon', 'public.request_share_consent(text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.respond_share_consent(uuid,boolean)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.my_share_consent(text)', 'EXECUTE'));
select pg_temp.ok('anon can execute the 6 quiz/event RPCs',
  has_function_privilege('anon', 'public.create_quiz(text,text,integer[],text)', 'EXECUTE')
  and has_function_privilege('anon', 'public.get_quiz_for_guess(text)', 'EXECUTE')
  and has_function_privilege('anon', 'public.submit_quiz_guess(text,integer[])', 'EXECUTE')
  and has_function_privilege('anon', 'public.create_challenge(text)', 'EXECUTE')
  and has_function_privilege('anon', 'public.get_challenge_result(text)', 'EXECUTE')
  and has_function_privilege('anon', 'public.log_event(text)', 'EXECUTE'));
select pg_temp.ok('anon cannot execute private helpers',
  not has_function_privilege('anon', 'private.new_token()', 'EXECUTE')
  and not has_function_privilege('anon', 'private.bump_usage(text,integer)', 'EXECUTE'));
select pg_temp.ok('every v10 public RPC is SECURITY DEFINER with search_path set',
  (select bool_and(p.prosecdef and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('my_share_consent', 'request_share_consent', 'respond_share_consent',
     'create_quiz', 'get_quiz_for_guess', 'submit_quiz_guess', 'create_challenge', 'get_challenge_result', 'log_event')));

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.raises('anon select private.quizzes denied', 'select count(*) from private.quizzes', 'permission denied');
select pg_temp.raises('anon select private.share_consents denied', 'select count(*) from private.share_consents', 'permission denied');
select pg_temp.raises('anon select private.funnel_events denied', 'select count(*) from private.funnel_events', 'permission denied');
select pg_temp.raises('anon request_share_consent denied', 'select public.request_share_consent(''combo'')', 'permission denied');
select pg_temp.raises('anon secret_emotions still denied', 'select count(*) from public.secret_emotions', 'permission denied');
reset role;

-- 2) share consent ------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select pg_temp.raises('authenticated select private.share_consents denied', 'select count(*) from private.share_consents', 'permission denied');
insert into t_v select 'c1', public.create_couple('지수')->>'code';
select pg_temp.raises('request before partner joined -> partner_not_joined', 'select public.request_share_consent(''combo'')', 'partner_not_joined');
select set_config('request.jwt.claims', '{"sub":"b2000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select pg_temp.ok('U2 joins', public.join_couple((select v from t_v where k = 'c1'), '민준')->>'role' = 'B');
select pg_temp.ok('my_share_consent before any request is null', public.my_share_consent('combo') is null);
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into t_v select 'consent', public.request_share_consent('combo')->>'id';
select pg_temp.ok('U1 request again returns the same pending row', public.request_share_consent('combo')->>'id' = (select v from t_v where k = 'consent'));
select pg_temp.ok('U1 sees own request as requested_by_me', (public.my_share_consent('combo')->>'requested_by_me')::boolean);
select pg_temp.raises('requester cannot answer own request', format('select public.respond_share_consent(%L, true)', (select v from t_v where k = 'consent')), 'cannot_answer_own_request');
select set_config('request.jwt.claims', '{"sub":"c3000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
insert into t_v select 'c3', public.create_couple('다른')->>'code';
select pg_temp.ok('outsider my_share_consent does not see other couple', public.my_share_consent('combo') is null);
select pg_temp.raises('non-member cannot respond to consent', format('select public.respond_share_consent(%L, true)', (select v from t_v where k = 'consent')), 'consent_not_found');
select set_config('request.jwt.claims', '{"sub":"b2000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select pg_temp.ok('partner sees pending request from 지수',
  (select r->>'status' = 'pending' and not (r->>'requested_by_me')::boolean and r->>'requester_name' = '지수' from (select public.my_share_consent('combo') r) x));
select pg_temp.ok('partner accepts', public.respond_share_consent((select v from t_v where k = 'consent')::uuid, true)->>'status' = 'accepted');
select pg_temp.ok('second answer does not change it', public.respond_share_consent((select v from t_v where k = 'consent')::uuid, false)->>'status' = 'accepted');
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select pg_temp.ok('requester sees accepted', public.my_share_consent('combo')->>'status' = 'accepted');
select pg_temp.ok('log_event as member stores couple_code', public.log_event('combo_view'));
reset role;
select pg_temp.ok('funnel row has the caller''s couple_code', exists (select 1 from private.funnel_events where event = 'combo_view' and couple_code = (select v from t_v where k = 'c1')));
-- declined flow: a fresh request after decline is allowed
update private.share_consents set status = 'declined' where id = (select v from t_v where k = 'consent')::uuid;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select pg_temp.ok('new request after decline creates a new pending row',
  (select r->>'status' = 'pending' and r->>'id' <> (select v from t_v where k = 'consent') from (select public.request_share_consent('combo') r) x));
reset role;
-- NULL seat: without coalesce, `false OR NULL` is NULL and IF does not raise
insert into private.share_consents(couple_code, requested_by, card_type)
  values ((select v from t_v where k = 'c3'), 'c3000000-0000-0000-0000-000000000003', 'combo');
insert into t_v select 'consent_null', id::text from private.share_consents
  where couple_code = (select v from t_v where k = 'c3') order by created_at desc limit 1;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select pg_temp.raises('non-member cannot respond when the other couple slot is NULL',
  format('select public.respond_share_consent(%L, true)', (select v from t_v where k = 'consent_null')), 'consent_not_found');
reset role;
select pg_temp.ok('NULL-slot consent stays pending after outsider attempt',
  (select status from private.share_consents where id = (select v from t_v where k = 'consent_null')::uuid) = 'pending');

-- 3) quiz (anon) -------------------------------------------------------------------
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
insert into t_v select 'q1', public.create_quiz('<b>지수</b>"&abcdefghijklmn', '민준<script>x</script>', array[0,1,2,3,0,1,2,3,0,1], null)::text;
select pg_temp.ok('token is >= 24 chars base64url', ((select v from t_v where k = 'q1')::jsonb->>'token') ~ '^[A-Za-z0-9_-]{24,}$');
select pg_temp.ok('nickname stripped of HTML and cut to 12', ((select v from t_v where k = 'q1')::jsonb->>'a_name') = '지수abcdefghij'
  and ((select v from t_v where k = 'q1')::jsonb->>'b_name') = '민준x');
insert into t_v select 'tok1', (select v from t_v where k = 'q1')::jsonb->>'token';
select pg_temp.raises('empty nickname rejected', 'select public.create_quiz(''<i></i>'', ''b'', array[0,0,0,0,0,0,0,0,0,0], null)', 'bad_nickname');
select pg_temp.raises('9 answers rejected', 'select public.create_quiz(''a'', ''b'', array[0,0,0,0,0,0,0,0,0], null)', 'bad_answers');
select pg_temp.raises('answer 4 rejected', 'select public.create_quiz(''a'', ''b'', array[0,0,0,0,0,0,0,0,0,4], null)', 'bad_answers');
insert into t_v select 'g1', public.get_quiz_for_guess((select v from t_v where k = 'tok1'))::text;
select pg_temp.ok('get_quiz_for_guess has no answers/guesses keys',
  not ((select v from t_v where k = 'g1')::jsonb ?| array['answers', 'guesses', 'answer']));
select pg_temp.ok('get_quiz_for_guess does not contain the answer array in any form',
  position('0,1,2,3' in replace((select v from t_v where k = 'g1'), ' ', '')) = 0);
select pg_temp.ok('get_quiz_for_guess keys are exactly the expected set',
  (select array_agg(k order by k) from jsonb_object_keys((select v from t_v where k = 'g1')::jsonb) k)
  = array['a_name','b_name','challenge','has_challenge','my_challenge_token','score','status','total']);
select pg_temp.ok('status open, score null', (select v from t_v where k = 'g1')::jsonb->>'status' = 'open' and (select v from t_v where k = 'g1')::jsonb->'score' = 'null'::jsonb);
select pg_temp.raises('create_challenge before guess -> quiz_not_finished', format('select public.create_challenge(%L)', (select v from t_v where k = 'tok1')), 'quiz_not_finished');
-- answers 0,1,2,3,0,1,2,3,0,1 ; guesses differ at positions 3 and 10 -> 8
select pg_temp.ok('scoring: 8 of 10', (public.submit_quiz_guess((select v from t_v where k = 'tok1'), array[0,1,0,3,0,1,2,3,0,2])->>'score')::int = 8);
select pg_temp.ok('second guess cannot change score (all-correct resubmit still 8)', (public.submit_quiz_guess((select v from t_v where k = 'tok1'), array[0,1,2,3,0,1,2,3,0,1])->>'score')::int = 8);
select pg_temp.ok('after guess, get_quiz_for_guess still has no answers',
  not (public.get_quiz_for_guess((select v from t_v where k = 'tok1')) ?| array['answers', 'guesses']));
select pg_temp.raises('wrong token -> link_expired', 'select public.get_quiz_for_guess(''nope'')', 'link_expired');

-- 4) challenge -------------------------------------------------------------------------
insert into t_v select 'ch', public.create_challenge((select v from t_v where k = 'tok1'))->>'token';
select pg_temp.ok('create_challenge is idempotent', public.create_challenge((select v from t_v where k = 'tok1'))->>'token' = (select v from t_v where k = 'ch'));
select pg_temp.ok('challenge waiting', public.get_challenge_result((select v from t_v where k = 'ch'))->>'status' = 'waiting');
insert into t_v select 'tok2', public.create_quiz('서연', '도윤', array[3,3,3,3,3,3,3,3,3,3], (select v from t_v where k = 'ch'))->>'token';
select pg_temp.ok('friend quiz linked (has_challenge)', (public.get_quiz_for_guess((select v from t_v where k = 'tok2'))->>'has_challenge')::boolean);
insert into t_v select 's2', public.submit_quiz_guess((select v from t_v where k = 'tok2'), array[3,3,3,3,3,3,3,0,0,0])::text;
select pg_temp.ok('friend scored 7 and gets comparison 8 vs 7',
  (select r->>'score' = '7' and r#>>'{challenge,status}' = 'done' and r#>>'{challenge,score}' = '8' and r#>>'{challenge,score2}' = '7'
     and r#>>'{challenge,a_name}' = '지수abcdefghij' and r#>>'{challenge,c_name}' = '서연' and r#>>'{challenge,d_name}' = '도윤'
   from (select (select v from t_v where k = 's2')::jsonb r) x));
select pg_temp.ok('challenger now sees done 8 vs 7',
  (select r->>'status' = 'done' and r->>'score' = '8' and r->>'score2' = '7' from (select public.get_challenge_result((select v from t_v where k = 'ch')) r) x));
select pg_temp.ok('challenge result has no answers', not (public.get_challenge_result((select v from t_v where k = 'ch'))::text ~ 'answers|guesses'));

-- 5) expiry + rate limits ------------------------------------------------------------
reset role;
update private.quizzes set expires_at = now() - interval '1 second' where token = (select v from t_v where k = 'tok1');
update private.quiz_challenges set expires_at = now() - interval '1 second' where token = (select v from t_v where k = 'ch');
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.raises('expired quiz: get -> link_expired', format('select public.get_quiz_for_guess(%L)', (select v from t_v where k = 'tok1')), 'link_expired');
select pg_temp.raises('expired quiz: submit -> link_expired', format('select public.submit_quiz_guess(%L, array[0,0,0,0,0,0,0,0,0,0])', (select v from t_v where k = 'tok1')), 'link_expired');
select pg_temp.raises('expired quiz: create_challenge -> link_expired', format('select public.create_challenge(%L)', (select v from t_v where k = 'tok1')), 'link_expired');
select pg_temp.raises('expired challenge: result -> link_expired', format('select public.get_challenge_result(%L)', (select v from t_v where k = 'ch')), 'link_expired');
select pg_temp.raises('expired challenge: new quiz from it -> link_expired', format('select public.create_quiz(''a'', ''b'', array[0,0,0,0,0,0,0,0,0,0], %L)', (select v from t_v where k = 'ch')), 'link_expired');
reset role;
select pg_temp.ok('default expiry is 14 days', (select bool_and(abs(extract(epoch from (expires_at - created_at)) - 14*86400) < 5) from private.quizzes where token = (select v from t_v where k = 'tok2')));
update private.quizzes set read_count = 200 where token = (select v from t_v where k = 'tok2');
insert into private.anon_usage(day, kind, n) values ((timezone('Asia/Seoul', now()))::date, 'quiz_create', 2000)
  on conflict (day, kind) do update set n = 2000;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.raises('per-token read cap -> rate_limited', format('select public.get_quiz_for_guess(%L)', (select v from t_v where k = 'tok2')), 'rate_limited');
select pg_temp.raises('global daily quiz cap (2000) -> rate_limited', 'select public.create_quiz(''a'', ''b'', array[0,0,0,0,0,0,0,0,0,0], null)', 'rate_limited');

-- 6) log_event ---------------------------------------------------------------------------
select pg_temp.ok('anon log_event whitelisted -> true', public.log_event('quiz_start'));
select pg_temp.ok('anon log_event unknown -> false', not public.log_event('drop table'));
reset role;
select pg_temp.ok('anon event stored with null couple_code', exists (select 1 from private.funnel_events where event = 'quiz_start' and couple_code is null));
insert into private.anon_usage(day, kind, n) values ((timezone('Asia/Seoul', now()))::date, 'event', 20000)
  on conflict (day, kind) do update set n = 20000;
set local role anon;
select pg_temp.ok('event daily cap -> false (no error)', not public.log_event('quiz_finish'));
reset role;
rollback;
