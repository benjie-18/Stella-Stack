const assert = require('assert'); const i = require('./index');
assert.strictEqual(i.fetchUser(1), 'ann'); assert.strictEqual(i.fetchUser(9), null);
assert.strictEqual(i.greet(2), 'hi bo'); assert.strictEqual(i.greet(9), 'hi stranger');

const fs = require('fs'); const files = ['index.js', ...fs.readdirSync('lib').map((f) => 'lib/' + f)];
assert.deepStrictEqual(files.filter((f) => fs.readFileSync(f, 'utf8').includes('getUser')), [], 'getUser must not remain');
console.log('ok');
