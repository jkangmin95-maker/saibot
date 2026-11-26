#!/bin/bash
# Throwaway local Postgres check for v11.3 (우리사이 온도): base -> ... -> v11.2 -> v11.3 up, up again, test,
# down (objects gone, v10.4 + v11.2 tests still pass), up again, test. Never point it at Supabase.
# Local: PGHOST=localhost PGPORT=55432 PGUSER=postgres bash scripts/run_local_sql_tests_v11_3.sh
set -u
cd "$(dirname "$0")/.."
DB=${DB:-urisai_v113_test}
P="psql -q -X"
$P -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null
$P -d $DB -v ON_ERROR_STOP=1 -f scripts/local_supabase_stub.sql >/dev/null 2>&1 || { echo "stub failed"; exit 1; }
for f in supabase_schema.sql supabase_migration_v8_kakao.sql supabase_migration_v9_chat.sql supabase_migration_v9_1_review.sql supabase_migration_v10_share_quiz.sql supabase_migration_v10_4_gratitude.sql supabase_migration_v10_5_book_clicks.sql supabase_migration_v11_paywall.sql supabase_migration_v11_2_book_click_paywall.sql; do
  sed -E 's/^create extension if not exists http with schema extensions;//' $f | $P -d $DB -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1 || { echo "FAILED $f"; exit 1; }
done
FAILS=0; PASSES=0
t() { local o; o=$($P -d $DB -f "$1" 2>&1 | grep -oE "(PASS|FAIL) .*|ERROR.*"); echo "$o" | grep -E "^(FAIL|ERROR)"; local p f; p=$(echo "$o" | grep -c ^PASS); f=$(echo "$o" | grep -cE "^(FAIL|ERROR)"); echo "  $(basename $1 .sql) -> PASS=$p FAIL=$f"; FAILS=$((FAILS + f)); PASSES=$((PASSES + p)); }
a() { $P -d $DB -v ON_ERROR_STOP=1 -f "$1" >/dev/null 2>/tmp/v113.err && echo "$2 ok" || { echo "$2 FAILED"; cat /tmp/v113.err; FAILS=$((FAILS + 1)); }; }
UP=supabase_migration_v11_3_temp.sql; DOWN=supabase_migration_v11_3_temp_down.sql
a $UP "v11.3 up"; a $UP "v11.3 up again"; t scripts/test_v11_3.sql; t scripts/test_v10_4.sql; t scripts/test_v11_2.sql
a $DOWN "v11.3 down"; a $DOWN "v11.3 down again"
r=$($P -d $DB -tAc "select count(*) from pg_class where relname in ('forecast_answers','temp_answers','temp_measurements','temp_config','self_missions')")+$($P -d $DB -tAc "select count(*) from pg_proc where proname in ('my_forecast','submit_forecast','forecast_answered','my_temp','submit_temp','create_self_mission','my_self_missions','accept_self_mission','temp_areas_json','self_mission_json')")
if [ "$r" = "0+0" ]; then echo "  PASS down: table + functions gone"; PASSES=$((PASSES + 1)); else echo "  FAIL down left objects ($r)"; FAILS=$((FAILS + 1)); fi
t scripts/test_v10_4.sql; t scripts/test_v11_2.sql
a $UP "v11.3 up after down"; t scripts/test_v11_3.sql
$P -d postgres -c "drop database if exists $DB" >/dev/null && echo "dropped $DB"
echo "TOTAL PASS = $PASSES  FAIL/ERROR = $FAILS"
