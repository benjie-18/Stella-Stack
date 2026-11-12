#!/usr/bin/env bash
# Hermetic self-test for K6: the owner settings files (roles.json owner_settings) are protected from every agent role, for
# reading and for writing. Table-driven: for every profile, every role without a profile (the unlisted fallback) and every tool
# the role's matchers cover, the role's own registered hooks are run on a probe owner file; a role passes a refusal case when at
# least one of its hooks refuses (exit 2 and a {"action": "block"} message), and fails it when no hook covers the tool.
#  1 probe table: owner_settings = a path that does not exist (nothing is read, created or written). Reads: read_file (absolute,
#    ..-relative, through a symlink), search_files on the file and on its folder, vision_analyze, skill_view, terminal cat / grep -r /
#    cp / > redirect, process_manage stdin. Writes: write_file, patch. Controls: ordinary reads and the owner example file next to it.
#  2 the same on a fixture file that does exist (under .scratch, removed at exit): a glob and a recursive search reach it.
#  3 the real table, whose owner_settings entry is only named (the path string comes from the table; no hook opens it).
#  4 fail closed: an unreadable or invalid table refuses ordinary reads too.
#  5 real path: a fake worker bound to a running card on a stub board, a shell and an interpreter below it, then the hook, from
#    the worker's main thread (the parent) and from a second thread of that process (a delegated child shares its worker's hooks:
#    bin/delegation-selftest.sh). Builder write_file / patch / redirect / cat of the owner path, and a git commit staging it.
#  7 RT6-01 write guard in a project repo outside /workspace: a scratch projects.db (PROJECTS_DB) binds a scratch repo to the board;
#    a bound builder of a card in it writes only in its own <repo>/.worktrees/<card> (write_file, patch, terminal redirects), and an
#    unreadable projects.db refuses a write outside /tmp.
#  6 pre-commit guard (bin/commit-guard.sh): a staged owner path is refused, an ordinary commit and a same-named file in another
#    folder are not, and an unreadable list refuses.
# STACK=<tree> runs the guards of another tree (default /workspace; the negative controls are the live tree and
# .scratch/readiness-pre; a staged tree is built by .scratch/k6/stage.sh). ROLES_FILE=<table> supplies the matchers and the real
# owner_settings entry (default the live table). Hooks are run from copies whose hard /workspace/bin import points at
# $STACK/bin. The stub `hermes` refuses `send`; ESCALATE_SUP_DIR is this run's own folder.
set -u
P=owner-settings-selftest
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "$P.*" -mmin +60 -exec rm -rf {} + 2>/dev/null
T=$(mktemp -d -t "$P.XXXXXX"); STR=; FIX=
trap '[ -n "$STR" ] && kill "$STR" 2>/dev/null; rm -rf "$T"; [ -n "$FIX" ] && rm -rf "$FIX"' EXIT
export ESCALATE_SUP_DIR=$T/sup; mkdir -p "$T/sup/logs" "$T/sup/state"
unset HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB HERMES_KANBAN_BOARD \
  HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT
