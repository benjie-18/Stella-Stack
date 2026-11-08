#!/usr/bin/env bash
# Hermetic self-test for the fail-closed per-profile hooks (D35, D36): synthetic pre_tool_call payloads, scratch
# Hermes root for the registration check, no network. Stella (default profile): no kanban_block, no file writes, a
# read-only terminal allowlist. Builders: no git config, --no-verify, sweep-staging, or push to main.
# K8/K9: REG=<register-escalation-hook.sh> and RTT=<reviewer test-only-terminal.sh> point the run at staged copies.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
D=${HD:-/workspace/docs/hermes-local/hooks}   # RT22: HD=<hooks dir> points the run at staged hooks
REG=${REG:-/workspace/bin/register-escalation-hook.sh}   # the registration script under test (a staged copy while it is being replaced)
RT=${RTT:-$D/reviewer/test-only-terminal.sh}   # the reviewer's terminal hook under test (K9)
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
# run <hook> <tool> <tool_input json>: the hook's exit code (2 = blocked); its stdout goes to $T/out
run() { jq -nc --arg t "$2" --argjson i "$3" '{hook_event_name: "pre_tool_call", tool_name: $t, tool_input: $i}' | "$1" >"$T/out" 2>/dev/null; echo $?; }
term() { run "$1" terminal "$(jq -nc --arg c "$2" '{command: $c}')"; }

B=$D/default/deny-kanban-block.sh
ok '[ "$(run $B kanban_block "{\"task_id\":\"t_aaaaaaaa\",\"kind\":\"needs_input\",\"reason\":\"x\"}")" = 2 ] && grep -q "Dispatchers do not block cards: the worker blocks its own card, and the #escalations thread follows automatically." "$T/out"' "dispatcher role: kanban_block refused with the dispatcher message"
W=$D/default/deny-write.sh
for t in write_file patch execute_code skill_manage cronjob_manage; do
  ok '[ "$(run $W '$t' "{\"path\":\"/workspace/x\"}")" = 2 ] && grep -q "Dispatchers do not write files: create a card for a worker instead." "$T/out"' "dispatcher role: $t refused"
done

R=$D/default/read-only-terminal.py
for c in "hermes kanban list" "hermes kanban show t_a837104f" "/workspace/bin/escalations-status.sh --all" "git status --short" \
         "git -C /workspace log --oneline -5" "git diff --stat" "git rev-parse HEAD" "git show HEAD:SUPERVISOR.md" \
         "ls -la /workspace/.worktrees" "cat /workspace/SUPERVISOR.md 2>/dev/null || echo missing" \
         "grep -n 'kanban|block' /workspace/SUPERVISOR.md | head -5" "tail -20 /workspace/.supervisor/escalations.log" \
         "wc -l /workspace/decisions.md" "jq -r .event /workspace/.supervisor/escalations.log 2>&1" \
         "cd /workspace && git log --oneline -3" "echo '=== status' && pwd" "/workspace/bin/alert-explain.sh STL-ESC-210"; do
  ok '[ "$(term $R "$c")" = 0 ]' "terminal allowed: $c"
done
for c in "touch /tmp/x" "ls > /tmp/x" "cat a >> b" "cat a | tee b" "rm x" "mv a b" "cp a b" "mkdir -p /workspace/27/10" \
         "chmod +x a" "git add -A" "git commit -m x" "git push" "git reset --mixed HEAD" "git checkout main" \
         "git config user.name test" "git -c core.pager=sh log" "git merge x" "git rebase main" "git diff --output=/tmp/x" \
         "npm test" "opencode run --auto 'x'" "claude -p x" "printf ok > /workspace/.scratch/gate.txt" "ls; rm x" \
         "ls && touch y" "ls \$(touch y)" "ls \`touch y\`" $'ls\nrm x' "ls & rm x" "(rm x)" "X=1 ls" "cat <<EOF" \
         "cat /workspace/.env" "cat ~/.hermes/.env" "hermes kanban block t_a837104f x" "hermes kanban create x" \
         "python3 -c 'open(\"x\",\"w\")'" "find /workspace -delete" "curl -X POST https://discord.com/api" \
         "sed -i s/a/b/ f" "cat 'unbalanced" "" "/workspace/bin/merge-card.sh t_aaaaaaaa --push" \
         "/workspace/bin/alert.sh STL-ESC-210" "/workspace/bin/alert.sh --sample STL-ESC-210" "bin/alert-explain.sh STL-ESC-210" \
         "/workspace/bin/alert-explain.sh STL-ESC-210 > /tmp/x" "ALERT_CATALOG=/tmp/x /workspace/bin/alert-explain.sh STL-ESC-210"; do
  ok '[ "$(term $R "$c")" = 2 ] && grep -q "read-only" "$T/out"' "terminal refused: ${c//$'\n'/\\n}"
done
ok '[ "$(run $R process_manage "{\"action\":\"list\"}")" = 0 ] && [ "$(run $R process_manage "{\"action\":\"poll\",\"session_id\":\"p1\"}")" = 0 ]' "process_manage list/poll allowed"
ok '[ "$(run $R process_manage "{\"action\":\"kill\",\"session_id\":\"p1\"}")" = 2 ] && [ "$(run $R process_manage "{\"action\":\"submit\",\"session_id\":\"p1\",\"data\":\"rm x\"}")" = 2 ]' "process_manage kill/submit refused"
ok '[ "$(echo not-json | $R >/dev/null 2>&1; echo $?)" = 2 ]' "read-only terminal fails closed on a garbage payload"

