#!/usr/bin/env bash
# Hermetic self-test for the secret-read checks (F11, F12): Stella's read-only terminal and the builders' secret guard
# refuse reading the secret paths however the path is written. Synthetic payloads, nothing is executed or read.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# STACK=<tree> runs the hooks of another tree (a staged one, K6); default /workspace.
STACK=${STACK:-/workspace}; D=$STACK/docs/hermes-local/hooks
# T7 (F1 W4 r4): every alert this run's guards write goes to this run's own folder, never the tree's alert log (on the live tree each line may page)
TREE_ALERTS=$STACK/.supervisor/logs/alerts.log; TREE_SIZE=$(stat -c %s "$TREE_ALERTS" 2>/dev/null || echo 0)
export ESCALATE_SUP_DIR=$T/sup; mkdir -p "$T/sup/logs"
R=$D/default/read-only-terminal.py S=$D/builder/secret-guard.py
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
# run <hook> <tool> <tool_input json>: the hook's exit code (2 = blocked); its stdout goes to $T/out
run() { jq -nc --arg t "$2" --argjson i "$3" '{tool_name: $t, tool_input: $i, cwd: "/workspace"}' | "$1" >"$T/out" 2>/dev/null; echo $?; }
term() { run "$1" terminal "$(jq -nc --arg c "$2" '{command: $c}')"; }
block() { sed -n '/^# --- secret paths/,/^# --- end secret paths/p' "$1"; }

ok '[ -n "$(block $R)" ] && [ "$(block $R)" = "$(block $S)" ]' "the secret-path block (list and matcher) is identical in both hooks"
# K6: the hooks import roles from /workspace/bin; run copies whose import points at $STACK/bin (a no-op for the installed tree)
cp_hook() { sed "s#/workspace/bin#$STACK/bin#g" "$1" >"$T/$(basename "$1")"; chmod +x "$T/$(basename "$1")"; }
cp_hook "$R"; cp_hook "$S"; R=$T/$(basename "$R"); S=$T/$(basename "$S")
# The Part A bypasses (register F11), the approved list, and each way of writing a path. Both hooks refuse them all.
# verifier M1: ordinary commands that mention /dev/std*, stdin or a project path with proc in it stay allowed (the /proc rule is about other processes' files)
# final red-team S6N-02: the dispatcher's git must not run inside a card worktree (the sibling folders of the sandbox table) or inside a .git folder: a builder's repo config could run code there
for c in 'git -C /workspace/.scratch/s6-scratch/.worktrees/t_1 status' 'cd /workspace/.scratch/s6-scratch/.worktrees/t_1 && git status' 'git -C /workspace/.scratch/s6-scratch/.WORKTREES/t_1/sub diff' \
         'git -C /workspace/.scratch/s6-scratch/.worktrees/t_1/.GIT log' 'cd /workspace/.scratch/s6-scratch/.worktrees && cd t_1 && git log --oneline' 'git -C /workspace/.git/worktrees/t_1 log'; do
  ok '[ "$(term $R "$c")" = 2 ]' "Stella refused: $c"
done
for c in 'git -C /workspace -C .scratch/s6-scratch/.worktrees/t_1 status' 'cd -- /workspace/.scratch/s6-scratch/.worktrees/t_1 && git status' 'cd -P /workspace/.scratch/s6-scratch/.worktrees/t_1 && git status' \
         'git -C /workspace/.scratch/s6-scratch/.worktree?/t_1 status' 'git -C /workspace/.scratch/s6-scratch/.worktree[s]/t_1 status' 'git -C /workspace/.scratch/s6-scratch/.w*/t_1 status' \
         'cd /workspace/.scratch/s6-scratch/.{worktrees,x}/t_1 && git status'; do   # delta red-team S6O-05
  ok '[ "$(term $R "$c")" = 2 ]' "Stella refused: $c"
