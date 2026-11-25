#!/bin/bash
# Throwaway local Postgres check: schema -> v8 -> v9 -> v9.1 -> v10 up -> up again -> test_v10 -> down -> up -> test_v10.
# Needs a local Postgres you can reach as superuser, e.g. PGHOST=/tmp PGPORT=5432 PGUSER=postgres. Never point it at Supabase.
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
run_tests() { $P -d $DB -f scripts/test_v10.sql 2>&1 | grep -oE "(PASS|FAIL) .*|ERROR.*" | tee /tmp/test_v10.out; echo "-> PASS=$(grep -c ^PASS /tmp/test_v10.out) FAIL=$(grep -c ^FAIL /tmp/test_v10.out) ERROR=$(grep -c ^ERROR /tmp/test_v10.out)"; }
$P -d $DB -v ON_ERROR_STOP=1 -f supabase_migration_v10_share_quiz.sql >/dev/null 2>&1 && echo "up ok" || echo "up FAILED"
$P -d $DB -v ON_ERROR_STOP=1 -f supabase_migration_v10_share_quiz.sql >/dev/null 2>&1 && echo "up again ok" || echo "up again FAILED"
run_tests
$P -d $DB -v ON_ERROR_STOP=1 -f supabase_migration_v10_share_quiz_down.sql >/dev/null 2>&1 && echo "down ok" || echo "down FAILED"
echo "left after down: tables=$($P -d $DB -tAc "select count(*) from pg_tables where schemaname='private' and tablename in ('share_consents','quizzes','quiz_challenges','anon_usage','funnel_events')") functions=$($P -d $DB -tAc "select count(*) from pg_proc where proname in ('my_share_consent','request_share_consent','respond_share_consent','create_quiz','get_quiz_for_guess','submit_quiz_guess','create_challenge','get_challenge_result','log_event','new_token','bump_usage','clean_nick','my_couple_row','challenge_json','consent_json')")"
$P -d $DB -v ON_ERROR_STOP=1 -f supabase_migration_v10_share_quiz.sql >/dev/null 2>&1 && echo "up again after down ok" || echo "up after down FAILED"
run_tests
