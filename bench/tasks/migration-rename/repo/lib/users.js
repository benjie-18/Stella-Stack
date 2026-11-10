const db = { 1: 'ann', 2: 'bo' };
exports.getUser = (id) => db[id] || null;
