const { getUser } = require('./lib/users');
module.exports = { getUser, greet: require('./lib/greet').greet };
