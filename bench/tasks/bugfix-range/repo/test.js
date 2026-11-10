const assert = require('assert'); const range = require('./lib/range');
assert.deepStrictEqual(range(2, 5), [2, 3, 4]);
assert.deepStrictEqual(range(0, 0), []);
console.log('ok');
