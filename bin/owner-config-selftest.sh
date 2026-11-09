#!/usr/bin/env bash
# Hermetic self-test for the owner config loaders (D39): bin/owner-config.sh and bin/owner_config.py. Stub hermes, scratch
# state, no network. A missing or incomplete config fails loudly and never falls back to the real config/owner.env.
# K8/K9 (SOUL rendering): SOULS=<dir>, STAGE=<bin dir>, ROLES_FILE=<table> and RTT=<reviewer terminal hook> point the SOUL cases at staged copies.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sup/state"
printf '#!/usr/bin/env bash\nshift; printf "%%s\\n" "$*" >> "$ESCALATE_SUP_DIR/sends"\n' > "$T/bin/hermes"; chmod +x "$T/bin/hermes"
printf 'ALERT_TARGET="discord:#alerts"\n' > "$T/sup/limits.env"
export PATH="$T/bin:$PATH" ESCALATE_SUP_DIR="$T/sup"
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
shell_vals() { ( . /workspace/bin/owner-config.sh; owner_config_read || exit 1; printf '%s|' "$OWNER_NAME" "$OWNER_STACK_PATH_WIN" "$OWNER_DISCORD_USER_ID" ); }
py_vals() { python3 -I -c 'import sys; sys.path.insert(0, "/workspace/bin"); import owner_config as o; c = o.load(); print("".join(c[k] + "|" for k in ("OWNER_NAME", "OWNER_STACK_PATH_WIN", "OWNER_DISCORD_USER_ID")), end="")'; }
events() { jq -r --arg e "$1" 'select(.event == $e) | .event' "$T/sup/escalations.log" 2>/dev/null | wc -l; }

# No fallback: a non-existent OWNER_CONFIG fails even though /workspace/config/owner.env may exist.
export OWNER_CONFIG="$T/does-not-exist.env"
ok '! shell_vals >/dev/null 2>&1 && ! py_vals >/dev/null 2>&1' "non-existent OWNER_CONFIG: shell and Python loaders fail, no fallback to real values"
ok '( . /workspace/bin/owner-config.sh; owner_config_read; [ -z "${OWNER_NAME:-}" ] && grep -q "does-not-exist.env" <<<"$OWNER_CONFIG_ERROR" )' "the error names the missing file and no key is set"
( card=t_aaaaaaaa; . /workspace/bin/owner-config.sh; owner_config_load ) 2>/dev/null; rc1=$?
( . /workspace/bin/owner-config.sh; owner_config_load ) 2>/dev/null
ok '[ "$rc1" = 1 ] && [ "$(events OWNER_CONFIG_MISSING)" = 2 ]' "owner_config_load: returns 1 and logs OWNER_CONFIG_MISSING every time"
ok '[ "$(grep -c "^--to discord:#alerts --quiet .*\[STL-CFG-301\]\*\*$" "$T/sup/sends")" = 1 ] && ! grep -q "does-not-exist" "$T/sup/sends" && grep -q "^STL-CFG-301 .*does-not-exist.env" "$T/sup/logs/alerts.log"' "one #alerts line, not one per call (at most one an hour)"
/workspace/bin/escalation-thread.sh t_aaaaaaaa "Title" "Decision needed: A or B." >/dev/null 2>&1; rc=$?
ok '[ "$rc" = 3 ] && [ "$(events OWNER_CONFIG_MISSING)" = 3 ]' "escalation script exits 3 and logs OWNER_CONFIG_MISSING (escalation-on-block.sh logs the card's HOOK_RESULT)"
rc=$(jq -nc '{tool_name: "kanban_block", tool_input: {task_id: "t_aaaaaaaa", reason: "x"}}' | /workspace/bin/kanban-guard.sh >/dev/null 2>&1; echo $?)
ok '[ "$rc" != 2 ]' "the kanban guard stays fail-open on a missing config (exit $rc, not 2)"
ok '! /workspace/bin/owner-config.sh --check >/dev/null' "--check fails on a missing config"
# F27: Stella's read-only status tool reads the config quietly: a missing config writes nothing and posts nothing.
rm -f "$T/sup/state/alert-owner-config-missing.stamp"; touch "$T/marker"; sleep 0.01
/workspace/bin/escalations-status.sh >/dev/null 2>&1; rc=$?
ok '[ "$rc" = 3 ] && [ -z "$(find "$T/sup" -newer "$T/marker")" ]' "F27: escalations-status.sh on a missing config exits 3, writes nothing, posts nothing"

