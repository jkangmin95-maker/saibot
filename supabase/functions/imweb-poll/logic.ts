// Pure decision logic for imweb-poll (no network, no Deno APIs) so it can be unit-tested with fixture orders.
// Order shape: GET https://openapi.imweb.me/orders → data.list[] (see urisai-growth/imweb-setup.md).

export type PollAction = "paid" | "revoke" | "no_code";
export interface Decision {
  orderNo: number;
  itemKey: string;
  action: PollAction;
  payCode: string | null;
}

export const CODE_OPTION_NAME = "결제 확인 코드";
const REVOKE_PAYMENT = new Set(["REFUND_COMPLETE", "PARTIAL_REFUND_COMPLETE", "CANCELLED_BEFORE_DEPOSIT"]);
// statuses where we keep whatever state we had (refund in flight / failed, unpaid bank transfer, …)
const FREE_METHODS = new Set(["FREE"]);

// deno-lint-ignore no-explicit-any
type J = any;

/** NFKC, upper case, unify dashes, drop whitespace. */
export function normalizeText(s: string): string {
  return s.normalize("NFKC").toUpperCase().replace(/[\u2010-\u2015\u2212\uFE58\uFE63\uFF0D]/g, "-").replace(/\s+/g, "");
}

const STRICT = /(?<![A-Z0-9])UR-([A-Z0-9]{6})(?![A-Z0-9])/g;
const LOOSE = /^UR-?([A-Z0-9]{6})$/;

/** A code typed into the named field: "ur-abc234", " UR ABC234 ", "URABC234" → "UR-ABC234". */
export function codeFromValue(v: unknown): string | null {
  if (typeof v !== "string" && typeof v !== "number") return null;
  const n = normalizeText(String(v));
  const m = n.match(LOOSE);
  if (m) return "UR-" + m[1];
  const all = distinctStrict(n);
  return all.length === 1 ? all[0] : null;
}

function distinctStrict(n: string): string[] {
  const out = new Set<string>();
  for (const m of n.matchAll(STRICT)) out.add("UR-" + m[1]);
  return [...out];
}

function isCodeName(k: unknown): boolean {
  return typeof k === "string" && normalizeText(k).includes(normalizeText(CODE_OPTION_NAME));
}

/** Values stored under a name that looks like "결제 확인 코드", from any of the shapes 아임웹 may use. */
function namedValues(node: J, out: unknown[], depth = 0): void {
  if (node == null || depth > 6) return;
  if (Array.isArray(node)) {
    // ["결제 확인 코드", "UR-…"] pair
    if (node.length >= 2 && isCodeName(node[0]) && !isCodeName(node[1])) out.push(node[1]);
    for (const x of node) namedValues(x, out, depth + 1);
    return;
  }
  if (typeof node === "object") {
    // {name|optionName|title|key: "결제 확인 코드", value|optionValue|…: "UR-…"}
    const nameKey = ["name", "optionName", "optionTitle", "title", "key", "label"].find((k) => isCodeName(node[k]));
    if (nameKey) {
      for (const k of ["value", "optionValue", "optionValueName", "inputValue", "text", "val"]) {
        if (k in node) out.push(Array.isArray(node[k]) ? node[k][0] : node[k]);
      }
    }
    // {"결제 확인 코드": "UR-…"}
    for (const [k, v] of Object.entries(node)) {
      if (isCodeName(k) && (typeof v === "string" || typeof v === "number")) out.push(v);
      else namedValues(v, out, depth + 1);
    }
  }
}

/** The buyer's 결제 확인 코드 from productInfo.optionInfo / optionInfoList, or null (missing or ambiguous). */
export function extractPayCode(productInfo: J): string | null {
  if (!productInfo || typeof productInfo !== "object") return null;
  const src = [productInfo.optionInfo, productInfo.optionInfoList].filter((x) => x != null);
  const named: unknown[] = [];
  for (const s of src) namedValues(typeof s === "string" ? tryJson(s) : s, named);
  const namedCodes = [...new Set(named.map(codeFromValue).filter((c): c is string => !!c))];
  if (namedCodes.length === 1) return namedCodes[0];
  if (namedCodes.length > 1) return null;
  // fallback: exactly one UR-XXXXXX anywhere in the option JSON
  const all = distinctStrict(normalizeText(JSON.stringify(src)));
  return all.length === 1 ? all[0] : null;
}

function tryJson(s: string): unknown {
  try { return JSON.parse(s); } catch { return s; }
}

function sectionRevoked(status: unknown): boolean {
  return typeof status === "string" && (status.startsWith("CANCEL_") || status.startsWith("RETURN_"));
}

export type PayState = "paid" | "revoked" | "pending";

/** Order-level payment state. Refund/cancel wins over paid. FREE payments never count as paid. */
export function paymentState(order: J): PayState {
  const pays: J[] = Array.isArray(order?.payments) ? order.payments : [];
  if (pays.some((p) => REVOKE_PAYMENT.has(p?.paymentStatus))) return "revoked";
  if (pays.some((p) => p?.isCancel === "Y" && p?.paymentStatus === "PAYMENT_COMPLETE")) return "revoked";
  const paid = pays.some((p) =>
    p?.paymentStatus === "PAYMENT_COMPLETE" && p?.isCancel !== "Y" &&
    !FREE_METHODS.has(p?.method) && !FREE_METHODS.has(p?.pgName)
  );
  return paid ? "paid" : "pending";
}

/** Decisions for every prodNo item in one order (empty when the order has none or is still pending). */
export function decideOrder(order: J, prodNo: number): Decision[] {
  const orderNo = Number(order?.orderNo);
  if (!Number.isSafeInteger(orderNo) || orderNo <= 0) return [];
  const sections: J[] = Array.isArray(order?.sections) ? order.sections : [];
  const pay = paymentState(order);
  const out: Decision[] = [];
  sections.forEach((s, si) => {
    const items: J[] = Array.isArray(s?.sectionItems) ? s.sectionItems : [];
    items.forEach((it, ii) => {
      if (Number(it?.productInfo?.prodNo) !== prodNo) return;
      const itemKey = String(it?.orderItemCode || it?.orderSectionItemNo || `${s?.orderSectionCode ?? si}:${ii}`).slice(0, 100);
      const payCode = extractPayCode(it?.productInfo);
      if (pay === "revoked" || sectionRevoked(s?.orderSectionStatus)) {
        out.push({ orderNo, itemKey, action: "revoke", payCode });
      } else if (pay === "paid" && Number(it?.qty ?? 1) >= 1) {
        out.push({ orderNo, itemKey, action: payCode ? "paid" : "no_code", payCode });
      }
    });
  });
  return out;
}

/** Decisions across pages, deduplicated by (orderNo, itemKey); a later copy of the same order replaces an earlier one. */
export function decideAll(orders: J[], prodNo: number): Decision[] {
  const m = new Map<string, Decision>();
  for (const o of orders) for (const d of decideOrder(o, prodNo)) m.set(`${d.orderNo}|${d.itemKey}`, d);
  return [...m.values()];
}

/** Constant-time string compare for the shared secret header (empty never matches). */
export function safeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  const n = Math.max(ea.length, eb.length);
  let diff = ea.length ^ eb.length;
  for (let i = 0; i < n; i++) diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return diff === 0 && ea.length > 0;
}
