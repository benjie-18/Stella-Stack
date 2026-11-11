const { strictEqual, deepStrictEqual } = require('assert');   // taken before any worker code loads (a worker module could replace assert.*)
 const i = require('./index');
strictEqual(i.fetchUser(1), 'ann'); strictEqual(i.fetchUser(9), null);
strictEqual(i.greet(2), 'hi bo'); strictEqual(i.greet(9), 'hi stranger');

const fs = require('fs'); const files = ['index.js', ...fs.readdirSync('lib').map((f) => 'lib/' + f)];
deepStrictEqual(files.filter((f) => fs.readFileSync(f, 'utf8').includes('getUser')), [], 'getUser must not remain');
console.log(process.env.BENCH_NONCE || 'ok');
