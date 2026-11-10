'use strict';
// bench/guard.js: preloaded (node --require) into the boxed check of a node task, before any worker code runs (S6C-06, S6D-01).
// It reads from stdin (the harness sends it there, so it is in no environment variable, no argument and no file) a one-time nonce and
// the protected test files. Every assert function is wrapped and then frozen, so worker code cannot replace them; only calls made from
// a protected test file are counted as passed or failed (the worker's own assert calls, padding, and failures it catches itself do not
// change the report; an async assertion counts when it settles). At exit one line is printed: @@BENCH-REPORT passed=N failed=M code=C
// mac=<sha256 of nonce:N:M:C>. Without the nonce nobody can make a valid line, so worker code that exits early, swallows the
// AssertionError, removes the exit listeners or prints its own report leaves the harness without a valid report, and the branch does
// not pass. Child node processes get no nonce and do nothing.
// shortcut: deliberate in-process tampering with JavaScript builtins the guard itself uses (e.g. Number.prototype.toString) is not
// stopped; a verdict computed in a separate process would be. Plain `bash` tasks use the nonce-on-last-line check instead.
const fs = require('fs');
const crypto = require('crypto');
const assert = require('assert');
const path = require('path');

let nonce = '';
let protectedFiles = new Set();
try {
  const lines = fs.readFileSync(0, 'utf8').split('\n').map((l) => l.trim()).filter(Boolean);
  nonce = lines[0] || '';
  protectedFiles = new Set(lines.slice(1).map((f) => path.resolve(process.cwd(), f)));
} catch (e) { /* no stdin: a child process */ }
if (nonce) {
  const writeSync = fs.writeSync;
  const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
  let passed = 0;
  let failed = 0;
  // The file that called an assert function: only calls made by a protected test file are counted (the worker's own assert calls,
  // padding, and failures it catches itself do not change the report).
  const callerFile = (self) => {
    const old = Error.prepareStackTrace;
    Error.prepareStackTrace = (_, sites) => sites;
    const holder = {};
    Error.captureStackTrace(holder, self);
    const sites = holder.stack;
    Error.prepareStackTrace = old;
    return Array.isArray(sites) && sites[0] ? sites[0].getFileName() : '';
  };
  const wrap = (fn) => function guarded(...args) {
    const counted = protectedFiles.has(callerFile(guarded));
    let r;
    try { r = fn.apply(this, args); } catch (e) { if (counted) failed += 1; throw e; }
    if (!counted) return r;
    if (r && typeof r.then === 'function') {   // rejects / doesNotReject: counted when the promise settles
      return Promise.resolve(r).then((v) => { passed += 1; return v; }, (e) => { failed += 1; throw e; });
    }
    passed += 1;
    return r;
  };
  const targets = [assert, assert.strict];
  for (const t of targets) {
    for (const k of Object.getOwnPropertyNames(t)) {
      const d = Object.getOwnPropertyDescriptor(t, k);
      if (d && typeof d.value === 'function' && k !== 'AssertionError' && k !== 'CallTracker' && k !== 'strict') {
        try { Object.defineProperty(t, k, { value: wrap(d.value), writable: false, configurable: false, enumerable: d.enumerable }); } catch (e) { /* not configurable */ }
      }
    }
  }
  Object.freeze(assert);
  Object.freeze(assert.strict);
  process.on('exit', (code) => {
    const c = typeof code === 'number' ? code : 0;
    const line = '@@BENCH-REPORT passed=' + passed + ' failed=' + failed + ' code=' + c + ' mac=' + sha256(nonce + ':' + passed + ':' + failed + ':' + c);
    try { writeSync(1, '\n' + line + '\n'); } catch (e) { /* stdout closed */ }
  });
}