STACK=${STACK:-/workspace}
SRC=${ROLES_FILE:-/workspace/docs/hermes-local/roles.json}
fails=0
say() { if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
# hf <hook as written in the table>: a runnable copy whose /workspace/bin import points at $STACK/bin (a `command` hook is used in place)
hf() {
  case $1 in /*) echo "$1" ;; *) [ -x "$T/h/$1" ] || { mkdir -p "$T/h/$(dirname "$1")"; sed "s#/workspace/bin#$STACK/bin#g" "$STACK/$1" >"$T/h/$1"; chmod +x "$T/h/$1"; }; echo "$T/h/$1" ;; esac
}
hk() { printf '%s' "$2" | "$1" >"$T/out" 2>"$T/err"; echo $?; }   # <hook> <payload>: its exit code; stdout in $T/out
blocked() { [ "$1" = 2 ] && jq -e '.action == "block"' "$T/out" >/dev/null 2>&1; }
pl() { jq -nc --arg t "$1" --argjson i "$2" --arg c "${3:-/workspace}" '{tool_name: $t, tool_input: $i, session_id: "s1", cwd: $c, profile: "p", extra: {}}'; }
js() { jq -nc "$@"; }
CURW=   # the worker kind of the profile being exercised (a role's hook may be for one worker kind only, as roles.py hooks_for reads it)
setw() { case $1 in role:*) CURW=;; *) CURW=$(jq -r --arg p "$1" '.profiles[$p].worker // ""' "$MT" 2>/dev/null) || CURW=;; esac; }
hooks_for() {   # <matcher table> <role> <tool>: the hooks (command or repo file) the role's matchers cover for <tool> and the current profile's worker kind; memoized in files
  local f="$T/hc/$(basename "$1").$2.$3.${CURW:-none}"
  # a catch_all matcher is the table's template, rendered as registration renders it (roles.hooks_for with the role's tools: T5); the others as written
  [ -f "$f" ] || { mkdir -p "$T/hc"; python3 -I -c '
import json, re, sys
sys.path.insert(0, sys.argv[5]); import roles
d, r, t, w = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4]
d["profiles"] = {"zz-p": {"role": r, **({"worker": w} if w else {})}}
tools = roles.role_tools(d, r) if any(h.get("catch_all") for h in d["roles"][r].get("hooks", [])) else None
[print(f or c.removeprefix("python3 -I ")) for m, c, _, f in roles.hooks_for(d, "", "zz-p", "", r, tools) if re.search(m, t)]' "$1" "$2" "$3" "$CURW" "$STACK/bin" >"$f"; }
  cat "$f"
}
MT=   # the table whose matchers pick each role's hooks

# refuse <label> <role> <tool> <tool_input> <description> [cwd]: some hook of the role covering <tool> refuses
refuse() {
  local hs h by="" pay; hs=$(hooks_for "$MT" "$2" "$3"); pay=$(pl "$3" "$4" "${6:-/workspace}")
  [ -n "$hs" ] || { say 1 "$1 $3 $5: no hook of the role covers $3"; return; }
  for h in $hs; do blocked "$(hk "$(hf "$h")" "$pay")" && by="$by $(basename "$h")"; done
  say "$([ -n "$by" ]; echo $?)" "$1 $3 $5: refused by${by:- (none)}"
}
# allow <label> <role> <tool> <tool_input> <description> [cwd]: every hook of the role covering <tool> lets it through
allow() {
  local h bad="" pay; pay=$(pl "$3" "$4" "${6:-/workspace}")
  for h in $(hooks_for "$MT" "$2" "$3"); do [ "$(hk "$(hf "$h")" "$pay")" = 0 ] || bad="$bad $(basename "$h")"; done
  say "$([ -z "$bad" ]; echo $?)" "$1 $3 $5: allowed${bad:+ (refused by$bad)}"
}
pairs() {   # "<label> <role>" for each profile, then each role no profile has (the unlisted fallback)
  jq -r '.profiles | to_entries[] | "\(.key) \(.value.role)"' "$MT"
  jq -r '([.profiles[].role]) as $u | .roles | keys[] | select(. as $k | ($u | any(. == $k)) | not) | "role:\(.) \(.)"' "$MT"
}

# matrix <tag> <owner path> <its folder> <glob/recursion cases: 1|0>: every case above for every role
matrix() {
  local tag=$1 own=$2 dir=$3 deep=$4 rel lab role c ex okc bad h n=0 t f
  ln -sfn "$own" "$T/lnk"
  rel=${own#/workspace/}; ex=${own%.env}.example.env
  # T1 (F1 W4 r4): the roles run six at a time, as in 3b (each in a subshell with its own output files; the hook copies and hook lists are made first)
  mkdir -p "$T/m1"; rm -f "$T"/m1/*
  while read -r lab role; do setw "$lab"; for t in read_file search_files vision_analyze skill_view terminal process_manage write_file patch; do for h in $(hooks_for "$MT" "$role" $t); do hf "$h" >/dev/null; done; done; done < <(pairs)
  while read -r lab role; do
    n=$((n+1)); matrix_role "$n" >"$T/m1/$n.out" 2>&1 &
    [ $((n % 6)) = 0 ] && wait
  done < <(pairs)
  wait
  for f in $(ls "$T"/m1/*.out | sort -V); do cat "$f"; fails=$((fails + $(grep -c '^FAIL' "$f"))); done
}
matrix_role() {   # matrix_role <n>: matrix's cases for one role ($lab, $role and the matrix's locals are the caller's); runs in a subshell, writes only $T/m1/<n>.*
    local n=$1
    hk() { printf '%s' "$2" | "$1" >"$T/m1/$n.o" 2>"$T/m1/$n.e"; echo $?; }
    blocked() { [ "$1" = 2 ] && jq -e '.action == "block"' "$T/m1/$n.o" >/dev/null 2>&1; }
    setw "$lab"
    L="$tag $lab/$role"
    refuse "$L" "$role" read_file "$(js --arg p "$own" '{path: $p}')" "owner file"
    refuse "$L" "$role" read_file "$(js --arg p "../$rel" '{path: $p}')" "../ relative from /workspace/bin" /workspace/bin
    refuse "$L" "$role" read_file "$(js --arg p "$T/lnk" '{path: $p}')" "through a symlink"
    refuse "$L" "$role" search_files "$(js --arg p "$own" '{pattern: "x", path: $p}')" "on the owner file"
    refuse "$L" "$role" search_files "$(js --arg p "$dir" '{pattern: "x", path: $p}')" "FOLDER of the owner file (content search)"
    refuse "$L" "$role" vision_analyze "$(js --arg p "$own" '{image_url: $p, question: "x"}')" "owner file"
    refuse "$L" "$role" skill_view "$(js --arg p "$own" '{name: "x", file_path: $p}')" "owner file"
    for c in "cat $own" "cat $rel" "grep -r x $own" "grep -r x $dir" "cp $own /tmp/x" "echo x > $own" "cp /tmp/x $own"; do
      refuse "$L" "$role" terminal "$(js --arg c "$c" '{command: $c}')" "$c"
    done
    refuse "$L" "$role" process_manage "$(js --arg d "cat $own" '{action: "write", session_id: "p1", data: $d}')" "stdin cat of the owner file"
    # B2V-01: /workspace is case-insensitive, so another spelling of the same path is the same file
    refuse "$L" "$role" read_file "$(js --arg p "/workspace/${rel^^}" '{path: $p}')" "the owner file upper-cased (B2V-01)"
    refuse "$L" "$role" read_file "$(js --arg p "/workspace/$(sed 's/[a-z]/\U&/' <<<"$rel")" '{path: $p}')" "the owner file with one letter of its folder upper-cased (B2V-01)"
    refuse "$L" "$role" terminal "$(js --arg c "cat /workspace/${rel^^}" '{command: $c}')" "cat of the owner file upper-cased (B2V-01)"
    if [ "$deep" = 1 ]; then
      for c in "cat $dir/*" "cat $dir/zz-owner-prob?.env" "cp -r $dir /tmp/x"; do
        refuse "$L" "$role" terminal "$(js --arg c "$c" '{command: $c}')" "$c"
      done
      # RT7-01: a recursive search with no path reads the current folder; the terminal never enters the owner folder
      for c in "grep -rn x" "rg x" "find -name x" "grep -r -m 5 x" "cd ${dir##*/} && cat *" "cd ${dir##*/} && grep -rn x" \
               "cd $dir" "cd -P $dir" "pushd $dir"; do
        refuse "$L" "$role" terminal "$(js --arg c "$c" '{command: $c}')" "$c, run in the folder above the owner folder (RT7-01)" "${dir%/*}"
      done
      refuse "$L" "$role" terminal "$(js --arg w "$dir" '{command: "cat *", workdir: $w}')" "workdir = the owner folder (RT7-01)"
      refuse "$L" "$role" search_files '{"pattern": "x"}' "no path, run in the folder above the owner folder (RT7-01)" "${dir%/*}"
      # B2V-14: git diff/grep with a path outside a repo (or --no-index), and diff of two folders, print every file;
      # B2V-15: cd behind a shell keyword or wrapper still moves the terminal
      for c in "git diff --no-index /tmp $dir" "git diff /tmp $dir" "git diff /tmp ${dir##*/}" "git grep --no-index -e . -- $dir" \
               "git -C ${dir%/*} grep --no-index -e . -- ${dir##*/}" "diff -rN $dir /tmp" "diff -N $dir /tmp" \
               "if cd ${dir##*/}; then cat *; fi" "{ cd ${dir##*/}; cat *; }" "builtin cd ${dir##*/} && cat *" \
               "command cd ${dir##*/} && cat *" "while cd ${dir##*/}; do cat *; break; done" "timeout 5 grep -rn x" "env A=1 grep -rn x"; do
        refuse "$L" "$role" terminal "$(js --arg c "$c" '{command: $c}')" "$c, run in the folder above the owner folder (B2V-14/15)" "${dir%/*}"
      done
    fi
    refuse "$L" "$role" write_file "$(js --arg p "$own" '{path: $p, content: "x"}')" "owner file"
    refuse "$L" "$role" patch "$(js --arg p "$own" '{mode: "replace", path: $p, old_string: "a", new_string: "b"}')" "owner file"
    # controls: the guards refuse by path, not everything
    allow "$L" "$role" read_file '{"path": "/workspace/SUPERVISOR.md"}' "ordinary file"
    allow "$L" "$role" read_file "$(js --arg p "$ex" '{path: $p}')" "the owner example file beside it"
    allow "$L" "$role" search_files '{"pattern": "x", "path": "/workspace/bin", "file_glob": "*.sh"}' "ordinary folder"
    allow "$L" "$role" vision_analyze '{"image_url": "/workspace/docs/x.png", "question": "x"}' "ordinary image"
    allow "$L" "$role" skill_view '{"name": "x"}' "ordinary skill"
    okc=
    for c in "cat package.json" "npm test" "git log --oneline"; do
      bad=0
      for h in $(hooks_for "$MT" "$role" terminal); do [ "$(hk "$(hf "$h")" "$(pl terminal "$(js --arg c "$c" '{command: $c}')")")" = 0 ] || bad=1; done
      [ $bad = 0 ] && { okc=$c; break; }
    done
    say "$([ -n "$okc" ]; echo $?)" "$L terminal control: an ordinary command passes all of the role's terminal hooks (${okc:-none does})"
    for h in $(hooks_for "$MT" "$role" terminal); do
      [ "$(hk "$(hf "$h")" "$(pl terminal '{"command": "cat package.json"}')")" = 0 ] || continue
      say "$([ "$(hk "$(hf "$h")" "$(pl terminal "$(js --arg c "cat $ex" '{command: $c}')")")" = 0 ]; echo $?)" "$L terminal control: cat of the owner example file allowed by $(basename "$h")"
    done
}

jq -e . "$SRC" >/dev/null 2>&1 || { echo "FAIL the role table $SRC is not readable"; echo "selftest FAIL (1)"; exit 1; }
PROBE=config/zz-owner-probe.env; POWN=/workspace/$PROBE
[ ! -e "$POWN" ] || { echo "FAIL $POWN exists: this test needs a path that does not"; echo "selftest FAIL (1)"; exit 1; }
tbl() { jq --argjson o "$2" '.owner_settings = $o' "$SRC" >"$1"; }   # <file> <owner_settings json>

# 1 probe table (nonexistent owner file)
tbl "$T/probe.json" "[\"$PROBE\"]"; MT=$T/probe.json; export ROLES_FILE=$MT
say "$([ "$(pairs | wc -l)" -ge 2 ] && pairs | grep -q "^role:$(jq -r .fallback_role "$MT") "; echo $?)" "1 the fallback role (no profile) is among the roles exercised"
matrix 1 "$POWN" /workspace/config 0
SGF=$(hf docs/hermes-local/hooks/builder/secret-guard.py)
say "$(blocked "$(hk "$SGF" "$(pl read_file "$(js --arg p "$POWN" '{path: $p}')")")" && grep -q "owner settings file" "$T/out" && ! grep -q kanban_block "$T/out"; echo $?)" "1 B2V-16: a direct read of the owner file gets the owner-settings message, not the block-for-a-secret one"
say "$(blocked "$(hk "$SGF" "$(pl terminal "$(js --arg c "cat $PROBE" '{command: $c}')")")" && grep -q "owner settings file" "$T/out" && ! grep -q kanban_block "$T/out"; echo $?)" "1 B2V-16: a command naming the owner file gets the owner-settings message"

# 2 a fixture that exists (a glob matches it, a recursive search would read it)
FIX=$(mktemp -d -p /workspace/.scratch "$P.XXXXXX"); echo "dummy=1" >"$FIX/zz-owner-probe.env"
FREL=${FIX#/workspace/}/zz-owner-probe.env; tbl "$T/fix.json" "[\"$FREL\"]"; MT=$T/fix.json; export ROLES_FILE=$MT
matrix 2 "$FIX/zz-owner-probe.env" "$FIX" 1

# 3 the real table: its owner_settings entry is a string only
MT=$SRC; export ROLES_FILE=$SRC
REAL=$(jq -r '.owner_settings[0] // empty' "$SRC")
say "$([ -n "$REAL" ]; echo $?)" "3 the real table lists an owner settings file"
if [ -n "$REAL" ]; then
  while read -r lab role; do
    setw "$lab"
    refuse "3 $lab/$role" "$role" read_file "$(js --arg p "/workspace/$REAL" '{path: $p}')" "real owner file"
    refuse "3 $lab/$role" "$role" vision_analyze "$(js --arg p "/workspace/$REAL" '{image_url: $p, question: "x"}')" "real owner file"
    refuse "3 $lab/$role" "$role" skill_view "$(js --arg p "/workspace/$REAL" '{name: "x", file_path: $p}')" "real owner file"
    refuse "3 $lab/$role" "$role" search_files "$(js --arg p "/workspace/$REAL" '{pattern: "x", path: $p}')" "real owner file"
    refuse "3 $lab/$role" "$role" terminal "$(js --arg c "cat /workspace/$REAL" '{command: $c}')" "cat real owner file"
    refuse "3 $lab/$role" "$role" terminal "$(js --arg c "echo x > /workspace/$REAL" '{command: $c}')" "redirect into the real owner file"
    refuse "3 $lab/$role" "$role" write_file "$(js --arg p "/workspace/$REAL" '{path: $p, content: "x"}')" "real owner file"
  done < <(pairs)
fi

# 3b F1 W4 (E7): the owner-only write path. For every role and every entry of owner_data (paths no role writes, but all may read) and of
# owner_commands (commands no role runs), from the table: the write tools, a redirect, copy/move/delete, git commands that write the
# path, a symlink to it, another spelling of it, and every spelling of each command; reads of owner data stay allowed. The tables are
# the real one and one with an extra entry in each list (no name is in the code).
printf '%s\n' 'diff --git a/ZZD/zz-probe.json b/ZZD/zz-probe.json' 'new file mode 100644' '--- /dev/null' '+++ b/ZZD/zz-probe.json' '@@ -0,0 +1 @@' '+x' >"$T/w4.patch.in"
M2=$T/m2; mkdir -p "$M2"
m2role() {   # m2role <tag> <profile label> <role> <owner data list> <owner commands list> <n> [light list]: one role's cases; runs in a subshell, writes only under $M2
  local tag=$1 lab=$2 role=$3 DS=$4 CS=$5 n=$6 DL=${7:-} OUT=$M2/$n.o ERR=$M2/$n.e LN=$M2/$n.lnk PT=$M2/$n.patch d f c x b q dir okc bad h
  hk() { printf '%s' "$2" | "$1" >"$OUT" 2>"$ERR"; echo $?; }
  blocked() { [ "$1" = 2 ] && jq -e '.action == "block"' "$OUT" >/dev/null 2>&1; }
  r1() {   # r1 <tool> <input> <description> [cwd]: refused as soon as one hook of the role covering <tool> blocks
    local hs h pay; hs=$(hooks_for "$MT" "$role" "$1"); pay=$(pl "$1" "$2" "${4:-/workspace}")
    [ -n "$hs" ] || { say 1 "$L $1 $3: no hook of the role covers $1"; return; }
    for h in $hs; do blocked "$(hk "$(hf "$h")" "$pay")" && { say 0 "$L $1 $3: refused by $(basename "$h")"; return; }; done
    say 1 "$L $1 $3: refused by (none)"
  }
  setw "$lab"; L="$tag $lab/$role"
  okc=; for c in "cat package.json" "npm test" "git log --oneline"; do
    bad=0; for h in $(hooks_for "$MT" "$role" terminal); do [ "$(hk "$(hf "$h")" "$(pl terminal "$(js --arg c "$c" '{command: $c}')")")" = 0 ] || bad=1; done
    [ $bad = 0 ] && { okc=$c; break; }
  done
  for d in $DS; do
    f=/workspace/$d/zz-probe.json; sed "s#ZZD#$d#g" "$T/w4.patch.in" >"$PT"; ln -sfn "/workspace/$d" "$LN"
    r1 write_file "$(js --arg p "$f" '{path: $p, content: "x"}')" "owner data $d"
    r1 patch "$(js --arg p "$f" '{mode: "replace", path: $p, old_string: "a", new_string: "b"}')" "owner data $d"
    r1 patch "$(js --arg p "$f" '{mode: "patch", patch: "*** Begin Patch\n*** Add File: \($p)\n+x\n*** End Patch"}')" "owner data $d, V4A add"
    r1 write_file "$(js --arg p "/workspace/${d^^}/zz-probe.json" '{path: $p, content: "x"}')" "owner data $d upper-cased (B2V-01)"
    r1 write_file "$(js --arg p "$LN/zz-probe.json" '{path: $p, content: "x"}')" "owner data $d through a symlink"
    r1 write_file "$(js --arg p "/workspace/.worktrees/t_00000000/$d/zz-probe.json" '{path: $p, content: "x"}')" "owner data $d in a card worktree of the stack"
    for c in "echo x > $f" "echo x >> $f" "cp /tmp/x $f" "mv /tmp/x $f" "tee $f" "sed -i s/a/b/ $f" "rm $f" "rm -r /workspace/$d" "dd if=/tmp/x of=$f" \
             "ln -sf /tmp/x $f" "echo x > $LN/zz-probe.json" "git add -f $f" "git -C /workspace add -f $d/zz-probe.json" "git commit -m x $f" \
             "git checkout HEAD -- $f" "git -C /workspace restore $d" "git rm $f" "git mv $f /tmp/x" "git mv /tmp/x $f" "git apply $PT" \
             "env GIT_DIR=/workspace/.git git add -f $f" "bash -c 'git add -f $f'"; do
      r1 terminal "$(js --arg c "$c" '{command: $c}')" "$c"
    done
    for c in "echo x >& $f" "echo x >&$f" ": <> $f" "echo x &> $f" "echo x >| $f" "echo x 2> $f" "echo ok
cp /tmp/x $f" "echo ok
tee $f" "echo ok
dd of=$f" "echo x > /workspace/${d^^}/zz-probe.json" "echo x > /workspace/$d/zz-pr{o,}be.json" "echo x > \$'/workspace/$d/zz-\x70robe.json'" \
             "cp /tmp/x /workspace/$d/zz-pro?e.json" "git update-index --add --cacheinfo 100644,0000000000000000000000000000000000000000,$d/zz-probe.json" \
             "git checkout -- ." "git restore ." "git reset --hard" "git hash-object -w $f"; do
      r1 terminal "$(js --arg c "$c" '{command: $c}')" "G2 form: ${c//$'\n'/<NL>}"
    done
    r1 terminal '{"command": "echo x > zz-probe.json"}' "relative redirect from inside owner data $d" "/workspace/$d"
    r1 terminal '{"command": "git add -f zz-probe.json"}' "relative git add from inside owner data $d" "/workspace/$d"
    r1 terminal "$(js --arg c "git apply - <<'EOF'
$(cat "$PT")
EOF" '{command: $c}')" "git apply of a patch given on stdin naming $d"
    r1 process_manage "$(js --arg d "echo x > $f" '{action: "write", session_id: "p1", data: $d}')" "stdin redirect into owner data $d"
    # controls: reading owner data is allowed
    allow "$L" "$role" read_file "$(js --arg p "$f" '{path: $p}')" "reading owner data $d"
    allow "$L" "$role" search_files "$(js --arg p "/workspace/$d" '{pattern: "x", path: $p}')" "searching owner data $d"
    if [ "$okc" = "cat package.json" ]; then   # a role that lets an ordinary read through lets a read of owner data through too
      bad=0; for h in $(hooks_for "$MT" "$role" terminal); do [ "$(hk "$(hf "$h")" "$(pl terminal "$(js --arg c "cat $f" '{command: $c}')")")" = 0 ] || bad=1; done
      say $bad "$L terminal control: cat of owner data $d allowed"
    fi
  done
  for d in $DL; do   # the other owner data paths the index names: the main cases, not the whole battery
    f=/workspace/$d/zz-probe.json
    r1 write_file "$(js --arg p "$f" '{path: $p, content: "x"}')" "owner data $d (index row)"
    r1 patch "$(js --arg p "$f" '{mode: "replace", path: $p, old_string: "a", new_string: "b"}')" "owner data $d (index row)"
    for c in "echo x > $f" "echo x >& $f" "cp /tmp/x $f" "rm $f" "git add -f $f"; do r1 terminal "$(js --arg c "$c" '{command: $c}')" "$c"; done
  done
  # B1: the apply tool's state (backups, applied state, event log) holds owner values: no role reads or writes any of the three; every spelling
  for x in "$BK/zz-probe/file" "$APS" "$EVL"; do
    r1 read_file "$(js --arg p "$x" '{path: $p}')" "state path ${x#/workspace/}"
    r1 search_files "$(js --arg p "${x%/*}" '{pattern: "x", path: $p}')" "folder of state path ${x#/workspace/} (content search)"
    for c in "cat $x" "head -c 5 ${x#/workspace/}" "grep -r x ${x%/*}" "python3 -c \"print(open('$x').read())\"" "python3 -c \"print(open('${x#/workspace/}').read())\"" "cat \$'${x%/*}/${x##*/}'"; do
      r1 terminal "$(js --arg c "$c" '{command: $c}')" "$c"
    done
    r1 process_manage "$(js --arg d "cat $x" '{action: "write", session_id: "p1", data: $d}')" "stdin cat of state path ${x#/workspace/}"
  done
  # B2: a role outside the box (runs_unboxed) refuses every write form by its hooks, the text guard's blind spots included
  if [ "$(jq -r --arg r "$role" '.roles[$r].runs_unboxed' "$MT")" = true ]; then
    f=/workspace/$(jq -r '.owner_data[0]' "$MT")/zz-probe.json
    for c in "echo ok
cp /tmp/x $f" "echo x >& $f" ": <> $f" "x=$f; echo y > \"\$x\"" "echo y > \$(echo $f)" "python3 -c \"open('$f','w').write('x')\"" "python3 -I -c 'import os; os.system(\"cp /tmp/x $f\")'" \
             "perl -e 'open(F, \">$f\")'" "sh -c 'echo y > $f'" "tee $f" "git -C /workspace checkout -- ."; do
      r1 terminal "$(js --arg c "$c" '{command: $c}')" "unboxed role: ${c//$'\n'/<NL>}"
    done
    [ "$role" != "$(jq -r .fallback_role "$MT")" ] || r1 zz_unknown_tool '{}' "unboxed fallback role: a tool no matcher of the role names"
    r1 execute_code '{"code": "open(\"/tmp/x\", \"w\")"}' "unboxed role: the code-execution tool"
    r1 cronjob_manage '{}' "unboxed role: the scheduler tool"
  fi
  # the apply tool's backup folder holds owner values in clear: no role reads or writes it; its applied state and event log (and the lock) are not written
  r1 read_file "$(js --arg p "$BK/zz-probe/file" '{path: $p}')" "backup folder file"
  r1 search_files "$(js --arg p "$BK" '{pattern: "x", path: $p}')" "backup folder (content search)"
  for c in "cat $BK/zz-probe/file" "grep -r x $BK" "cp -r $BK /tmp/x" "echo x > $BK/zz-probe/file" "rm -r $BK" "echo x > $APS" "cp /tmp/x $EVL" "echo x >> $EVL" "echo x > $EVL.lock"; do
    r1 terminal "$(js --arg c "$c" '{command: $c}')" "$c"
  done
  r1 write_file "$(js --arg p "$EVL" '{path: $p, content: "x"}')" "event log"
  r1 write_file "$(js --arg p "$APS" '{path: $p, content: "x"}')" "applied state"
  r1 write_file "$(js --arg p "$BK/zz-probe/file" '{path: $p, content: "x"}')" "backup folder file"
  for c in $CS; do
    b=${c##*/}; q="${b:0:2}''${b:2}"; dir=${c%/*}
    for x in "/workspace/$c" "bash /workspace/$c" "sh /workspace/$c x" "source /workspace/$c" ". /workspace/$c" "env X=1 /workspace/$c" "X=1 /workspace/$c" \
             "python3 -I /workspace/$c set A b" "bash -c '/workspace/$c x'" "bash /workspace/$dir/$q" "./$c" "/workspace/$dir/../$c" "timeout 5 /workspace/$c" \
             "echo y | /workspace/$c" "setsid -f /workspace/$c" "nohup setsid python3 /workspace/$c" "env -u HERMES_KANBAN_WORKSPACE python3 -I ./$c" "python3 $c"; do
      r1 terminal "$(js --arg c "$x" '{command: $c}')" "owner command: $x"
    done
    r1 terminal '{"command": "bash ./'"$b"'"}' "owner command from inside its folder: $c" "/workspace/$dir"
    r1 process_manage "$(js --arg d "/workspace/$c x
" '{action: "write", session_id: "p1", data: $d}')" "owner command on stdin: $c"
  done
}
matrix2() {   # matrix2 <tag> <owner data list> <owner commands list> [light data list]: every profile and role without one, six at a time, output kept in order
  local tag=$1 lab role n=0 f t h
  while read -r lab role; do setw "$lab"; for t in write_file patch terminal process_manage read_file search_files; do for h in $(hooks_for "$MT" "$role" $t); do hf "$h" >/dev/null; done; done; done < <(pairs)
  while read -r lab role; do
    n=$((n+1)); m2role "$tag" "$lab" "$role" "$2" "$3" "$n" "${4:-}" >"$M2/$n.out" 2>&1 &
    [ $((n % 6)) = 0 ] && wait
  done < <(pairs)
  wait
  for f in $(ls "$M2"/*.out | sort -V); do cat "$f"; fails=$((fails + $(grep -c '^FAIL' "$f"))); done; rm -f "${M2:?}"/*
}
IDX=$STACK/$(jq -r .data_index "$SRC"); BK=/workspace/$(jq -r .backup_dir "$IDX"); APS=/workspace/$(jq -r .applied_state "$IDX"); EVL=/workspace/$(jq -r .event_log "$IDX")
MT=$SRC; export ROLES_FILE=$SRC
say "$(jq -e '(.owner_data | length > 0) and (.owner_commands | length > 0) and (.worker_markers | length > 0)' "$SRC" >/dev/null; echo $?)" "3b the real table has owner_data, owner_commands and worker_markers"
SETP=$(jq -r '.files[] | select(.id == "settings") | .path' "$IDX")   # an owner_only index row, found by its id
OWNP=$(ROLES_FILE=$SRC python3 -I "$STACK/bin/roles.py" owner-data | jq -r '.[]')   # G1: the one function (index + owner_only rows + the table's list)
say "$([ "$(wc -l <<<"$OWNP")" -gt 5 ] && grep -qx "$SETP" <<<"$OWNP" && grep -qx '.supervisor/limits.env' <<<"$OWNP" && ! grep -qx '.stella/capabilities.json' <<<"$OWNP"; echo $?)" "3b G1: the owner data set holds the index rows with owner_only (settings, limits) and not the capability registry"
matrix2 "3b real table" "$(jq -r '.owner_data[]' "$SRC"; grep -x "$SETP" <<<"$OWNP")" "$(jq -r '.owner_commands[]' "$SRC")" "$(grep -vx -e "$SETP" -e "$(jq -r '.owner_data[0]' "$SRC")" <<<"$OWNP" | grep -v '^config/')"
jq '.owner_data += ["zz-odata/sub"] | .owner_commands += ["tools/zz-owner-cmd.sh"]' "$SRC" >"$T/extra.json"; MT=$T/extra.json; export ROLES_FILE=$MT
matrix2 "3b extra entries" "zz-odata/sub" "tools/zz-owner-cmd.sh"
MT=$SRC; export ROLES_FILE=$SRC

# 3c F1 W4 round 2 (the critical red team asserted decisions, not effects): the commands the hooks let through are run for real, in a scratch owner-data
# folder under .scratch; the owner file there must be byte-identical afterwards, for every role. A control that is allowed must change its own file.
NL=$'\n'; EFF=$FIX/eff; mkdir -p "$EFF"; printf 'orig\n' >"$EFF/owner.txt"; EFH=$(sha256sum <"$EFF/owner.txt"); printf 'new\n' >"$T/effsrc"
jq --arg o "${EFF#/workspace/}" '.owner_data += [$o]' "$SRC" >"$T/eff.json"; MT=$T/eff.json; export ROLES_FILE=$MT
effcmds=("echo ok${NL}echo y > $EFF/owner.txt" "echo y >& $EFF/owner.txt" "echo y 1<> $EFF/owner.txt" "echo y >| $EFF/owner.txt" "echo y | tee $EFF/owne{r,r}.txt"
         "echo y | tee \$'$EFF/owner.\\x74xt'" "cp $T/effsrc $EFF/ow?er.txt" "x=$EFF/owner.txt; echo y > \"\$x\"" "echo ok${NL}cp $T/effsrc $EFF/owner.txt")
EFR=$EFF/repo; git init -q "$EFR"; printf 'base\n' >"$EFR/f.txt"; git -C "$EFR" add f.txt; git -C "$EFR" -c user.name=t -c user.email=t@t commit -qm base; printf 'dirty\n' >"$EFR/f.txt"
gitcmds=("git -C $EFR checkout -- ." "git -C $EFR reset --hard" "git -C $EFR stash" "git -C $EFR restore .")   # git working-tree writers: the dirty file must survive
ctl="echo ctl | tee $T/effctl"; ran=0; ctlran=0
while read -r lab role; do
  setw "$lab"
  for c in "${effcmds[@]}" "$ctl"; do
    pay=$(pl terminal "$(js --arg c "$c" '{command: $c}')"); allowed=1
    for h in $(hooks_for "$MT" "$role" terminal); do [ "$(hk "$(hf "$h")" "$pay")" = 0 ] || allowed=0; done
    if [ $allowed = 1 ]; then (cd /workspace && bash -c "$c" >/dev/null 2>&1); [ "$c" = "$ctl" ] && ctlran=$((ctlran+1)) || ran=$((ran+1)); fi
    if [ "$c" = "$ctl" ]; then continue; fi
    say "$([ "$(sha256sum <"$EFF/owner.txt")" = "$EFH" ]; echo $?)" "3c $lab/$role: the owner data file is unchanged after: ${c//$NL/<NL>} (hooks $([ $allowed = 1 ] && echo allowed || echo refused))"
    printf 'orig\n' >"$EFF/owner.txt"
  done
done < <(pairs)
while read -r lab role; do
  setw "$lab"
  for c in "${gitcmds[@]}"; do
    pay=$(pl terminal "$(js --arg c "$c" '{command: $c}')"); allowed=1
    for h in $(hooks_for "$MT" "$role" terminal); do [ "$(hk "$(hf "$h")" "$pay")" = 0 ] || allowed=0; done
    [ $allowed = 1 ] && (cd /workspace && bash -c "$c" >/dev/null 2>&1)
    say "$([ "$(cat "$EFR/f.txt")" = dirty ]; echo $?)" "3c $lab/$role: the working tree of a repo in the main checkout is unchanged after: $c (hooks $([ $allowed = 1 ] && echo allowed || echo refused))"
    printf 'dirty\n' >"$EFR/f.txt"
  done
done < <(pairs)
say "$([ "$ctlran" -gt 0 ] && [ -s "$T/effctl" ]; echo $?)" "3c control: an allowed command really runs here and changes its own file ($ctlran roles let it through; $ran effect commands were let through and left the owner file alone)"
MT=$SRC; export ROLES_FILE=$SRC

# RT7-02: a MEDIA:/path tag in a gateway reply uploads a file with no tool call (no hook sees it); every role that talks on
# Discord gets strict delivery (Hermes caches, allow-listed dirs only; no recent-file trust), set by apply from this table
say "$(jq -e '[.roles[] | select(.platform_toolsets.discord) | .config["gateway.strict"] == true and .config["gateway.trust_recent_files"] == false] | length > 0 and all' "$SRC" >/dev/null; echo $?)" "3 every role with a Discord toolset has gateway.strict true and gateway.trust_recent_files false (RT7-02)"

# 4 fail closed: a table the guards cannot read refuses ordinary reads as well
MT=$T/probe.json
printf 'not json' >"$T/garbage.json"
jq 'del(.owner_settings)' "$SRC" >"$T/none.json"
tbl "$T/empty.json" '[]'; tbl "$T/dotdot.json" '["../etc/zz"]'; tbl "$T/abs.json" '["/etc/zz"]'; tbl "$T/str.json" '"config/zz"'; tbl "$T/mixed.json" '["config/ok", 7]'
# F1 W4: the three owner-write lists are part of the table: without one, with it empty, or with a bad entry, every role refuses everything
jq 'del(.owner_data)' "$SRC" >"$T/nod.json"; jq 'del(.owner_commands)' "$SRC" >"$T/noc.json"; jq 'del(.worker_markers)' "$SRC" >"$T/nom.json"
jq '.data_index = ".stella/zz-missing-index.json"' "$SRC" >"$T/noidx.json"; jq '.owner_data = []' "$SRC" >"$T/emd.json"; jq '.owner_commands = [""]' "$SRC" >"$T/emc.json"; jq '.worker_markers = ["a b"]' "$SRC" >"$T/bmk.json"
for bad in "$T/missing.json" "$T/garbage.json" "$T/none.json" "$T/empty.json" "$T/dotdot.json" "$T/abs.json" "$T/str.json" "$T/mixed.json" \
           "$T/nod.json" "$T/noc.json" "$T/nom.json" "$T/emd.json" "$T/emc.json" "$T/bmk.json" "$T/noidx.json"; do
  export ROLES_FILE=$bad
  while read -r lab role; do
    setw "$lab"
    refuse "4 $(basename "$bad") $lab/$role" "$role" read_file '{"path": "/workspace/SUPERVISOR.md"}' "ordinary file (fail closed)"
    refuse "4 $(basename "$bad") $lab/$role" "$role" terminal '{"command": "ls"}' "ls (fail closed)"
  done < <(pairs)
done
export ROLES_FILE=$T/probe.json

# 5 real path: a fake worker bound to a running card on a stub board; the hook runs below it, from its main thread and from a second thread
mkdir -p "$T/bin" "$T/cards"
export PATH="$T/bin:$PATH" FAKE_CARDS=$T/cards
FAKE_BOARD=$(sed -n 's/^KANBAN_BOARD=\([A-Za-z0-9_-]*\).*/\1/p' /workspace/bin/kanban-board.sh | head -1); export FAKE_BOARD   # the stack's one board
EXPECT_HOME=$(getent passwd "$(id -u)" | cut -d: -f6)/.hermes; export EXPECT_HOME
sleep 600 & STR=$!
cat >"$T/bin/hermes" <<'SH'
#!/usr/bin/env bash
# stub: refuses `send`; `kanban --board $FAKE_BOARD show <id>` and `list [--assignee <p>] --status running` answer from $FAKE_CARDS.
[ "${1:-}" = send ] && { echo "owner-settings-selftest: hermes send refused" >&2; exit 1; }
[ "$1" = kanban ] || exit 1
b=$3; shift 3
[ "$b" = "$FAKE_BOARD" ] || { echo "board $b not found" >&2; exit 1; }
root=${HERMES_KANBAN_HOME:-${HERMES_HOME:-$EXPECT_HOME}}; [ "$root" = "$EXPECT_HOME" ] || { [ "$1" = list ] && echo "[]" && exit 0; exit 1; }
case "$1" in
  show) exec cat "$FAKE_CARDS/$(printf '%s' "$2" | tr -c 'A-Za-z0-9_' '_').json" ;;
  list) a=; [ "$2" = --assignee ] && a=$3
        cat "$FAKE_CARDS"/*.json 2>/dev/null | jq -sc --arg a "$a" '[.[] | select(.task.status == "running" and ($a == "" or .task.assignee == $a)) | {id: .task.id}]' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/hermes"
printf '%s\n' 'import subprocess, sys' 'sys.exit(subprocess.call(sys.argv[2:], stdin=open(sys.argv[1], "rb")))' >"$T/runner.py"
cat >"$T/worker.py" <<'PY'
import os, subprocess, sys, threading, time
d, mode, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
with open(f"{d}/pid", "w") as f:
    f.write(str(os.getpid()))
while not os.path.exists(f"{d}/go"):
    time.sleep(0.02)
def run():
    with open(f"{d}/out", "wb") as out:
        rc = subprocess.call(["sh", "-c", '"$@"', "sh", *cmd], stdout=out, stderr=subprocess.STDOUT)
    with open(f"{d}/rc", "w") as f:
        f.write(str(rc))
if mode == "thread":
    th = threading.Thread(target=run); th.start(); th.join()
else:
    run()
PY
fp() { echo "$(cat /proc/sys/kernel/random/boot_id):$(sed 's/.*) //' /proc/1/stat | awk '{print $20}')|$(sed 's/.*) //' /proc/$1/stat | awk '{print $20}')"; }
mk() {  # mk <card> <assignee> <workspace> <branch> <worker pid>: the card on the stub board, running, its open run bound to the worker
  jq -nc --arg id "$1" --arg a "$2" --arg ws "$3" --arg br "$4" --argjson pid "$5" --arg sig "$(fp "$5")" \
    '{task: {id: $id, assignee: $a, status: "running", workspace_path: $ws, branch_name: $br}, runs: [{id: 7, ended_at: null}],
      events: [{kind: "claimed", run_id: 7, payload: {lock: "host:1"}},
        {kind: "worker_bound", run_id: 7, payload: {pid: $pid, claim_lock: "host:1", started_at: $sig}}]}' \
    >"$FAKE_CARDS/$(printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_').json"
}
bound() {  # bound <main|thread> <payload> <cmd...>: <cmd> (@P = the payload file) below the bound worker; prints its exit code, output in $T/bout
  local m=$1 pl=$2 d w x; shift 2; d=$(mktemp -d -p "$T"); local cmd=()
  printf '%s' "$pl" >"$d/payload"; rm -f "$FAKE_CARDS"/*.json
  for x; do cmd+=("${x//@P/"$d/payload"}"); done
  python3 "$T/worker.py" "$d" "$m" "${cmd[@]}" </dev/null & w=$!
  for _ in $(seq 200); do [ -s "$d/pid" ] && break; sleep 0.02; done
  mk "$C" "$BP" "$WS" "$BRA" "$(cat "$d/pid")"
  touch "$d/go"; wait "$w"; cp -f "$d/out" "$T/bout" 2>/dev/null || : >"$T/bout"; cat "$d/rc" 2>/dev/null || echo missing
}
SEC=5
FENCE=$T/fenced   # the marker Hermes puts in every process a worker spawns
bhook() {  # bhook <mode> <script> <payload>: the hook two levels below the worker, as a tool call's hook runs
  bound "$1" "$3" python3 "$T/runner.py" @P env "HERMES_KANBAN_WORKSPACE=$WS" "HERMES_DELEGATED_CHILD_CONTEXT=$FENCE" "$2"
}
# brefuse / ballow <mode> <tool> <input> <description>: the builder-like role's hooks for <tool>, below the bound worker
brefuse() {
  local CURW=; local h by="" pay; pay=$(jq -nc --arg t "$2" --argjson i "$3" --arg c "$WS" --arg p "$BP" '{tool_name: $t, tool_input: $i, session_id: "s1", cwd: $c, profile: $p, extra: {}}')
  for h in $(hooks_for "$MT" "$BR" "$2"); do [ "$(bhook "$1" "$(hf "$h")" "$pay")" = 2 ] && by="$by $(basename "$h")"; done
  say "$([ -n "$by" ]; echo $?)" "$SEC $1 $BP: $2 $4: refused by${by:- (none)}"
}
ballow() {
  local CURW=; local h bad="" pay; pay=$(jq -nc --arg t "$2" --argjson i "$3" --arg c "$WS" --arg p "$BP" '{tool_name: $t, tool_input: $i, session_id: "s1", cwd: $c, profile: $p, extra: {}}')
  for h in $(hooks_for "$MT" "$BR" "$2"); do [ "$(bhook "$1" "$(hf "$h")" "$pay")" = 0 ] || bad="$bad $(basename "$h")"; done
  say "$([ -z "$bad" ]; echo $?)" "$SEC $1 $BP: $2 $4: allowed${bad:+ (refused by$bad)}"
}
MT=$T/probe.json; export ROLES_FILE=$MT
BP=$(jq -r '.roles as $r | .profiles | to_entries[] | select($r[.value.role].workspace == "git-worktree") | .key' "$MT" | head -1)
[ -n "$BP" ] || { echo "FAIL no git-worktree profile in the table"; echo "selftest FAIL (1)"; exit 1; }
BR=$(jq -r --arg p "$BP" '.profiles[$p].role' "$MT")
C=t_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n'); WS=/workspace/.worktrees/$C; BRA=stella/$C-x
for m in main thread; do
  ballow $m write_file "$(js --arg p "$WS/a.md" '{path: $p, content: "x"}')" "in its own worktree (control: the proof works)"
  brefuse $m write_file "$(js --arg p "$POWN" '{path: $p, content: "x"}')" "owner file"
  brefuse $m patch "$(js --arg p "$POWN" '{mode: "replace", path: $p, old_string: "a", new_string: "b"}')" "owner file"
  brefuse $m terminal "$(js --arg c "echo x > $POWN" '{command: $c}')" "redirect into the owner file"
  brefuse $m terminal "$(js --arg c "cat $POWN" '{command: $c}')" "cat of the owner file"
  brefuse $m terminal "$(js --arg c "cp $POWN /tmp/x" '{command: $c}')" "cp of the owner file"
  brefuse $m read_file "$(js --arg p "$POWN" '{path: $p}')" "owner file"
  brefuse $m search_files "$(js --arg p "/workspace/config" '{pattern: "x", path: $p}')" "FOLDER of the owner file (content search)"
  brefuse $m vision_analyze "$(js --arg p "$POWN" '{image_url: $p, question: "x"}')" "owner file"
  brefuse $m skill_view "$(js --arg p "$POWN" '{name: "x", file_path: $p}')" "owner file"
  ballow $m read_file '{"path": "/workspace/SUPERVISOR.md"}' "ordinary file (control)"
  ballow $m terminal '{"command": "cat package.json"}' "ordinary command (control)"
  # F1 W4: owner data and owner commands, from the bound worker's main thread and from a delegated child (a second thread)
  while read -r d; do
    for tgt in "/workspace/$d/zz-probe.json" "$WS/$d/zz-probe.json"; do
      brefuse $m write_file "$(js --arg p "$tgt" '{path: $p, content: "x"}')" "owner data $tgt"
      brefuse $m patch "$(js --arg p "$tgt" '{mode: "replace", path: $p, old_string: "a", new_string: "b"}')" "owner data $tgt"
      for c in "echo x > $tgt" "git -C $WS add -f $tgt" "git commit -m x $tgt" "git checkout HEAD -- $tgt"; do
        brefuse $m terminal "$(js --arg c "$c" '{command: $c}')" "$c"
      done
    done
    ballow $m read_file "$(js --arg p "$WS/$d/zz-probe.json" '{path: $p}')" "reading owner data (control)"
    ballow $m terminal "$(js --arg c "cat $WS/$d/zz-probe.json" '{command: $c}')" "cat of owner data (control)"
  done < <(jq -r '.owner_data[]' "$MT")
  while read -r c; do
    for x in "bash /workspace/$c" "python3 -I $WS/$c x" "env X=1 $WS/$c"; do
      brefuse $m terminal "$(js --arg c "$x" '{command: $c}')" "owner command: $x"
    done
  done < <(jq -r '.owner_commands[]' "$MT")
  ballow $m terminal "$(js --arg c "echo x > $WS/zz-ok.txt" '{command: $c}')" "an ordinary write in its own worktree (control)"
  ballow $m write_file "$(js --arg p "$WS/docs-ok.md" '{path: $p, content: "x"}')" "an ordinary file in its own worktree (control)"
done

# 6 the pre-commit guard, in scratch repos; its list is read from the docs/hermes-local/roles.json beside its own bin/
mktree() {  # mktree <name> <table or ->: a copy of the guard at <name>/bin with its table (none when -)
  mkdir -p "$T/$1/bin" "$T/$1/docs/hermes-local" "$T/$1/.stella"; cp "$STACK/bin/commit-guard.sh" "$STACK/bin/roles.py" "$T/$1/bin/"; cp "$STACK/.stella/data-files.json" "$T/$1/.stella/"   # the guard reads the data index of its own tree (G1)
  [ "$2" = - ] || cp "$2" "$T/$1/docs/hermes-local/roles.json"
}
mktree tree "$T/probe.json"; mktree treebad "$T/garbage.json"; mktree treenone "$T/none.json"; mktree treegone -
export GIT_AUTHOR_NAME=owner GIT_AUTHOR_EMAIL=owner@example.invalid GIT_COMMITTER_NAME=owner GIT_COMMITTER_EMAIL=owner@example.invalid
git init -q -b main "$T/repo" && (cd "$T/repo" && echo a >a && git add a && git commit -q -m init && mkdir -p config sub/config)
echo x >"$T/repo/config/zz-owner-probe.env"; echo x >"$T/repo/sub/config/zz-owner-probe.env"; echo x >"$T/repo/config/zz-owner-probe.example.env"
cg() { (cd "$T/repo" && "$T/$1/bin/commit-guard.sh" >"$T/out" 2>&1; echo $?); }   # the guard on what is staged now
echo y >"$T/repo/b"; git -C "$T/repo" add b
say "$([ "$(cg tree)" = 0 ]; echo $?)" "6 an ordinary file staged: the commit is allowed"
for t in treebad treenone treegone; do
  say "$([ "$(cg $t)" = 1 ] && grep -qi "cannot be read" "$T/out"; echo $?)" "6 the owner list unreadable ($t), an ordinary file staged: refused (fail closed)"
done
git -C "$T/repo" add config/zz-owner-probe.env
say "$([ "$(cg tree)" = 1 ] && grep -qi "owner settings" "$T/out"; echo $?)" "6 the owner path staged with an ordinary file: refused, naming owner settings"
mkdir -p "$T/repo/zzzz"; for i in $(seq 1500); do : >"$T/repo/zzzz/$(printf 'f%060d' "$i")"; done; git -C "$T/repo" add zzzz
say "$([ "$(cg tree)" = 1 ] && grep -qi "owner settings" "$T/out"; echo $?)" "6 the owner path staged before 1500 more files (over 64 KB of names): refused, no SIGPIPE fail-open (RT7-05)"
git -C "$T/repo" rm -rq --cached zzzz; git -C "$T/repo" reset -q config/zz-owner-probe.env
mkdir -p "$T/repo/CONFIG"; echo x >"$T/repo/CONFIG/zz-owner-probe.env"; git -C "$T/repo" add CONFIG/zz-owner-probe.env
say "$([ "$(cg tree)" = 1 ] && grep -qi "owner settings" "$T/out"; echo $?)" "6 the owner path staged upper-cased (the same file on the case-insensitive /workspace): refused (B2V-01)"
git -C "$T/repo" reset -q CONFIG/zz-owner-probe.env
# F1 W4: owner_data is committed by the owner and refused only for a worker (below): with no worker proof the guard lets it through
OD=$(jq -r '.owner_data[0]' "$T/probe.json"); mkdir -p "$T/repo/$OD"; echo x >"$T/repo/$OD/zz-w4.json"; git -C "$T/repo" add -f "$OD/zz-w4.json"
say "$([ "$(cg tree)" = 0 ]; echo $?)" "6 owner data staged by the owner (no worker proof, no marker): allowed (the owner and the build commit it)"
git -C "$T/repo" reset -q "$OD/zz-w4.json"; git -C "$T/repo" rm -q --cached -f b
git -C "$T/repo" add sub/config/zz-owner-probe.env config/zz-owner-probe.example.env
say "$([ "$(cg tree)" = 0 ]; echo $?)" "6 same file name in another folder, and the owner example file: allowed (the exact path decides)"
# a real commit by the bound worker, in its card worktree on its card branch, the hook installed as the repo's pre-commit
K=$T/k6; WA=$K/wa
git init -q -b main "$K/main" && (cd "$K/main" && echo a >a && git add a && git commit -q -m init) \
  && git -C "$K/main" worktree add -q -b "$BRA" "$WA" && ln -s "$T/tree/bin/commit-guard.sh" "$K/main/.git/hooks/pre-commit"
mkdir -p "$WA/config"; WS=$WA
gc() {  # gc <mode> <file>: add and commit <file> in the card worktree as the worker's tool call
  bound "$1" '{}' env "HERMES_KANBAN_WORKSPACE=$WA" "HERMES_DELEGATED_CHILD_CONTEXT=$FENCE" \
    sh -c 'cd "$1" && mkdir -p "$(dirname "$2")" && echo x >"$2" && git add -f -- "$2" && git commit -q -m "$2"' sh "$WA" "$2"
}
for m in main thread; do
  N0=$(git -C "$WA" rev-list --count HEAD)
  say "$([ "$(gc $m ok-$m.txt)" = 0 ] && [ "$(git -C "$WA" rev-list --count HEAD)" = $((N0+1)) ]; echo $?)" "6 $m: the bound worker's ordinary commit in its card worktree is allowed (control: the proof works)"
  N0=$(git -C "$WA" rev-list --count HEAD)
  say "$([ "$(gc $m $PROBE)" != 0 ] && grep -qi "owner settings" "$T/bout" && [ "$(git -C "$WA" rev-list --count HEAD)" = "$N0" ]; echo $?)" "6 $m: the bound worker's commit staging the owner path: refused by the owner list, no commit made"
  git -C "$WA" reset -q --hard; git -C "$WA" clean -qfd   # the refused commit above left its file staged
  N0=$(git -C "$WA" rev-list --count HEAD)
  say "$([ "$(gc $m "$OD/zz-w4-$m.json")" != 0 ] && grep -qi "owner data" "$T/bout" && [ "$(git -C "$WA" rev-list --count HEAD)" = "$N0" ]; echo $?)" "6 $m: the bound worker's commit staging owner data ($OD): refused as owner data, no commit made"
  git -C "$WA" reset -q --hard; git -C "$WA" clean -qfd
done
# F1 W4: the worker markers come from the table: a marked commit nothing proves is refused, whatever the marker's name
jq '.worker_markers += ["ZZ_W4_MARK"]' "$T/probe.json" >"$T/marks.json"; mktree treemark "$T/marks.json"
mktree treenom "$T/nom.json"; mktree treeemd "$T/emd.json"; mktree treebmk "$T/bmk.json"
echo y >"$T/repo/c"; git -C "$T/repo" add c
say "$([ "$(cd "$T/repo" && ZZ_W4_MARK=1 "$T/treemark/bin/commit-guard.sh" >"$T/out" 2>&1; echo $?)" = 1 ] && grep -qi "cannot be proven" "$T/out"; echo $?)" "6 a marker variable that only the table names (ZZ_W4_MARK) marks a worker: the unproven commit is refused"
say "$([ "$(cd "$T/repo" && ZZ_W4_MARK=1 "$T/tree/bin/commit-guard.sh" >"$T/out" 2>&1; echo $?)" = 0 ]; echo $?)" "6 the same variable is no marker in a table that does not list it (control)"
for t in treenom treeemd treebmk; do
  say "$([ "$(cg $t)" = 1 ] && grep -qi "cannot be read" "$T/out"; echo $?)" "6 the worker marker or owner data list unreadable ($t): refused (fail closed)"
done
git -C "$T/repo" reset -q c
rm -f "$K/main/.git/hooks/pre-commit"


# 7 RT6-01: the write guard in a project repo bound to the board, outside /workspace
PR=$T/proj; OT=$T/other; mkdir -p "$PR" "$OT"; git init -q -b main "$PR"
export PROJECTS_DB=$T/projects.db
python3 - "$PROJECTS_DB" "$FAKE_BOARD" "$PR" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("create table projects (id integer primary key, slug text, primary_path text, board_slug text, archived integer)")
c.execute("insert into projects values (1, 'scratch', ?, ?, 0)", (sys.argv[3], sys.argv[2]))
c.commit()
PY
SEC=7; C=t_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n'); WS=$PR/.worktrees/$C; BRA=stella/$C-x; SIB=$PR/.worktrees/t_0000beef
for m in main thread; do
  ballow $m write_file "$(js --arg p "$WS/a.md" '{path: $p, content: "x"}')" "into its own worktree $PR/.worktrees/<card> (control)"
  ballow $m write_file "$(js --arg p "$OT/a.md" '{path: $p, content: "x"}')" "into a folder in no bound repo (control)"
  for tgt in "$PR/a.md" "$SIB/a.md" "$PR/.git/config"; do
    brefuse $m write_file "$(js --arg p "$tgt" '{path: $p, content: "x"}')" "to ${tgt#$PR/} of the project repo"
    brefuse $m patch "$(js --arg p "$tgt" '{mode: "replace", path: $p, old_string: "a", new_string: "b"}')" "to ${tgt#$PR/} of the project repo"
    for c in "echo x > $tgt" "echo x >> $tgt" "cp /tmp/x $tgt" "tee $tgt" "sed -i s/a/b/ $tgt"; do
      brefuse $m terminal "$(js --arg c "$c" '{command: $c}')" "$c"
    done
  done
  ballow $m terminal "$(js --arg c "echo x > $WS/a.md" '{command: $c}')" "echo x > its own worktree file (control)"
  ballow $m terminal "$(js --arg c "echo x > $OT/a.md" '{command: $c}')" "echo x > a folder in no bound repo (control)"
done
export PROJECTS_DB=$T/missing.db   # unreadable: anything outside /tmp counts as inside a repo
for m in main thread; do
  brefuse $m write_file "$(js --arg p "$HOME/zz-k6-probe.txt" '{path: $p, content: "x"}')" "to the home folder (projects.db unreadable, fail closed)"
  brefuse $m terminal "$(js --arg c "echo x > $HOME/zz-k6-probe.txt" '{command: $c}')" "echo x > the home folder (projects.db unreadable, fail closed)"
  ballow $m write_file "$(js --arg p "$OT/a.md" '{path: $p, content: "x"}')" "under /tmp (projects.db unreadable, control)"
done

[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
