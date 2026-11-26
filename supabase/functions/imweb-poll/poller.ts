// imweb-poll core: one run = take lease → read recent 아임웹 orders → apply decisions → release lease.
// Network calls go through the injected fetch so poller_test.ts can run it against fakes.
import { decideAll, safeEqual } from "./logic.ts";

export interface Env {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  IMWEB_CLIENT_ID: string;
  IMWEB_CLIENT_SECRET: string;
  IMWEB_POLL_SECRET: string;
  IMWEB_UNIT_CODE: string;
  IMWEB_PROD_NO: number;
  IMWEB_API_BASE: string;
}
type Fetch = typeof fetch;
// deno-lint-ignore no-explicit-any
type J = any;

const PAGE_LIMIT = 50;
const MAX_PAGES = 20;
const TIME_BUDGET_MS = 40_000;
const DAY = 86_400_000;

export function envFrom(get: (k: string) => string | undefined): Env {
  return {
    SUPABASE_URL: get("SUPABASE_URL") ?? "",
    SUPABASE_SERVICE_ROLE_KEY: get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    IMWEB_CLIENT_ID: get("IMWEB_CLIENT_ID") ?? "",
    IMWEB_CLIENT_SECRET: get("IMWEB_CLIENT_SECRET") ?? "",
    IMWEB_POLL_SECRET: get("IMWEB_POLL_SECRET") ?? "",
    IMWEB_UNIT_CODE: get("IMWEB_UNIT_CODE") ?? "u202606249b836b8dc5010",
    IMWEB_PROD_NO: Number(get("IMWEB_PROD_NO") ?? "11"),
    IMWEB_API_BASE: get("IMWEB_API_BASE") ?? "https://openapi.imweb.me",
  };
}

class PollError extends Error {
  constructor(public status: string) { super(status); }
}

