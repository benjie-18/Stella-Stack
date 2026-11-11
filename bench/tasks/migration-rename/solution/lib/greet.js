const { fetchUser } = require('./users');
exports.greet = (id) => 'hi ' + (fetchUser(id) || 'stranger');