done
# delta verifier F5: a card worktree is recognised by the file system (its .git is a FILE), not only by the spelling of its path; cd - and variables are refused
mkdir -p "$T/lw/sub" && echo "gitdir: /nonexistent" >"$T/lw/.git"
for c in "git -C $T/lw status" "git -C $T/lw/sub status" "cd $T/lw && git status" "cd /workspace && cd - && git status" 'cd $OLDPWD && git status' "git -C / -C $T/lw status"; do
  ok '[ "$(term $R "$c")" = 2 ]' "Stella refused: ${c//$T/T}"
done
# delta-2 S6P-02: tilde forms and variables as folders, and any cd into a card worktree (the session keeps the cd for the next call)
for c in "cd $T/lw" 'cd /workspace && cd / && git -C ~- status' 'git -C $OLDPWD status' 'cd ~- && git status' 'git -C "$OLDPWD" status' 'cd ~root && git status'; do
  ok '[ "$(term $R "$c")" = 2 ]' "Stella refused: ${c//$T/T}"
done
for c in 'git -C /workspace log --oneline -5' 'git -C /workspace status --short' 'git -C /workspace/bin log --oneline -2'; do
  ok '[ "$(term $R "$c")" = 0 ]' "Stella allowed: $c"
done
# delta red-team S6O-07: only the standard streams as written are exempt, not a link that resolves to one
ln -sf /proc/self/fd/0 "$T/plink"
ok '[ "$(term $R "cat $T/plink")" = 2 ] && [ "$(term $S "cat $T/plink")" = 2 ]' "a planted symlink to a process fd is refused (only /dev/stdin, /dev/stdout, /dev/stderr, /dev/fd/0-2 as written are exempt)"
for c in 'cat /dev/stdin' 'cat src/proc/self_test.js' 'ls data/proc/2024' 'ls /proc' 'cat /proc/cpuinfo'; do
  ok '[ "$(term $R "$c")" = 0 ]' "Stella allowed: $c"
  ok '[ "$(term $S "$c")" = 0 ]' "builder allowed: $c"
done
for c in 'echo hi > /dev/stderr' 'node app.js 2>/dev/stderr' 'npm test 2>&1 | tee /dev/stderr'; do   # the dispatcher's terminal is read-only (no redirects); builders may write to the standard streams
  ok '[ "$(term $S "$c")" = 0 ]' "builder allowed: $c"
done
for c in 'cat ~/.hermes/.env' 'cat ~/.hermes/.en?' 'cat /home/node/.hermes/.e*' 'grep -r BOT_TOKEN /home/node/.hermes --include=.e*' \
         'grep -rh TOKEN /home/node/.hermes/profiles' 'cat /home/node/.claude/.credentials.json' 'jq . ~/.local/share/opencode/auth.json' \
         'cat $HOME/.hermes/.env' 'cd ~/.hermes && cat auth.json' 'cd /home/node/.hermes && cat .e*' 'cat ~/.hermes/auth.json' \
         'grep -r x . --include=.env*' 'cat /workspace/.env' 'head .env.local' 'cat x.pem' 'tail ~/certs/server.key' \
         'ls ~/.ssh' 'cat ~/.aws/credentials' 'cat ~/.config/gh/hosts.yml' 'git diff --no-index ~/.hermes/.env /dev/null' \
         'grep -r token ~' 'cat "$HOME"/.hermes/.e"nv"' 'cat ~/.hermes/.{env,x}' 'grep -r TOKEN ~/.{hermes,claude}' \
         'cat ~/.hermes/.{e,f}nv' "cat ~/.hermes/\$'\\x2e\\x65\\x6e\\x76'" "cat \$'/home/node/.hermes/auth\\x2ejson'" \
         'cat ~/.hermes/broker/claude-reviewer' 'ls /home/node/.hermes/broker' 'cd ~/.hermes/broker && cat *' 'cat $HOME/.hermes/broker/x' 'cat /proc/4321/environ' 'cat /proc/self/environ' 'tr "\\0" "\\n" < /proc/1234/environ' 'cat /proc/4321/task/4321/environ' 'cat /proc/4321/./environ' 'cd /proc/4321 && cat environ' 'cat /proc/*/environ' 'cat /proc/[0-9]*/environ' 'cat /proc/$$/environ' 'grep -f/proc/1234/environ -o -e . /dev/null' 'tar -C/proc/1234 -cf - environ' 'cat --file=/proc/1234/environ' 'cat /proc/thread-self/environ' 'cat /proc//1234/environ' 'cat /proc/./self/environ' 'cd /proc/; cat self/environ' 'cat "/proc/"self/environ' "cat /proc/'1234'/environ" 'cat /proc/{self,x}/environ' 'cat /pro?/self/environ' 'cat /proc/\self/environ' 'grep -ra --include=environ CLAUDE /proc' 'grep -a CLAUDE_CODE_OAUTH /proc//*/environ' 'cat /dev/fd/../../1234/environ'; do
  ok '[ "$(term $R "$c")" = 2 ] && grep -q "secret" "$T/out"' "Stella refused: $c"
  ok '[ "$(term $S "$c")" = 2 ] && grep -q "secret" "$T/out"' "builder refused: $c"
