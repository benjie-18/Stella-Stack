#!/usr/bin/env bash
# Option A (OS box) self-test. Layers: 1 roles.py sandbox validator and spec; 2 box.py mount list; 3 the real bwrap box on
# scratch trees (git-route attacks fail inside, succeed outside); 4 the terminal plugin (provider flags, env, refusals).
# The `sandbox` block of roles.json is data: profile names come from the table, never from this file's logic.
# Not part of `npm test` (the suite is not changed by this build); run as: flock .scratch/readiness/test.lock bin/box-selftest.sh
set -u
T=$(mktemp -d); trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
W=/workspace; S=${STAGE:-/workspace/bin}   # roles.py under test (a staged copy while it is being replaced)
RF=${ROLES_FILE:-$W/docs/hermes-local/roles.json}
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/out" ] && sed 's/^/     /' "$T/out" | tail -4; fi; }
# a worker profile (git-worktree role) and a read-only reviewing one, from the table
P=$(jq -r '. as $d | .profiles | to_entries[] | select($d.roles[.value.role].workspace == "git-worktree") | .key' "$RF" | head -1)
R=$(jq -r '. as $d | .profiles | to_entries[] | select($d.roles[.value.role].workspace == "read-parent-worktree") | .key' "$RF" | head -1)
SB='{"schema_version":1,"backend":"os_box","unboxed_backend":"local","boxed_profiles":[$p],"plugin_dir":"docs/hermes-local/plugins/os-box",
 "tmp_dir":"{profile_dir}/box-tmp","home_ro":[".local/bin",".local/share/uv"],"home_protect":[".local/bin/",".local/lib/",".bash_profile",".bashrc",".gitconfig",".config/git/",".jq"],"hide":[".scratch"],"sibling_dirs":[".worktrees"],
 "canary":"boxcanary/canary.txt","env":{"LC_ALL":"C.UTF-8"},"profile_overrides":{($p):{"claude_config_dir":"{home}/.claude","ro_over":["settings.json","hooks"]}}}'
mkrf() { jq --arg p "$P" --arg r "$R" "$1" "$RF" >"$T/roles.json"; }   # scratch table: the real one with a sandbox edit
val() { ROLES_FILE=$T/roles.json python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import roles
try: d = roles.load(); print("VALID")
except roles.RolesError as e: print("INVALID", e)' "$S"; }

# ---- 1. validator
mkrf ".sandbox = $SB"
ok '[ "$(val)" = VALID ]' "1.1 a complete sandbox block is valid"
mkrf 'del(.sandbox)'
ok '[ "$(val)" = VALID ]' "1.2 no sandbox block is valid (boxed profiles are refused at run time, not here)"
bad() { mkrf ".sandbox = $SB | $1"; val >"$T/out"; grep -q "^INVALID.*$2" "$T/out"; }
ok 'bad "del(.sandbox.schema_version)" schema_version' "1.3 missing schema_version"
ok 'bad ".sandbox.schema_version = 2" schema_version' "1.4 unknown schema_version"
ok 'mkrf ".sandbox = $SB | .sandbox.boxed_profiles = [\"nope\"]"; [ "$(val)" = VALID ] && ROLES_FILE=$T/roles.json python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import roles; g = roles.coverage(roles.load(), sys.argv[2]); print(g)" "$S" "$T/nohome" | grep -q "boxed_profiles.*nope"' "1.5 a boxed profile not in the table: the table still loads (other guards and a profile rename are not affected), roles.py check reports a coverage gap"
ok 'bad ".sandbox.boxed_profiles = \"x\"" boxed_profiles' "1.6 boxed_profiles not a list"
ok 'bad ".sandbox.tmp_dir = \"/tmp/x\"" tmp_dir' "1.7 tmp_dir without {profile_dir}"
ok 'bad ".sandbox.tmp_dir = \"{profile_dir}/../x\"" tmp_dir' "1.8 tmp_dir with .."
ok 'bad ".sandbox.home_ro = [\"/etc\"]" home_ro' "1.9 absolute home_ro entry"
ok 'bad ".sandbox.home_ro = [\"a/../b\"]" home_ro' "1.10 home_ro entry with .."
ok 'bad ".sandbox.hide = [\"/x\"]" hide' "1.11 absolute hide entry"
ok 'bad ".sandbox.canary = \"/abs/c\"" canary' "1.12 absolute canary"
ok 'bad ".sandbox.canary = \"\"" canary' "1.13 empty canary"
ok 'bad ".sandbox.profile_overrides = {\"nope\":{}}" profile_overrides' "1.14 override for a profile not in the table"
ok 'bad ".sandbox.profile_overrides[\$p].ro_over = [\"a/b\"]" ro_over' "1.15 ro_over entry with a slash"
ok 'bad ".sandbox.profile_overrides[\$p].claude_config_dir = \"/x\"" claude_config_dir' "1.16 claude_config_dir without {home}"
ok 'bad ".sandbox.backend = \"Bad-Name\"" backend' "1.17 backend not [a-z0-9_]+"
ok 'bad ".sandbox.backend = \"local\"" backend' "1.18 backend equal to the unboxed backend"
ok 'bad ".sandbox.sibling_dirs = [\"a/b\"]" sibling_dirs' "1.19 sibling_dirs entry with a slash"
ok 'bad ".sandbox.plugin_dir = \"../x\"" plugin_dir' "1.20 plugin_dir with .."

ok 'bad ".sandbox.env = [\"LC_ALL\"]" env' "1.27 env must be an object"
ok 'bad ".sandbox.env = {\"lc all\": \"x\"}" env' "1.28 env names must be upper-case identifiers"
ok 'bad ".sandbox.env = {\"LC_ALL\": 1}" env' "1.29 env values must be strings"
ok 'bad ".sandbox.env = {\"HOME\": \"/x\"}" env' "1.30 env cannot set a variable the box owns (HOME)"
ok 'bad ".sandbox.tmp_dir = \"{profile_dir}/./x\"" tmp_dir' "1.31 a . segment in tmp_dir (it would alias another folder)"
ok 'bad ".sandbox.home_ro = [\".\"]" home_ro' "1.32 home_ro entry \".\" (binds the whole home)"
ok 'bad ".sandbox.home_ro = [\"./.claude\"]" home_ro' "1.33 home_ro entry with a . segment (defeats the secret-class check)"
ok 'bad ".sandbox.hide = [\"./.scratch\"]" hide' "1.34 hide entry with a . segment (it would hide nothing)"
ok 'bad ".sandbox.env = {\"LD_PRELOAD\": \"/x\"}" env' "1.35 env cannot set the dynamic loader (LD_PRELOAD)"
ok 'bad ".sandbox.env = {\"PATH\": \"/x\"}" env' "1.36 env cannot set PATH"
ok 'bad ".sandbox.home_protect = [\"a/../b\"]" home_protect' "1.37 home_protect entry with .."
# ---- 1b. spec(): what register-toolsets applies per profile
mkrf ".sandbox = $SB"
spec() { ROLES_FILE=$T/roles.json python3 "$S/roles.py" spec "$HOME/.hermes" 2>/dev/null; }
ok '[ "$(spec | jq -r --arg p "$P" ".[\$p].config[\"terminal.backend\"]")" = os_box ]' "1.21 a boxed profile gets terminal.backend from the block"
ok '[ "$(spec | jq -r --arg p "$P" ".[\$p].config[\"plugins.isolation\"]")" = in_process ]' "1.22 a boxed profile is pinned to in_process isolation"
ok '[ "$(spec | jq -r --arg r "$R" ".[\$r].config[\"terminal.backend\"]")" = local ]' "1.23 an unboxed profile is pinned to the unboxed backend (rollback)"
ok 'spec | jq -e --arg p "$P" ".[\$p].hook_files | keys | map(select(endswith(\"/plugins/os-box/__init__.py\"))) | length == 1" >/dev/null' "1.24 a boxed profile gets the plugin files"
ok '[ "$(spec | jq -r --arg r "$R" ".[\$r].hook_files | keys | map(select(test(\"/plugins/\"))) | length")" = 0 ]' "1.25 an unboxed profile gets no plugin files"
ok '[ "$(spec | jq -r --arg p "$P" ".[\$p].plugin_enable")" = os-box ]' "1.26 a boxed profile gets the plugin enabled"


# ---- 2. box.py: the mount list, on scratch trees (the real tree is checked in 3.x with the real bwrap)
F=$T/f; mkdir -p "$F/ws/bin" "$F/ws/docs" "$F/ws/config" "$F/ws/boxcanary" "$F/ws/.scratch/proj" "$F/home/.claude" "$F/home/.local/bin" "$F/home/.local/share/uv"
H2=$F/home/.hermes; mkdir -p "$H2/hermes-agent" "$H2/profiles/$P/home" "$H2/profiles/$P/skills" "$H2/profiles/$R/home" "$H2/profiles/$R/skills"
echo x >"$F/ws/bin/a"; echo x >"$F/ws/docs/b"; echo S >"$F/ws/config/owner.env"; echo S >"$F/ws/config/Owner.Env"; echo e >"$F/ws/config/owner.example.env"
echo c >"$F/ws/boxcanary/canary.txt"; echo S >"$F/ws/.env"; echo ok >"$F/ws/.env.example"; echo S >"$F/ws/id.pem"; echo S >"$F/ws/x.key"
echo h >"$F/ws/.scratch/hidden"; echo k >"$F/home/.claude/.credentials.json"; echo s >"$F/ws/CaSe"
ln -s "$F/ws/config/owner.env" "$F/ws/via-link"; ln -s /etc "$F/ws/out-link"; ln -s "$F/ws/bin" "$F/ws/in-link"
G="git -c user.name=t -c user.email=t@t -c init.defaultBranch=main"
$G -C "$F/ws" init -q && echo r >"$F/ws/README" && $G -C "$F/ws" add README && $G -C "$F/ws" commit -qm r
$G -C "$F/ws" worktree add -q "$F/ws/.worktrees/card1" -b card/x; $G -C "$F/ws" worktree add -q "$F/ws/.worktrees/sib1" -b card/s
$G -C "$F/ws/.scratch/proj" init -q && echo r >"$F/ws/.scratch/proj/README" && $G -C "$F/ws/.scratch/proj" add README && $G -C "$F/ws/.scratch/proj" commit -qm r
$G -C "$F/ws/.scratch/proj" worktree add -q "$F/ws/.scratch/proj/.worktrees/card2" -b card/y
mkrf ".sandbox = $SB | .sandbox.boxed_profiles += [\$r]"
cat >"$T/plan.py" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[1]); import roles, box
F, prof, ws, br = sys.argv[2:6]
d = roles.load()
try:
    m, env = box.plan(d, prof, {"card": "t_1", "workspace": ws, "branch": br}, hermes_root=F + "/home/.hermes", home=F + "/home",
                      roots=([] if os.environ.get("ROOTS") == "none" else [F + "/ws", F + "/ws/.scratch/proj"]), stack_root=F + "/ws")   # the board lists the project repo; VH-01 refuses any other git folder