# One grammar for shell and Python: single quotes literal (backslashes, #, spaces, $), CRLF, comments, last key wins.
printf "# comment\r\nOWNER_NAME='A \$B #c'\r\nOWNER_DISCORD_USER_ID=\nOWNER_STACK_PATH_WIN='C:\\\\stack\\\\'\nGITHUB_OWNER=org\nDISCORD_GUILD_ID=12345\nESCALATIONS_CHANNEL_ID='100000000000000003'\nSUPERVISOR_CHANNEL_ID=1\nSUPERVISOR_CHANNEL_ID=100000000000000004\n" > "$T/g.env"
export OWNER_CONFIG="$T/g.env"
ok '[ "$(shell_vals)" = "A \$B #c|C:\\stack\\||" ] && [ "$(py_vals)" = "$(shell_vals)" ]' "shell and Python read the same values (quoted literal, CRLF, empty owner id)"
ok 'python3 -I -c "import sys; sys.path.insert(0, \"/workspace/bin\"); import owner_config as o; assert o.windows(o.load(), \"a/b.md\") == \"C:\\\\stack\\\\a\\\\b.md\""' "one trailing backslash of the path is dropped when joining"
out=$(/workspace/bin/owner-config.sh --check); rc=$?
ok '[ "$rc" = 1 ] && grep -q "FAIL DISCORD_GUILD_ID" <<<"$out" && ! grep -q "FAIL SUPERVISOR_CHANNEL_ID\\|FAIL OWNER_DISCORD_USER_ID" <<<"$out" && grep -q "WARN OWNER_DISCORD_USER_ID is empty" <<<"$out"' "--check: a short id fails; the last of two keys wins; an empty owner id only warns"
ok 'grep -q "WARN $T/g.env is writable" <<<"$out" && grep -q "WARN $T is writable, so $T/g.env can be replaced: chmod 555 $T" <<<"$out"' "--check warns when the file or its folder is writable (D40)"
# K5 (owner decision 2026-10-29): a double-quoted value with no $, backtick, backslash or " is accepted and reads exactly as
# its single-quoted form. k5_form: an error names the file, the line number and the three accepted forms (not the sentence).
k5_form() { grep -qF "$1 line $2:" "$3" && grep -qF 'KEY=value' "$3" && grep -qF "KEY='value'" "$3" && grep -qF 'KEY="value"' "$3"; }
k5_val() { [ "$(OWNER_CONFIG="$1" shell_vals | cut -d'|' -f1)" = "$2" ] && [ "$(OWNER_CONFIG="$1" py_vals | cut -d'|' -f1)" = "$2" ]; }
{ cat /workspace/config/owner.example.env; printf '%s\n' 'OWNER_NAME="x"'; } > "$T/k5-x.env"
ok 'k5_val "$T/k5-x.env" x' 'K5: OWNER_NAME="x" is accepted and reads x in the shell and Python loaders'
{ cat /workspace/config/owner.example.env; printf '%s\n' 'OWNER_NAME="A B #c"'; } > "$T/k5-dq.env"
{ cat /workspace/config/owner.example.env; printf '%s\n' "OWNER_NAME='A B #c'"; } > "$T/k5-sq.env"
k5_same() { [ "$(OWNER_CONFIG="$T/k5-dq.env" shell_vals)" = "$(OWNER_CONFIG="$T/k5-sq.env" shell_vals)" ] && [ "$(OWNER_CONFIG="$T/k5-dq.env" py_vals)" = "$(OWNER_CONFIG="$T/k5-sq.env" py_vals)" ]; }
ok 'k5_val "$T/k5-dq.env" "A B #c" && k5_same' 'K5: OWNER_NAME="A B #c" (a space and a #) reads exactly like OWNER_NAME='"'"'A B #c'"'"', in both loaders'
apos="Dana's #1"; { cat /workspace/config/owner.example.env; printf '%s\n' "OWNER_NAME=\"$apos\""; } > "$T/k5-apos.env"
ok 'k5_val "$T/k5-apos.env" "$apos"' "K5: a single quote inside double quotes is literal (OWNER_NAME=\"$apos\")"
{ cat /workspace/config/owner.example.env; printf '%s\n' 'OWNER_NAME=""'; } > "$T/k5-edq.env"
{ cat /workspace/config/owner.example.env; printf '%s\n' "OWNER_NAME=''"; } > "$T/k5-esq.env"
k5_empty() { for f in k5-edq k5-esq; do ! OWNER_CONFIG="$T/$f.env" shell_vals >/dev/null 2>&1 || return 1; OWNER_CONFIG="$T/$f.env" python3 -I /workspace/bin/owner_config.py --shell 2>&1 >/dev/null | grep -q "missing or empty OWNER_NAME" || return 1; done; }
ok k5_empty 'K5: OWNER_NAME="" is refused as missing or empty, as OWNER_NAME='"''"' is (both loaders)'
# K5: this change follows the owner's K5 decision of 2026-10-29. OWNER_NAME="x" moved to the accepted cases above; the other
# bad lines and the double-quote variants below must still fail, in both loaders, with the error form.
for bad in "OWNER_NAME=a b" "OWNER_NAME=\$HOME" "OWNER_STACK_PATH_WIN=C:\\x" "export OWNER_NAME=x" 'OWNER_NAME="x$y"' 'OWNER_NAME="a`b"' 'OWNER_STACK_PATH_WIN="C:\\x"' 'OWNER_NAME="a"b"' 'OWNER_NAME="x'; do
  { cat /workspace/config/owner.example.env; printf '%s\n' "$bad"; } > "$T/bad.env"
  OWNER_CONFIG="$T/bad.env" shell_vals >/dev/null 2>&1 && { echo "FAIL accepted bad line: $bad"; fails=$((fails+1)); }
  OWNER_CONFIG="$T/bad.env" py_vals >/dev/null 2>&1 && { echo "FAIL python accepted bad line: $bad"; fails=$((fails+1)); }
  OWNER_CONFIG="$T/bad.env" python3 -I /workspace/bin/owner_config.py --shell >/dev/null 2>"$T/bad.err"
  k5_form "$T/bad.env" "$(wc -l < "$T/bad.env")" "$T/bad.err" || { echo "FAIL no file, line number and forms in the error: $bad"; fails=$((fails+1)); }