G=${GG:-$D/builder/git-guard.py}
for c in "git config user.name x" "git config --global user.email a@b" "git -c user.email=x commit -m y" \
         "git commit --no-verify -m x" "git commit -nm x" "git push origin main" "git push origin HEAD:main" \
         "git push --all" "git add -A" "git add ." "git add --all" "cd /workspace && git add -A && git commit -m x" \
         "bash -c 'git config user.name x'" "opencode run --standalone --auto 'git add -A and commit'" \
         "git push origin +refs/heads/main" "git push origin HEAD:heads/main" "git push origin +HEAD:heads/main" "git push origin HEAD:refs/heads/*" \
         "git push origin 'refs/heads/*:refs/heads/*'" "git push origin HEAD:ma*" "git push --force origin refs/heads/*" "git push origin --delete heads/main" \
         "git fetch origin '+refs/heads/*:refs/heads/*'" "git fetch origin HEAD:heads/main" "git fetch origin +main:+refs/heads/main" \
         "git push origin HEAD:MAIN" "git push origin HEAD:refs/HEADS/main" "git push origin Main" "git push origin +HEAD:Main" "git fetch origin +HEAD:Main" \
         "git fetch origin HEAD:refs/HEADS/MAIN" "git push origin -- -x:heads/main" "git fetch origin -- -x:heads/main" "git push --force -- origin -x:refs/heads/main" \
         "git push origin --end-of-options -x:heads/main" "git fetch origin --end-of-options -x:heads/main" "git pull origin card:main" "git pull origin card:heads/MAIN" \
         "git pull origin '+refs/heads/*:refs/heads/*'" "git fetch --refmap=+refs/heads/card:heads/MAIN origin card" \
         "git fetch --update-head-ok --refmap='+refs/heads/*:refs/heads/*' origin" "git fetch --refmap +refs/heads/card:heads/main origin card" \
         "git fetch --refm=+refs/heads/card:heads/main origin card" "git push --mir origin" "git push --al origin" "git push --m origin" "git push --mirror origin" \
         "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.push GIT_CONFIG_VALUE_0=HEAD:refs/heads/main git push origin" \
         "env GIT_CONFIG_PARAMETERS=x git push" "GIT_CONFIG_GLOBAL=/dev/null git status"; do
  ok '[ "$(term $G "$c")" = 2 ] && grep -q "git guard" "$T/out"' "builder terminal refused: $c"
done
for c in "git add phase4-test.md && git commit -m 'Add phase4-test.md'" "git push -u origin HEAD" \
         "git rev-parse --show-toplevel && git branch --show-current" "git status" "git log -n 3" \
         "opencode run --standalone --auto 'create phase4-test.md'" "npm test" "ls -la" \
         "git push origin HEAD:refs/heads/mainline" "git push origin HEAD:card-branch" "git push origin HEAD:refs/heads/card-*" \
         "git fetch origin" "git fetch origin '+refs/heads/*:refs/remotes/origin/*'" "git fetch origin main" \
         "git push origin HEAD:Mainline" "git push origin HEAD:refs/heads/card-Main-x" "git push --set-upstream origin HEAD" "git fetch --all" "git pull" \
         "git pull origin" "git pull origin card-branch" "git pull --rebase origin card-branch" "git push --atomic origin HEAD" "git push --follow-tags origin HEAD" \
         "git fetch --refmap='+refs/heads/*:refs/remotes/origin/*' origin" "git fetch --prune origin"; do
  ok '[ "$(term $G "$c")" = 0 ]' "builder terminal allowed: $c"
done
ok '[ "$(echo not-json | $G >/dev/null 2>&1; echo $?)" = 2 ]' "git guard fails closed on a garbage payload"
# K1b (red team): git writes to the main checkout are refused from any directory (-C, --git-dir, a ref update of main, a
# commit against a path that is not a repo), and reads and linked-worktree commits are not. No bound worker: git-guard has no proof.
GR=$T/gg; git init -q -b main "$GR/main" && git -C "$GR/main" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m init \
  && git -C "$GR/main" worktree add -q -b stella/gg "$GR/wt"
for c in "git -C /workspace merge --ff-only x" "git -C /workspace reset --hard" "git --git-dir=/workspace/.git reset --hard" \
         "git update-ref refs/heads/main abc" "git branch -f main HEAD" "git branch -M x main" "git fetch . HEAD:main" \
         "git -C $T/nonrepo commit -m x"; do
  ok '[ "$(term $G "$c")" = 2 ] && grep -q "git guard" "$T/out"' "builder terminal refused (K1b): $c"
done
for c in "git -C /workspace status" "git -C /workspace log -1" "git -C /workspace diff" "git -C $GR/wt commit -m x" \
         "git merge main" "git branch --show-current"; do
  ok '[ "$(term $G "$c")" = 0 ]' "builder terminal allowed (K1b): $c"
done
# K1c (red team): GIT_DIR/GIT_WORK_TREE set in the environment, relative -C on a write, and --output into a main checkout are
# git writes to the main checkout; a read or an output outside it is not.
for c in "GIT_DIR=/workspace/.git git reset --hard" "env GIT_DIR=/workspace/.git GIT_WORK_TREE=/workspace git reset --hard" \
         "git -C ws merge x" "git diff --output=/workspace/bin/x" "git archive --output=/workspace/bin/x HEAD"; do
  ok '[ "$(term $G "$c")" = 2 ] && grep -q "git guard" "$T/out"' "builder terminal refused (K1c): $c"
done
for c in "git diff --output=/tmp/x" "GIT_DIR=/workspace/.git git log -1"; do
  ok '[ "$(term $G "$c")" = 0 ]' "builder terminal allowed (K1c): $c"
done

# F14 model guard: builders run Claude Code only as Sonnet; Opus and Haiku go through bin/escalate.sh. A bare claude -p
# is refused too: the builder's default model is not Sonnet (~/.claude/settings.json "model": "opus").
M=$D/builder/model-guard.py
for c in "claude -p --model opus x" "claude -p --model=haiku x" "claude -p --model opusplan x" "claude -p --model claude-opus-5-5 x" \
         "claude -p x" "claude" "timeout 300 claude -p 'x'" "claude -p --model sonnet --dangerously-skip-permissions x" \
         "claude -p --model sonnet --permission-mode bypassPermissions x" "claude -p --model sonnet --permission-mode=bypassPermissions x" \
         "claude -p --model sonnet --yolo x" "claude -p --model sonnet --allow-dangerously-skip-permissions x" \
         "claude -p --model sonnet --fallback-model opus x" "bash -c 'claude -p --model opus x'" "cd w && /usr/local/bin/claude --print x" \
         "opencode run --standalone --auto 'run claude -p --model opus to plan'" \
         "/workspace/bin/escalate.sh t_aaaaaaaa sonnet review why -- --dangerously-skip-permissions" \
         "ESCALATE_SUP_DIR=/tmp/x /workspace/bin/escalate.sh t_aaaaaaaa opus plan why" "export ESCALATE_SUP_DIR=/tmp/x" \
         "ESCALATE_REPLAY=q_1 bin/escalate.sh t_aaaaaaaa haiku judge why" "npx @anthropic-ai/claude-code -p --model opus x" "timeout 900 claude 'fix it'"; do
  ok '[ "$(term $M "$c")" = 2 ] && grep -q "model guard" "$T/out"' "builder terminal refused: $c"
