-- Checks for supabase_migration_v11_5_heart.sql (상대 미션 알림 + 하트). Run on a scratch copy AFTER v11.3 + v11.5 (as postgres).
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
create or replace function pg_temp.u(n int) returns uuid language sql as $$ select ('f5000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create or replace function pg_temp.a(v int[]) returns smallint[] language sql as $$ select v::smallint[] $$;
create or replace function pg_temp.dm(p_id text, p_code text, p_target text, p_sender int, p_acc boolean, p_acc_at timestamptz)
returns void language plpgsql as $$ begin
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.u(p_sender), 'role', 'authenticated')::text, true);
  insert into public.daily_missions(id, couple_code, target_role, title, message, accepted, accepted_at, created_at)
  values (p_id, p_code, p_target, 'SECRET-TITLE', 'SECRET-MESSAGE', p_acc, p_acc_at, now() - interval '1 hour');
  perform set_config('request.jwt.claims', '{}', true);
end $$;
create or replace function pg_temp.gr(p_code text, p_role text, p_day date, p_uid int) returns void language plpgsql as $$ begin
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.u(p_uid), 'role', 'authenticated')::text, true);
  insert into private.gratitude_sends(couple_code, sender_role, sent_on) values (p_code, p_role, p_day);
  perform set_config('request.jwt.claims', '{}', true);
end $$;
create temp table t_v(k text primary key, v jsonb);
grant all on t_v to anon, authenticated;
grant execute on all functions in schema pg_temp to anon, authenticated;

-- ---------- privileges ----------
select pg_temp.ok('mission_hearts: in private, RLS on, no policies, no grants',
  (select relrowsecurity from pg_class where oid = 'private.mission_hearts'::regclass)
  and not exists (select 1 from pg_policies where schemaname = 'private' and tablename = 'mission_hearts')
  and not exists (select 1 from information_schema.role_table_grants where table_schema = 'private' and table_name = 'mission_hearts' and grantee in ('anon', 'authenticated', 'PUBLIC')));
select pg_temp.ok('my_heart_notices / send_heart / submit_temp: SECURITY DEFINER, search_path=public, pg_temp',
  (select count(*) from pg_proc where oid in ('public.my_heart_notices()'::regprocedure, 'public.send_heart(text)'::regprocedure, 'public.submit_temp(smallint[])'::regprocedure)
     and prosecdef and array_to_string(proconfig, ',') = 'search_path=public, pg_temp') = 3);
select pg_temp.ok('execute: authenticated yes, anon no, PUBLIC no',
  (select bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE') and not has_function_privilege('anon', p.oid, 'EXECUTE')
     and not exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0))
   from pg_proc p where p.oid in ('public.my_heart_notices()'::regprocedure, 'public.send_heart(text)'::regprocedure, 'public.submit_temp(smallint[])'::regprocedure)));