done
ok 'true' "lines outside the grammar are refused (unquoted space, double quotes, \$, backslash, export)"

# K5: the #alerts text (STL-CFG-301) names the bad line and the three forms, never a value from the file; a missing file names
# neither. The real entry point escalation-thread.sh is run too (it sends through the stub hermes). Each case has its own state dir.
{ cat /workspace/config/owner.example.env; printf '%s\n' 'OWNER_NAME="zq7marker$x"'; } > "$T/k5-mal.env"
k5_alert() { rm -rf "$2"; mkdir -p "$2/state" "$2/logs"; ( export ESCALATE_SUP_DIR="$2" OWNER_CONFIG="$1"; . /workspace/bin/owner-config.sh; owner_config_load ) >/dev/null 2>&1; cat "$2/sends" 2>/dev/null; }
mal=$(k5_alert "$T/k5-mal.env" "$T/k5-mal"); gone=$(k5_alert "$T/k5-missing.env" "$T/k5-gone")
k5_names() { grep -q STL-CFG-301 <<<"$1" && grep -qE "line $2([^0-9]|\$)" <<<"$1" && grep -qF 'KEY=value' <<<"$1" && grep -qF "KEY='value'" <<<"$1" && grep -qF 'KEY="value"' <<<"$1"; }
k5_silent() { grep -q STL-CFG-301 <<<"$1" && ! grep -qE 'line [0-9]' <<<"$1" && ! grep -qF 'KEY=value' <<<"$1" && ! grep -qF "KEY='value'" <<<"$1" && ! grep -qF 'KEY="value"' <<<"$1"; }
ok 'k5_names "$mal" "$(wc -l < "$T/k5-mal.env")"' "K5: the #alerts text for a malformed line names its line number and the three accepted forms"
ok 'grep -q STL-CFG-301 <<<"$mal" && ! grep -q zq7marker <<<"$mal"' "K5: the #alerts text for a malformed line never contains a value from the file"
ok 'k5_silent "$gone"' "K5: the #alerts text for a missing file names no line and no form"
rm -rf "$T/k5-thr"; mkdir -p "$T/k5-thr/state" "$T/k5-thr/logs"
ESCALATE_SUP_DIR="$T/k5-thr" OWNER_CONFIG="$T/k5-mal.env" /workspace/bin/escalation-thread.sh t_aaaaaaaa "Title" "Decision needed: A or B." >/dev/null 2>&1; k5_trc=$?
ok '[ "$k5_trc" = 3 ] && k5_names "$(cat "$T/k5-thr/sends" 2>/dev/null)" "$(wc -l < "$T/k5-mal.env")"' "K5: escalation-thread.sh on a malformed line exits 3 and its #alerts send names the line and the forms"
# K5 follow-up (the verifier's findings): lines end at "\n" only; after a value only space, tab or CR may follow; the unquoted
# class excludes shell operators, glob and tilde characters; a blank line is spaces, tabs or CRs; the file is UTF-8 (a BOM is
# ignored, a bad byte names its line and never crashes). Every fixture is a scratch file, the bad line is always the last one.
k5_bad() { { cat /workspace/config/owner.example.env; printf '%s\n' "$1"; } > "$2"; }
k5_refuse() { # k5_refuse <file> <line>: both loaders refuse; --shell exits 2 with the file, the line and the forms, no traceback
  local err="$T/k5-refuse.err"
  OWNER_CONFIG="$1" python3 -I /workspace/bin/owner_config.py --shell >/dev/null 2>"$err"; [ "$?" = 2 ] || return 1
  ! grep -q Traceback "$err" && grep -qF "$1 line $2:" "$err" && k5_form "$1" "$2" "$err" && ! OWNER_CONFIG="$1" shell_vals >/dev/null 2>&1 && ! OWNER_CONFIG="$1" py_vals >/dev/null 2>&1
}
k5_bad $'OWNER_NAME="x"\xc2\xa0' "$T/k5-nbsp.env"
ok 'k5_refuse "$T/k5-nbsp.env" "$(wc -l < "$T/k5-nbsp.env")"' 'K5: OWNER_NAME="x" followed by a no-break space (U+00A0) is refused with its line number, no traceback'
k5_bad $'OWNER_NAME="x"\x0b' "$T/k5-vt.env"
ok 'k5_refuse "$T/k5-vt.env" "$(wc -l < "$T/k5-vt.env")"' 'K5: OWNER_NAME="x" followed by a vertical tab (\x0b) is refused with its line number'
k5_bad $'OWNER_NAME="x"\xe3\x80\x80' "$T/k5-ideo.env"
ok 'k5_refuse "$T/k5-ideo.env" "$(wc -l < "$T/k5-ideo.env")"' 'K5: OWNER_NAME="x" followed by an ideographic space (U+3000) is refused with its line number'
k5_bad $'OWNER_NAME="x"\x1cGITHUB_OWNER=\'y\'' "$T/k5-fs.env"
ok 'k5_refuse "$T/k5-fs.env" "$(wc -l < "$T/k5-fs.env")"' "K5: OWNER_NAME=\"x\"<FS>GITHUB_OWNER='y' on one line is refused: a file separator does not end a line"
k5_bad 'OWNER_NAME=~' "$T/k5-tilde.env"
ok 'k5_refuse "$T/k5-tilde.env" "$(wc -l < "$T/k5-tilde.env")"' 'K5: an unquoted ~ is refused with its line number'
k5_bad 'OWNER_NAME=x>y' "$T/k5-gt.env"
ok 'k5_refuse "$T/k5-gt.env" "$(wc -l < "$T/k5-gt.env")"' 'K5: an unquoted x>y is refused with its line number'
k5_bad 'OWNER_NAME=x;' "$T/k5-semi.env"
ok 'k5_refuse "$T/k5-semi.env" "$(wc -l < "$T/k5-semi.env")"' 'K5: an unquoted x; is refused with its line number'
k5_bad 'OWNER_NAME=a[b]' "$T/k5-brk.env"
ok 'k5_refuse "$T/k5-brk.env" "$(wc -l < "$T/k5-brk.env")"' 'K5: an unquoted a[b] is refused with its line number'
k5_bad $'\xc2\xa0' "$T/k5-nbsp-only.env"
ok 'k5_refuse "$T/k5-nbsp-only.env" "$(wc -l < "$T/k5-nbsp-only.env")"' 'K5: a line holding only a no-break space is refused (it is not blank) with its line number'
k5_bad $'OWNER_NAME="caf\xe9"' "$T/k5-latin.env"
ok 'k5_refuse "$T/k5-latin.env" "$(wc -l < "$T/k5-latin.env")"' 'K5: a latin-1 byte in a value is refused with its line number and the forms, no traceback'
lat=$(k5_alert "$T/k5-latin.env" "$T/k5-lat")
ok 'k5_names "$lat" "$(wc -l < "$T/k5-latin.env")"' 'K5: owner_config_load on a latin-1 byte: the #alerts send names its line and the forms'
{ printf '%s' $'\xef\xbb\xbf'; printf 'OWNER_NAME="A B"\n'; grep -v '^OWNER_NAME=' /workspace/config/owner.example.env; } > "$T/k5-bom.env"
{ printf 'OWNER_NAME="A B"\n'; grep -v '^OWNER_NAME=' /workspace/config/owner.example.env; } > "$T/k5-nobom.env"
k5_eq() { [ "$(OWNER_CONFIG="$1" shell_vals)" = "$(OWNER_CONFIG="$2" shell_vals)" ] && [ "$(OWNER_CONFIG="$1" py_vals)" = "$(OWNER_CONFIG="$2" py_vals)" ]; }
ok 'k5_eq "$T/k5-bom.env" "$T/k5-nobom.env" && k5_val "$T/k5-bom.env" "A B"' 'K5: a UTF-8 BOM on line 1 is ignored: the same values as without it, in both loaders'
{ cat /workspace/config/owner.example.env; printf '%s\n' $'OWNER_NAME="x"   '; } > "$T/k5-sp.env"
ok 'k5_val "$T/k5-sp.env" x' 'K5: OWNER_NAME="x" followed by spaces is accepted'
{ cat /workspace/config/owner.example.env; printf '%s\n' $'OWNER_NAME="x"\t'; } > "$T/k5-tab.env"
ok 'k5_val "$T/k5-tab.env" x' 'K5: OWNER_NAME="x" followed by a tab is accepted'
{ cat /workspace/config/owner.example.env; printf '%s\n' $'OWNER_NAME="x"\r'; } > "$T/k5-crlf.env"
ok 'k5_val "$T/k5-crlf.env" x' 'K5: OWNER_NAME="x" with a CRLF line end is accepted'
{ cat /workspace/config/owner.example.env; printf '%s\n' 'OWNER_NAME="x"' $'   \t\r'; } > "$T/k5-blank.env"
ok 'k5_val "$T/k5-blank.env" x' 'K5: a line of spaces, tabs and a CR is blank and accepted'
grep -v '^GITHUB_OWNER=' /workspace/config/owner.example.env > "$T/inc.env"
ok '! OWNER_CONFIG="$T/inc.env" shell_vals >/dev/null 2>&1 && OWNER_CONFIG="$T/inc.env" python3 -I /workspace/bin/owner_config.py --shell 2>&1 | grep -q "missing or empty GITHUB_OWNER"' "an incomplete config fails and names the key"
ok 'OWNER_CONFIG=/workspace/config/owner.example.env /workspace/bin/owner-config.sh --check | grep -q "owner config: OK"' "config/owner.example.env passes --check"