except box.BoxError as e:
    print("REFUSED", e); sys.exit(0)
for x in m: print(*x)
print("ENV", json.dumps(env, sort_keys=True))
PY
pl() { ROLES_FILE=$T/roles.json python3 "$T/plan.py" "$S" "$F" "$@" >"$T/plan.txt" 2>"$T/out"; }
has() { grep -qxF -- "$1" "$T/plan.txt"; }
hasre() { grep -qE -- "$1" "$T/plan.txt"; }
WT=$(realpath "$F/ws/.worktrees/card1"); WS=$(realpath "$F/ws")
pl "$P" "$WT" card/x
ok 'has "tmpfs $WS"' "2.1 the project root is a tmpfs, children bound one by one"
ok 'has "ro $WS/bin $WS/bin" && has "ro $WS/docs $WS/docs"' "2.2 ordinary children are bound read-only"
ok '! hasre "owner.env"' "2.3 no mount names the owner file (the parent folder is a tmpfs, the child dropped)"
ok 'has "tmpfs $WS/config" && has "ro $WS/config/owner.example.env $WS/config/owner.example.env"' "2.4 the owner folder is a tmpfs parent, its other children are bound"
ok '! hasre "Owner.Env"' "2.5 a case variant of the owner file name is dropped"
ok '! hasre "boxcanary/canary.txt"' "2.6 the canary is dropped"
ok '! hasre " $WS/(\.env|id\.pem|x\.key)$"' "2.7 .env, *.pem, *.key children are dropped"
ok 'has "ro $WS/.env.example $WS/.env.example"' "2.8 .env.example stays (SECRET_OK)"
ok '! hasre "via-link" && ! hasre "out-link"' "2.9 a symlink to the owner file or out of the root is dropped"
ok 'has "ro $WS/bin $WS/in-link"' "2.10 a symlink inside the root is bound by its resolved target"
ok '! hasre "\.scratch"' "2.11 nothing of .scratch is mounted for a card outside it"
ok '! hasre "sib1"' "2.12 a sibling worktree is not bound"
ok 'has "rw $WT $WT"' "2.13 a worker role gets its card worktree read-write at the real path"
G1=$(sed -n 's/^gitdir: //p' "$WT/.git"); ID=$(basename "$G1"); CD=$(realpath "$F/ws/.git")
ok 'has "ro $CD $CD"' "2.14 the repo git dir is read-only"
ok 'has "rw $CD/objects $CD/objects" && has "rw $CD/worktrees/$ID $CD/worktrees/$ID"' "2.15 objects and the worktree id folder are writable"
ok 'hasre "^rw [^ ]*/box-tmp\.refs/[0-9a-f]+/refs $CD/refs/heads/card$" && hasre "^rw [^ ]*/box-tmp\.refs/[0-9a-f]+/logs $CD/logs/refs/heads/card$" && ! has "rw $CD/refs/heads/card $CD/refs/heads/card" && ! has "rw $CD/logs/refs/heads/card $CD/logs/refs/heads/card"' "2.16 HH-05: the branch folder of refs and logs is a private view, not the shared folder (replaces the shared rw bind)"
ok '! hasre "rw .*refs/heads/main" && ! hasre "^rw $CD/refs/heads $"' "2.17 refs/heads/main and refs/heads itself are not writable"
ok 'has "ro $WT/.git $WT/.git" && has "ro $CD/worktrees/$ID/commondir $CD/worktrees/$ID/commondir" && has "ro $CD/worktrees/$ID/gitdir $CD/worktrees/$ID/gitdir"' "2.18 the worktree .git file, commondir and gitdir are read-only over the writable binds"
ok '[ "$(grep -n "^rw $CD/worktrees/$ID " "$T/plan.txt" | cut -d: -f1)" -lt "$(grep -n "^ro $CD/worktrees/$ID/commondir" "$T/plan.txt" | cut -d: -f1)" ]' "2.19 the read-only overlays come after the writable binds"
ok '[ "$(grep -c "^remount_ro " "$T/plan.txt")" -ge 2 ] && grep -q "^remount_ro $WS$" "$T/plan.txt"' "2.20 every tmpfs parent is remounted read-only after its binds"
ok '[ "$(grep -n "^remount_ro $WS$" "$T/plan.txt" | cut -d: -f1)" -gt "$(grep -n "^ro .* $WS/" "$T/plan.txt" | tail -1 | cut -d: -f1)" ]' "2.21 the remount comes after the binds"
ok 'has "tmpfs $F/home" && has "ro $F/home/.local/bin $F/home/.local/bin" && ! hasre " $F/home/\.claude"' "2.22 the real home is a tmpfs with only home_ro bound; the owner Claude folder is absent"
PH=$H2/profiles/$P
ok 'has "tmpfs $H2" && has "rw $PH/home $PH/home" && has "ro $PH/skills $PH/skills" && has "rw $PH/box-tmp $PH/box-tmp"' "2.23 ~/.hermes is a tmpfs; only the profile home, skills and tmp_dir are bound"
ok '! hasre "profiles/$R/"' "2.24 another profile is not bound"
ok 'grep -q "^ENV " "$T/plan.txt" && grep "^ENV " "$T/plan.txt" | sed "s/^ENV //" | jq -e --arg h "$PH/home" --arg w "$WT" ".HOME == \$h and .TMPDIR == \"/tmp\" and .HERMES_KANBAN_WORKSPACE == \$w and .HERMES_KANBAN_BRANCH == \"card/x\" and .CLAUDE_CONFIG_DIR == (\$h + \"/.claude\")" >/dev/null' "2.25 env: HOME, TMPDIR, the commit-guard markers, CLAUDE_CONFIG_DIR from the override"
ok 'grep "^ENV " "$T/plan.txt" | sed "s/^ENV //" | jq -e ".LC_ALL == \"C.UTF-8\"" >/dev/null' "2.38 env from the sandbox block reaches the plan"
ok 'has "ro $PH/home/.claude/settings.json $PH/home/.claude/settings.json" && has "ro $PH/home/.claude/hooks $PH/home/.claude/hooks" && [ -f "$PH/home/.claude/settings.json" ] && [ -d "$PH/home/.claude/hooks" ]' "2.26 ro_over entries are created outside the box and bound read-only"
ok '[ -d "$CD/logs/refs/heads/card" ]' "2.27 the branch reflog folder is created outside the box"
pl "$P" "$WT" main;       ok 'grep -q "^REFUSED.*branch" "$T/plan.txt"' "2.28 a branch without a folder part is refused"
pl "$P" "$WS" card/x;     ok 'grep -q "^REFUSED" "$T/plan.txt"' "2.29 a card workspace equal to the project root is refused (it would re-expose the owner folder)"
pl "$P" "$F/ws/.worktrees/none" card/x; ok 'grep -q "^REFUSED" "$T/plan.txt"' "2.30 a workspace that is not a linked worktree is refused"
ln "$F/ws/boxcanary/canary.txt" "$F/hl" 2>/dev/null
pl "$P" "$WT" card/x;     ok 'grep -q "^REFUSED.*link" "$T/plan.txt"' "2.31 a hard-linked canary makes the plan refuse"
rm -f "$F/hl"
pl "$P" "$WT" "card/it's a ünï"; ok 'grep -q "^REFUSED" "$T/plan.txt" || hasre "^rw [^ ]*/box-tmp\.refs/[0-9a-f]+/refs $CD/refs/heads/card$"' "2.32 apostrophe, space and unicode in the branch cannot break the plan"
WT2=$(realpath "$F/ws/.scratch/proj/.worktrees/card2"); CD2=$(realpath "$F/ws/.scratch/proj/.git")
pl "$P" "$WT2" card/y
ok 'has "rw $WT2 $WT2" && has "ro $CD2 $CD2"' "2.33 a card in a separate repo under a hidden folder: worktree and git dir are bound at their real paths"
ok '! hasre "^(ro|rw) $WS/.scratch " && ! hasre "hidden"' "2.34 ...while the rest of the hidden folder stays unbound"
pl "$R" "$WT" card/x
ok 'has "ro $WT $WT" && has "ro $CD $CD" && ! hasre "^rw ($WT|$CD)"' "2.35 a read-only workspace role gets the worktree and the git dir read-only"
pl_home() { ROLES_FILE=$T/roles.json python3 - "$S" "$F" "$P" "$WT" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1]); import roles, box
F, prof, wt, home = sys.argv[2:6]
d = roles.load()
try:
    box.plan(d, prof, {"card": "t", "workspace": wt, "branch": "card/x"}, hermes_root=F + "/home/.hermes", home=home, roots=[F + "/ws"], stack_root=F + "/ws"); print("PLANNED")
