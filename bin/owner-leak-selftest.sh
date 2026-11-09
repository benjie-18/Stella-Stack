#!/usr/bin/env bash
# Leak self-test (D39): no owner value from the real config/owner.env (OWNER_NAME, GITHUB_OWNER, the Discord ids, the
# Windows stack path, also as \\-escaped and /mnt/<drive>/ forms) in a tracked or untracked non-ignored file. Allowlist:
# decisions.md (history) only. Names and ids match as whole words, case-sensitive. A fresh clone (no config/owner.env)
# reports SKIP. The one self-test that reads the real config: it compares against it, nothing else.
set -u
inner=${1:-}   # --inner: the nested run of the K13 check below (an argument, so no environment can switch the check off)
CFG="${OWNER_LEAK_CFG:-/workspace/config/owner.env}"   # override: tests of the fresh-clone SKIP only
[ -e "$CFG" ] || { echo "SKIP no $CFG (fresh clone)"; echo "selftest SKIP"; exit 0; }
eval "$(OWNER_CONFIG="$CFG" python3 -I /workspace/bin/owner_config.py --shell)" || { echo "FAIL cannot read $CFG"; exit 1; }
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
p="${OWNER_STACK_PATH_WIN%\\}"
words=() fixed=(-e "$p" -e "${p//\\/\\\\}" -e "/mnt/$(tr A-Z a-z <<<"${p:0:1}")$(tr '\\' / <<<"${p:2}")")
for v in "$OWNER_NAME" "$GITHUB_OWNER" "$OWNER_DISCORD_USER_ID" "$DISCORD_GUILD_ID" "$ESCALATIONS_CHANNEL_ID" "$SUPERVISOR_CHANNEL_ID"; do
  [ -z "$v" ] || words+=(-e "$v")
done
scan() {  # NUL-separated file names on stdin -> matching lines
  local l; l=$(mktemp); cat >"$l"
  xargs -0 -r grep -nIHwF "${words[@]}" -- <"$l" 2>/dev/null; xargs -0 -r grep -nIHF "${fixed[@]}" -- <"$l" 2>/dev/null
  rm -f "$l"
}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf 'x %s y\n' "$OWNER_NAME" > "$T/a"; printf 'x%sy\n' "$OWNER_NAME" > "$T/b"; printf '%s\\docs\n' "${p//\\/\\\\}" > "$T/c"
ok '[ "$(printf "%s\0" "$T/a" "$T/b" "$T/c" | scan | cut -d: -f1 | sort -u | tr "\n" " ")" = "$T/a $T/c " ]' "the scan finds a planted name and an escaped path, and no name inside a longer word"
ok '! printf "%s\0" /workspace/config/owner.example.env | scan | grep -q .' "config/owner.example.env holds no owner value"
list_files() { (cd /workspace && git ls-files -coz --exclude-standard); }  # its exit status is kept: an empty list is not a pass
ok '[ -n "$inner" ] || ! GIT_DIR=/nonexistent bash "$0" --inner >/dev/null 2>&1' "the whole selftest fails when git cannot list files (K13), not an empty repo read as clean"
list_files >"$T/files" 2>"$T/git.err"; rc=$?
ok '[ "$rc" = 0 ]' "git lists the repo's files (exit $rc)"
[ "$rc" = 0 ] || head -3 "$T/git.err" | sed 's/^/     /'
hits=$(grep -zvx decisions.md <"$T/files" | scan)
ok '[ -z "$hits" ]' "no owner value in any tracked or untracked non-ignored file outside decisions.md"
[ -z "$hits" ] || printf '%s\n' "$hits" | cut -c1-200 | sed 's/^/     /'
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
