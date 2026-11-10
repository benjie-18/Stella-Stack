const { getUser } = require('./users');
exports.greet = (id) => 'hi ' + (getUser(id) || 'stranger');