done
for c in "claude -p --model sonnet 'fix the test'" "claude --model=sonnet -p x" "claude -p --model claude-sonnet-5-5 x" \
         "cd /workspace/.worktrees/t_aaaaaaaa && timeout 900 claude -p --model sonnet --output-format json 'x'" "claude --version" \
         "claude mcp list" "/workspace/bin/escalate.sh t_aaaaaaaa opus plan 'why' < prompt.txt" "bin/escalate.sh t_aaaaaaaa haiku judge why" \
         "npm test" "git status" "ls -la" "which claude" "command -v claude" "grep -rn claude docs" "git log --grep claude"; do
  ok '[ "$(term $M "$c")" = 0 ]' "builder terminal allowed: $c"
done
ok '[ "$(run $M process_manage "{\"action\":\"write\",\"session_id\":\"p1\",\"data\":\"claude -p --model opus x\\n\"}")" = 2 ] && [ "$(run $M process_manage "{\"action\":\"poll\",\"session_id\":\"p1\"}")" = 0 ]' "model guard: process_manage stdin checked, poll allowed"
ok '[ "$(echo not-json | $M >/dev/null 2>&1; echo $?)" = 2 ]' "model guard fails closed on a garbage payload"

# RT22-01: a # inside a word is not a comment in bash (only a # at the start of a word is), so what follows `;` still runs and every
# hook must still see it. Attack = harmless part with a # inside a word, then a command the hook refuses. Controls: the same # in a
# harmless command, a real comment, and a comment followed by `;` (bash ignores that tail; the hook scans it: fail-safe, accepted).
for c in "echo x#; rm x" "echo x#; touch /tmp/x" "echo x#y; ls > /tmp/x"; do
  ok '[ "$(term $R "$c")" = 2 ]' "RT22-01 Stella refused (# inside a word hides nothing): $c"
done
for c in "echo x#y" "echo a#b" "ls # note"; do
  ok '[ "$(term $R "$c")" = 0 ]' "RT22-01 Stella allowed (# in a word or a real comment): $c"
done
ok '[ "$(term $R "ls # note; rm x")" = 2 ]' "RT22-01 Stella refused (accepted fail-safe: the tail after a real comment is scanned too): ls # note; rm x"
for c in "echo x#; git push origin HEAD:main" "echo x#y && git add -A"; do
  ok '[ "$(term $G "$c")" = 2 ] && grep -q "git guard" "$T/out"' "RT22-01 builder git guard refused (# inside a word): $c"
done
for c in "echo x#y" "echo a#b" "ls # note"; do
  ok '[ "$(term $G "$c")" = 0 ]' "RT22-01 builder git guard allowed (# in a word or a real comment): $c"
done
ok '[ "$(term $G "ls # git push origin main")" = 2 ] && grep -q "git guard" "$T/out"' "RT22-01 builder git guard refused (accepted fail-safe: a comment that names a refused command is scanned): ls # git push origin main"
for c in "echo x#; claude -p --model opus x" "echo x#y && claude -p x"; do
  ok '[ "$(term $M "$c")" = 2 ] && grep -q "model guard" "$T/out"' "RT22-01 builder model guard refused (# inside a word): $c"
done
for c in "echo x#y" "echo a#b" "ls # note"; do
  ok '[ "$(term $M "$c")" = 0 ]' "RT22-01 builder model guard allowed (# in a word or a real comment): $c"
done
ok '[ "$(term $M "ls # claude -p --model opus x")" = 2 ] && grep -q "model guard" "$T/out"' "RT22-01 builder model guard refused (accepted fail-safe: a comment that names a refused command is scanned): ls # claude -p --model opus x"
# RT23-01: bash reads $'\'' as ONE quote character; shlex reads it as two, so a stray quote pair hid `; touch /tmp/x ;` from the allowlist.
# The command text is read literally from this block (no shell quoting layer): attacks refused, parseable lookalikes allowed.
while IFS= read -r c; do
  ok '[ "$(term $R "$c")" = 2 ]' "RT23-01 Stella refused (\$'\\'' is one quote character to bash): $c"
done <<'RT23'
echo $'\'' ; touch /tmp/x ; echo \'
echo $'\'' ; rm x ; echo \'
echo $'\'' ; ls > /tmp/x ; echo \'
RT23
while IFS= read -r c; do
  ok '[ "$(term $R "$c")" = 0 ]' "RT23-01 Stella allowed (harmless \$'…' escapes): $c"
done <<'RT23'
echo $'\'' ; ls ; echo \'
echo $'a\tb'
RT23
# RT23-02: a comment or prose with an apostrophe makes shlex fail. The terminal allowlist fails closed on that (live and staged alike).
while IFS= read -r c; do
  ok '[ "$(term $R "$c")" = 2 ]' "RT23-02 Stella refused (an unparseable line fails closed): $c"
done <<'RT23'
echo it's fine
ls # don't
x>/workspace/bin/y # don't
RT23
# RT24 (R2-02, differential): with commenters off, a comment ending in a backslash glues the next line onto the comment word, so a
# command on that line was hidden from the git and model guards. NL is a real newline: bash ends a comment at it, a backslash-newline
# before it is just a line join INSIDE the comment only when the comment is not a comment (see hooks' all_tokens).
NL=$'\n'
for c in "#\\${NL}git push origin HEAD:main" "# note \\${NL}git push origin HEAD:main" "echo a # note\\${NL}git push origin HEAD:main"; do
  ok '[ "$(term $G "$c")" = 2 ] && grep -q "git guard" "$T/out"' "RT24 builder git guard refused (a comment ending in a backslash hides nothing): ${c//$NL/<NL>}"
