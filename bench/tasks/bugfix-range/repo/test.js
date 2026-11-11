const { strictEqual, deepStrictEqual } = require('assert');   // taken before any worker code loads (a worker module could replace assert.*)
 const range = require('./lib/range');
deepStrictEqual(range(2, 5), [2, 3, 4]);
deepStrictEqual(range(0, 0), []);
console.log(process.env.BENCH_NONCE || 'ok');
