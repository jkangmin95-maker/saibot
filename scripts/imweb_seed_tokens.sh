#!/bin/bash
# Seed private.imweb_oauth from the box token file, once, AFTER supabase_migration_v11_1_imweb.sql is applied.
# Prints nothing secret: the tokens go to psql on stdin as bind parameters (\bind, psql >= 16), so they are never in argv,
# never in the statement text (a failed statement's text is written to the Postgres log), and psql's own stderr is dropped.
# The password comes from a file via PGPASSWORD.
#   PGHOST=<db host> PGPORT=5432 PGUSER=postgres PGDATABASE=postgres DB_PASSWORD_FILE=/workspace/secrets/urisai-db-password \
#     bash scripts/imweb_seed_tokens.sh [/workspace/secrets/imweb-tokens.json]
# After this the DB copy is the live one: the poller rotates the refresh token. The script writes "$TF.db-seeded" so box
# helpers stop refreshing from the (now stale) box file.
set -euo pipefail
TF=${1:-/workspace/secrets/imweb-tokens.json}
: "${PGHOST:?set PGHOST}" "${DB_PASSWORD_FILE:?set DB_PASSWORD_FILE}"
v=$(psql --version | grep -oE '[0-9]+' | head -1); [ "$v" -ge 16 ] || { echo "need psql >= 16 (\\bind)" >&2; exit 1; }
export PGPASSWORD; PGPASSWORD=$(cat "$DB_PASSWORD_FILE")
if ! python3 - "$TF" <<'PY' | psql -q -X -v ON_ERROR_STOP=1 -tA >/dev/null 2>&1
import json, sys
d = json.load(open(sys.argv[1]))["data"]
a, r = str(d.get("accessToken") or ""), str(d["refreshToken"])
if not r or len(r) > 4000 or len(a) > 4000 or "\n" in a + r: sys.exit("bad token shape")
q = lambda s: "'" + s.replace("\\", "\\\\").replace("'", "''") + "'"
print(f"select private.imweb_seed_tokens($1, $2) \\bind {q(a)} {q(r)} \\g")
PY
then echo "seed failed (details suppressed so no token is printed; check the migration is applied and the token file)" >&2; exit 1; fi
date -u +%FT%TZ > "$TF.db-seeded"; chmod 600 "$TF.db-seeded"
echo "seeded: $(psql -X -tA -c "select 'token_updated_at=' || token_updated_at from private.imweb_oauth")"
