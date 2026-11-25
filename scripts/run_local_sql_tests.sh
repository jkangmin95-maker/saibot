#!/bin/bash
# Throwaway local Postgres check. Never point it at Supabase.
#   schema -> v8 -> v9 -> v9.1
#   v10: up -> up again -> test_v10 -> down -> up -> test_v10
#   v11: up -> up again -> test_v10 + test_v11 -> down -> test_v10 -> up -> test_v10 + test_v11
# Needs a local Postgres you can reach as superuser, e.g. PGHOST=/tmp PGPORT=5432 PGUSER=postgres.
# The pg http extension is replaced by a stub (scripts/local_supabase_stub.sql), so Gemini calls just return null.
set -u
cd "$(dirname "$0")/.."
DB=${DB:-urisai_local_test}
P="psql -q -X"
$P -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null
$P -d $DB -v ON_ERROR_STOP=1 -f scripts/local_supabase_stub.sql >/dev/null 2>&1 || { echo "stub failed"; exit 1; }
for f in supabase_schema.sql supabase_migration_v8_kakao.sql supabase_migration_v9_chat.sql supabase_migration_v9_1_review.sql; do
  sed -E 's/^create extension if not exists http with schema extensions;//' $f | $P -d $DB -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1 || { echo "FAILED $f"; exit 1; }
done
TOTAL_FAIL=0
run_tests() { # $1 = test file
  local n; n=$(basename "$1" .sql)
  $P -d $DB -f "$1" 2>&1 | grep -oE "(PASS|FAIL) .*|ERROR.*" > /tmp/$n.out
  grep -E "^(FAIL|ERROR)" /tmp/$n.out
  local p f e; p=$(grep -c ^PASS /tmp/$n.out); f=$(grep -c ^FAIL /tmp/$n.out); e=$(grep -c ^ERROR /tmp/$n.out)
  echo "  $n -> PASS=$p FAIL=$f ERROR=$e"; TOTAL_FAIL=$((TOTAL_FAIL + f + e))
}
apply() { $P -d $DB -v ON_ERROR_STOP=1 -f "$1" >/dev/null 2>/tmp/apply.err && echo "$2 ok" || { echo "$2 FAILED"; cat /tmp/apply.err; TOTAL_FAIL=$((TOTAL_FAIL + 1)); }; }
V10=supabase_migration_v10_share_quiz; V11=supabase_migration_v11_paywall
echo "== v10"
apply $V10.sql "v10 up"; apply $V10.sql "v10 up again"; run_tests scripts/test_v10.sql
apply ${V10}_down.sql "v10 down"
echo "  left after v10 down: tables=$($P -d $DB -tAc "select count(*) from pg_tables where schemaname='private' and tablename in ('share_consents','quizzes','quiz_challenges','anon_usage','funnel_events')") functions=$($P -d $DB -tAc "select count(*) from pg_proc where proname in ('my_share_consent','request_share_consent','respond_share_consent','create_quiz','get_quiz_for_guess','submit_quiz_guess','create_challenge','get_challenge_result','log_event','new_token','bump_usage','clean_nick','my_couple_row','challenge_json','consent_json')")"
apply $V10.sql "v10 up after down"; run_tests scripts/test_v10.sql
echo "== v11"
apply $V11.sql "v11 up"; apply $V11.sql "v11 up again"; run_tests scripts/test_v10.sql; run_tests scripts/test_v11.sql
apply ${V11}_down.sql "v11 down"
echo "  left after v11 down: tables=$($P -d $DB -tAc "select count(*) from pg_tables where schemaname='private' and tablename in ('paywall_config','couple_entitlements')") functions=$($P -d $DB -tAc "select count(*) from pg_proc where proname in ('get_paywall_config','request_pay_code','my_report','paywall_on','new_pay_code','set_couple_paid')") log_event_v11_events=$($P -d $DB -tAc "select count(*) from pg_proc where proname='log_event' and prosrc like '%paywall_view%'")"
run_tests scripts/test_v10.sql
apply $V11.sql "v11 up after down"; run_tests scripts/test_v10.sql; run_tests scripts/test_v11.sql
echo "TOTAL FAIL/ERROR = $TOTAL_FAIL"
