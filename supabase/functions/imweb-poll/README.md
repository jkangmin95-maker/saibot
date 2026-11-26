# imweb-poll: 아임웹 결제 → 속마음 리포트 자동 열기

Every minute pg_cron calls this function. It reads recent 아임웹 orders, finds 상품 prodNo 11 (우리사이 속마음 리포트),
reads the buyer's **결제 확인 코드** (UR-XXXXXX) from the product's required input option of that name (prodNo 11, optionCode O20261126d4894320f7625; the delivery memo is not read) and adds or takes back one pass per order item (30 days × the item's quantity) through `public.imweb_poll_apply`
(→ `private.set_couple_paid(code, true|false, 'imweb', '<orderNo>/<itemKey>')`, v11 `private.couple_passes`).

| Order state | Action |
|---|---|
| payment `PAYMENT_COMPLETE` (not FREE), section not CANCEL_*/RETURN_* | `paid` (or `no_code` if no/ambiguous code) |
| payment `REFUND_COMPLETE` / `PARTIAL_REFUND_COMPLETE` / `CANCELLED_BEFORE_DEPOSIT`, a completed cancel payment, or section `CANCEL_*` / `RETURN_*` | `revoke` (takes back only this order item's 30-day pass; other orders and manual unlocks keep their days) |
| anything else (`PAYMENT_PREPARATION`, `REFUND_PROCESSING`, `REFUND_FAILED`, …) | no change |

Queries per run: orders created in the last 2 days (30 days at UTC minute 0), plus cancel/return requests in the last 2 days.
Logs carry counts and order numbers only — never codes, names, phones, emails or tokens.

## Deploy (owner, in order)
1. SQL editor: `supabase_migration_v11_1_imweb.sql` (after v11).
2. Seed tokens once with `scripts/imweb_seed_tokens.sh` only. Don't paste tokens into the SQL editor (query history keeps
   them, and a failed statement is written to the Postgres log with its literals). The script sends them as bind parameters.
   It also writes `<token file>.db-seeded`; from then on the DB copy is the live one and the box helper
   (`/workspace/imweb-work/api.py`) refuses to refresh from the box file unless `IMWEB_ALLOW_BOX_REFRESH=1`.
3. Function secrets (Dashboard → Edge Functions → Secrets, or `supabase secrets set`):
   `IMWEB_CLIENT_ID`, `IMWEB_CLIENT_SECRET`, `IMWEB_POLL_SECRET` (new random value, e.g. `openssl rand -hex 32`).
   Optional: `IMWEB_UNIT_CODE` (default u202606249b836b8dc5010), `IMWEB_PROD_NO` (default 11).
   `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` are provided by the platform.
4. `supabase functions deploy imweb-poll --project-ref iyligsrpaxitlpuwbdjx --no-verify-jwt` (config.toml also sets verify_jwt = false).
5. SQL editor: store the same `IMWEB_POLL_SECRET` value in Vault as `imweb_poll_secret`, then run `supabase_cron_v11_1_imweb.sql`.
6. Check: `select last_run_at, last_ok_at, last_status from private.imweb_oauth;`

Rollback: `select cron.unschedule('imweb-poll');` → `supabase_migration_v11_1_imweb_down.sql` → delete the function.

## Tests
- `deno test supabase/functions/imweb-poll/` (fixture orders in `fixtures/orders.json`; fake 아임웹 + fake RPC)
- `PGHOST=… PGPORT=… PGUSER=postgres bash scripts/run_local_sql_tests.sh` (includes `scripts/test_v11_1.sql`)