select pg_temp.ok('private.heart_candidates: no EXECUTE for anon / authenticated / PUBLIC',
  not has_function_privilege('authenticated', 'private.heart_candidates(text, uuid, uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'private.heart_candidates(text, uuid, uuid)', 'EXECUTE')
  and not exists (select 1 from aclexplode((select coalesce(proacl, acldefault('f', proowner)) from pg_proc where oid = 'private.heart_candidates(text, uuid, uuid)'::regprocedure)) a where a.grantee = 0));
select pg_temp.ok('no heart function reads title/message/secret_emotions or writes couples / missions',
  not exists (select 1 from pg_proc where proname in ('my_heart_notices', 'send_heart', 'heart_candidates')
    and (prosrc ~* '\m(title|message|badge|secret_emotions)\M' or prosrc ~* 'update\s+(public|private)\.'))
);
select pg_temp.ok('heart_candidates never reads self_missions and requires sender_id = caller; old 2-arg version gone',
  (select prosrc from pg_proc where oid = 'private.heart_candidates(text, uuid, uuid)'::regprocedure) !~* 'self_missions'
  and (select prosrc from pg_proc where oid = 'private.heart_candidates(text, uuid, uuid)'::regprocedure) ~* 'm\.sender_id\s*=\s*p_caller'
  and to_regprocedure('private.heart_candidates(text, uuid)') is null);

-- ---------- fixtures ----------
insert into auth.users(id) select pg_temp.u(n) from generate_series(1, 6) n;
insert into public.couples(code, user_a, user_b, name_a, name_b, warmth_temp, created_at) values
  ('TH-1', pg_temp.u(1), pg_temp.u(2), '민준', '서연', 37.5, now() - interval '100 days'),
  ('TH-2', pg_temp.u(3), pg_temp.u(4), '지호', '하린', 37.5, now() - interval '100 days'),
  ('TH-3', pg_temp.u(6), null, '혼자', null, 37.5, now() - interval '100 days');
-- u1 (A of TH-1): two partner missions done today, one done 5 days ago, one not done; a self mission done today;
-- a mission sent by a FORMER partner (u5, before the re-pair) done today; a self mission u1 completes via the RPC below
select pg_temp.dm('th-d1', 'TH-1', 'A', 2, true, now());
select pg_temp.dm('th-d5', 'TH-1', 'A', 2, true, now());
select pg_temp.dm('th-d6', 'TH-1', 'A', 5, true, now());
select pg_temp.dm('th-d2', 'TH-1', 'A', 2, true, now() - interval '5 days');
select pg_temp.dm('th-d3', 'TH-1', 'A', 2, false, null);
insert into private.self_missions(id, couple_code, user_id, title, message, accepted, accepted_at, created_on)
values ('th-s1', 'TH-1', pg_temp.u(1), 'SECRET-TITLE', 'SECRET-MESSAGE', true, now(), (now() at time zone 'Asia/Seoul')::date),
       ('th-s2', 'TH-1', pg_temp.u(1), 'SECRET-TITLE', 'SECRET-MESSAGE', false, null, (now() at time zone 'Asia/Seoul')::date - 1);
-- u3 (TH-2) did a mission today too
select pg_temp.dm('th-d4', 'TH-2', 'A', 4, true, now());

-- ---------- anon ----------
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.raises('anon: my_heart_notices denied', 'select public.my_heart_notices()', 'permission denied');
select pg_temp.raises('anon: send_heart denied', 'select public.send_heart(''00000000000000000000000000000000'')', 'permission denied');
select pg_temp.raises('anon: select private.mission_hearts denied', 'select count(*) from private.mission_hearts', 'permission denied');
reset role;

set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select pg_temp.raises('no uid: my_heart_notices -> not_authenticated', 'select public.my_heart_notices()', 'not_authenticated');
select pg_temp.raises('no uid: send_heart -> not_authenticated', 'select public.send_heart(''00000000000000000000000000000000'')', 'not_authenticated');
select pg_temp.as_user(pg_temp.u(5)::text);
select pg_temp.ok('non-member: notices = []', public.my_heart_notices() = '[]'::jsonb);
select pg_temp.as_user(pg_temp.u(6)::text);
select pg_temp.ok('no partner yet: notices = []', public.my_heart_notices() = '[]'::jsonb);

-- ---------- the partner sees name + date only ----------
select pg_temp.as_user(pg_temp.u(1)::text);
select pg_temp.ok('u1 completes a self mission via accept_self_mission', (public.accept_self_mission('th-s2')->>'accepted')::boolean);
select pg_temp.as_user(pg_temp.u(2)::text);
insert into t_v values ('n2', public.my_heart_notices());
select pg_temp.ok('partner sees exactly 2 notices = the 2 couple missions they sent, done today (no self missions, not the 5-day-old, undone or former partner''s)',
  jsonb_array_length((select v from t_v where k = 'n2')) = 2
  and (select array_agg(e->>'id' order by e->>'id') from jsonb_array_elements((select v from t_v where k = 'n2')) e)
      = (select array_agg(x order by x) from unnest(array[md5('d:th-d1' || 'TH-1' || pg_temp.u(2)::text), md5('d:th-d5' || 'TH-1' || pg_temp.u(2)::text)]) x));
select pg_temp.ok('accept_self_mission produced no notice for the partner (no s: key under any id)',
  not exists (select 1 from jsonb_array_elements((select v from t_v where k = 'n2')) e
    where e->>'id' in (md5('s:th-s1' || 'TH-1' || pg_temp.u(2)::text), md5('s:th-s2' || 'TH-1' || pg_temp.u(2)::text), md5('s:th-s1'), md5('s:th-s2'))));
select pg_temp.raises('former partner''s mission cannot be hearted', format('select public.send_heart(%L)', md5('d:th-d6' || 'TH-1' || pg_temp.u(2)::text)), 'notice_not_found');
select pg_temp.raises('self mission cannot be hearted', format('select public.send_heart(%L)', md5('s:th-s2' || 'TH-1' || pg_temp.u(2)::text)), 'notice_not_found');
select pg_temp.raises('old id formula md5(key) rejected', format('select public.send_heart(%L)', md5('d:th-d1')), 'notice_not_found');
select pg_temp.ok('notice keys are exactly done_on / hearted / id / name',
  (select bool_and((select array_agg(k order by k) from jsonb_object_keys(e) k) = array['done_on', 'hearted', 'id', 'name']) from jsonb_array_elements((select v from t_v where k = 'n2')) e));
select pg_temp.ok('notice: name = doer''s nickname, done_on = today KST, hearted false',
  (select bool_and(e->>'name' = '민준' and (e->>'done_on')::date = (now() at time zone 'Asia/Seoul')::date and (e->>'hearted')::boolean = false)
     from jsonb_array_elements((select v from t_v where k = 'n2')) e));
select pg_temp.ok('no mission content, ids or kind leak (title, message, th-d1, th-s1, d:, s:)',
  (select v::text from t_v where k = 'n2') !~ '(SECRET|th-d|th-s|"d:|"s:)');
select pg_temp.ok('notice id is an opaque 32-hex token',
  (select bool_and(e->>'id' ~ '^[0-9a-f]{32}$') from jsonb_array_elements((select v from t_v where k = 'n2')) e));
select pg_temp.raises('member: SELECT private.mission_hearts denied', 'select * from private.mission_hearts', 'permission denied');

select pg_temp.as_user(pg_temp.u(1)::text);
select pg_temp.ok('doer does not see a notice for their own missions', public.my_heart_notices() = '[]'::jsonb);
select pg_temp.raises('doer cannot heart own mission -> notice_not_found',
  format('select public.send_heart(%L)', (select v->0->>'id' from t_v where k = 'n2')), 'notice_not_found');
select pg_temp.as_user(pg_temp.u(3)::text);
select pg_temp.ok('other couple doer (u3): no notices, none from TH-1',
  jsonb_array_length(public.my_heart_notices()) = 0);
select pg_temp.as_user(pg_temp.u(4)::text);
select pg_temp.ok('TH-2 partner sees 1 notice named 지호', jsonb_array_length(public.my_heart_notices()) = 1 and public.my_heart_notices()->0->>'name' = '지호');
select pg_temp.raises('other couple cannot heart TH-1 mission -> notice_not_found',
  format('select public.send_heart(%L)', (select v->0->>'id' from t_v where k = 'n2')), 'notice_not_found');
select pg_temp.as_user(pg_temp.u(2)::text);
select pg_temp.raises('bad id format -> notice_not_found', 'select public.send_heart(''th-d1'')', 'notice_not_found');
select pg_temp.raises('null id -> notice_not_found', 'select public.send_heart(null)', 'notice_not_found');
select pg_temp.raises('md5 of the 5-day-old mission -> notice_not_found', format('select public.send_heart(%L)', md5('d:th-d2' || 'TH-1' || pg_temp.u(2)::text)), 'notice_not_found');

-- ---------- sending ----------
insert into t_v values ('h1', public.send_heart((select v->0->>'id' from t_v where k = 'n2')));
select pg_temp.ok('send_heart -> that notice hearted, the other not',
  (select count(*) from jsonb_array_elements((select v from t_v where k = 'h1')) e where (e->>'hearted')::boolean) = 1);
insert into t_v values ('h2', public.send_heart((select v->0->>'id' from t_v where k = 'n2')));
reset role;
select pg_temp.ok('one heart per mission (second send is a no-op)', (select count(*) from private.mission_hearts where couple_code = 'TH-1') = 1);
select pg_temp.ok('heart row: sender = partner, doer = u1, sent_on today',
  (select bool_and(sender_id = pg_temp.u(2) and doer_id = pg_temp.u(1) and sent_on = (now() at time zone 'Asia/Seoul')::date) from private.mission_hearts where couple_code = 'TH-1'));
select pg_temp.ok('heart changes nothing on missions / couple',
  (select accepted from public.daily_missions where id = 'th-d1') and (select accepted from public.daily_missions where id = 'th-d5')
  and (select warmth_temp from public.couples where code = 'TH-1') = 37.5);
set local role authenticated;
select pg_temp.as_user(pg_temp.u(2)::text);
insert into t_v values ('h3', public.send_heart((select v->1->>'id' from t_v where k = 'n2')));
reset role;
select pg_temp.ok('second mission gets its own heart (2 rows)', (select count(*) from private.mission_hearts where couple_code = 'TH-1') = 2);

-- ---------- 고마움 area: a heart is the sender's gratitude-day, deduped with a same-day gratitude ----------
-- u2: gratitude yesterday + gratitude today + hearts today  => 2 days. A stray heart row by a non-member must not count.
select pg_temp.gr('TH-1', 'B', (now() at time zone 'Asia/Seoul')::date - 1, 2);
select pg_temp.gr('TH-1', 'B', (now() at time zone 'Asia/Seoul')::date, 2);
insert into private.mission_hearts(mission_key, couple_code, doer_id, sender_id) values ('d:stray', 'TH-1', pg_temp.u(1), pg_temp.u(5));
set local role authenticated;
select pg_temp.as_user(pg_temp.u(1)::text); select public.submit_temp(pg_temp.a(array[2,2,2,2,2,2,2,2,2,2]));
select pg_temp.as_user(pg_temp.u(2)::text);
insert into t_v values ('m1', public.submit_temp(pg_temp.a(array[2,2,2,2,2,2,2,2,2,2])));
reset role;
select pg_temp.ok('TH-1 고마움 = base + 2 days * grat_step (heart counted, same day not double, stray ignored)',
  ((select v from t_v where k = 'm1')->'last'->'areas'->0->>'temp')::numeric
   = (select round(least(max_temp, greatest(min_temp, base + least(grat_cap, grat_step * 2))), 1) from private.temp_config where id = 1));
-- control: TH-2, no gratitude / hearts => 고마움 = base
set local role authenticated;
select pg_temp.as_user(pg_temp.u(3)::text); select public.submit_temp(pg_temp.a(array[2,2,2,2,2,2,2,2,2,2]));
select pg_temp.as_user(pg_temp.u(4)::text);
insert into t_v values ('m2', public.submit_temp(pg_temp.a(array[2,2,2,2,2,2,2,2,2,2])));
reset role;
select pg_temp.ok('control couple without hearts: 고마움 = base',
  ((select v from t_v where k = 'm2')->'last'->'areas'->0->>'temp')::numeric = (select round(base, 1) from private.temp_config where id = 1));
select pg_temp.ok('hearts never lower anything: TH-1 total >= TH-2 total',
  ((select v from t_v where k = 'm1')->'last'->>'total')::numeric >= ((select v from t_v where k = 'm2')->'last'->>'total')::numeric);
rollback;
