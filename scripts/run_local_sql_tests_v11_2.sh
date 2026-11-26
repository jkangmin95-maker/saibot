#!/bin/bash
# Throwaway local Postgres check for v11.2 (paywall book click key): base -> v10.4 -> v10.5 -> v11.2 up, up again, test,
# down (v10.5 test must pass again, 'paywall' rejected), up, test. Never point it at Supabase.
set -u
cd "$(dirname "$0")/.."
DB=${DB:-urisai_v112_test}
P="psql -q -X"
$P -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null
$P -d $DB -v ON_ERROR_STOP=1 -f scripts/local_supabase_stub.sql >/dev/null 2>&1 || { echo "stub failed"; exit 1; }
for f in supabase_schema.sql supabase_migration_v8_kakao.sql supabase_migration_v9_chat.sql supabase_migration_v9_1_review.sql supabase_migration_v10_share_quiz.sql supabase_migration_v10_4_gratitude.sql supabase_migration_v10_5_book_clicks.sql; do
  sed -E 's/^create extension if not exists http with schema extensions;//' $f | $P -d $DB -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1 || { echo "FAILED $f"; exit 1; }
done
FAILS=0
t() { local o; o=$($P -d $DB -f "$1" 2>&1 | grep -oE "(PASS|FAIL) .*|ERROR.*"); echo "$o" | grep -E "^(FAIL|ERROR)"; local p f; p=$(echo "$o" | grep -c ^PASS); f=$(echo "$o" | grep -cE "^(FAIL|ERROR)"); echo "  $(basename $1 .sql) -> PASS=$p FAIL=$f"; FAILS=$((FAILS + f)); }
a() { $P -d $DB -v ON_ERROR_STOP=1 -f "$1" >/dev/null 2>/tmp/v112.err && echo "$2 ok" || { echo "$2 FAILED"; cat /tmp/v112.err; FAILS=$((FAILS + 1)); }; }
UP=supabase_migration_v11_2_book_click_paywall.sql; DOWN=supabase_migration_v11_2_book_click_paywall_down.sql
a $UP "v11.2 up"; a $UP "v11.2 up again"; t scripts/test_v11_2.sql; t scripts/test_v10_5.sql
a $DOWN "v11.2 down"; t scripts/test_v10_5.sql
r=$($P -d $DB -tAc "select pg_get_constraintdef(oid) from pg_constraint where conname = 'book_clicks_link_key_check'")
case "$r" in *paywall*) echo "  FAIL down left paywall in check"; FAILS=$((FAILS + 1));; *) echo "  PASS down: check back to card/settings";; esac
a $UP "v11.2 up after down"; t scripts/test_v11_2.sql
$P -d postgres -c "drop database if exists $DB" >/dev/null && echo "dropped $DB"
echo "TOTAL FAIL/ERROR = $FAILS"
