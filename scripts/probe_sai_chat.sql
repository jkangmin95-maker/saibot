-- Prints what public.sai_chat sends to Gemini for a fixed couple + messages, and an md5 of its source.
-- Used by scripts/run_local_sql_tests.sh to prove: v11 with the flag OFF sends byte-for-byte the same request as v9.1,
-- and v11 down restores the exact v9.1 function. Everything is rolled back. The key below is a fake placeholder.
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
begin;
insert into vault.secrets(name, secret) values ('urisai_gemini_api_key', 'local-fake-key');
create temp table t_http(n serial, body text);
grant all on t_http to authenticated;
grant usage, select on sequence t_http_n_seq to authenticated;
create or replace function extensions.http(r extensions.http_request) returns extensions.http_response language plpgsql as $$
begin insert into pg_temp.t_http(body) values (r.content); return (500, 'application/json', null, '{}')::extensions.http_response; end $$;
insert into auth.users(id) values ('a9000000-0000-0000-0000-000000000091'), ('b9000000-0000-0000-0000-000000000092');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a9000000-0000-0000-0000-000000000091","role":"authenticated"}', true) is not null as x \gset
select public.create_couple('지수')->>'code' as code \gset
select set_config('request.jwt.claims', '{"sub":"b9000000-0000-0000-0000-000000000092","role":"authenticated"}', true) is not null as x \gset
select (public.join_couple(:'code', '민준')->>'role') as r \gset
select set_config('request.jwt.claims', '{"sub":"a9000000-0000-0000-0000-000000000091","role":"authenticated"}', true) is not null as x \gset
select coalesce(public.sai_chat(:'code', '[{"role":"user","text":"안녕"},{"role":"bot","text":"안녕하세요!"},{"role":"user","text":"요즘 연락이 너무 없어서 서운해"}]'::jsonb)::text, 'NULL') as out \gset
reset role;
select 'RESULT ' || :'out';
select 'BODY ' || regexp_replace(body, 'S2-[A-Z0-9]+', 'S2-CODE', 'g') from t_http where n = (select min(n) from t_http);
select 'ATTEMPTS ' || count(*) from t_http;
select 'SRC ' || md5(prosrc) || ' ' || coalesce(array_to_string(proconfig, ','), '') || ' ' || prosecdef from pg_proc where proname = 'sai_chat';
rollback;