# Rendering (SOULs and the board description): exact text, no sed; unknown or leftover placeholders are errors.
render() { python3 -I -c 'import sys; sys.path.insert(0, "/workspace/bin"); import owner_config as o; print(o.render(sys.argv[1], o.load()))' "$1" 2>&1; }
ok '[ "$(OWNER_CONFIG="$T/g.env" render "{{OWNER_STACK_PATH_WIN}}\\<p> {{OWNER_NAME}}")" = "C:\\stack\\<p> A \$B #c" ]' "render: values replaced exactly (backslashes, \$, #), one trailing backslash dropped"
ok 'OWNER_CONFIG="$T/g.env" render "{{OWNER_NAM}}" | grep -q "unknown placeholder {{OWNER_NAM}}" && OWNER_CONFIG="$T/g.env" render "{{{{OWNER_NAME}}}}" | grep -q "placeholder left"' "render: an unknown or leftover placeholder is an error"
# D46: a SOUL source also takes the role values (bin/roles.py soul_values) for the profile whose row names it, exactly as
# bin/apply-hermes-local.sh renders it; the board binding is a scratch projects.db.
python3 -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("create table projects (id, slug, name, board_slug, primary_path, archived)"); c.execute("insert into projects values (?, ?, ?, ?, ?, 0)", ("p_0000aaaa", "proj-a", "A", sys.argv[2], "/workspace")); c.commit()' "$T/projects.db" "$(. /workspace/bin/kanban-board.sh; echo "$KANBAN_BOARD")"
SOULS=${SOULS:-/workspace/docs/hermes-local/soul}   # the SOUL sources under test (staged copies while they are being replaced)
S=${STAGE:-/workspace/bin}   # owner_config.py and roles.py under test
RF=${ROLES_FILE:-/workspace/docs/hermes-local/roles.json}   # the role table under test
RTT=${RTT:-/workspace/docs/hermes-local/hooks/reviewer/test-only-terminal.sh}   # the reviewer terminal hook under test
render_soul() { PROJECTS_DB="$T/projects.db" python3 -I -c 'import sys; sys.path.insert(0, sys.argv[3]); import owner_config as o, roles; d = roles.load(); p = next(n for n, r in d["profiles"].items() if r.get("soul") == sys.argv[2]); print(o.render(sys.argv[1], dict(o.load(), **roles.soul_values(d, p))))' "$(cat "$1")" "${1##*/}" "$S" 2>&1; }
ok '( for f in $SOULS/*.md; do OWNER_CONFIG=/workspace/config/owner.example.env render_soul "$f" | grep -q "{{\|placeholder\|Error" && exit 1; done; OWNER_CONFIG=/workspace/config/owner.example.env render "$(cat /workspace/docs/hermes-local/board.md)" | grep -q "{{\|placeholder\|Error" && exit 1; true )' "every SOUL source and the board source render cleanly"