done
BIG="cat ~/.hermes/.{$(printf 'x%s,' $(seq 1 64))env}"   # 65 alternatives, .env last (review round 2)
ok '[ "$(term $R "$BIG")" = 2 ] && [ "$(term $S "$BIG")" = 2 ]' "a brace expanding past 64 words is refused, not truncated"
for c in 'cat /workspace/.env.example' 'cat .env.sample' 'cat /workspace/SUPERVISOR.md' 'grep -n kanban /workspace/SUPERVISOR.md' \
         'tail -20 /workspace/.supervisor/escalations.log' 'ls -la /workspace/.worktrees' 'jq -r .event /workspace/.supervisor/escalations.log' \
         'cat ~/.hermes/config.yaml' 'ls ~/.hermes'; do
  ok '[ "$(term $R "$c")" = 0 ]' "Stella allowed: $c"
done
for c in 'npm test' 'node -e "console.log(process.env.HOME)"' 'grep -rn TODO bin' 'cat package.json' 'git status' \
         "opencode run --standalone --auto 'create a.md'" 'ls ~/.hermes' 'find docs -name "*.md"'; do
  ok '[ "$(term $S "$c")" = 0 ]' "builder allowed: $c"
done
# K6 (owner decision 2026-10-29): recursing from /workspace reaches the owner settings file, so `.` here is refused.
for c in 'grep -rn TODO .' 'find . -name "*.md"'; do
  ok '[ "$(term $S "$c")" = 2 ]' "builder refused in /workspace (an owner settings file below): $c"
done
# RT7-01 controls: a recursive search with no path reads the current folder, so it is judged by that folder only
for c in 'cd bin && grep -rn TODO' 'cd docs && find -name "*.md"' 'grep -rn TODO bin docs' 'grep -r -m 5 TODO bin'; do
  ok '[ "$(term $S "$c")" = 0 ]' "builder allowed (no owner settings file in the folder searched): $c"
done
ok '[ "$(term $R "grep -rn TODO /workspace/bin")" = 0 ] && [ "$(term $R "cd bin && grep -rn TODO")" = 2 ]' "Stella allowed with an absolute folder, refused with cd (follow-up 5, F5RT-01: the session would keep the cd)"
# follow-up 5 (red-team F5RT-01): a cd in one dispatcher call is kept by the session; the hook would resolve the next call's relative path against the wrong folder
for c in 'cd /home/node/.hermes' 'cd /proc' 'cd /home/node/.claude' 'cd /workspace/config' 'cd ..' 'cd'; do
  ok '[ "$(term $R "$c")" = 2 ]' "Stella refused: $c"
