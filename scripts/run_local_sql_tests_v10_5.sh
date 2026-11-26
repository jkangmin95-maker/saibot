#!/bin/bash
# Throwaway local Postgres check for v10.5: schema -> v8 -> v9 -> v9.1 -> v10 -> v10.4 -> v10.5 up -> up again -> test -> down -> up -> test.
# Needs a local Postgres you can reach as superuser (PGHOST/PGPORT/PGUSER). Never point it at Supabase.
set -u
cd "$(dirname "$0")/.."
DB=${DB:-urisai_v105_test}
P="psql -q -X"
$P -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null
$P -d $DB -v ON_ERROR_STOP=1 -f scripts/local_supabase_stub.sql >/dev/null 2>&1 || { echo "stub failed"; exit 1; }
for f in supabase_schema.sql supabase_migration_v8_kakao.sql supabase_migration_v9_chat.sql supabase_migration_v9_1_review.sql supabase_migration_v10_share_quiz.sql supabase_migration_v10_4_gratitude.sql; do
  sed -E 's/^create extension if not exists http with schema extensions;//' $f | $P -d $DB -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1 || { echo "FAILED $f"; exit 1; }
done
UP=supabase_migration_v10_5_book_clicks.sql; DOWN=supabase_migration_v10_5_book_clicks_down.sql
run_tests() { $P -d $DB -f scripts/test_v10_5.sql 2>&1 | grep -oE "(PASS|FAIL) .*|ERROR.*" | tee /tmp/test_v10_5.out; echo "-> PASS=$(grep -c ^PASS /tmp/test_v10_5.out) FAIL=$(grep -c ^FAIL /tmp/test_v10_5.out) ERROR=$(grep -c ^ERROR /tmp/test_v10_5.out)"; }
$P -d $DB -v ON_ERROR_STOP=1 -f $UP >/dev/null 2>&1 && echo "up ok" || echo "up FAILED"
$P -d $DB -v ON_ERROR_STOP=1 -f $UP >/dev/null 2>&1 && echo "up again ok" || echo "up again FAILED"
run_tests
$P -d $DB -v ON_ERROR_STOP=1 -f $DOWN >/dev/null 2>&1 && echo "down ok" || echo "down FAILED"
echo "left after down: tables=$($P -d $DB -tAc "select count(*) from pg_tables where schemaname='private' and tablename in ('book_clicks','book_click_caps')") functions=$($P -d $DB -tAc "select count(*) from pg_proc where proname='log_book_click'")"
$P -d $DB -v ON_ERROR_STOP=1 -f $UP >/dev/null 2>&1 && echo "up again after down ok" || echo "up after down FAILED"
run_tests
echo "regression: test_v10_4.sql after v10.5 -> PASS=$($P -d $DB -f scripts/test_v10_4.sql 2>&1 | grep -c 'PASS ') FAIL=$($P -d $DB -f scripts/test_v10_4.sql 2>&1 | grep -cE 'FAIL |ERROR')"
echo "regression: test_v10.sql after v10.5 -> PASS=$($P -d $DB -f scripts/test_v10.sql 2>&1 | grep -c 'PASS ') FAIL=$($P -d $DB -f scripts/test_v10.sql 2>&1 | grep -cE 'FAIL |ERROR')"
$P -d postgres -c "drop database if exists $DB" >/dev/null && echo "dropped $DB"
