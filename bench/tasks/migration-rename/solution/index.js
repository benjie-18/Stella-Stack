const { fetchUser } = require('./lib/users');
module.exports = { fetchUser, greet: require('./lib/greet').greet };
