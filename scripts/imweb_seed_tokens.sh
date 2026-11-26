#!/bin/bash
# Seed private.imweb_oauth from the box token file, once, AFTER supabase_migration_v11_1_imweb.sql is applied.
# Prints nothing secret: the tokens go to psql on stdin (not argv), the password comes from a file via PGPASSWORD.
#   PGHOST=<db host> PGPORT=5432 PGUSER=postgres PGDATABASE=postgres DB_PASSWORD_FILE=/workspace/secrets/urisai-db-password \
#     bash scripts/imweb_seed_tokens.sh [/workspace/secrets/imweb-tokens.json]
# After this the DB copy is the live one: the poller rotates the refresh token, so stop refreshing from the box file.
set -euo pipefail
TF=${1:-/workspace/secrets/imweb-tokens.json}
: "${PGHOST:?set PGHOST}" "${DB_PASSWORD_FILE:?set DB_PASSWORD_FILE}"
export PGPASSWORD; PGPASSWORD=$(cat "$DB_PASSWORD_FILE")
python3 - "$TF" <<'PY' | psql -q -X -v ON_ERROR_STOP=1 -tA >/dev/null
import json, sys
d = json.load(open(sys.argv[1]))["data"]
q = lambda s: "'" + str(s).replace("'", "''") + "'"
print(f"select private.imweb_seed_tokens({q(d.get('accessToken') or '')}, {q(d['refreshToken'])});")
PY
echo "seeded: $(psql -X -tA -c "select 'token_updated_at=' || token_updated_at from private.imweb_oauth")"
