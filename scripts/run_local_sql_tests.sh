#!/bin/bash
# Throwaway local Postgres check. Never point it at Supabase.
#   schema -> v8 -> v9 -> v9.1
#   v10: up -> up again -> test_v10 -> down -> up -> test_v10
#   v11: up -> up again -> test_v10 + test_v11 -> down -> test_v10 -> up -> test_v10 + test_v11
#   v11.1: up -> up again -> test_v11 + test_v11_1 -> down -> test_v11 -> up -> test_v11_1
#   sai_chat probe (scripts/probe_sai_chat.sql): the Gemini request sai_chat builds with the v11 flag OFF must be
#   byte-for-byte the v9.1 one, and v11 down must restore the exact v9.1 sai_chat / v9 generate_mission source.
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
probe() { $P -d $DB -f scripts/probe_sai_chat.sql 2>&1 | grep -E "^(RESULT|BODY|ATTEMPTS|SRC|ERROR)" > /tmp/probe_$1.out; }
same() { # $1 label, $2 probe name, $3 grep pattern for compared lines
  if [ -s /tmp/probe_$2.out ] && diff <(grep -E "$3" /tmp/probe_v91.out) <(grep -E "$3" /tmp/probe_$2.out) >/dev/null && grep -q "^BODY {" /tmp/probe_$2.out; then
    echo "  PASS $1"; else echo "  FAIL $1"; diff <(grep -E "$3" /tmp/probe_v91.out) <(grep -E "$3" /tmp/probe_$2.out) | cut -c1-300; TOTAL_FAIL=$((TOTAL_FAIL + 1)); fi
}
probe v91
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
probe v11off; same "sai_chat flag OFF: Gemini request + result identical to v9.1" v11off "^(RESULT|BODY|ATTEMPTS)"
apply ${V11}_down.sql "v11 down"
probe v11down; same "v11 down: sai_chat + generate_mission source/config identical to v9.1/v9 and same request" v11down "^(RESULT|BODY|ATTEMPTS|SRC)"
echo "  left after v11 down: tables=$($P -d $DB -tAc "select count(*) from pg_tables where schemaname='private' and tablename in ('paywall_config','couple_entitlements','secret_report_consents','secret_topic_tags','couple_passes','report_snapshots','secret_ai_usage')") functions=$($P -d $DB -tAc "select count(*) from pg_proc where proname in ('get_paywall_config','request_pay_code','my_report','paywall_on','new_pay_code','set_couple_paid','consent_secret_report','record_secret_topic','secret_topic','withdraw_secret_report','recompute_paid_until','secret_ai_daily_cap','take_secret_ai_call')") generate_mission_capped=$($P -d $DB -tAc "select count(*) from pg_proc where proname='generate_mission' and prosrc like '%take_secret_ai_call%'") log_event_v11_events=$($P -d $DB -tAc "select count(*) from pg_proc where proname='log_event' and prosrc like '%paywall_view%'")"
run_tests scripts/test_v10.sql
apply $V11.sql "v11 up after down"; run_tests scripts/test_v10.sql; run_tests scripts/test_v11.sql
probe v11again; same "v11 up after down, flag OFF: sai_chat request identical to v9.1" v11again "^(RESULT|BODY|ATTEMPTS)"
V111=supabase_migration_v11_1_imweb
echo "== v11.1"
apply $V111.sql "v11.1 up"; apply $V111.sql "v11.1 up again"; run_tests scripts/test_v11.sql; run_tests scripts/test_v11_1.sql
$P -d $DB -c "insert into public.couples(code) values ('DOWNT')" -c "insert into private.couple_entitlements(couple_code, pay_code, report_paid, paid_at, paid_source, payment_ref) values ('DOWNT', 'UR-DDDDDD', true, now(), 'imweb', '42')" >/dev/null
apply ${V111}_down.sql "v11.1 down"
echo "  imweb-paid couple after down (expect t|manual|42): $($P -d $DB -tAc "select report_paid, paid_source, payment_ref from private.couple_entitlements where couple_code='DOWNT'")"
$P -d $DB -c "delete from public.couples where code='DOWNT'" >/dev/null
echo "  left after v11.1 down: tables=$($P -d $DB -tAc "select count(*) from pg_tables where schemaname='private' and tablename like 'imweb%'") functions=$($P -d $DB -tAc "select count(*) from pg_proc where proname like 'imweb_%'") imweb_in_check=$($P -d $DB -tAc "select count(*) from pg_constraint where conname='couple_entitlements_paid_source_check' and pg_get_constraintdef(oid) like '%imweb%'")"
run_tests scripts/test_v11.sql
apply ${V111}_down.sql "v11.1 down again"
apply $V111.sql "v11.1 up after down"; run_tests scripts/test_v11.sql; run_tests scripts/test_v11_1.sql
echo "TOTAL FAIL/ERROR = $TOTAL_FAIL"
