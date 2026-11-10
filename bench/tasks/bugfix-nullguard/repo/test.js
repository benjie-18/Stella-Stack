const assert = require('assert'); const t = require('./lib/title');
assert.strictEqual(t('hello world'), 'Hello World');
assert.strictEqual(t(null), ''); assert.strictEqual(t(undefined), ''); assert.strictEqual(t(''), '');
console.log('ok');
