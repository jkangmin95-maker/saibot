// Handler tests against fake Supabase RPC + fake 아임웹 (no network).
import { assertEquals } from "jsr:@std/assert@1";
import { createHandler, envFrom } from "./poller.ts";
import fixtures from "./fixtures/orders.json" with { type: "json" };
// deno-lint-ignore no-explicit-any
const F: Record<string, any> = fixtures;

const env = envFrom((k) => ({
  SUPABASE_URL: "https://db.test", SUPABASE_SERVICE_ROLE_KEY: "eyJ.service", IMWEB_CLIENT_ID: "cid", IMWEB_CLIENT_SECRET: "csec",
  IMWEB_POLL_SECRET: "s3cret", IMWEB_API_BASE: "https://imweb.test",
} as Record<string, string>)[k]);

function fake(opts: { expiredAccess?: boolean; leaseBusy?: boolean; saveOk?: boolean; orders?: unknown[] } = {}) {
  const calls: { rpc: Record<string, unknown>[]; urls: string[]; logs: string[] } = { rpc: [], urls: [], logs: [] };
  const store = { access: opts.expiredAccess ? "old-access" : "good-access", refresh: "r1" };
  const f = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    calls.urls.push(url.split("?")[0]);
    if (url.startsWith("https://db.test/rest/v1/rpc/")) {
      const fn = url.split("/").pop()!;
      const args = JSON.parse(String(init?.body));
      calls.rpc.push({ fn, ...args });
      const h = new Headers(init?.headers);
      if (h.get("apikey") !== "eyJ.service") return new Response("no", { status: 401 });
      if (fn === "imweb_poll_lease") {
        return Response.json(opts.leaseBusy ? null : { lease: "L1", access_token: store.access, refresh_token: store.refresh });
      }
      if (fn === "imweb_poll_save_tokens") {
        const ok = (opts.saveOk ?? true) && args.p_old_refresh === store.refresh;
        if (ok) { store.access = args.p_access; store.refresh = args.p_refresh; }
        return Response.json(ok);
      }
      if (fn === "imweb_poll_apply") return Response.json(args.p_action === "paid" ? "unlocked" : args.p_action === "revoke" ? "revoked" : "no_code");
      if (fn === "imweb_poll_finish") return Response.json(true);
    }
    if (url === "https://imweb.test/oauth2/token") {
      const b = new URLSearchParams(String(init?.body));
      if (b.get("refreshToken") !== store.refresh || b.get("clientSecret") !== "csec") return new Response("{}", { status: 400 });
      return Response.json({ statusCode: 200, data: { accessToken: "new-access", refreshToken: "r2" } });
    }
    if (url.startsWith("https://imweb.test/orders?")) {
      const auth = new Headers(init?.headers).get("authorization");
      if (auth !== "Bearer good-access" && auth !== "Bearer new-access") return Response.json({ statusCode: 401 }, { status: 401 });
      const q = new URL(url).searchParams;
      const list = q.has("startWtime") ? (opts.orders ?? []) : [];
      return Response.json({ statusCode: 200, data: { totalCount: list.length, totalPage: 1, currentPage: 1, list } });
    }
    return new Response("unexpected " + url, { status: 599 });
  }) as typeof fetch;
  return { f, calls, store };
}
const post = (secret?: string) => new Request("https://fn.test/imweb-poll", {
  method: "POST", headers: secret ? { "x-imweb-poll-secret": secret } : {}, body: "{}",
});
const quiet = async <T>(fn: () => Promise<T>) => {
  const o = [console.log, console.warn, console.error];
  console.log = console.warn = console.error = () => {};
  try { return await fn(); } finally { [console.log, console.warn, console.error] = o; }
};

