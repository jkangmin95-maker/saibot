-- Simulates three Kakao users + anon against the v8 RPCs and RLS. Rolls back everything.
\set ON_ERROR_STOP 0
begin;
insert into auth.users(id) values
 ('11111111-1111-1111-1111-111111111111'),('22222222-2222-2222-2222-222222222222'),
 ('33333333-3333-3333-3333-333333333333'),('44444444-4444-4444-4444-444444444444');
create temp table t_codes(who text, code text);
grant all on t_codes to authenticated, anon;

-- U1 creates
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',true);
select 'U1 my_couple before' t, public.my_couple() r;
insert into t_codes select 'c1', (public.create_couple('지수'))->>'code';
select 'U1 create again (idempotent)' t, public.create_couple('x')->>'code' = (select code from t_codes where who='c1') ok;
select 'U1 my_couple' t, public.my_couple() r;

-- U2 joins with lowercase code without prefix
select set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}',true);
select 'U2 join' t, public.join_couple(lower(substr((select code from t_codes where who='c1'),4)), '민준') r;

-- U3 tries to join full couple
select set_config('request.jwt.claims','{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}',true);
savepoint s1;
select 'U3 join full (expect couple_full)' t, public.join_couple((select code from t_codes where who='c1'), '침입자');
rollback to savepoint s1;
savepoint s2;
select 'U3 join bogus (expect code_not_found)' t, public.join_couple('S2-NOPE00', 'x');
rollback to savepoint s2;
-- U3 makes own couple
insert into t_codes select 'c3', (public.create_couple('다른커플'))->>'code';
insert into public.daily_missions(id,couple_code,target_role,title,message) values ('m-u3',(select code from t_codes where who='c3'),'A','u3','u3');
savepoint s3;
select 'U3 join another while in couple (expect already_in_couple)' t, public.join_couple((select code from t_codes where who='c1'),'x');
rollback to savepoint s3;
select 'U3 sees couples' t, count(*) from public.couples;
select 'U3 sees c1 missions (expect 0 later)' t, count(*) from public.daily_missions where couple_code=(select code from t_codes where who='c1');
savepoint s4;
insert into public.daily_missions(id,couple_code,target_role,title,message) values ('m-evil',(select code from t_codes where who='c1'),'A','x','x');
rollback to savepoint s4;
update public.couples set warmth_temp=99 where code=(select code from t_codes where who='c1');
select 'U3 cross-couple update rows changed (expect 0)' t, count(*) from public.couples where warmth_temp=99;
select 'U3 generate_mission for c1 (expect null)' t, public.generate_mission('서운해', (select code from t_codes where who='c1')) r;

-- U1 writes and reads
select set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',true);
insert into public.daily_missions(id,couple_code,target_role,title,message) values ('m-1',(select code from t_codes where who='c1'),'B','t','m');
select 'U1 sees couples (expect 1)' t, count(*) from public.couples;
select 'U1 sees missions (expect 1: m-1 only)' t, string_agg(id, ',') from public.daily_missions;
update public.couples set name_a='지수2', warmth_temp=38.7 where code=(select code from t_codes where who='c1');
select 'U1 name/temp update' t, name_a, warmth_temp from public.couples;
savepoint s5;
update public.couples set user_b='33333333-3333-3333-3333-333333333333' where code=(select code from t_codes where who='c1');
rollback to savepoint s5;
select 'U1 generate_mission own couple (non-null if Gemini ok)' t, public.generate_mission('밥 먹을 때 폰만 봐서 서운해', (select code from t_codes where who='c1')) is not null ok;

-- U2 sees the mission and accepts
select set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}',true);
update public.daily_missions set accepted=true where id='m-1';
select 'U2 sees + accepted' t, id, accepted from public.daily_missions;
select 'U2 my_couple' t, public.my_couple() r;

-- U4 (no couple) sees nothing
select set_config('request.jwt.claims','{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}',true);
select 'U4 sees couples/missions (expect 0/0)' t, (select count(*) from public.couples), (select count(*) from public.daily_missions);

-- anon
reset role;
set local role anon;
select set_config('request.jwt.claims','{"role":"anon"}',true);
savepoint s6;
select 'anon couples (expect permission denied)' t, count(*) from public.couples;
rollback to savepoint s6;
savepoint s7;
select 'anon create_couple (expect permission denied)' t, public.create_couple('x');
rollback to savepoint s7;
savepoint s8;
select 'anon generate_mission (expect permission denied)' t, public.generate_mission('x','S2-AAAAAA');
rollback to savepoint s8;
reset role;
rollback;