done
for c in "#\\${NL}claude -p --model opus x" "# note \\${NL}claude -p --model opus x" "echo a # note\\${NL}claude -p x"; do
  ok '[ "$(term $M "$c")" = 2 ] && grep -q "model guard" "$T/out"' "RT24 builder model guard refused (a comment ending in a backslash hides nothing): ${c//$NL/<NL>}"
done
for c in "ls # note" "git status" "npm test" "git commit -m 'fix #12 and #3'" "git add a.md && git commit -m 'Add #7'" "echo a # note${NL}ls" "# build${NL}ls -la" "ls # note\\${NL}ls"; do
  ok '[ "$(term $G "$c")" = 0 ] && [ "$(term $M "$c")" = 0 ]' "RT24 builder git and model guards allowed (comments and # in quotes): ${c//$NL/<NL>}"
done
ok '[ "$(term $M "claude -p --model sonnet \"fix #12\"")" = 0 ]' "RT24 builder model guard allowed: claude -p --model sonnet \"fix #12\""
# Differential: the hook is at least as strict as the pre-RT22-01 parse (shlex default comment character), built from a copy of the
# hook under test with its `lex.commenters = …` line removed: whatever that copy refuses, the hook refuses.
sed '/^ *lex\.commenters = /d' "$G" >"$T/pre-gg.py"; sed '/^ *lex\.commenters = /d' "$M" >"$T/pre-mg.py"; chmod +x "$T/pre-gg.py" "$T/pre-mg.py"
DIFF=("# note${NL}git push origin HEAD:main" "# note${NL}claude -p --model opus x" "#!/bin/bash${NL}git add -A" "#\\${NL}git push origin HEAD:main" "# note \\${NL}git push origin HEAD:main"
      "echo a # note\\${NL}git push origin HEAD:main" "#\\${NL}claude -p --model opus x" "echo a # note\\${NL}claude -p x" "# build${NL}ls -la" "echo a # note${NL}ls"
      "echo x#; git push origin HEAD:main" "echo x#; claude -p --model opus x" "echo x#y && git add -A" "echo x#y && claude -p x" "ls # git push origin main"
      "ls # claude -p --model opus x" "ls # note; git push origin main" "ls # note; claude -p x" "git push origin HEAD:main # done" "claude -p x # done"
      "git commit -m 'fix #12'" "claude -p --model sonnet 'fix #12'" "echo it's; git push origin main" "git status" "npm test")
dgood=1; for c in "${DIFF[@]}"; do for pair in "$T/pre-gg.py $G" "$T/pre-mg.py $M"; do set -- $pair
  [ "$(term $1 "$c")" = 2 ] && [ "$(term $2 "$c")" != 2 ] && { dgood=0; echo "     not as strict as pre-RT22-01: $(basename $2): ${c//$NL/<NL>}"; }; done; done
ok '[ "$dgood" = 1 ]' "RT24 differential: git guard and model guard refuse everything their pre-RT22-01 parse refuses (${#DIFF[@]} mixed commands)"
ok '[ "$(term $T/pre-gg.py "# note${NL}git push origin HEAD:main")" = 2 ]' "RT24 differential premise: the pre-RT22-01 copy does refuse a command after a leading comment line"
# RT25-01: the two-view hooks skipped the pre-RT22-01 view when only that view could not parse (an unbalanced quote after a `#` word),
# while the pre-RT22-01 hooks refused every parse error. Text is read literally from the heredocs; <NL> is a real newline.
while IFS= read -r c; do
  ok '[ "$(term $G "${c//<NL>/$NL}")" = 2 ] && grep -q "git guard" "$T/out"' "RT25-01 builder git guard refused (a hidden push, the old view cannot parse the rest): $c"
done <<'RT25'
#\<NL>git push origin HEAD:main; echo x#'<NL>'
# note \<NL>git push origin HEAD:main; echo x#'<NL>'
#\<NL>git push origin HEAD:main<NL>echo x#'<NL>'
ls; # c\<NL>git push origin HEAD:main && echo a#'<NL>'
RT25
while IFS= read -r c; do
  ok '[ "$(term $M "${c//<NL>/$NL}")" = 2 ] && grep -q "model guard" "$T/out"' "RT25-01 builder model guard refused (a hidden opus override, the old view cannot parse the rest): $c"
done <<'RT25'
#\<NL>claude -p --model opus x; echo x#'<NL>'
# note \<NL>claude -p --model opus x; echo x#'<NL>'
#\<NL>claude -p --model opus x<NL>echo x#'<NL>'
ls; # c\<NL>claude -p --model opus x && echo a#'<NL>'
RT25
ok '[ "$(term $G "#\\${NL}git push origin HEAD:main")" = 2 ] && [ "$(term $M "#\\${NL}claude -p --model opus x")" = 2 ]' "RT25-01 the same hidden lines without the unparseable suffix stay refused (RT24)"
# accepted over-refusal (since RT22-01, not caused by RT25): a line whose own parse hits an unbalanced quote is refused by both guards
while IFS= read -r c; do
  ok '[ "$(term $G "$c")" = 2 ] && [ "$(term $M "$c")" = 2 ]' "RT25-01 accepted over-refusal: both guards refuse a line they cannot parse: $c"
done <<'RT25'
ls # don't
echo x#; ls # it's here
echo it's fine
RT25
while IFS= read -r c; do
  ok '[ "$(term $G "$c")" = 0 ] && [ "$(term $M "$c")" = 0 ]' "RT25-01 normal flows unchanged, both guards allow: $c"