except box.BoxError as e: print("REFUSED", e)
PY
}
ok 'pl_home "$PH/home" | grep -q "^REFUSED.*home"' "2.37 a \"real home\" that is the profile home (HOME inside a Hermes worker) is refused: its read-only remount would make the profile home read-only"
# V-A-01: the hide rules must not depend on the board's project list (a retired project, an unreadable board)
ROOTS=none pl "$P" "$WT" card/x
ok 'has "tmpfs $WS/config" && ! hasre "owner\.env|boxcanary/canary|\.scratch|sib1" && has "rw $WT $WT"' "2.39 with NO board project roots the stack repo is still walked: owner folder, canary, .scratch and sibling worktrees stay hidden"
unset ROOTS
cat >"$T/verify.py" <<'PY'
import sys
sys.path.insert(0, sys.argv[1]); import box
def refuses(m, hide, prot, musts=()):
    try: box.verify(m, hide, prot, list(musts)); return "no"
    except box.BoxError: return "yes"
print(refuses([("ro", "/x/ws", "/x/ws")], set(), {"/x/ws/config/owner.env"}),      # contains an owner file
      refuses([("ro", "/x/ws/.scratch", "/x/ws/.scratch")], {"/x/ws/.scratch"}, set()),   # is a hidden folder
      refuses([("ro", "/x/ws/.scratch/p/f", "/x/ws/.scratch/p/f")], {"/x/ws/.scratch"}, set()),   # inside a hidden folder, not a card folder
      refuses([("ro", "/x/ws/.scratch/p/f", "/x/ws/.scratch/p/f")], {"/x/ws/.scratch"}, set(), ["/x/ws/.scratch/p"]))   # inside, but a card folder
PY
ok '[ "$(python3 "$T/verify.py" "$S")" = "yes yes yes no" ]' "2.40 the pre-exec check refuses a bind that contains an owner path, is or lies in a hidden folder, and allows a card folder"
jq '.sandbox.home_ro += [".claude"]' "$T/roles.json" >"$T/roles2.json"
ROLES_FILE=$T/roles2.json python3 "$T/plan.py" "$S" "$F" "$P" "$WT" card/x >"$T/plan.txt" 2>"$T/out"
ok 'grep -q "^REFUSED.*home_ro" "$T/plan.txt"' "2.41 a home_ro entry that is, or holds, a secret class folder (.claude) is refused"
# round 2 (red team): back-pointer, protected home entries, read-only roles, symlinked ro_over
G3=$($G -C "$F/ws" rev-parse --git-common-dir); CDW=$(realpath "$F/ws/.git"); IDS=$(sed -n 's/^gitdir: //p' "$F/ws/.worktrees/sib1/.git")
cp "$F/ws/.worktrees/card1/.git" "$T/card1.git.orig"
printf 'gitdir: %s\n' "$IDS" >"$F/ws/.worktrees/card1/.git"     # a worker rewrote .GIT to point at a sibling's git dir
pl "$P" "$WT" card/x; ok 'grep -q "^REFUSED.*gitdir" "$T/plan.txt"' "2.42 a worktree whose .git points at a git dir that does not point back is refused (RT-A-02)"
cp "$T/card1.git.orig" "$F/ws/.worktrees/card1/.git"
pl "$P" "$WT" card/x
ok 'has "ro $PH/home/.local/bin $PH/home/.local/bin" && has "ro $PH/home/.local/lib $PH/home/.local/lib" && has "ro $PH/home/.bash_profile $PH/home/.bash_profile" && [ -d "$PH/home/.local/lib" ] && [ -f "$PH/home/.bashrc" ]' "2.43 home_protect entries (python user site, PATH dir, shell startup files) are created outside and bound read-only inside the profile home (RT-A-01)"
# RT-RTA-01/02: hooks (unboxed, HOME = this folder) run git and jq; both read config from HOME (git: trace2.* writes any file the owner can write; jq: ~/.jq defines functions)
ok 'jq -e "(.sandbox.home_protect | index(\".gitconfig\") != null and index(\".config/git/\") != null and index(\".jq\") != null)" "$RF" >/dev/null' "2.45 the real table protects ~/.gitconfig, ~/.config/git/ and ~/.jq in a worker's profile home"
ok 'has "ro $PH/home/.gitconfig $PH/home/.gitconfig" && has "ro $PH/home/.jq $PH/home/.jq" && has "ro $PH/home/.config/git $PH/home/.config/git" && [ -f "$PH/home/.jq" ] && [ -d "$PH/home/.config/git" ]' "2.46 the mount list binds them read-only (a missing one is created outside first)"
pl "$R" "$WT" card/x
ok 'has "ro $H2/profiles/$R/home $H2/profiles/$R/home" && ! has "rw $H2/profiles/$R/home $H2/profiles/$R/home" && grep "^ENV " "$T/plan.txt" | sed "s/^ENV //" | jq -e ".HOME == \"/tmp\"" >/dev/null' "2.44 a read-only workspace role gets its profile home read-only and a private HOME (RT-A-03)"
jq '.sandbox.profile_overrides[$p] = {claude_config_dir: "{home}/.claude-link", ro_over: ["settings.json"]}' --arg p "$P" "$T/roles.json" >"$T/roles3.json"
mkdir -p "$F/elsewhere"; ln -s "$F/elsewhere" "$PH/home/.claude-link"
ROLES_FILE=$T/roles3.json python3 "$T/plan.py" "$S" "$F" "$P" "$WT" card/x >"$T/plan.txt" 2>"$T/out"
ok 'grep -q "^REFUSED.*symlink" "$T/plan.txt" && [ ! -e "$F/elsewhere/settings.json" ]; r=$?; head -c 300 "$T/plan.txt" >"$T/out"; [ $r = 0 ]' "2.45 a symlinked Claude config folder is refused and nothing is created through it (RT-A-04)"
rm "$PH/home/.claude-link"
ok 'S1=$(python3 -c "import ast,sys; t=ast.parse(open(\"/workspace/docs/hermes-local/hooks/builder/secret-guard.py\").read()); print(len([n for n in t.body if isinstance(n, ast.Assign) and n.targets[0].id==\"SECRETS\"]))"); [ "$S1" = 1 ]' "2.36 the secret classes still come from one constant in secret-guard.py (the box reads it, no copy)"


