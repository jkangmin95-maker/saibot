// deno test supabase/functions/imweb-poll/
import { assertEquals } from "jsr:@std/assert@1";
import { codeFromValue, decideAll, decideOrder, extractPayCode, paymentState, safeEqual } from "./logic.ts";
import fixtures from "./fixtures/orders.json" with { type: "json" };
// deno-lint-ignore no-explicit-any
const F: Record<string, any> = fixtures;
const P = 11;
const one = (k: string) => decideOrder(F[k], P);

Deno.test("paid order → paid with code", () => {
  assertEquals(one("paid"), [{ orderNo: 1001, itemKey: "OI1001", action: "paid", payCode: "UR-ABC234", qty: 1 }]);
});
Deno.test("code is normalized (case, spaces, dashes) from optionInfoList objects", () => {
  assertEquals(one("paid_messy_code")[0].payCode, "UR-ABC234");
  assertEquals(codeFromValue("ur abc234"), "UR-ABC234");
  assertEquals(codeFromValue("UR–ABC234"), "UR-ABC234"); // en dash
  assertEquals(codeFromValue("ＵＲ－ＡＢＣ２３４"), "UR-ABC234"); // full width
  assertEquals(codeFromValue("UR-ABC2345"), null);
});
Deno.test("fallback regex finds exactly one UR- code anywhere in the options", () => {
  assertEquals(one("paid_fallback_regex")[0], { orderNo: 1003, itemKey: "OI1003", action: "paid", payCode: "UR-XYZ789", qty: 1 });
});
Deno.test("two different codes → no_code (ambiguous)", () => {
  assertEquals(one("ambiguous")[0].action, "no_code");
});
Deno.test("refunds / cancels / returns → revoke (with code when present)", () => {
  for (const k of ["refunded", "partial_refund", "cancel_section", "return_request", "cancelled_before_deposit"]) {
    const d = one(k);
    assertEquals(d.length, 1, k);
    assertEquals(d[0].action, "revoke", k);
    assertEquals(d[0].payCode, "UR-ABC234", k);
  }
});
Deno.test("paid but missing / unparseable code → no_code", () => {
  assertEquals(one("missing_code")[0].action, "no_code");
  assertEquals(one("missing_code")[0].payCode, null);
  assertEquals(one("no_options")[0].action, "no_code");
});
Deno.test("wrong product → nothing", () => assertEquals(one("wrong_product"), []));
Deno.test("pending bank transfer, FREE payment, refund in flight → nothing", () => {
  assertEquals(one("pending_bank"), []);
  assertEquals(one("free_payment"), []);
  assertEquals(one("refund_processing"), []);
});
Deno.test("multi-product order → only prodNo 11 item", () => {
  assertEquals(one("multi"), [{ orderNo: 1016, itemKey: "OI1016", action: "paid", payCode: "UR-QQQ222", qty: 1 }]);
});
Deno.test("duplicates across pages collapse; last copy wins", () => {
  const d = decideAll([F.paid, F.duplicate, F.wrong_product, F.paid], P);
  assertEquals(d.length, 1);
  const later = structuredClone(F.paid);
  later.payments[0].paymentStatus = "REFUND_COMPLETE";
  assertEquals(decideAll([F.paid, later], P)[0].action, "revoke");
});
Deno.test("garbage input never throws", () => {
  for (const x of [null, {}, { orderNo: "x" }, { orderNo: 5, sections: "no" }, { orderNo: 5, sections: [{ sectionItems: [null] }] }]) {
    assertEquals(decideOrder(x, P), []);
  }
  assertEquals(extractPayCode(null), null);
  assertEquals(extractPayCode({ optionInfo: '{"결제 확인 코드":"UR-ABC234"}' }), "UR-ABC234"); // JSON string shape
  assertEquals(paymentState({}), "pending");
});
Deno.test("cancel payment entry marks order revoked", () => {
  const o = structuredClone(F.paid);
  o.payments.push({ paymentStatus: "PAYMENT_COMPLETE", isCancel: "Y", method: "CARD" });
  assertEquals(decideOrder(o, P)[0].action, "revoke");
});
Deno.test("safeEqual", () => {
  assertEquals(safeEqual("abc", "abc"), true);
  assertEquals(safeEqual("abc", "abd"), false);
  assertEquals(safeEqual("abc", "abcd"), false);
  assertEquals(safeEqual("", ""), false);
});
Deno.test("each prodNo item has a stable, distinct itemKey (one 30-day pass per item)", () => {
  const a = decideAll([F.paid, F.paid_messy_code, F.duplicate], P);
  assertEquals(a.map((d) => `${d.orderNo}/${d.itemKey}`), ["1001/OI1001", "1002/OI1002"]);
  assertEquals(decideOrder(F.paid, P)[0].itemKey, decideOrder(F.duplicate, P)[0].itemKey);
});
Deno.test("quantity: qty N → one decision with qty N; bad qty → nothing", () => {
  const two = structuredClone(F.paid); two.sections[0].sectionItems[0].qty = 2;
  assertEquals(decideOrder(two, P), [{ orderNo: 1001, itemKey: "OI1001", action: "paid", payCode: "UR-ABC234", qty: 2 }]);
  const str = structuredClone(F.paid); str.sections[0].sectionItems[0].qty = "3";
  assertEquals(decideOrder(str, P)[0].qty, 3);
  for (const bad of [0, -1, 1.5, "x"]) {
    const o = structuredClone(F.paid); o.sections[0].sectionItems[0].qty = bad;
    assertEquals(decideOrder(o, P), [], String(bad));
  }
  const rv = structuredClone(F.refunded); rv.sections[0].sectionItems[0].qty = 2;
  assertEquals(decideOrder(rv, P)[0].action, "revoke");
});
