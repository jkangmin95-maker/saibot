-- Local stand-in for the Supabase platform pieces the migrations rely on. For scripts/run_local_sql_tests.sh only; never run on Supabase.
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;
grant anon, authenticated, service_role to postgres;
create schema auth;
create table auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid $$;
create or replace function auth.role() returns text language sql stable as $$
  select current_setting('request.jwt.claims', true)::jsonb ->> 'role' $$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on all functions in schema auth to anon, authenticated, service_role;
create schema extensions;
grant usage on schema extensions to anon, authenticated, service_role;
create extension pgcrypto with schema extensions;
-- pg http extension stub (not installed locally): http() always fails, which gemini_json catches
create type extensions.http_header as (field varchar, value varchar);
create type extensions.http_request as (method varchar, uri varchar, headers extensions.http_header[], content_type varchar, content varchar);
create type extensions.http_response as (status integer, content_type varchar, headers extensions.http_header[], content varchar);
create function extensions.http_header(text, text) returns extensions.http_header language sql as $$ select ($1, $2)::extensions.http_header $$;
create function extensions.http_set_curlopt(text, text) returns boolean language sql as $$ select true $$;
create function extensions.http(extensions.http_request) returns extensions.http_response language plpgsql as $$ begin raise exception 'http stub'; end $$;
create schema vault;
create table vault.secrets(name text, secret text);
create view vault.decrypted_secrets as select name, secret as decrypted_secret from vault.secrets;
-- Supabase default privileges: anything new in public is granted to the API roles
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
create publication supabase_realtime;
