#!/bin/bash
# Throwaway local Postgres check for v11.9 (review mode, temp scale, prompt encoding). Never point it at Supabase.
# Local: PGHOST=localhost PGPORT=55432 PGUSER=postgres bash scripts/run_local_sql_tests_v11_9.sh
set -u
cd "$(dirname "$0")/.."
DB=${DB:-urisai_v119_test}
P="psql -q -X"
$P -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null
$P -d $DB -v ON_ERROR_STOP=1 -f scripts/local_supabase_stub.sql >/dev/null 2>&1 || { echo "stub failed"; exit 1; }
for f in supabase_schema.sql supabase_migration_v8_kakao.sql supabase_migration_v9_chat.sql supabase_migration_v9_1_review.sql supabase_migration_v10_share_quiz.sql supabase_migration_v10_4_gratitude.sql supabase_migration_v10_5_book_clicks.sql supabase_migration_v11_paywall.sql supabase_migration_v11_2_book_click_paywall.sql supabase_migration_v11_3_temp.sql supabase_migration_v11_5_heart.sql; do
  sed -E 's/^create extension if not exists http with schema extensions;//' $f | $P -d $DB -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1 || { echo "FAILED $f"; exit 1; }
done
FAILS=0; PASSES=0
t() { local o; o=$($P -d $DB -f "$1" 2>&1 | grep -oE "(PASS|FAIL) .*|ERROR.*"); echo "$o" | grep -E "^(FAIL|ERROR)"; local p f; p=$(echo "$o" | grep -c ^PASS); f=$(echo "$o" | grep -cE "^(FAIL|ERROR)"); echo "  $(basename $1 .sql) -> PASS=$p FAIL=$f"; FAILS=$((FAILS + f)); PASSES=$((PASSES + p)); }
a() { $P -d $DB -v ON_ERROR_STOP=1 -f "$1" >/dev/null 2>/tmp/v119.err && echo "$2 ok" || { echo "$2 FAILED"; cat /tmp/v119.err; FAILS=$((FAILS + 1)); }; }
c() { if [ "$2" = "$3" ]; then echo "  PASS $1"; PASSES=$((PASSES + 1)); else echo "  FAIL $1 (got $2, want $3)"; FAILS=$((FAILS + 1)); fi; }
q() { $P -d $DB -tAc "$1"; }
ENC="select count(*) from pg_proc where proname in ('sai_chat','generate_mission','my_report','secret_topic') and prosrc ~ '[À-ÿ]'"
HAN="select count(*) from pg_proc where proname in ('sai_chat','generate_mission','my_report','secret_topic') and prosrc ~ '[가-힣]'"
# encoding: down reproduces the live (garbled) state, up repairs it; grants unchanged
G0=$(q "select string_agg(p.proname||':'||coalesce(p.proacl::text,''), ',' order by p.proname) from pg_proc p where proname in ('sai_chat','generate_mission','my_report','secret_topic')")
a supabase_migration_v11_9_prompt_encoding_down.sql "encoding down (= live garbled copy)"
c "down: 4 functions garbled like live" "$(q "$ENC")" 4
a supabase_migration_v11_9_prompt_encoding.sql "encoding up"; a supabase_migration_v11_9_prompt_encoding.sql "encoding up again"
c "up: no garbled characters left" "$(q "$ENC")" 0
c "up: Korean text present in all 4" "$(q "$HAN")" 4
c "up: grants unchanged" "$(q "select string_agg(p.proname||':'||coalesce(p.proacl::text,''), ',' order by p.proname) from pg_proc p where proname in ('sai_chat','generate_mission','my_report','secret_topic')")" "$G0"
c "up: secret_topic matches Korean again" "$(q "select private.secret_topic('하루 종일 연락이 없어서 서운해')")" "contact"
# temp scale
a supabase_migration_v11_9_temp_scale.sql "temp scale up"; a supabase_migration_v11_9_temp_scale.sql "temp scale up again"
c "temp scale: base/span 30/13" "$(q "select base||'/'||span from private.temp_config where id=1")" "30.0/13.0"
# review
a supabase_migration_v11_9_review.sql "review up"; a supabase_migration_v11_9_review.sql "review up again"
t scripts/test_v11_9_review.sql
t scripts/test_v11_5_heart.sql
a supabase_migration_v11_9_review_down.sql "review down"; a supabase_migration_v11_9_review_down.sql "review down again"
c "review down: objects gone" "$(q "select count(*) from pg_proc where proname in ('am_reviewer','review_reset','is_reviewer')")+$(q "select count(*) from pg_class where relname='review_users'")" "0+0"
a supabase_migration_v11_9_temp_scale_down.sql "temp scale down"
c "temp scale down: back to 32/10" "$(q "select base||'/'||span from private.temp_config where id=1")" "32.0/10.0"
t scripts/test_v11_3.sql
a supabase_migration_v11_9_review.sql "review up after down"
$P -d postgres -c "drop database if exists $DB" >/dev/null && echo "dropped $DB"
echo "TOTAL PASS = $PASSES  FAIL/ERROR = $FAILS"