function json(status: number, body: unknown): Response {
  // no CORS headers on purpose: browsers can't call this
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

export function createHandler(env: Env, fetchImpl: Fetch = fetch, now: () => number = Date.now) {
  const rpc = async (fn: string, args: Record<string, unknown>): Promise<J> => {
    const key = env.SUPABASE_SERVICE_ROLE_KEY;
    const headers: Record<string, string> = { "Content-Type": "application/json", apikey: key };
    if (key.startsWith("eyJ")) headers.Authorization = `Bearer ${key}`; // legacy JWT key; new sb_secret_ keys go in apikey only
    const r = await fetchImpl(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: "POST", headers, body: JSON.stringify(args) });
    if (!r.ok) { await r.body?.cancel(); throw new PollError(`rpc_${fn.replace(/^imweb_poll_/, "")}_${r.status}`); }
    return await r.json();
  };

  return async function handle(req: Request): Promise<Response> {
    if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
    if (!env.IMWEB_POLL_SECRET || !env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY || !env.IMWEB_CLIENT_ID ||
        !env.IMWEB_CLIENT_SECRET || !Number.isSafeInteger(env.IMWEB_PROD_NO)) {
      console.error("imweb-poll: misconfigured");
      return json(500, { error: "misconfigured" });
    }
    if (!safeEqual(req.headers.get("x-imweb-poll-secret") ?? "", env.IMWEB_POLL_SECRET)) {
      return json(401, { error: "unauthorized" });
    }
    await req.body?.cancel();

    const started = now();
    const lease = await rpc("imweb_poll_lease", { p_seconds: 55 });
    if (!lease) return json(200, { skipped: "busy_or_not_seeded" });
    const leaseId: string = lease.lease;
    let access: string = lease.access_token ?? "";
    let refreshTok: string = lease.refresh_token ?? "";
    let refreshed = false;

    const refresh = async () => {
      if (refreshed) throw new PollError("unauthorized_after_refresh");
      refreshed = true;
      const body = new URLSearchParams({
        grantType: "refresh_token", clientId: env.IMWEB_CLIENT_ID, clientSecret: env.IMWEB_CLIENT_SECRET, refreshToken: refreshTok,
      });
      const r = await fetchImpl(`${env.IMWEB_API_BASE}/oauth2/token`, {
        method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body,
      });
      const j: J = await r.json().catch(() => null);
      const na = j?.data?.accessToken, nr = j?.data?.refreshToken;
      if (!r.ok || typeof na !== "string" || !na) throw new PollError("refresh_failed");
      const args = { p_lease: leaseId, p_old_refresh: refreshTok, p_access: na, p_refresh: typeof nr === "string" ? nr : null };
      // the old refresh token may already be spent, so try hard to persist the new pair
      const saved = await rpc("imweb_poll_save_tokens", args).catch(() => rpc("imweb_poll_save_tokens", args));
      if (saved !== true) throw new PollError("token_save_conflict");
      access = na;
      if (typeof nr === "string" && nr) refreshTok = nr;
      console.log("imweb-poll: token refreshed");
    };

    const imweb = async (path: string, params: Record<string, string>): Promise<J> => {
      const url = `${env.IMWEB_API_BASE}${path}?${new URLSearchParams(params)}`;
      for (let attempt = 0; attempt < 2; attempt++) {
        const r = await fetchImpl(url, { headers: { Authorization: `Bearer ${access}` } });
        const j: J = await r.json().catch(() => null);
        if (r.status === 401 || j?.statusCode === 401) { await refresh(); continue; }
        if (!r.ok) throw new PollError(`imweb_http_${r.status}`);
        return j;
      }
      throw new PollError("unauthorized_after_refresh");
    };

    const listAll = async (filter: Record<string, string>): Promise<J[]> => {
      const out: J[] = [];
      for (let page = 1; page <= MAX_PAGES; page++) {
        if (now() - started > TIME_BUDGET_MS) { console.warn("imweb-poll: time budget hit while paging"); break; }
        const j = await imweb("/orders", { ...filter, page: String(page), limit: String(PAGE_LIMIT), unitCode: env.IMWEB_UNIT_CODE });
        const list: J[] = Array.isArray(j?.data?.list) ? j.data.list : [];
        out.push(...list);
        const totalPage = Number(j?.data?.totalPage ?? 0);
        if (list.length === 0 || page >= totalPage) break;
      }
      return out;
    };

    const counts: Record<string, number> = {};
    let status = "ok";
    try {
      const t = now();
      // hourly (UTC minute 0) look back 30 days to catch late refunds; otherwise 2 days
      const lookback = new Date(t).getUTCMinutes() === 0 ? 30 * DAY : 2 * DAY;
      const since = new Date(t - lookback).toISOString();
      const since2d = new Date(t - 2 * DAY).toISOString();
      const orders = await listAll({ startWtime: since });
      const claimFilters: Record<string, string>[] = [{ startCancelRequestTime: since2d }, { startReturnRequestTime: since2d }];
      for (const f of claimFilters) {
        try { orders.push(...await listAll(f)); } catch (e) {
          if (e instanceof PollError && e.status.startsWith("imweb_http_")) console.warn(`imweb-poll: claim query ${e.status}`);
          else throw e;
        }
      }
      counts.orders = orders.length;
      const decisions = decideAll(orders, env.IMWEB_PROD_NO);
      counts.items = decisions.length;
      for (const d of decisions) {
        const res: string = await rpc("imweb_poll_apply", {
          p_lease: leaseId, p_order_no: d.orderNo, p_item_key: d.itemKey, p_action: d.action, p_pay_code: d.payCode,
        });
        counts[res] = (counts[res] ?? 0) + 1;
        // order numbers only (no codes, names, phones or emails) so the owner can look the order up in 아임웹
        if (res === "unknown_code" || res === "no_code" || res === "bad_input") console.warn(`imweb-poll: ${res} order ${d.orderNo}`);
        if (res === "unlocked" || res === "revoked") console.log(`imweb-poll: ${res} order ${d.orderNo}`);
        if (res === "no_lease") throw new PollError("lease_lost");
      }
    } catch (e) {
      status = e instanceof PollError ? e.status : "internal_error";
      console.error(`imweb-poll: ${status}`);
    } finally {
      await rpc("imweb_poll_finish", { p_lease: leaseId, p_status: status }).catch(() =>
        console.error("imweb-poll: finish failed")
      );
    }
    counts.ms = now() - started;
    console.log(`imweb-poll: ${status} ${JSON.stringify(counts)}`);
    return json(status === "ok" ? 200 : 502, { status, counts });
  };
}