done
# B2V-14/15 controls: ordinary git and diff reads, and wrapped commands on an ordinary folder, still pass
for c in 'git diff --stat main...HEAD' 'git diff' 'git -C /workspace diff --stat' 'git diff --name-only HEAD~1 HEAD' \
         'diff bin/alert.sh bin/alert.sh' 'timeout 5 grep -rn x bin' 'if cd bin; then grep -rn x; fi'; do
  ok '[ "$(term $S "$c")" = 0 ]' "builder allowed (B2V-14/15 control): $c"
done
for c in 'git diff --stat main...HEAD' 'git -C /workspace diff --stat'; do
  ok '[ "$(term $R "$c")" = 0 ]' "Stella allowed (B2V-14 control): $c"
done
# RT8-01: a glob operand that matches names those paths (judged as written), it is not "no path"
for c in 'grep -rn TODO *.md' 'grep -rn TODO docs/*.md'; do
  ok '[ "$(term $S "$c")" = 0 ]' "builder allowed in /workspace (RT8-01: the glob names files, not the current folder): $c"
done
ok '[ "$(term $S "grep -rn TODO *")" = 2 ]' "builder refused in /workspace: grep -rn TODO * (the glob matches the folder holding the owner settings file)"
for c in 'grep -rn TODO' 'rg TODO'; do
  ok '[ "$(term $S "$c")" = 2 ]' "builder refused in /workspace, no path given (the current folder holds an owner settings file below): $c"