done <<'RT25'
git status
git push -u origin HEAD
git commit -m 'fix #12'
npm test
claude -p --model sonnet 'fix #12'
echo x#y
ls # note
RT25
# Differential (>= 20 commands, some the default-comment parse cannot read): the staged hooks refuse everything the pre-RT22-01 view refuses.
DIFF=(); while IFS= read -r c; do DIFF+=("${c//<NL>/$NL}"); done <<'RT25'
#\<NL>git push origin HEAD:main; echo x#'<NL>'
# note \<NL>git push origin HEAD:main; echo x#'<NL>'
#\<NL>git push origin HEAD:main<NL>echo x#'<NL>'
ls; # c\<NL>git push origin HEAD:main && echo a#'<NL>'
#\<NL>claude -p --model opus x; echo x#'<NL>'
# note \<NL>claude -p --model opus x; echo x#'<NL>'
#\<NL>claude -p --model opus x<NL>echo x#'<NL>'
ls; # c\<NL>claude -p --model opus x && echo a#'<NL>'
#\<NL>git push origin HEAD:main
#\<NL>claude -p --model opus x
# note<NL>git push origin HEAD:main
# note<NL>claude -p --model opus x
echo a # note\<NL>git push origin HEAD:main
echo x#; git push origin HEAD:main
echo x#; claude -p --model opus x
ls # don't
echo x#; ls # it's here
git push origin HEAD:main # it's done
claude -p --model opus x # it's done
echo "a # b; git push origin HEAD:main
git commit -m 'fix #12'
claude -p --model sonnet 'fix #12'
git status
echo x#y
# build<NL>ls -la
RT25
dgood=1; for c in "${DIFF[@]}"; do for pair in "$T/pre-gg.py $G" "$T/pre-mg.py $M"; do set -- $pair
  [ "$(term $1 "$c")" = 2 ] && [ "$(term $2 "$c")" != 2 ] && { dgood=0; echo "     not as strict as pre-RT22-01: $(basename $2): ${c//$NL/<NL>}"; }; done; done
ok '[ "$dgood" = 1 ]' "RT25 differential: git and model guards refuse everything their pre-RT22-01 view refuses, parse errors included (${#DIFF[@]} mixed commands)"
ok '[ "$(term $T/pre-gg.py "echo x#'"'"'${NL}'"'"'")" = 2 ] && [ "$(term $T/pre-mg.py "echo x#'"'"'${NL}'"'"'")" = 2 ] ' "RT25 differential premise: the pre-RT22-01 copies refuse echo x#'<NL>' (their parse hits an unclosed quote)"
# Registration (scratch HOME): Stella's hooks land in the default profile only, the git guard in both builders only,
# all fail_closed. A worker's kanban_block therefore meets only the kanban guard, which allows a first block.
H="$T/home/.hermes"; mkdir -p "$H/profiles/builder-local" "$H/profiles/builder-claude" "$H/profiles/reviewer"
for p in "" profiles/builder-local/ profiles/builder-claude/ profiles/reviewer/; do printf 'model: x\n' > "$H/${p}config.yaml"; done
HOME="$T/home" "$REG" >/dev/null
has() { grep -A3 -F "$2" "$H/$1config.yaml" | grep -q "fail_closed: true"; }
ok 'has "" deny-kanban-block.sh && has "" read-only-terminal.py && has "" hooks/deny-write.sh && has "" hooks/secret-guard.py' "default profile: four fail-closed Stella hooks registered (secret guard on read_file/search_files, D42)"
ok 'has profiles/reviewer/ secret-guard.py && has profiles/builder-local/ deny-skill-manage.sh && has profiles/builder-claude/ deny-skill-manage.sh && ! grep -q deny-skill-manage "$H/config.yaml" "$H/profiles/reviewer/config.yaml"' "D42: reviewer secret guard and the builders' skill_manage deny registered fail-closed, in the right profiles only"
ok '! grep -q "deny-kanban-block\|read-only-terminal" "$H/profiles/builder-local/config.yaml" "$H/profiles/builder-claude/config.yaml" "$H/profiles/reviewer/config.yaml"' "Stella's hooks are not registered in any worker profile"
ok 'has profiles/builder-local/ git-guard.py && has profiles/builder-claude/ git-guard.py && ! grep -q git-guard "$H/config.yaml" "$H/profiles/reviewer/config.yaml"' "git guard registered fail-closed in both builders only"
ok 'has profiles/builder-local/ write-guard.py && has profiles/builder-claude/ write-guard.py && ! grep -q write-guard "$H/config.yaml" "$H/profiles/reviewer/config.yaml"' "write guard registered fail-closed in both builders only (D40)"
ok '( for g in secret-guard.py model-guard.py; do has profiles/builder-local/ $g && has profiles/builder-claude/ $g || exit 1; done ) && ! grep -q model-guard.py "$H/config.yaml" "$H/profiles/reviewer/config.yaml"' "secret guard (F12) and model guard (F14) registered fail-closed in both builders; the model guard in no other profile (the secret guard also guards Stella's and the reviewer's file reads, D42)"
ok 'HOME="$T/home" "$REG" --check >/dev/null' "registration --check: in sync after apply"
sed -i '/deny-kanban-block/,+2d' "$H/config.yaml"
ok '! HOME="$T/home" "$REG" --check >/dev/null' "registration --check: a missing hook is drift"
# Matchers, checked the way Hermes checks them (re.fullmatch, agent/shell_hooks.py) against the real tool names, so a
# matcher that names no real tool ("^kanban_", "process") fails here (D31 matcher fix).
HOME="$T/home" "$REG" >/dev/null   # restore the hook the drift case above removed
fm() { python3 - "$H/$1config.yaml" "$2" "$3" <<'PYM'
import re, sys
s = open(sys.argv[1]).read()
m = re.findall(r'- matcher: "([^"]*)"\n      command: "([^"]*)"', s)
pats = [p for p, c in m if sys.argv[2] in c]
sys.exit(0 if len(pats) == 1 and all(re.fullmatch(pats[0], t) for t in sys.argv[3].split()) else 1)
PYM
}
for p in "" profiles/builder-local/ profiles/builder-claude/ profiles/reviewer/; do
  ok 'fm "$p" kanban-guard.sh "kanban_block kanban_create kanban_complete kanban_show"' "${p:-default} kanban guard matcher fullmatches kanban_block/create/complete/show"
done
ok 'fm profiles/reviewer/ test-only-terminal.sh "terminal process_manage"' "reviewer terminal guard fullmatches terminal and process_manage"
# K8: the role guard's matcher covers kanban_request_review on every profile, so a builder cannot hand a card to itself unseen.
for p in "" profiles/builder-local/ profiles/builder-claude/ profiles/reviewer/; do
  ok 'fm "$p" role-guard.py "kanban_request_review kanban_create kanban_complete kanban_unblock kanban_claim delegate_task" && ! fm "$p" role-guard.py "kanban_show kanban_comment kanban_block"' "${p:-default} role guard matcher fullmatches kanban_request_review and the gated tools, not kanban_show/comment/block (K8)"