# ---- 3. the real bwrap box (box_argv) on the scratch trees: the git-route attacks must fail inside and succeed outside
bwrap --unshare-user --ro-bind / / true 2>"$T/out"; ok '[ $? = 0 ]' "3.0 bwrap runs here (no skip: without it the box cannot exist)"
cat >"$T/argv.py" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[1]); import roles, box
F, prof, ws, br = sys.argv[2:6]
d = roles.load()
a, env = box.box_argv(d, prof, {"card": "t_1", "workspace": ws, "branch": br}, hermes_root=F + "/home/.hermes", home=F + "/home",
                      roots=[F + "/ws"], stack_root=F + "/ws")
open(sys.argv[6], "wb").write(b"\0".join(x.encode() for x in a) + b"\0")
open(sys.argv[7], "w").write("\n".join(f"{k}={v}" for k, v in env.items()) + "\n")
PY
PHH=$PH/home; printf '[user]\n\temail = t@t\n\tname = t\n[safe]\n\tdirectory = *\n' >"$PHH/.gitconfig"
echo ro >"$T/remote-note"; git init -q --bare -b main "$F/R.git" && $G -C "$F/ws" remote add origin "$F/R.git" && $G -C "$F/ws" push -q origin main && $G -C "$F/ws" push -q origin card/x
mkbox() { ROLES_FILE=$T/roles.json python3 "$T/argv.py" "$S" "$F" "$1" "$2" "$3" "$T/argv.bin" "$T/env.txt" 2>"$T/out"; }
boxrun() { # $1 profile $2 worktree $3 branch $4 script; the fake remote is read-only in the box (stands in for "no write credential")
  mkbox "$1" "$2" "$3" || return 99; mapfile -d '' A <"$T/argv.bin"; mapfile -t E <"$T/env.txt"
  env "${E[@]}" "${A[@]}" --ro-bind "$F/R.git" "$F/R.git" --chdir "$2" bash -c "$4" 2>&1 | grep -v setlocale | head -${LINES_MAX:-6}; return "${PIPESTATUS[0]}"; }
