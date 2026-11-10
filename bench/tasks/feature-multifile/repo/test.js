const { strictEqual, deepStrictEqual } = require('assert');   // taken before any worker code loads (a worker module could replace assert.*)
 const { execFileSync } = require('child_process');
const { slugify, version } = require('./index');
strictEqual(version(), '1.0.0');
strictEqual(slugify('Hello, World!'), 'hello-world');
strictEqual(slugify('  a  b--c '), 'a-b-c');
strictEqual(execFileSync('node', ['cli.js', 'Foo Bar']).toString().trim(), 'foo-bar');
console.log(process.env.BENCH_NONCE || 'ok');