done
for p in profiles/builder-local/ profiles/builder-claude/; do
  ok 'fm "$p" write-guard.py "write_file patch terminal process_manage" && ! fm "$p" write-guard.py read_file && ! fm "$p" write-guard.py tool_call' "$p write guard matcher fullmatches the real tool names write_file, patch, terminal, process_manage (D40)"
done
ok 'fm "" read-only-terminal.py "terminal process_manage" && fm profiles/builder-local/ git-guard.py "terminal process_manage" && fm profiles/builder-claude/ git-guard.py "terminal process_manage"' "Stella and builder terminal guards fullmatch terminal and process_manage"
for p in profiles/builder-local/ profiles/builder-claude/; do
  ok 'fm "$p" secret-guard.py "terminal process_manage read_file search_files vision_analyze skill_view" && ! fm "$p" secret-guard.py write_file && fm "$p" model-guard.py "terminal process_manage"' "$p secret and model guard matchers fullmatch their real tool names"
done
ok 'fm profiles/reviewer/ deny-write.sh "write_file patch skill_manage"' "reviewer deny-write fullmatches write_file, patch and skill_manage (F9)"
ok 'fm "" deny-kanban-block.sh kanban_block && fm "" hooks/deny-write.sh "write_file patch execute_code skill_manage cronjob_manage"' "Stella's block and write guards fullmatch their tools (cronjob_manage too, D42)"
ok 'fm "" secret-guard.py "read_file search_files" && ! fm "" secret-guard.py "terminal write_file" && fm profiles/reviewer/ secret-guard.py "read_file search_files" && ! fm profiles/reviewer/ secret-guard.py "terminal write_file"' "D42: Stella's and the reviewer's secret guard fullmatch read_file and search_files only"
for p in profiles/builder-local/ profiles/builder-claude/; do
  ok 'fm "$p" deny-skill-manage.sh skill_manage && ! fm "$p" deny-skill-manage.sh "memory write_file skill_view skills_list"' "$p skill_manage deny fullmatches skill_manage only (D42)"
done
# The pre-fix volume state: a registered command with a wrong matcher is drift, and apply corrects it in place.
sed -i 's/"\^kanban_\.\*"/"^kanban_"/; s/"\^(terminal|process_manage)\$"/"^(terminal|process)$"/' "$H/profiles/reviewer/config.yaml"
ok '! fm profiles/reviewer/ kanban-guard.sh kanban_block && ! fm profiles/reviewer/ test-only-terminal.sh process_manage' "the old matchers fail the fullmatch check"
ok 'HOME="$T/home" "$REG" --check | grep -q "MATCHER DRIFT"' "registration --check reports a wrong matcher"
HOME="$T/home" "$REG" >/dev/null
ok 'fm profiles/reviewer/ kanban-guard.sh kanban_block && fm profiles/reviewer/ test-only-terminal.sh "terminal process_manage" && [ "$(grep -c kanban-guard.sh "$H/profiles/reviewer/config.yaml")" = 1 ]' "apply corrects the matchers in place, no duplicate entry"
# K8: a role-guard entry registered before kanban_request_review was added is drift, and is corrected in place.
sed -i 's/|kanban_request_review//' "$H/profiles/builder-local/config.yaml"
ok '! fm profiles/builder-local/ role-guard.py kanban_request_review && HOME="$T/home" "$REG" --check | grep -q "MATCHER DRIFT"' "K8: a role guard matcher without kanban_request_review: --check reports drift"
HOME="$T/home" "$REG" >/dev/null
ok 'fm profiles/builder-local/ role-guard.py kanban_request_review && [ "$(grep -c role-guard.py "$H/profiles/builder-local/config.yaml")" = 1 ]' "K8: apply corrects the role guard matcher in place, no duplicate entry"
# K1-RT-11 (RT7-07): a registered hook whose timeout differs from roles.json is drift, and is corrected in place.
wt() { grep -A1 "command: \".*$2\"" "$H/${1}config.yaml" | sed -n 's/.*timeout: //p'; }
want=$(jq -r '[.roles[].hooks[]? | select((.file // "") | endswith("write-guard.py")) | .timeout] | first' /workspace/docs/hermes-local/roles.json)
sed -i '/command: ".*write-guard.py"/{n;s/timeout: [0-9]*/timeout: 7/}' "$H/profiles/builder-local/config.yaml"
ok '[ "$(wt profiles/builder-local/ write-guard.py)" = 7 ] && HOME="$T/home" "$REG" --check | grep -q "TIMEOUT DRIFT"' "K1-RT-11: a hook registered with another timeout than roles.json: --check reports drift"
HOME="$T/home" "$REG" >/dev/null
ok '[ -n "$want" ] && [ "$(wt profiles/builder-local/ write-guard.py)" = "$want" ] && [ "$(grep -c write-guard.py "$H/profiles/builder-local/config.yaml")" = 1 ]' "K1-RT-11: apply sets the timeout from roles.json in place ($want s), no duplicate entry"
# S4, S24, F25, S25: apply-hermes-local.sh against a scratch HOME with a hermes stub whose `config get` fails. It must not
# abort before the hook and toolset steps; an unmarked SOUL keeps its first line; SOUL.md, config.yaml and the allowlist
# are replaced atomically with a backup first; hooks registered but not listed are reported.
A="$T/apply"; HA="$A/.hermes"; mkdir -p "$A/bin" "$HA/profiles/builder-local" "$HA/profiles/builder-claude" "$HA/profiles/reviewer" "$HA/kanban/boards/ai-stack"
for p in "" profiles/builder-local/ profiles/builder-claude/ profiles/reviewer/; do printf 'model: x\n' > "$HA/${p}config.yaml"; echo '{"approvals": []}' > "$HA/${p}shell-hooks-allowlist.json"; done
echo '{}' > "$HA/kanban/boards/ai-stack/board.json"
python3 -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("create table projects (id, slug, name, board_slug, primary_path, archived)"); c.execute("insert into projects values (?, ?, ?, ?, ?, 0)", ("p_0000aaaa", "proj-a", "A", sys.argv[2], "/workspace")); c.commit()' "$HA/projects.db" "$(. /workspace/bin/kanban-board.sh; echo "$KANBAN_BOARD")"   # D46: the board binding the SOUL renders
printf 'My own first line\nmore hand-written text\n' > "$HA/profiles/reviewer/SOUL.md"
printf 'You are Hermes Agent, a helpful assistant.\nold text\n' > "$HA/SOUL.md"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls"\ncase "$*" in *"config get"*|*"config set"*) exit 1;; esac\nexit 0\n' "$A" > "$A/bin/hermes"; chmod +x "$A/bin/hermes"
ap() { HOME="$A" PATH="$A/bin:$PATH" OWNER_CONFIG=/workspace/config/owner.example.env /workspace/bin/apply-hermes-local.sh "$@" > "$A/out" 2>&1; echo $?; }
# Guard: apply must touch nothing outside the scratch HOME. A literal /home/node/.hermes root (outside PATH lines and
# comments) means a live write, so the scratch run is skipped and reported.
if grep -nE '(^|[^:])/home/node/\.hermes"?($|[;/ "])' /workspace/bin/apply-hermes-local.sh /workspace/bin/register-toolsets.sh | grep -vE ':\s*#|export PATH=|dst="\$H\$\{dst#'; then
  echo "FAIL apply-hermes-local.sh or register-toolsets.sh names /home/node/.hermes: scratch apply skipped"; fails=$((fails+1)); ap() { echo 99; }