done
# Builder-only tools and payload shapes
ok '[ "$(term $S "X=~/.hermes; cat \$X/auth.json")" = 2 ] && [ "$(term $S "python3 -c \"print(open('"'"'/home/node/.hermes/.env'"'"').read())\"")" = 2 ]' "builder: a variable set on the line, or a path inside quoted code, refused"
ok '[ "$(term $S "opencode run --standalone --auto '"'"'read the .env file'"'"'")" = 2 ]' "builder: an instruction to OpenCode that names .env refused"
ok '[ "$(run $S terminal "{\"command\": \"cat auth.json\", \"workdir\": \"/home/node/.hermes\"}")" = 2 ]' "builder: workdir is used to resolve relative paths"
ok '[ "$(run $S process_manage "{\"action\": \"write\", \"session_id\": \"p1\", \"data\": \"cat ~/.hermes/.env\\n\"}")" = 2 ] && [ "$(run $S process_manage "{\"action\": \"poll\", \"session_id\": \"p1\"}")" = 0 ]' "builder: process_manage stdin refused, poll allowed"
ok '[ "$(run $S read_file "{\"path\": \"/home/node/.hermes/.env\"}")" = 2 ] && [ "$(run $S read_file "{\"path\": \"/workspace/SUPERVISOR.md\"}")" = 0 ]' "builder: read_file of a secret refused, an ordinary file allowed"
ok '[ "$(run $S search_files "{\"pattern\": \"TOKEN\", \"path\": \"/home/node/.hermes\"}")" = 2 ] && [ "$(run $S search_files "{\"pattern\": \"x\", \"path\": \".\", \"file_glob\": \".env*\"}")" = 2 ] && [ "$(run $S search_files "{\"pattern\": \"x\", \"path\": \"/workspace/bin\", \"file_glob\": \"*.sh\"}")" = 0 ]' "builder: search_files in a secret folder or for .env files refused, ordinary search allowed"
ok '[ "$(run $S vision_analyze "{\"image_url\": \"/home/node/.ssh/id_ed25519\", \"question\": \"x\"}")" = 2 ] && [ "$(run $S skill_view "{\"name\": \"x\", \"file_path\": \"../../.env\"}")" = 2 ] && [ "$(run $S skill_view "{\"name\": \"x\"}")" = 0 ]' "builder: vision_analyze and skill_view on secret paths refused"
ok '[ "$(run $S search_files "{\"pattern\": \"*.json\", \"target\": \"files\", \"path\": \"/home/node/.hermes/profiles\"}")" = 0 ] && [ "$(run $S search_files "{\"pattern\": \"TOKEN\", \"target\": \"content\", \"path\": \"/home/node/.hermes/profiles\"}")" = 2 ] && [ "$(run $S search_files "{\"pattern\": \"x\", \"target\": \"files\", \"path\": \"/home/node/.ssh\"}")" = 2 ] && [ "$(run $S search_files "{\"pattern\": \"x\", \"target\": \"content\", \"path\": \"/workspace\", \"file_glob\": \".env*\"}")" = 2 ]' "batch 6: a find-by-name search (target files) of ~/.hermes/profiles is allowed (replay false positive), a content search there, a secret directory and a .env* glob are refused"
ok '[ "$(echo not-json | $S >/dev/null 2>&1; echo $?)" = 2 ]' "builder secret guard fails closed on a garbage payload"
# K6: the owner settings files named by the role table (the path string only; no hook opens it) are refused by both hooks, and the
# example file beside it is not. The table is ${ROLES_FILE:-the live one}.
OWN=$(jq -r '.owner_settings[0] // empty' "${ROLES_FILE:-/workspace/docs/hermes-local/roles.json}"); EX=${OWN%.env}.example.env
ok '[ -n "$OWN" ]' "K6: the role table lists an owner settings file"
ok '[ "$(run $R read_file "{\"path\": \"/workspace/$OWN\"}")" = 2 ] && [ "$(run $S read_file "{\"path\": \"/workspace/$OWN\"}")" = 2 ]' "K6: read_file of the owner settings file refused by both hooks"
ok '[ "$(term $R "cat /workspace/$OWN")" = 2 ] && [ "$(term $S "cat /workspace/$OWN")" = 2 ] && [ "$(term $S "cat $OWN")" = 2 ]' "K6: a terminal naming the owner settings file refused by both hooks"
ok '[ "$(run $S vision_analyze "{\"image_url\": \"/workspace/$OWN\", \"question\": \"x\"}")" = 2 ] && [ "$(run $S skill_view "{\"name\": \"x\", \"file_path\": \"/workspace/$OWN\"}")" = 2 ]' "K6: vision_analyze and skill_view of the owner settings file refused"
ok '[ "$(run $S read_file "{\"path\": \"/workspace/$EX\"}")" = 0 ] && [ "$(term $S "cat /workspace/$EX")" = 0 ] && [ "$(term $R "cat /workspace/$EX")" = 0 ]' "K6: the owner example file next to it is still readable"
# RT22-01: a # inside a word is not a comment in bash, so what follows `;` still runs: both hooks must still refuse it.
# the first two are also caught by the hooks' plain-text scan of the owner path (they held before the fix); the rest need the parsed words
OB=${OWN%.env}
for c in "echo x#; cat /workspace/$OWN" "echo x#y && cat $OWN" "echo x#; cat /workspace/$OB.e\"nv\"" "echo x#; cat /workspace/$OB.{env,x}" "echo x#y; cat /workspace/$OB.e?v" "echo x#; cat $OB.e*"; do
  ok '[ "$(term $R "$c")" = 2 ] && grep -q "secret" "$T/out"' "RT22-01 Stella refused (# inside a word hides nothing): $c"
  ok '[ "$(term $S "$c")" = 2 ] && grep -q "secret" "$T/out"' "RT22-01 builder refused (# inside a word hides nothing): $c"
done
for c in "echo x#y" "echo a#b" "ls # note" "cat /workspace/$EX # note" "echo x#; cat /workspace/$EX"; do
  ok '[ "$(term $R "$c")" = 0 ] && [ "$(term $S "$c")" = 0 ]' "RT22-01 both allowed (# in a word, a real comment, or the example file): $c"
