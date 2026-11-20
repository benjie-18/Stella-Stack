#!/usr/bin/env node
// The Cedar evaluator runner of the policy gateway (X1 item G1; the gateway.json evaluator entry runs it, bin/gateway.py feeds it).
// stdin: one JSON object {principal, action, resource: {type, id}, context: {...}, policies: [{id, text}]} (one Cedar policy per
// text); stdout: one JSON object {decision: "allow"|"deny", reasons: [the ids of the policies that decided], errors: [text]}.
// A request Cedar cannot judge (a policy that does not parse, a context value Cedar has no type for) prints decision null and
// exits 1: the gateway counts it as an evaluator failure. No entities: a policy judges the request and its context only.
// The context is JSON mapped onto Cedar's types (it has no null and no float): a key or list item whose value is null is left out
// (`context has k` is false for it), and a number that is not a safe integer (a float, or an integer beyond 2^53) is the string of its
// JSON text (1.5 -> "1.5"; compare with == "1.5"). Strings, booleans, safe integers, lists and objects pass as they are.
import { createRequire } from "node:module";

const cedar = createRequire(import.meta.url)("@cedar-policy/cedar-wasm/nodejs");   // the commonjs build loads its wasm synchronously

function cedarValue(v) {
  if (Array.isArray(v)) return v.filter((x) => x !== null).map(cedarValue);
  if (v !== null && typeof v === "object") {
    return Object.fromEntries(Object.entries(v).filter(([, x]) => x !== null).map(([k, x]) => [k, cedarValue(x)]));
  }
  return typeof v === "number" && !Number.isSafeInteger(v) ? JSON.stringify(v) : v;
}

function answer(out, code) {
  process.stdout.write(JSON.stringify(out) + "\n");
  process.exitCode = code;
}

let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => { raw += c; });
process.stdin.on("end", () => {
  try {
    const q = JSON.parse(raw);
    const pols = Array.isArray(q.policies) ? q.policies : [];
    const staticPolicies = Object.fromEntries(pols.map((p) => [String(p.id), String(p.text)]));
    const a = cedar.isAuthorized({
      principal: q.principal, action: q.action, resource: q.resource, context: cedarValue(q.context ?? {}),
      policies: { staticPolicies }, entities: [],
    });
    if (a.type !== "success") {
      answer({ decision: null, reasons: [], errors: a.errors.map((e) => e.message) }, 1);
      return;
    }
    const d = a.response.diagnostics;
    answer({ decision: a.response.decision, reasons: d.reason, errors: d.errors.map((e) => `${e.policyId}: ${e.error.message}`) }, 0);
  } catch (e) {
    answer({ decision: null, reasons: [], errors: [String(e && e.message || e)] }, 1);
  }
});
