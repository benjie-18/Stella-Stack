const assert = require('assert'); const { execFileSync } = require('child_process');
const { slugify, version } = require('./index');
assert.strictEqual(version(), '1.0.0');
assert.strictEqual(slugify('Hello, World!'), 'hello-world');
assert.strictEqual(slugify('  a  b--c '), 'a-b-c');
assert.strictEqual(execFileSync('node', ['cli.js', 'Foo Bar']).toString().trim(), 'foo-bar');
console.log('ok');