ok '[ "$(OWNER_LEAK_CFG="$T/none.env" /workspace/bin/owner-leak-selftest.sh 2>/dev/null | tail -1)" = "selftest SKIP" ]' "leak test on a fresh clone (no config/owner.env): SKIP, not a failure"

RULE="- A card assigned to builder-local always contains, in its body, the exact command \`cd <worktree path> && opencode run --standalone --auto '<instruction>'\`, and says that the worker runs this command and does not write the deliverable itself."
# Retired by the owner (2026-11-04, K9): the dispatcher no longer puts a shell command in builder-local card bodies; the
# replacement assertions below ("Never put a shell command", no opencode template) carry the rule's intent.
ok '! OWNER_CONFIG=/workspace/config/owner.example.env render_soul $SOULS/default.md | grep -qxF -- "$RULE"' "rendered default SOUL no longer carries the retired builder-local delegate-command rule (K9)"
# K8/K9: the SOULs. The builders' SOULs name the table's reviewers (rendered {{REVIEWERS}}); the dispatcher's card bodies are
# plain language (no command in a body); the reviewer's SOUL names the read-only git forms its terminal hook allows.
RL=$(ROLES_FILE=$RF python3 -I -c 'import sys, json; sys.path.insert(0, sys.argv[1]); import roles; print(", ".join("`" + p + "`" for p in roles.reviewers(roles.load())))' "$S" 2>&1)
ok '[ -n "$RL" ] && [ "${RL#*Error}" = "$RL" ]' "K8: the table lists a reviewing profile for the SOUL ($RL)"
for f in $(grep -l "{{REVIEWERS}}" $SOULS/*.md); do
  ok 'out=$(OWNER_CONFIG=/workspace/config/owner.example.env render_soul "$f"); grep -qF "reviewer\` set to one of $RL:" <<<"$out" && ! grep -q "{{" <<<"$out"' "K8: ${f##*/} renders {{REVIEWERS}} as the table's reviewers, no placeholder left"