inb() { boxrun "$P" "$WT" card/x "$1" >"$T/out" 2>&1; }
moved() { [ "$($G -C "$F/ws" rev-parse main)" != "$BASEM" ] || [ "$(git -C "$F/R.git" rev-parse main)" != "$BASEM" ]; }
BASEM=$($G -C "$F/ws" rev-parse main); MAIN_SHA=$BASEM
ok 'inb "echo hi" && grep -q hi "$T/out"' "3.1 a command runs in the box"
ok 'inb "echo hi > $WT/new && git add new && git commit -qm n && git log --oneline | head -1" && grep -q " n$" "$T/out"' "3.2 a commit in the card worktree works in the box (pre-commit proof falls back to the marker)"
ok '! inb "test -e $WS/boxcanary/canary.txt" && ! inb "test -e $WS/BOXCANARY/CANARY.TXT" && ! inb "test -e $WS/config/owner.env" && ! inb "test -e $WS/Config/OWNER.ENV"' "3.3 the canary, the owner file and their case variants are absent in the box"
ok 'test -r "$WS/boxcanary/canary.txt"' "3.4 negative control: the canary is readable outside the box by a plain read"
ok '! inb "touch $WS/newfile" && grep -qi "read-only" "$T/out"' "3.5 a new file in the project root fails (EROFS)"
ok '! inb "echo x > $WS/bin/a" && grep -qi "read-only" "$T/out"' "3.6 a bound child is read-only"
ok 'inb "echo x > $WT/f2" && [ -f "$WT/f2" ]' "3.7 the card worktree is writable"
ok '! inb "echo x > $WT/.git" && grep -qi "read-only" "$T/out"' "3.8 the worktree .git file is read-only (EROFS)"
ok '! inb "echo x > $CD/worktrees/$ID/gitdir" && ! inb "echo x > $CD/worktrees/$ID/commondir"' "3.9 gitdir and commondir are read-only"
ok '! inb "git update-ref refs/heads/main HEAD~0 && git branch -f main card/x" ; ! moved' "3.10 refs/heads/main cannot be written"
ok '! inb "echo x > $CD/config" && ! inb "git config alias.p status"' "3.11 .git/config is read-only"
ok 'inb "echo v > \$HOME/.gitconfig2 && echo ok" && grep -q ok "$T/out"' "3.12 the profile home is writable (a written ~/.gitconfig only affects later boxed runs)"
ok '! inb "test -e $F/home/.claude" && ! inb "test -e $H2/profiles/$R"' "3.13 the owner Claude folder and another profile are absent"
ok '! inb "touch $F/home/zz-home" && ! inb "touch $H2/zz-hermes" && [ ! -e "$F/home/zz-home" ] && [ ! -e "$H2/zz-hermes" ]' "3.27 the real home and ~/.hermes are read-only tmpfs mounts (nothing written there reaches the host)"
ok '! inb "echo x > \$HOME/.local/lib/zz" && ! inb "mv \$HOME/.local/lib \$HOME/.local/lib2" && ! inb "echo x > \$HOME/.bashrc" && inb "echo x > \$HOME/.local/ok-write" && [ ! -e "$PH/home/.local/lib/zz" ]' "3.28 in the real box the python user site, ~/.local/bin and shell startup files cannot be written or renamed (RT-A-01)"
GC0=$(sha256sum "$PHH/.gitconfig" | cut -c1-16)
ok '! inb "echo x >> \$HOME/.gitconfig" && ! inb "printf \"[trace2]\\n\" > \$HOME/.gitconfig" && ! inb "mv \$HOME/.gitconfig \$HOME/.gitconfig.o" && ! inb "echo x > \$HOME/.jq" && ! inb "mkdir -p \$HOME/.config/git && echo x > \$HOME/.config/git/config" && ! inb "echo x > \$HOME/.config/git/attributes" && [ "$(sha256sum "$PHH/.gitconfig" | cut -c1-16)" = "$GC0" ] && [ ! -s "$PHH/.jq" ] && [ -z "$(ls -A "$PHH/.config/git")" ]' "3.28 a worker cannot write ~/.gitconfig, ~/.jq or ~/.config/git in the box (RT-RTA-01/02); the files a hook's git and jq read are as the owner left them"
ok 'inb "git config --global --list >/dev/null && echo \$HOME/.jq >/dev/null && test -f \$HOME/.jq"' "3.29 negative control: they stay readable in the box (git still finds its identity)"
# RT-A-04: the Claude config folder itself cannot be moved or replaced (a bind makes it a mount point: rename gives EBUSY), writes inside it still work
cp "$T/roles.json" "$T/roles.base.json"; jq '.sandbox.profile_overrides[$p] = {claude_config_dir: "{home}/.claude", ro_over: ["settings.json", "hooks"]}' --arg p "$P" "$T/roles.base.json" >"$T/roles.json"
inb "true"   # the first boxed call creates .claude and its ro_over entries
S0=$(sha256sum "$PHH/.claude/settings.json" | cut -c1-16)
ok '! inb "mv \$HOME/.claude \$HOME/.claude.o" && ! inb "mkdir \$HOME/evil && echo {} > \$HOME/evil/settings.json && mv \$HOME/.claude \$HOME/c.o && mv \$HOME/evil \$HOME/.claude" && ! inb "rm -rf \$HOME/.claude" && [ -d "$PHH/.claude/hooks" ] && [ ! -e "$PHH/.claude.o" ] && [ ! -e "$PHH/c.o" ] && [ "$(sha256sum "$PHH/.claude/settings.json" | cut -c1-16)" = "$S0" ]' "3.49 mv, replace or rm of the Claude config folder fails in the box and the ro_over entries stay (RT-A-04)"
ok 'inb "mkdir \$HOME/.claude/projects && echo n > \$HOME/.claude/notes" && [ -d "$PHH/.claude/projects" ] && [ -f "$PHH/.claude/notes" ] && ! inb "echo x > \$HOME/.claude/settings.json"' "3.50 negative control: new files in the Claude config folder are still writable, ro_over entries are not"
cp "$T/roles.base.json" "$T/roles.json"
ok '! inb "unshare -Ur true" && ( unshare -Ur true )' "3.14 unshare works outside, fails inside (--disable-userns)"
ok 'inb "ls /proc | grep -c \"^[0-9]\"" && [ "$(head -1 "$T/out")" -lt 10 ]' "3.15 the box sees only its own processes"
( sleep 1; touch "$T/survived-out" ) >/dev/null 2>&1 &
sleep 1.6; ok '[ -f "$T/survived-out" ]' "3.16 negative control: a delayed background job started outside completes"
inb "(sleep 1; touch $WT/survived-in) >/dev/null 2>&1 & true"; sleep 1.8; ok '[ ! -e "$WT/survived-in" ]' "3.17 a background job dies with its call (per-command box, known limit 4.7)"
LINES_MAX=3
$G -C "$F/ws" push -q -f origin card/x   # the remote's card branch is ahead of main, so a fetch or push of it can really move main
# the git routes of the red-team (RT21/RT22), run for real: outside they move main, inside they cannot. No git-guard involved.
attack() { # $1 label, $2 script: fresh main, unboxed (control) then boxed
  $G -C "$F/ws" update-ref refs/heads/main "$MAIN_SHA"; git -C "$F/R.git" update-ref refs/heads/main "$MAIN_SHA"
  ( cd "$WT" && HOME=$PHH bash -c "$2" >/dev/null 2>&1 ); local u=0; moved && u=1
  $G -C "$F/ws" update-ref refs/heads/main "$MAIN_SHA"; git -C "$F/R.git" update-ref refs/heads/main "$MAIN_SHA"
  inb "$2"; local b=0; moved && b=1
  $G -C "$F/ws" update-ref refs/heads/main "$MAIN_SHA"; git -C "$F/R.git" update-ref refs/heads/main "$MAIN_SHA"
  [ "$u" = 1 ] && [ "$b" = 0 ]; }
ok 'attack x "echo refs/heads/card/x:refs/heads/main | git fetch -u --stdin origin"' "3.18 git fetch --stdin: moves main outside, not inside"
ok 'attack x "export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.push GIT_CONFIG_VALUE_0=refs/heads/card/x:refs/heads/main; git push origin"' "3.19 git config reaching push through an export"
ok 'attack x "mkdir -p \$HOME/h2 && printf \"[remote \\\"origin\\\"]\\n\\tpush = refs/heads/card/x:refs/heads/main\\n\" > \$HOME/h2/.gitconfig && HOME=\$HOME/h2 git push origin"' "3.20 HOME= override with a written .gitconfig"
ok 'attack x "git config --global alias.p \"push origin refs/heads/card/x:refs/heads/main\" && git p"' "3.21 a written ~/.gitconfig alias"
ok 'attack x "git update-ref refs/heads/main refs/heads/card/x; git remote add --mirror=push m \$(git config remote.origin.url); git push m"' "3.22 git remote add --mirror"
ok 'attack x "git push --end-of-options origin refs/heads/card/x:refs/heads/main"' "3.23 --end-of-options"
ok 'attack x "git fetch -u --refmap=refs/heads/card/x:refs/heads/main origin refs/heads/card/x"' "3.24 --refmap="

