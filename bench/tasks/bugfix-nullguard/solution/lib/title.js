module.exports = function titleCase(s) {
  if (!s) return '';
  return s.split(' ').map((w) => (w ? w[0].toUpperCase() + w.slice(1) : w)).join(' ');
};