done
ok '[ "$(grep -l "{{REVIEWERS}}" $SOULS/*.md | wc -l)" = 2 ] && grep -q "{{REVIEWERS}}" $SOULS/builder-local.md $SOULS/builder-claude.md' "K8: exactly the two builder SOULs carry {{REVIEWERS}}"
jq '.roles[].may_review = false' "$RF" >"$T/nomr0.json"
ok 'out=$(ROLES_FILE=$T/nomr0.json OWNER_CONFIG=/workspace/config/owner.example.env render_soul $SOULS/builder-local.md) && grep -qF "(no reviewing profile listed)" <<<"$out" && ! grep -q "{{" <<<"$out"' "K8: with no reviewing role the builder SOUL says '(no reviewing profile listed)', no placeholder left"
D9=$(OWNER_CONFIG=/workspace/config/owner.example.env render_soul $SOULS/default.md)
ok 'grep -qF "Never put a shell command" <<<"$D9" && ! grep -qF "cd <worktree path>" <<<"$D9" && ! grep -qF "opencode run --standalone --auto '"'"'<instruction>'"'"'" <<<"$D9"' "K9: the rendered dispatcher SOUL says no shell command in a card body and carries no command template"
R9=$(OWNER_CONFIG=/workspace/config/owner.example.env render_soul $SOULS/reviewer.md)
ok 'grep -qF "git diff --name-only main...HEAD" <<<"$R9" && grep -qF "touches any file the card does not name" <<<"$R9" && grep -qF "Never call kanban_request_changes to say the work is approved" <<<"$R9"' "K9: the rendered reviewer SOUL has the scope check and never approves via request_changes"
n=0; bad=""
while IFS= read -r c; do n=$((n+1)); [ "$(jq -nc --arg c "$c" '{tool_name: "terminal", tool_input: {command: $c}}' | $RTT >/dev/null 2>&1; echo $?)" = 0 ] || bad="$bad [$c]"; done < <(grep -o '`git [^`]*`' <<<"$R9" | tr -d '`')
ok '[ "$n" -ge 3 ] && [ -z "$bad" ]' "K9: every git command the reviewer SOUL tells it to run is allowed by its terminal hook ($n checked${bad:+, refused:$bad})"

# Every self-test that runs an owner-config consumer points OWNER_CONFIG at its own scratch file.
miss=""
for t in /workspace/bin/*-selftest.sh; do
  case "${t##*/}" in owner-config-selftest.sh|owner-leak-selftest.sh) continue ;; esac   # the leak test compares against the real file
  grep -qE 'bin/(escalation-[a-z-]+|kanban-guard|escalations-status)\.sh|false-close-guard\.py|owner[-_]config' "$t" || continue
  grep -q 'OWNER_CONFIG="\$T/' "$t" || miss="$miss ${t##*/}"
done
ok '[ -z "$miss" ]' "every consumer self-test sets OWNER_CONFIG to a scratch file${miss:+ (missing:$miss)}"
# A6-01: seven selftests build their scratch owner config as `cat config/owner.example.env` plus appended lines; a missing
# final newline fuses the first appended key into the last line and 5 of them fail with no hint why (15 red hours, 2026-11-05).
ok '[ "$(tail -c1 /workspace/config/owner.example.env | od -An -c | tr -d " ")" = "\\n" ]' "config/owner.example.env ends with a newline (the consumer selftests append lines to a copy of it)"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
