#!/usr/bin/env bash
# Self-test of the engine-model step of bin/register-toolsets.sh (F2b item H): a scratch copy of the tree, a scratch HOME with the
# default profile's folder, a fake hermes on PATH that keeps `config set` values. The expected model is read from the resolver, never named.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R=$T/root; mkdir -p "$R" "$T/home/.hermes" "$T/fh" "$T/store"
cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$R/"
sed -i "s#/workspace/#$R/#g; s#/workspace\"#$R\"#g" "$R/bin/register-toolsets.sh"   # a scratch copy never reads or writes the live root
sed -i "s#^ROOT = \"/workspace\"#ROOT = \"$R\"#" "$R/bin/roles.py"
printf 'model:\n  default: old\n' >"$T/home/.hermes/config.yaml"; echo old >"$T/store/model.default"
cat >"$T/fh/hermes" <<S
#!/usr/bin/env bash
[ "\${1:-}" = -p ] && exit 0   # only the default profile has a folder here
case "\$1 \${2:-}" in
  "config get") cat "$T/store/\$3" 2>/dev/null || echo unset;;
  "config set") printf '%s\n' "\$4" >"$T/store/\$3";;
  "tools list") printf '  \xe2\x9c\x93 enabled file\n';;
esac
exit 0
S
chmod +x "$T/fh/hermes"
fails=0; ok() { if ( eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
reg() { HOME=$T/home PATH="$T/fh:$PATH" STELLA_ROOT=$R "$R/bin/register-toolsets.sh" "$@" >"$T/out" 2>&1; echo $?; }
role=$(python3 -I "$R/bin/roles.py" spec "$T/home/.hermes" | jq -r '.default.role')
res=$(python3 -I "$R/bin/resolve.py" resolve --role "$role" --project "" --json 2>/dev/null)
jq -e .chain >/dev/null 2>&1 <<<"$res" || res=$(python3 -I "$R/bin/resolve.py" resolve --role "$role" --project "" --card "$(cat /proc/sys/kernel/random/uuid)" --json 2>/dev/null)
want=$(jq -r '[.chain[] | select(.status == "usable")][0].model // empty' <<<"$res")
if [ -n "$want" ]; then
  ok '[ "$(reg --check)" = 1 ] && grep -q "model.default is old, expected $want" "$T/out" && [ "$(cat "$T/store/model.default")" = old ]' "1 --check reports the stale model and changes nothing"
  reg >/dev/null; ok '[ "$(cat "$T/store/model.default")" = "$want" ] && ls "$T"/home/.hermes/backups/*/default.config.yaml' "2 apply sets the resolver's first usable model and backs up config.yaml"
  ok 'reg >/dev/null; grep -q "model.default $want (in sync)" "$T/out"' "3 a second apply finds it in sync"
else
  echo old >"$T/store/model.default"; rc=$(reg)
  ok '[ "$rc" != 0 ] && grep -q "model.default left unchanged: STL-" "$T/out" && [ "$(cat "$T/store/model.default")" = old ]' "1 no usable link: the model is unchanged, the code is reported, exit non-zero"
fi
echo "register-toolsets selftest: $fails failed"; [ "$fails" = 0 ] && echo "selftest PASS"   # the runner judges the last line (W1P-03)
[ "$fails" = 0 ]