fi
rc=$(ap)
ok 'has profiles/reviewer/ test-only-terminal.sh "" 2>/dev/null; grep -q "test-only-terminal.sh" "$HA/profiles/reviewer/config.yaml" && [ -s "$HA/profiles/builder-local/hooks/secret-guard.py" ] && [ -s "$HA/hooks/secret-guard.py" ] && [ -s "$HA/profiles/reviewer/hooks/secret-guard.py" ] && [ -x "$HA/profiles/builder-claude/hooks/deny-skill-manage.sh" ]' "S4: a failing hermes config get no longer stops apply before the hook and toolset steps (exit $rc)"
ok '[ "$(head -1 "$HA/profiles/reviewer/SOUL.md")" = "My own first line" ] && [ "$(head -1 "$HA/SOUL.md")" = "You are Hermes Agent, a helpful assistant." ] && grep -q "stella-rules:begin" "$HA/profiles/reviewer/SOUL.md"' "S24: an unmarked SOUL keeps its first line (the persona line as before, or a hand-written one)"
ok 'ls "$HA"/backups/*/reviewer.SOUL.md >/dev/null 2>&1 && ls "$HA"/backups/*/reviewer.config.yaml >/dev/null 2>&1 && ls "$HA"/backups/*/reviewer.shell-hooks-allowlist.json >/dev/null 2>&1 && [ -z "$(find "$HA" -name "*.tmp*")" ]' "F25/S25: SOUL.md, config.yaml and the allowlist are backed up before the first change; no temp file left"
printf '\n' >> "$HA/config.yaml"; sed -i 's#^hooks:$#hooks:\n  pre_tool_call:\n    - matcher: "^x$"\n      command: "/tmp/stale-hook.sh"\n      timeout: 10#' "$HA/config.yaml"
sed -i '/deny-kanban-block/,+2d' "$HA/config.yaml"
rc=$(ap --check)
ok '[ "$rc" = 1 ] && grep -qF "MISSING pre_tool_call ^kanban_block\$" "$A/out" && grep -q "UNLISTED.*/tmp/stale-hook.sh" "$A/out"' "S4: --check still reports a missing hook; F25: a hook registered but not listed is reported"
n=$(find "$HA/backups" -type f | wc -l); ap >/dev/null; ap >/dev/null
ok '[ "$(find "$HA/backups" -type f | wc -l)" -gt "$n" ] && m=$(find "$HA/backups" -type f | wc -l) && ap >/dev/null && [ "$(find "$HA/backups" -type f | wc -l)" = "$m" ]' "F25: an in-sync run writes and backs up nothing"
mkdir -p "$T/sup/state"; : > "$T/sup/limits.env"
{ cat /workspace/config/owner.example.env; printf "ESCALATIONS_CHANNEL_ID='100'\\n"; } > "$T/owner.env"; export OWNER_CONFIG="$T/owner.env"   # scratch owner config (D39)
ok '[ "$(jq -nc "{tool_name: \"kanban_block\", tool_input: {task_id: \"t_aaaaaaaa\", reason: \"Decision needed: A or B.\"}}" | ESCALATE_SUP_DIR="$T/sup" HERMES_KANBAN_TASK=t_aaaaaaaa /workspace/bin/kanban-guard.sh >/dev/null 2>&1; echo $?)" = 0 ]' "worker kanban_block payload allowed (kanban guard, first block)"
# K9: the reviewer's terminal runs tests and, to check a commit's scope, exactly these read-only git forms:
# git [-C <path>] (diff --name-only|diff --stat|show --stat|show --name-only|log --oneline [-n N]) [rev[..rev]...]
# Revisions never start with "-" (git diff --output=<file> would write a file), no shell metacharacter, no newline.
# (A lone trailing newline is not tested: the hook reads the command with $(...), which strips it, and nothing can follow it.)
for c in "npm test" "npm run test" "npm run lint" "node --test" \
         "git diff --name-only main...HEAD" "git show --stat HEAD" "git log --oneline -n 5" "git -C /abs/path diff --stat a..b" \
         "git diff --name-only HEAD~1..HEAD" "git diff --stat main..HEAD" "git diff --stat HEAD~1...HEAD" "git diff --name-only HEAD^..HEAD" "git diff --name-only origin/main...HEAD" \
         "git show --name-only HEAD" "git show --stat HEAD~2" "git show --stat" "git log --oneline" "git log --oneline main..HEAD" "git log --oneline -n 20 main..stella/t_14f8f08b-x" \
         "git -C /workspace/.worktrees/t_14f8f08b diff --name-only main...HEAD" "git -C /abs/wt log --oneline -n 3" "git -C /abs/wt show --stat HEAD~1..HEAD"; do
  ok '[ "$(term $RT "$c")" = 0 ]' "reviewer terminal allowed: $c"