# ---- 3c. HH-05 (a boxed builder repoints another card's branch) and HH-06 (HOME=<dir> git commit skips the commit guard), run for
# real on a tree on the stack's own kind of mount (9p, case-insensitive): a bind over one spelling of a ref hides only that spelling
# (`T_SIB` overwrites `t_sib`), so the card's refs cannot be per-file read-only binds inside a shared folder: the box gets a private
# copy of its own ref, and box.py applies it to the real repo after the call.
L=$(mktemp -d "${HH_TREE:-$W/.scratch/readiness}/hh-box.XXXXXX"); F2=$L/f
trap '[ -n "${KEEP:-}" ] || rm -rf "$T" "$L"' EXIT
mkdir -p "$F2/ws" "$F2/home/.hermes/profiles/$P/home" "$F2/home/.hermes/profiles/$P/skills" "$F2/R.git"
PHH2=$F2/home/.hermes/profiles/$P/home; printf '[user]\n\temail = t@t\n\tname = t\n[safe]\n\tdirectory = *\n' >"$PHH2/.gitconfig"
: >"$F2/ws/.alias-probe"
ok '[ -e "$F2/ws/.ALIAS-PROBE" ]' "3.30 control: this tree is case-insensitive like /workspace (a case variant names the same file)"
$G -C "$F2/ws" init -q && echo r >"$F2/ws/README" && $G -C "$F2/ws" add README && $G -C "$F2/ws" commit -qm r
C0=$($G -C "$F2/ws" rev-parse HEAD); S1=$($G -C "$F2/ws" commit-tree -m s1 "$C0^{tree}" -p "$C0"); P1=$($G -C "$F2/ws" commit-tree -m p1 "$C0^{tree}" -p "$C0")
$G -C "$F2/ws" branch proj/t_pak-c "$P1" && $G -C "$F2/ws" pack-refs --all --prune   # a card branch that only packed-refs holds
$G -C "$F2/ws" worktree add -q "$F2/ws/.worktrees/own" -b proj/t_own-a "$C0" && $G -C "$F2/ws" worktree add -q "$F2/ws/.worktrees/sib" -b proj/t_sib-b "$S1"
printf '#!/bin/sh\n# stand-in for the commit guard: refuses the author address the real one refuses\n[ "$(git var GIT_AUTHOR_IDENT | sed -n "s/.*<\\(.*\\)>.*/\\1/p")" != test@test.com ] || { echo "stand-in commit-guard: refused" >&2; exit 1; }\n' >"$F2/ws/.git/hooks/pre-commit"; chmod +x "$F2/ws/.git/hooks/pre-commit"
WT2=$(realpath "$F2/ws/.worktrees/own"); CD2=$(realpath "$F2/ws/.git")
ref2() { $G -C "$F2/ws" rev-parse "$1"; }
inb2() { local F=$F2; boxrun "$P" "$WT2" proj/t_own-a "$1" >"$T/out" 2>&1; }   # F is read by mkbox and boxrun: the box is planned on this tree
rew() { rm -f "$CD2"/refs/heads/proj/*; $G -C "$F2/ws" update-ref refs/heads/proj/t_sib-b "$S1"; $G -C "$F2/ws" update-ref refs/heads/proj/t_pak-c "$P1"; $G -C "$F2/ws" update-ref refs/heads/proj/t_own-a "$C0"; $G -C "$WT2" reset -q --hard "$C0"; rm -rf "$WT2/.hh"; }
( cd "$WT2" && HOME=$PHH2 bash -c 'git update-ref refs/heads/proj/t_sib-b HEAD && git update-ref refs/heads/proj/t_pak-c HEAD' ) >/dev/null 2>&1
ok '[ "$(ref2 proj/t_sib-b)" = "$C0" ] && [ "$(ref2 proj/t_pak-c)" = "$C0" ]' "3.31 negative control: unboxed, a plain git update-ref repoints a sibling card's branch (loose and packed-only)"
rew
LINES_MAX=6
inb2 "git update-ref refs/heads/proj/t_sib-b HEAD"
ok '[ "$(ref2 proj/t_sib-b)" = "$S1" ]' "3.32 HH-05: a boxed builder cannot repoint a sibling card's branch (loose ref)"
inb2 "git update-ref refs/heads/proj/t_pak-c HEAD"
ok '[ "$(ref2 proj/t_pak-c)" = "$P1" ] && [ ! -e "$CD2/refs/heads/proj/t_pak-c" ]' "3.33 HH-05: nor a branch that only packed-refs holds (no loose ref appears)"
inb2 "git update-ref refs/heads/proj/T_SIB-B HEAD; printf '%s\\n' \$(git rev-parse HEAD) > $CD2/refs/heads/proj/T_SIB-B; printf '%s\\n' \$(git rev-parse HEAD) > $CD2/refs/heads/proj/T_PAK-C"
ok '[ "$(ref2 proj/t_sib-b)" = "$S1" ] && [ "$(ref2 proj/t_pak-c)" = "$P1" ] && [ "$(ls "$CD2/refs/heads/proj" | grep -c "^T_")" = 0 ]' "3.34 HH-05: nor through a case variant of the name (a bind over one spelling hides only that spelling)"
inb2 "echo c1 >c1 && git add c1 && git commit -qm c1; exit 7"; rc=$?
ok '[ "$rc" = 7 ] && [ "$(ref2 proj/t_own-a)" = "$($G -C "$WT2" rev-parse HEAD)" ] && [ "$(ref2 proj/t_own-a)" != "$C0" ] && [ "$($G -C "$F2/ws" log -1 --format=%s proj/t_own-a)" = c1 ]' "3.35 HH-05: the card's own branch advances in the real repo after the call (a commit in the box)"
rew; inb2 "echo c1 >c1 && git add c1 && git commit -qm c1; exit 7"
ok '[ "$(ref2 proj/t_own-a)" != "$C0" ]' "3.36 the own branch lands even when the command exits non-zero"
rew; inb2 "exit 7"; rc=$?   # the launcher is not allowed to change the exit code
ok '[ "$rc" = 7 ]' "3.37 the call's exit code is the command's"
rew; inb2 "rm -f $CD2/refs/heads/proj/t_own-a; ln -s $F2/ws/README $CD2/refs/heads/proj/t_own-a"
ok '[ "$(ref2 proj/t_own-a)" = "$C0" ] && [ ! -L "$CD2/refs/heads/proj/t_own-a" ]' "3.38 a symlink put at the own ref in the box is never followed or applied"
rew; inb2 "echo not-a-commit-id > $CD2/refs/heads/proj/t_own-a"
ok '[ "$(ref2 proj/t_own-a)" = "$C0" ]' "3.39 garbage written to the own ref in the box is not applied"
rew; inb2 "git branch proj/t_new-d"
ok '! $G -C "$F2/ws" rev-parse -q --verify refs/heads/proj/t_new-d >/dev/null' "3.40 a branch other than the card's own does not reach the real repo (known limit, documented)"
# HH-06: a planted config under HOME=<dir> / XDG_CONFIG_HOME=<dir> that switches the commit hook off
rew; mkdir -p "$WT2/.hh/git"; printf '[core]\n\thooksPath = /dev/null\n' | tee "$WT2/.hh/.gitconfig" >"$WT2/.hh/git/config"
BAD='GIT_AUTHOR_EMAIL=test@test.com GIT_AUTHOR_NAME=x GIT_COMMITTER_EMAIL=x@x GIT_COMMITTER_NAME=x'
( cd "$WT2" && env $BAD HOME=$WT2/.hh bash -c 'echo h >h1 && git add h1 && git commit -qm h1' ) >/dev/null 2>&1; rc=$?
ok '[ "$rc" = 0 ] && [ "$($G -C "$WT2" log -1 --format=%s)" = h1 ]' "3.41 negative control: unboxed, HOME=<dir> with a planted core.hooksPath skips the commit hook (the bad author gets through)"
rew; mkdir -p "$WT2/.hh/git"; printf '[core]\n\thooksPath = /dev/null\n' | tee "$WT2/.hh/.gitconfig" >"$WT2/.hh/git/config"
inb2 "echo h >h1 && git add h1 && $BAD HOME=\$PWD/.hh git commit -qm h1"
ok '[ "$(ref2 proj/t_own-a)" = "$C0" ] && grep -q "stand-in commit-guard: refused" "$T/out"' "3.42 HH-06: boxed, HOME=<dir> git commit with a planted config still runs the commit hook (refused)"
inb2 "echo h >h1 && git add h1 && $BAD XDG_CONFIG_HOME=\$PWD/.hh git commit -qm h1"
ok '[ "$(ref2 proj/t_own-a)" = "$C0" ] && grep -q "stand-in commit-guard: refused" "$T/out"' "3.43 HH-06: nor does XDG_CONFIG_HOME=<dir> skip it"
rew
inb2 "echo h >h1 && git add h1 && git commit -qm ok"
ok '[ "$(ref2 proj/t_own-a)" != "$C0" ]' "3.44 negative control: a good commit in the box still lands (the pin does not block legitimate git use)"
rew
# VH-01 (verifier): a case variant of `.git` reaches the real file, so a two-call chain could make the launcher run git on a git folder the box wrote
GF=$(cat "$WT2/.git")
inb2 "mkdir -p $WT2/.fk/worktrees/own $WT2/.fk/objects $WT2/.fk/refs/heads/proj && echo $WT2/.git > $WT2/.fk/worktrees/own/gitdir && echo ../.. > $WT2/.fk/worktrees/own/commondir && echo 'gitdir: $WT2/.fk/worktrees/own' > $WT2/.GIT"
ok '[ "$(cat "$WT2/.git")" != "$GF" ]' "3.45 premise: a write to .GIT in the box reaches the real worktree .git file (case-insensitive mount)"
LINES_MAX=6; inb2 "echo c1 >c1 && git add c1 && git commit -qm c1"; rc=$?
ok '[ "$rc" = 99 ] && [ "$(ref2 proj/t_own-a)" = "$C0" ] && [ "$(ref2 proj/t_sib-b)" = "$S1" ]' "3.46 VH-01: the next call is refused when the worktree .git names a git folder that is not a known repository (the box wrote it)"
printf '%s\n' "$GF" >"$WT2/.git"; rew
# VH-01: the launcher never follows a symref at the card's ref
$G -C "$F2/ws" symbolic-ref refs/heads/proj/t_own-a refs/heads/proj/t_sib-b
SPEC=$(jq -nc --arg c "$CD2" --arg p "$L/priv-symref" '{common: $c, branch: "proj/t_own-a", priv: $p}')
python3 -I "$S/box.py" run "$SPEC" -- bash -c "echo $C0 > $L/priv-symref/refs/t_own-a" >"$T/out" 2>&1
ok '[ "$(ref2 proj/t_sib-b)" = "$S1" ]' "3.47 VH-01: a card ref that is a symref is never followed by the write-back (the sibling stays)"
rm -f "$CD2/refs/heads/proj/t_own-a"; rew
# VH-04: a signal meant for the call ends the box, the ref is still applied, the exit code is the signal's
SPEC=$(jq -nc --arg c "$CD2" --arg p "$L/priv-sig" '{common: $c, branch: "proj/t_own-a", priv: $p}')
python3 -I "$S/box.py" run "$SPEC" -- bash -c "echo $S1 > $L/priv-sig/refs/t_own-a; sleep 30" >"$T/out" 2>&1 &
LP=$!; for _ in $(seq 50); do [ -s "$L/priv-sig/refs/t_own-a" ] && [ "$(cat "$L/priv-sig/refs/t_own-a")" = "$S1" ] && break; sleep 0.1; done
sleep 0.3; kill -TERM $LP; wait $LP; rc=$?
ok '[ "$rc" = 143 ] && [ "$(ref2 proj/t_own-a)" = "$S1" ] && [ ! -e "$L/priv-sig" ]' "3.48 VH-04: SIGTERM to the launcher ends the call (143), applies the card ref once and leaves no private folder"
rew

# ---- 3b. offline test over the REAL tree: names only, no content read. A role without a card keeps this independent of any worktree.
mkrf ".sandbox = $SB | .sandbox.boxed_profiles = [first(. as \$d | .profiles | to_entries[] | select(\$d.roles[.value.role].workspace == \"none\")).key] | .sandbox.profile_overrides = {}"
NP=$(jq -r '.sandbox.boxed_profiles[0]' "$T/roles.json"); mkdir -p "$F/home/.hermes/profiles/$NP/home" "$F/home/.hermes/home"
cat >"$T/real.py" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1]); import roles, box
d = roles.load(); prof = d["sandbox"]["boxed_profiles"][0]
row = d["profiles"][prof]
m, env = box.plan(d, prof, {}, hermes_root=sys.argv[2], home=sys.argv[3], roots=["/workspace"])
sec, ok_ = box.secret_classes()
bad = [x for op, *p in m if op in ("ro", "rw") for x in p if any(s in os.path.basename(x).casefold() for s in ("owner.env", "canary.txt"))]
import fnmatch
bad += [x for op, *p in m if op in ("ro", "rw") for x in p[:1] if os.path.basename(x).casefold() not in [o.casefold() for o in ok_]
        and any(fnmatch.fnmatchcase(os.path.basename(x).casefold(), s.casefold()) for s in sec if not s.startswith("~"))]
print("BAD", bad)
print("EXAMPLE", ("ro", "/workspace/config/owner.example.env", "/workspace/config/owner.example.env") in m)
print("N", len(m))
PY
ROLES_FILE=$T/roles.json python3 "$T/real.py" "$S" "$F/home/.hermes" "$F/home" >"$T/real.txt" 2>"$T/out"
ok 'grep -qx "BAD \[\]" "$T/real.txt"' "3.25 offline: no owner, canary or secret-class name among the real tree's bind list"
ok 'grep -qx "EXAMPLE True" "$T/real.txt"' "3.26 offline: negative control, the other children of the owner folder are bound (the test sees the real tree)"


# ---- 4. the terminal plugin under Hermes's own interpreter: real BaseEnvironment.execute, real bwrap, fixture trees
mkrf ".sandbox = $SB | .sandbox.boxed_profiles += [\$r]"
HPY=$(hermes --print-runtime-command python3 | jq -r '.[0]')
PLUG=${PLUGIN:-$W/docs/hermes-local/plugins/os-box/__init__.py}
cat >"$T/plug.py" <<'PY'
import importlib.util, json, os, sys
os.environ.pop("PYTHONHOME", None); sys.path.insert(0, "/home/node/.hermes/hermes-agent")
import hermes_bootstrap
from tools.environments.local import LocalEnvironment
F, WT, PLUGF, mode, PH = sys.argv[1:6]
import pwd
spec = importlib.util.spec_from_file_location("osbox_under_test", PLUGF); m = importlib.util.module_from_spec(spec)
class Ctx:
    got = None
    def register_terminal_environment_provider(self, p): Ctx.got = p
try:
    spec.loader.exec_module(m)
    os.environ["HOME"] = PH + "/home"   # inside a Hermes worker $HOME is the profile home
    os.environ["HERMES_SCRATCH_DIR"] = "/should-not-reach-the-box"
    HOME_DEFAULT = m._home()
    m._stack_root = lambda: F + "/ws"; m._hermes_home = lambda: PH; m._home = lambda: F + "/home"; m._roots = lambda d: [F + "/ws"]
    m._prove = lambda profile: ({"task": {"id": "t_1", "workspace_path": WT, "branch_name": "card/x"}}, None)
    if mode == "unproven": m._prove = lambda profile: (None, "no running card is assigned to this profile")
    m.register(Ctx())
except Exception as e:
    print(json.dumps({"register_err": f"{type(e).__name__}: {str(e)[:160]}"})); sys.exit(0)
pr = Ctx.got
out = {"home_is_passwd": HOME_DEFAULT == pwd.getpwuid(os.getuid()).pw_dir, "name": pr.name, "container": pr.is_container, "remote": pr.is_remote, "skip": pr.skip_container_guards,
       "cache": pr.cache_path_base, "cwd_abs": str(pr.default_cwd).startswith("/"), "avail": pr.is_available()}
try:
    env = pr.create_environment(cwd="", timeout=30, task_id="t")
except Exception as e:
    out["create_err"] = f"{type(e).__name__}: {str(e)[:160]}"; print(json.dumps(out)); sys.exit(0)
out["is_local_subclass"] = isinstance(env, LocalEnvironment)
def x2(c, cwd):
    r = env.execute(c, cwd=cwd, timeout=30); r["output"] = "\n".join(l for l in r["output"].splitlines() if "setlocale" not in l); return r
def x(c):   # the container's missing locale makes bash warn on stderr; every selftest here filters it
    r = env.execute(c, timeout=30); r["output"] = "\n".join(l for l in r["output"].splitlines() if "setlocale" not in l); return r
os.environ["ANTHROPIC_API_KEY"] = "sk-leak-canary"
r = x("echo hi; pwd"); out["run"] = r["output"].split(); out["rc"] = r["returncode"]
out["scrub"] = x('[ -z "${ANTHROPIC_API_KEY:-}" ] && echo scrubbed || echo LEAK')["output"].strip()
out["marker"] = x("printenv HERMES_KANBAN_WORKSPACE")["output"].strip()
x("export SNAPVAR=kept; mkdir -p sub && cd sub"); r = x("echo $SNAPVAR; pwd"); out["persist"] = r["output"].split()
out["cwd_slash"] = x2("pwd", "/")["output"].strip().splitlines()[-1]   # Hermes passes the provider default_cwd per call
from tools.file_operations import ShellFileOperations   # the file tools of a non-local backend run shell probes through execute()
fo = ShellFileOperations(env, cwd=WT)
out["fo_read"] = fo.read_file(WT + "/README").content.strip()
out["fo_canary"] = fo.read_file(F + "/ws/boxcanary/canary.txt").content.strip()
out["fo_write_ok"] = bool(fo.write_file(WT + "/fo-new.txt", "written\n").bytes_written) and os.path.exists(WT + "/fo-new.txt")
w = fo.write_file(F + "/ws/fo-root.txt", "x\n")
out["fo_write_root_blocked"] = not os.path.exists(F + "/ws/fo-root.txt")
out["scratch_env"] = x("printenv HERMES_SCRATCH_DIR | wc -c")["output"].strip()
out["canary_rc"] = x(f"test -e {F}/ws/boxcanary/canary.txt; echo $?")["output"].strip()
out["ro_rc"] = x(f"touch {F}/ws/newfile 2>&1 | grep -c 'Read-only'")["output"].strip()
tmpd = env.get_temp_dir(); out["tmp"] = tmpd
other = os.path.join(tmpd, "hermes-snap-othersession.sh"); open(other, "w").close()
out["snap_before"] = len([f for f in os.listdir(tmpd) if env._session_id in f])
env.cleanup()
out["snap_after"] = len([f for f in os.listdir(tmpd) if env._session_id in f]); out["other_kept"] = os.path.exists(other)
print(json.dumps(out))
PY
plug() { # $1 mode, extra env via caller
  env PATH="${PP:-$PATH}" ROLES_FILE=$T/roles.json "$HPY" -I "$T/plug.py" "$F" "$WT" "$PLUG" "$1" "$PH" 2>"$T/out" | tail -1 >"$T/plug.json"; cut -c1-600 "$T/plug.json" >>"$T/out"; }
pj() { jq -r "$1" "$T/plug.json"; }
plug ok; [ -n "${DEBUG:-}" ] && { echo "driver: $(jq -c "{fo_read,fo_canary,fo_write_ok,fo_write_root_blocked}" "$T/plug.json")"; }
ok '[ "$(pj .name)" = os_box ] && [ "$(pj .container)" = false ] && [ "$(pj .remote)" = false ] && [ "$(pj .skip)" = false ] && [ "$(pj .cache)" = null ] && [ "$(pj .cwd_abs)" = true ]' "4.1 provider flags: not a container, not remote, approvals stay on, no cache rewrite, explicit cwd (Hermes defaults are the unsafe ones)"
ok '[ "$(pj .is_local_subclass)" = false ]' "4.2 the environment is not a LocalEnvironment (file tools must not take the native unboxed path)"
ok '[ "$(pj ".run[0]")" = hi ] && [ "$(pj ".run[1]")" = "$WT" ] && [ "$(pj .rc)" = 0 ]' "4.3 a command runs through Hermes's own execute() in the box, starting in the card worktree"
ok '[ "$(pj .scrub)" = scrubbed ]' "4.4 a provider key in the parent environment is absent inside the box"
ok '[ "$(pj .marker)" = "$WT" ]' "4.5 the commit-guard marker is set from the proof"
ok '[ "$(pj ".persist[0]")" = kept ] && [ "$(pj ".persist[1]")" = "$WT/sub" ]' "4.6 the session snapshot works: exports and cwd persist across calls (tmp_dir is writable and shared)"
ok '[ "$(pj .home_is_passwd)" = true ]' "4.14 the plugin takes the real home from the passwd entry, not from \$HOME (a worker's HOME is its profile home)"
ok '[ "$(pj .fo_read)" = "1|r" ] && [ "$(pj .fo_canary)" = "" ]' "4.15 the file tools through the box: read_file returns a real file's content and nothing for the canary (the locale warning must not corrupt the size probe)"
ok '[ "$(pj .fo_write_ok)" = true ] && [ "$(pj .fo_write_root_blocked)" = true ]' "4.16 write_file works in the card worktree and cannot write into the project root"
ok '[ "$(pj .scratch_env)" = 0 ]' "4.17 HERMES_SCRATCH_DIR does not reach the box (design 4.1-3: TMPDIR is the private /tmp)"
ok '[ "$(pj .cwd_slash)" = "$WT/sub" ]' "4.13 a per-call cwd of / (Hermes's default_cwd for the backend) means no cwd: the command runs where the session is (in the worktree), not in /"
ok '[ "$(pj .canary_rc)" = 1 ] && [ "$(pj .ro_rc)" = 1 ]' "4.7 through execute(): the canary is absent and a write to the project root is read-only"
ok '[ "$(pj .snap_before)" -ge 1 ] && [ "$(pj .snap_after)" = 0 ] && [ "$(pj .other_kept)" = true ] && [ "$(pj .tmp)" = "$PH/box-tmp" ]' "4.8 cleanup removes only this session's files from tmp_dir"
plug unproven; ok 'pj .create_err | grep -q "STL-GRD-603"' "4.9 an unprovable card refuses the terminal with STL-GRD-603"
mkrf 'del(.sandbox)'; plug ok; ok '[ "$(pj .register_err)" != null ] || [ "$(pj .create_err)" != null ]' "4.10 with the sandbox block removed the plugin refuses (registers nothing or refuses to create)"
mkrf ".sandbox = $SB | .sandbox.boxed_profiles = []"; plug ok; ok '[ "$(pj .create_err)" != null ]' "4.11 a profile that is not in boxed_profiles gets no box environment"
mkrf ".sandbox = $SB | .sandbox.boxed_profiles += [\$r]"
NB=$(mktemp -d); ln -s "$(command -v jq)" "$NB/jq"; ln -s "$(command -v python3)" "$NB/python3"
PP=$NB plug ok; unset PP; ok '[ "$(pj .avail)" = false ]' "4.12 without bwrap on PATH the backend is unavailable"


# ---- 5. bin/register-toolsets.sh: the per-profile backend, the plugin files and the plugin enable (scratch HOME, stub hermes)
A5=$T/home5; H5=$A5/.hermes; mkdir -p "$A5/bin" "$H5/profiles/$P" "$H5/profiles/$R"
for d in "$H5" "$H5/profiles/$P" "$H5/profiles/$R"; do printf 'model: x\n' >"$d/config.yaml"; done
printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls"\ncase "$*" in *"config get"*) echo unset;; esac\nexit 0\n' "$A5" >"$A5/bin/hermes"; chmod +x "$A5/bin/hermes"
jq --arg p "$P" --arg r "$R" ".sandbox = $SB | .roles[].platform_toolsets = {} " "$RF" >"$T/roles5.json"
for pp in $(jq -r '.profiles | keys[] | select(. != "default")' "$T/roles5.json"); do mkdir -p "$H5/profiles/$pp"; printf 'model: x\n' >"$H5/profiles/$pp/config.yaml"; done
reg() { HOME="$A5" PATH="$A5/bin:$PATH" ROLES_FILE=$T/roles5.json "${REG:-$W/bin/register-toolsets.sh}" "$@" >"$T/out" 2>&1; echo $?; }
: >"$A5/calls"; ok '[ "$(reg)" = 0 ]' "5.1 register-toolsets applies a table with a sandbox block"
ok 'grep -qx -- "-p $P config set terminal.backend os_box" "$A5/calls" && grep -qx -- "-p $P config set plugins.isolation in_process" "$A5/calls"' "5.2 a boxed profile gets the backend and in_process isolation"
ok 'grep -qx -- "-p $P plugins enable os-box" "$A5/calls"' "5.3 a boxed profile gets the plugin enabled"
ok 'cmp -s "$W/docs/hermes-local/plugins/os-box/__init__.py" "$H5/profiles/$P/plugins/os-box/__init__.py" && cmp -s "$W/docs/hermes-local/plugins/os-box/plugin.yaml" "$H5/profiles/$P/plugins/os-box/plugin.yaml"' "5.4 the plugin files are copied from the repo into the boxed profile"
ok 'grep -qx -- "-p $R config set terminal.backend local" "$A5/calls" && ! grep -q -- "-p $R plugins enable" "$A5/calls" && [ ! -e "$H5/profiles/$R/plugins" ]' "5.5 an unboxed profile is pinned to the unboxed backend and gets no plugin"
n1=$(grep -c ' set \| enable ' "$A5/calls"); ok '[ "$(reg --check)" = 1 ] && grep -q "plugin os-box DRIFT" "$T/out" && [ "$(grep -c " set \| enable " "$A5/calls")" = "$n1" ]' "5.6 --check reports the plugin drift and changes nothing"

[ -n "${KEEP:-}" ] && echo "KEPT $T"
[ "$fails" = 0 ] && echo "box selftest PASS" || { echo "box selftest FAIL ($fails)"; exit 1; }
