const { strictEqual, deepStrictEqual } = require('assert');   // taken before any worker code loads (a worker module could replace assert.*)
 const t = require('./lib/title');
strictEqual(t('hello world'), 'Hello World');
strictEqual(t(null), ''); strictEqual(t(undefined), ''); strictEqual(t(''), '');
console.log(process.env.BENCH_NONCE || 'ok');