done
ok '[ "$(term $R "ls # cat /workspace/$OB.e\"nv\"")" = 2 ] && [ "$(term $S "ls # cat /workspace/$OB.e\"nv\"")" = 2 ]' "RT22-01 both refused (accepted fail-safe: a comment that names the owner settings file is scanned)"
# RT23-01: bash reads $'\'' as ONE quote character; shlex reads it as two. Read literally from this block (no shell quoting layer).
while IFS= read -r c; do
  c=${c//@OWN@/$OWN}; c=${c//@OB@/${OWN%.env}}
  ok '[ "$(term $R "$c")" = 2 ] && grep -q "secret" "$T/out"' "RT23-01 Stella refused (\$'\\'' is one quote character to bash): ${c//$OWN/<owner file>}"
  ok '[ "$(term $S "$c")" = 2 ] && grep -q "secret" "$T/out"' "RT23-01 builder refused (\$'\\'' is one quote character to bash): ${c//$OWN/<owner file>}"
done <<'RT23'
echo $'\'' ; cat /workspace/@OWN@ ; echo \'
echo $'\'' ; cat /workspace/@OB@.e?v ; echo \'
echo $'\'' ; cat</workspace/@OB@.e?v ; echo \'
RT23
# RT23-02: a quote mark in a real comment makes shlex fail; the fallback must still split `;` `<` `>` from words and drop the quote
# marks, so a path glued to an operator is still judged. The builder guard end to end, and the secret block both hooks share
# (Stella's terminal refuses an unparseable line anyway, so its block is run directly: rsw prints its verdict, "-" for none).
{ echo "import sys"; block "$R"; echo 'print(secret_why(sys.argv[1], "/workspace") or "-")'; } >"$T/blk.py"
rsw() { python3 -I "$T/blk.py" "$1"; }
while IFS= read -r c; do
  c=${c//@OWN@/$OWN}; c=${c//@OB@/${OWN%.env}}
  ok '[ "$(term $S "$c")" = 2 ] && grep -q "secret" "$T/out"' "RT23-02 builder refused (a quote mark in a comment, path glued to an operator): ${c//$OWN/<owner file>}"
  ok '[ "$(rsw "$c")" != - ]' "RT23-02 the secret block (also in Stella's hook) names it: ${c//$OWN/<owner file>}"
done <<'RT23'
cat</workspace/@OB@.e?v # don't
true;cat</workspace/@OB@.{env,x} # don't
ls;cat<@OB@.e* # don't
cat</workspace/@OB@.e"nv" # "lone
RT23
while IFS= read -r c; do
  c=${c//@EX@/${OWN%.env}.example.env}
  ok '[ "$(term $S "$c")" = 0 ] && [ "$(rsw "$c")" = - ]' "RT23-02 builder allowed, secret block silent (harmless apostrophe or the example file): $c"
done <<'RT23'
echo it's fine
ls # don't
echo it's fine > /tmp/x
true;cat</workspace/@EX@ # don't
RT23
# RT24 (R2-01/02 for the secret guard): a comment line, or one ending in a backslash, before a read of an owner settings path. The guard
# also scans the plain text for the owner path, so these hold with and without the two-view parse (regression rows).
NL=$'\n'; OB=${OWN%.env}
for c in "# c \\${NL}cat /workspace/$OWN" "#\\${NL}cat /workspace/$OB.e?v" "echo a # n\\${NL}cat /workspace/$OB.e\"nv\"" "# c${NL}cat /workspace/$OB.{env,x}"; do
  ok '[ "$(term $S "$c")" = 2 ] && grep -q "secret" "$T/out"' "RT24 builder refused (a comment line, or one ending in a backslash, before an owner file read): $(l=${c//$OWN/<owner file>}; echo "${l//$NL/<NL>}")"
done
for c in "# c \\${NL}cat /workspace/$OB.example.env" "# note \\${NL}ls" "# build${NL}ls -la" "ls # note\\${NL}ls"; do
  ok '[ "$(term $S "$c")" = 0 ]' "RT24 builder allowed (comment lines around harmless commands or the example file): ${c//$NL/<NL>}"
done
# Differential: at least as strict as the pre-RT22-01 parse (copy of the guard under test with its `lex.commenters = …` line removed).
sed '/^ *lex\.commenters = /d' "$S" >"$T/pre-sg.py"; chmod +x "$T/pre-sg.py"
DIFF=("# c \\${NL}cat /workspace/$OWN" "#\\${NL}cat /workspace/$OB.e?v" "echo a # n\\${NL}cat /workspace/$OB.e\"nv\"" "# c${NL}cat /workspace/$OB.{env,x}" "echo x#; cat /workspace/$OB.e?v"
      "echo x#y && cat $OWN" "cat</workspace/$OB.e?v # don't" "true;cat</workspace/$OB.{env,x} # don't" "ls # note; cat /workspace/$OB.e?v" "cat /workspace/$OB.e?v # done"
      "echo \$'\\'' ; cat /workspace/$OB.e?v ; echo \\'" "cat ~/.hermes/.e\"nv\" # c" "# c${NL}cat ~/.hermes/.env" "echo it's fine" "ls # note" "echo x#y"
      "# build${NL}ls -la" "cat /workspace/$OB.example.env # c" "grep -rn TODO bin # c" "echo a # note${NL}ls")
dgood=1; for c in "${DIFF[@]}"; do
  [ "$(term $T/pre-sg.py "$c")" = 2 ] && [ "$(term $S "$c")" != 2 ] && { dgood=0; echo "     not as strict as pre-RT22-01: ${c//$OWN/<owner file>}"; }; done
ok '[ "$dgood" = 1 ]' "RT24 differential: the secret guard refuses everything its pre-RT22-01 parse refuses (${#DIFF[@]} mixed commands)"
ok '[ "$(term $T/pre-sg.py "echo a # n\\${NL}cat /workspace/$OB.e\"nv\"")" = 2 ]' "RT24 differential premise: the pre-RT22-01 copy refuses a tokenised read after a backslash comment"
# B.2 point 9 (r5, W4-CV3-03): jq builds a file name from a NAMED folder and a module word (jq -L <dir> 'import ...'); the folder it searches is judged. A
# state-path folder and a Hermes-home folder are both refused, by the whole `-L <dir>` and the attached `-L<dir>` form, through both read guards.
EVD=/workspace/$(dirname "$(jq -r .event_log /workspace/.stella/data-files.json)")   # the folder holding the event log (a state path)
for g in "$S" "$R"; do
  for c in "jq -L $EVD -n 'import \"events\" as \$a; \$a'" "jq -L$EVD -n 'import \"events\" as \$a; \$a'" "jq --library-path $EVD -n 'include \"events\"; .'"; do
    ok '[ "$(term $g "$c")" = 2 ] && grep -q "STL-CFG-312" "$T/out"' "B.2 point 9: $(basename $g) refuses jq searching the state-path folder: $c"
  done
  ok '[ "$(term $g "jq -L /home/node/.hermes -n '"'"'import \"auth\" as \$a; \$a'"'"'")" = 2 ]' "B.2 point 9: $(basename $g) refuses jq -L of a Hermes home folder (its auth.json is a secret)"
  ok '[ "$(term $g "jq -n '"'"'.'"'"'")" = 0 ] && [ "$(term $g "jq -L /tmp -n 1")" = 0 ]' "B.2 point 9 control: $(basename $g) allows jq with no library path and jq -L of /tmp"
done
ok '[ "$(ROLES_FILE=$T/none run $S read_file "{\"path\": \"/workspace/SUPERVISOR.md\"}")" = 2 ] && [ "$(ROLES_FILE=$T/none term $R "ls")" = 2 ]' "K6: an unreadable role table refuses every read (fail closed)"
ok '[ "$(tail -c +$((TREE_SIZE + 1)) "$TREE_ALERTS" 2>/dev/null | grep -c .)" = 0 ]' "T7 (r5, W4-VER3-07): the tree's alert log gained no line of any kind during this run"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
