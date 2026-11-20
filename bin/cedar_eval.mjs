#!/usr/bin/env node
// The Cedar evaluator runner of the policy gateway (X1 item G1; the gateway.json evaluator entry runs it, bin/gateway.py feeds it).
// stdin: one JSON object {principal, action, resource: {type, id}, context: {...}, policies: [{id, text}]} (one Cedar policy per
// text); stdout: one JSON object {decision: "allow"|"deny", reasons: [the ids of the policies that decided], errors: [text]}.
// A request Cedar cannot judge (a policy that does not parse, a context value Cedar has no type for) prints decision null and
// exits 1: the gateway counts it as an evaluator failure. No entities: a policy judges the request and its context only.
import { createRequire } from "node:module";

const cedar = createRequire(import.meta.url)("@cedar-policy/cedar-wasm/nodejs");   // the commonjs build loads its wasm synchronously

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
      principal: q.principal, action: q.action, resource: q.resource, context: q.context ?? {},
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
