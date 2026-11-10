const db = { 1: 'ann', 2: 'bo' };
exports.fetchUser = (id) => db[id] || null;