Deno.test("rejects GET, missing and wrong secret; no CORS header", async () => {
  const { f, calls } = fake();
  const h = createHandler(env, f);
  const r1 = await h(new Request("https://fn.test", { method: "GET" }));
  assertEquals(r1.status, 405);
  assertEquals((await h(new Request("https://fn.test", { method: "OPTIONS" }))).status, 405);
  assertEquals((await h(post())).status, 401);
  const r = await h(post("nope"));
  assertEquals(r.status, 401);
  assertEquals(r.headers.get("access-control-allow-origin"), null);
  assertEquals(calls.urls.length, 0);
});
Deno.test("misconfigured (no secret env) → 500 and nothing called", async () => {
  const { f, calls } = fake();
  const h = createHandler({ ...env, IMWEB_POLL_SECRET: "" }, f);
  assertEquals((await quiet(() => h(post("")))).status, 500);
  assertEquals(calls.urls.length, 0);
});
Deno.test("lease busy → skipped", async () => {
  const { f, calls } = fake({ leaseBusy: true });
  const r = await createHandler(env, f)(post("s3cret"));
  assertEquals(r.status, 200);
  assertEquals((await r.json()).skipped, "busy_or_not_seeded");
  assertEquals(calls.rpc.map((c) => c.fn), ["imweb_poll_lease"]);
});
Deno.test("happy path: applies paid/revoke/no_code, ignores others, finishes ok", async () => {
  const orders = [F.paid, F.refunded, F.missing_code, F.wrong_product, F.pending_bank, F.duplicate];
  const { f, calls } = fake({ orders });
  const r = await quiet(() => createHandler(env, f)(post("s3cret")));
  assertEquals(r.status, 200);
  const applies = calls.rpc.filter((c) => c.fn === "imweb_poll_apply");
  assertEquals(applies.map((a) => [a.p_order_no, a.p_action, a.p_pay_code]), [
    [1001, "paid", "UR-ABC234"], [1004, "revoke", "UR-ABC234"], [1009, "no_code", null],
  ]);
  assertEquals(calls.rpc.at(-1), { fn: "imweb_poll_finish", p_lease: "L1", p_status: "ok" });
  const body = await r.json();
  assertEquals([body.counts.unlocked, body.counts.revoked, body.counts.no_code], [1, 1, 1]);
});
Deno.test("expired access token → refresh once, CAS-save rotated pair, retry", async () => {
  const { f, calls, store } = fake({ expiredAccess: true, orders: [F.paid] });
  const r = await quiet(() => createHandler(env, f)(post("s3cret")));
  assertEquals(r.status, 200);
  assertEquals(store, { access: "new-access", refresh: "r2" });
  const save = calls.rpc.find((c) => c.fn === "imweb_poll_save_tokens")!;
  assertEquals([save.p_lease, save.p_old_refresh, save.p_refresh], ["L1", "r1", "r2"]);
  assertEquals(calls.urls.filter((u) => u.endsWith("/oauth2/token")).length, 1);
});
Deno.test("token save conflict → stop, finish with status, 502", async () => {
  const { f, calls } = fake({ expiredAccess: true, saveOk: false, orders: [F.paid] });
  const r = await quiet(() => createHandler(env, f)(post("s3cret")));
  assertEquals(r.status, 502);
  assertEquals(calls.rpc.filter((c) => c.fn === "imweb_poll_apply").length, 0);
  assertEquals(calls.rpc.at(-1), { fn: "imweb_poll_finish", p_lease: "L1", p_status: "token_save_conflict" });
});
Deno.test("logs never contain codes, buyer names, emails or phones", async () => {
  const { f } = fake({ orders: [F.paid, F.missing_code, F.refunded] });
  const lines: string[] = [];
  const o = [console.log, console.warn, console.error];
  console.log = console.warn = console.error = (...a: unknown[]) => lines.push(a.join(" "));
  try { await createHandler(env, f)(post("s3cret")); } finally { [console.log, console.warn, console.error] = o; }
  const all = lines.join("\n");
  for (const bad of ["UR-", "홍길동", "@example.com", "010-", "good-access", "r1"]) assertEquals(all.includes(bad), false, bad);
});
