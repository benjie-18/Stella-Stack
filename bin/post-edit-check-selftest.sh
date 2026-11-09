#!/usr/bin/env bash
# Hermetic self-test for scripts/post-edit-check.sh (Claude Code PostToolUse hook): stub npm, no network.
# STAGE=<dir> runs a staged copy while the hook is being replaced.
set -u
H=${STAGE:-/workspace/scripts}/post-edit-check.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
cat >"$T/bin/npm" <<'S'
#!/usr/bin/env bash
echo "$3" >>"$NPM_LOG"
[ "$3" = "${NPM_FAIL:-}" ] && { echo "boom from $3"; exit 1; }
exit 0
S
chmod +x "$T/bin/npm"
export PATH="$T/bin:$PATH" NPM_LOG="$T/npm.log" CLAUDE_PROJECT_DIR="$T"
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
run() { : >"$NPM_LOG"; out=$(echo '{}' | "$H" 2>&1); rc=$?; }

run
ok '[ "$rc" = 0 ] && grep -qx lint "$NPM_LOG"' "a clean edit: lint runs, exit 0"
ok '! grep -qx test "$NPM_LOG"' "the slow suite is not run after an edit (11-13 min against a 120 s hook timeout)"
NPM_FAIL=lint run
ok '[ "$rc" = 2 ] && grep -q "npm run lint failed" <<<"$out" && grep -q "boom from lint" <<<"$out"' "a lint failure is a blocking error (exit 2) with its output"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
