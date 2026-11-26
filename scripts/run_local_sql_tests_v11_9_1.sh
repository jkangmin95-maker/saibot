#!/bin/bash
# Throwaway local Postgres check for v11.9.1 (review link test couple). Never point it at Supabase.
# Local: PGHOST=localhost PGPORT=55432 PGUSER=postgres bash scripts/run_local_sql_tests_v11_9_1.sh [seed.sql seed-down.sql]
# Without args it generates a throwaway seed into a temp dir (deleted at the end).
set -u
cd "$(dirname "$0")/.."
export PGHOST=${PGHOST:-localhost} PGPORT=${PGPORT:-55432} PGUSER=${PGUSER:-postgres}
DB=${DB:-urisai_v1191_test}
P="psql -q -X"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
if [ $# -ge 2 ]; then SEED=$1; SEED_DOWN=$2; else REVIEW_OUT_DIR=$TMP python3 scripts/make_review_link.py >/dev/null || { echo "generator failed"; exit 1; }; SEED=$TMP/review-link-seed.sql; SEED_DOWN=$TMP/review-link-seed-down.sql; fi
$P -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null
$P -d $DB -v ON_ERROR_STOP=1 -f scripts/local_supabase_stub.sql >/dev/null 2>&1 || { echo "stub failed"; exit 1; }
for f in supabase_schema.sql supabase_migration_v8_kakao.sql supabase_migration_v9_chat.sql supabase_migration_v9_1_review.sql supabase_migration_v10_share_quiz.sql supabase_migration_v10_4_gratitude.sql supabase_migration_v10_5_book_clicks.sql supabase_migration_v11_paywall.sql supabase_migration_v11_2_book_click_paywall.sql supabase_migration_v11_3_temp.sql supabase_migration_v11_5_heart.sql supabase_migration_v11_9_temp_scale.sql supabase_migration_v11_9_review.sql; do
  sed -E 's/^create extension if not exists http with schema extensions;//' $f | $P -d $DB -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1 || { echo "FAILED $f"; exit 1; }
done
# auth.users / auth.identities columns the seed writes (Supabase shape)
$P -d $DB -v ON_ERROR_STOP=1 >/dev/null <<'SQL' || { echo "auth stub ext failed"; exit 1; }
alter table auth.users add column instance_id uuid, add column aud varchar(255), add column role varchar(255), add column email varchar(255),
  add column encrypted_password varchar(255), add column email_confirmed_at timestamptz, add column raw_app_meta_data jsonb, add column raw_user_meta_data jsonb,
  add column created_at timestamptz, add column updated_at timestamptz, add column confirmation_token varchar(255), add column recovery_token varchar(255),
  add column email_change_token_new varchar(255), add column email_change varchar(255);
create table auth.identities(provider_id text not null, user_id uuid not null references auth.users(id) on delete cascade, identity_data jsonb not null,
  provider text not null, last_sign_in_at timestamptz, created_at timestamptz, updated_at timestamptz, id uuid primary key default gen_random_uuid(),
  unique (provider_id, provider));
-- the live owner: Kakao account in a real couple, already allowlisted by the v11.9 seed
insert into auth.users(id, email) values ('0a000000-0000-0000-0000-000000000001', null), ('0a000000-0000-0000-0000-000000000002', null);
insert into auth.identities(provider_id, user_id, identity_data, provider) values ('k1', '0a000000-0000-0000-0000-000000000001', '{}', 'kakao');
insert into public.couples(code, user_a, user_b, name_a, name_b) values ('S2-OWNER1', '0a000000-0000-0000-0000-000000000001', '0a000000-0000-0000-0000-000000000002', 'o', 'p');
insert into private.review_users(user_id) values ('0a000000-0000-0000-0000-000000000001');
SQL
FAILS=0; PASSES=0
a() { $P -d $DB -v ON_ERROR_STOP=1 -f "$1" >/dev/null 2>$TMP/err && { echo "  PASS $2"; PASSES=$((PASSES + 1)); } || { echo "  FAIL $2"; cat $TMP/err; FAILS=$((FAILS + 1)); }; }
x() { if [ -f "$1" ]; then XA=(-f "$1"); else XA=(-c "$1"); fi; $P -d $DB -v ON_ERROR_STOP=1 "${XA[@]}" >/dev/null 2>$TMP/err && { echo "  FAIL $2 (no error)"; FAILS=$((FAILS + 1)); } || { grep -q "$3" $TMP/err && { echo "  PASS $2"; PASSES=$((PASSES + 1)); } || { echo "  FAIL $2"; cat $TMP/err; FAILS=$((FAILS + 1)); }; }; }
c() { if [ "$2" = "$3" ]; then echo "  PASS $1"; PASSES=$((PASSES + 1)); else echo "  FAIL $1 (got $2, want $3)"; FAILS=$((FAILS + 1)); fi; }
q() { $P -d $DB -tAc "$1"; }
A=$(grep -oE "values \('00000000-0000-0000-0000-000000000000', '[0-9a-f-]{36}'" "$SEED" | head -1 | grep -oE "[0-9a-f-]{36}'$" | tr -d "'")
B=$(grep -oE "values \('00000000-0000-0000-0000-000000000000', '[0-9a-f-]{36}'" "$SEED" | sed -n 2p | grep -oE "[0-9a-f-]{36}'$" | tr -d "'")
as() { echo "select set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated')::text, false); set role authenticated;"; }

a supabase_migration_v11_9_1_review_link.sql "migration up"; a supabase_migration_v11_9_1_review_link.sql "migration up again (idempotent)"
c "existing owner row became kind=owner" "$(q "select kind from private.review_users")" "owner"
c "grants on review_users unchanged (none for anon/authenticated)" "$(q "select count(*) from information_schema.role_table_grants where table_schema='private' and table_name='review_users' and grantee in ('anon','authenticated','PUBLIC')")" "0"
a "$SEED" "seed: 2 test accounts + couple"
c "review_users = 1 owner + 2 test" "$(q "select string_agg(kind||':'||n, ',' order by kind) from (select kind, count(*) n from private.review_users group by kind) s")" "owner:1,test:2"
c "seed: email identities, confirmed, bcrypt only" "$(q "select count(*) from auth.users u join auth.identities i on i.user_id=u.id and i.provider='email' where u.id in ('$A','$B') and u.email_confirmed_at is not null and u.encrypted_password like '\$2a\$10\$%'")" "2"
c "seed: A and B share one couple" "$(q "select count(*) from public.couples where user_a='$A' and user_b='$B'")" "1"
x "$SEED" "seed again refused" "already exist"
x "insert into auth.users(id) values ('0b000000-0000-0000-0000-000000000009'); insert into private.review_users(user_id, kind) values ('0b000000-0000-0000-0000-000000000009','test')" "3rd test account refused" "at most 2 test"
x "insert into auth.users(id) values ('0b000000-0000-0000-0000-000000000008'); insert into private.review_users(user_id) values ('0b000000-0000-0000-0000-000000000008')" "2nd owner refused" "review_users_one_owner"
x "update private.review_users set kind='test' where kind='owner'" "owner->test (3rd test) refused" "at most 2 test"
c "am_reviewer as test A" "$(q "$(as $A) select public.am_reviewer();" | tail -1)" "t"
c "am_reviewer as test B" "$(q "$(as $B) select public.am_reviewer();" | tail -1)" "t"
c "am_reviewer as owner's partner (not allowlisted)" "$(q "$(as 0a000000-0000-0000-0000-000000000002) select public.am_reviewer();" | tail -1)" "f"
c "review_reset(mission) as A works on own couple" "$(q "$(as $A) select public.review_reset('mission')->>'ok';" | tail -1)" "true"
c "review_reset(temp) as A (partner B joined)" "$(q "$(as $A) select public.review_reset('temp')->>'ok';" | tail -1)" "true"
c "my_couple as B returns the test couple" "$(q "$(as $B) select (public.my_couple()->>'code') is not null;" | tail -1)" "t"
c "authenticated cannot read review_users" "$($P -d $DB -tAc "$(as $A) select count(*) from private.review_users;" 2>&1 | grep -c 'permission denied')" "1"
a "$SEED_DOWN" "seed down"
c "after seed down: owner only, test users/couple gone" "$(q "select (select count(*) from private.review_users)||'/'||(select count(*) from auth.users where email like 'review-%')||'/'||(select count(*) from public.couples where code<>'S2-OWNER1')")" "1/0/0"
a supabase_migration_v11_9_1_review_link_down.sql "migration down"; a supabase_migration_v11_9_1_review_link_down.sql "migration down again"
c "down: column/trigger/function gone, owner row kept" "$(q "select (select count(*) from information_schema.columns where table_schema='private' and table_name='review_users' and column_name='kind')||'/'||(select count(*) from pg_proc where proname='review_users_cap')||'/'||(select count(*) from private.review_users)")" "0/0/1"
a supabase_migration_v11_9_1_review_link.sql "migration up after down"
a "$SEED" "seed after re-up"
# v11.10.1 Before User Created hook
$P -d postgres -c "do \$\$ begin if not exists (select 1 from pg_roles where rolname='supabase_auth_admin') then create role supabase_auth_admin nologin; end if; end \$\$" >/dev/null
$P -d $DB -c "alter default privileges in schema public grant execute on functions to anon, authenticated" >/dev/null
a supabase_auth_hook_v11_10_1.sql "auth hook up"; a supabase_auth_hook_v11_10_1.sql "auth hook up again"
c "hook: email signup rejected with 403" "$(q "select public.hook_before_user_created('{\"user\":{\"app_metadata\":{\"provider\":\"email\"}}}')->'error'->>'http_code'")" "403"
c "hook: kakao signup allowed ({})" "$(q "select public.hook_before_user_created('{\"user\":{\"app_metadata\":{\"provider\":\"kakao\"}}}')::text")" "{}"
c "hook: missing provider allowed ({})" "$(q "select public.hook_before_user_created('{}')::text")" "{}"
c "hook: search_path pinned" "$(q "select array_to_string(proconfig, ',') from pg_proc where proname='hook_before_user_created'")" "search_path=pg_catalog, pg_temp"
c "hook: execute only supabase_auth_admin (not PUBLIC/anon/authenticated)" "$(q "select has_function_privilege('supabase_auth_admin','public.hook_before_user_created(jsonb)','EXECUTE')::text||'/'||has_function_privilege('anon','public.hook_before_user_created(jsonb)','EXECUTE')::text||'/'||has_function_privilege('authenticated','public.hook_before_user_created(jsonb)','EXECUTE')::text||'/'||(select count(*) from aclexplode((select proacl from pg_proc where proname='hook_before_user_created')) x where x.grantee=0)")" "true/false/false/0"
a supabase_auth_hook_v11_10_1_down.sql "auth hook down"; a supabase_auth_hook_v11_10_1_down.sql "auth hook down again"
c "hook down: function gone" "$(q "select count(*) from pg_proc where proname='hook_before_user_created'")" "0"
a supabase_auth_hook_v11_10_1.sql "auth hook up after down"
$P -d postgres -c "drop database if exists $DB" >/dev/null && echo "dropped $DB"
echo "TOTAL PASS = $PASSES  FAIL = $FAILS"
[ $FAILS -eq 0 ]
