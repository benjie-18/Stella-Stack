module.exports = function titleCase(s) {
  return s.split(' ').map((w) => w[0].toUpperCase() + w.slice(1)).join(' ');
};