done
# RT6-02: -C is absolute, no .. path segment anywhere, git diff takes exactly one revision range (so it never compares two files)
for c in "git diff --name-only" "git diff --stat" "git diff --stat HEAD" "git diff --name-only HEAD" "git diff --stat HEAD~1 HEAD" "git diff --stat a..b c..d" \
         "git diff --stat a b" "git -C / diff --stat a b" "git -C /abs diff --stat a" "git -C ./wt log --oneline -n 3" "git -C wt show --stat HEAD" \
         "git -C .. show --stat HEAD" "git -C /abs/../etc diff --stat a..b" "git -C /.. log --oneline" "git -C /abs/.. show --name-only HEAD" \
         "git show --stat ../x" "git show --stat HEAD ../../etc/passwd" "git log --oneline ../x" "git diff --stat ../a..b" \
         "git -C /abs/.. diff --stat a..b"; do
  ok '[ "$(term $RT "$c")" = 2 ]' "reviewer terminal refused (RT6-02): $c"
done
for c in "git diff --output=x" "git diff --output=x HEAD" "git diff --name-only --output x" "git diff --name-only --output=/tmp/x main...HEAD" \
         "git diff --stat main...HEAD --output=x" "git diff --name-only HEAD --output=x" "git show --stat --output=x HEAD" "git log --oneline --output=x" \
         "git diff --name-only -O/tmp/x" "git diff --name-only --no-index /etc/passwd /dev/null" "git diff --stat -- x" "git diff --name-only --ext-diff" \
         "git diff --name-only;rm x" "git diff --name-only; touch /tmp/x" "git diff --name-only | sh" "git diff --name-only|sh" "git diff --name-only && rm x" \
         "git diff --name-only || rm x" "git diff --name-only & rm x" "git diff --name-only > /tmp/x" "git diff --name-only >> /tmp/x" "git diff --name-only < /etc/passwd" \
         'git diff --name-only $(touch /tmp/x)' 'git diff --name-only `touch /tmp/x`' 'git diff --name-only $HOME' 'git diff --name-only ${HOME}' \
         'git show --stat HEAD;touch /tmp/x' 'git log --oneline -n 5;touch /tmp/x' 'git log --oneline -n 5 | sh' 'git -C /tmp;touch x diff --stat' \
         'git diff --name-only main...HEAD*' 'git diff --name-only "HEAD"' "git diff --name-only 'HEAD'" 'git diff --name-only HEAD\' 'git diff --name-only (HEAD)' \
         $'git diff --name-only\nrm x' $'git diff --name-only HEAD\nrm x' $'git diff --name-only HEAD\r' $'git log --oneline\nnpm test' $'npm test\nrm x' \
         $'git diff --name-only\t--output=x' "git  diff --name-only" "git diff  --name-only" "git diff --name-only  HEAD" " git diff --name-only" "git diff --name-only " \
         "git commit -m x" "git commit --allow-empty -m x" "git push" "git push origin main" "git add -A" "git checkout main" "git reset --hard" "git status" "git diff" "git show HEAD" \
         "git log" "git log -p" "git log --oneline -p" "git log --oneline -n" "git log --oneline -n x" "git log --oneline -n -5" "git log --oneline -n 5x" \
         "git config user.name x" "git -c core.pager=sh log --oneline" "git --no-pager diff --stat" "git -c core.fsmonitor=x diff --stat" "git branch -D x" "git merge x" "git stash" \
         "git -C ~/x show --stat" 'git -C $HOME/x show --stat' "git -C ~ diff --stat" "git -C '/p' diff --stat" 'git -C "/p" diff --stat' "git -C a b diff --stat" "git -C /x -C /y diff --stat" \
         "git -C /x" "git -C diff --stat" "git -C /x commit -m x" "git -C /x push" "git -C /tmp/x*/y diff --stat" \
         "cat x" "ls" "rm x" "npm install" "npm test x" "npm test; rm x" "node --test x" "bash -c 'git diff --name-only'" "env git diff --name-only" "GIT_DIR=x git diff --name-only" "/usr/bin/git diff --name-only" "" ; do
  ok '[ "$(term $RT "$c")" = 2 ] && grep -q "the reviewer role: terminal is limited" "$T/out"' "reviewer terminal refused: ${c//$'\n'/\\n}"
done
ok '[ "$(term $RT "git diff --output=x")" = 2 ] && grep -q "git diff --name-only" "$T/out" && grep -q "git log --oneline" "$T/out"' "K9: the refusal lists the allowed read-only git forms"
ok '[ "$(echo not-json | $RT >/dev/null 2>&1; echo $?)" = 2 ] && [ "$(run $RT read_file "{\"path\":\"x\"}")" = 2 ]' "K9: the reviewer terminal hook fails closed on a garbage payload and on a tool that is not terminal"
# Why the --output refusals matter, and that the allowed forms really are read-only: run them in a scratch repo.
GR="$T/gitrepo"; git init -q -b main "$GR"; git -C "$GR" -c core.hooksPath=/dev/null -c user.name=s -c user.email=s@example.invalid commit -q --allow-empty -m base
printf 'a\n' >"$GR/a.txt"; git -C "$GR" add a.txt; git -C "$GR" -c core.hooksPath=/dev/null -c user.name=s -c user.email=s@example.invalid commit -q -m "add a"
git -C "$GR" diff --output="$T/leak" HEAD~1 HEAD; ok '[ -f "$T/leak" ]' "K9: premise: git diff --output=<file> does write a file, so an option-looking revision must be refused"
rm -f "$T/leak"; h0=$(git -C "$GR" rev-parse HEAD)
ok '( for c in "git -C $GR diff --name-only main...HEAD" "git -C $GR show --stat HEAD" "git -C $GR log --oneline -n 5" "git -C $GR diff --stat HEAD~1..HEAD" "git -C $GR show --name-only HEAD~1"; do [ "$(term $RT "$c")" = 0 ] && bash -c "$c" >/dev/null 2>&1 || exit 1; done ) && [ -z "$(git -C $GR status --porcelain)" ] && [ "$(git -C $GR rev-parse HEAD)" = "$h0" ] && [ "$(ls -A $GR | grep -vx .git | wc -l)" = 1 ]' "K9: the allowed git forms run for real in a scratch repo and change nothing"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
