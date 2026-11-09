#!/usr/bin/env bash
# Hermetic self-test for bin/false-close-guard.py: a scratch session store (GUARD_STATE_DB) and a scratch worktree
# under /workspace/.scratch (gitignored; the Windows path is only defined under /workspace), no network.
# 3b rows (S3A-06): GUARD=<guard> or STAGE=<dir> runs a staged copy; every row of bin/false-close-guard-selftest.sh is kept as is,
# and the rows at the end pin the reassign sentence of the no-delegate refusal.
# Replays t_fbfdaf63 (heredoc write, then OpenCode), the recovery path the refusal names, and the Windows-path checks (F3, F4).
set -u
T=$(mktemp -d); W=$(mktemp -d /workspace/.scratch/fcg.XXXXXX); trap 'rm -rf "$T" "$W"' EXIT
echo "Phase 4 test OK" > "$W/phase4-test.md"
cp /workspace/config/owner.example.env "$T/owner.env"   # scratch owner config (D39): OWNER_STACK_PATH_WIN='C:\stack'
export OWNER_CONFIG="$T/owner.env" ESCALATE_SUP_DIR="$T"
WIN="C:\\stack\\${W#/workspace/}"; WIN="${WIN//\//\\}\\phase4-test.md"
G=${GUARD:-${STAGE:-/workspace/bin}/false-close-guard.py}   # the guard under test (a staged copy while it is being replaced)
export PYTHONPATH=/workspace/bin   # a guard outside /workspace/bin still finds owner_config
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
# session <json list of [tool, args, result]>: a fresh store holding one session "s1" with those calls, in order.
session() {
  rm -f "$T/state.db"
  python3 -I - "$T/state.db" "$1" <<'PY'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table messages (session_id, role, tool_call_id, tool_calls, content)")
for i, (name, args, res) in enumerate(json.loads(sys.argv[2])):
    tc = [{"id": f"c{i}", "function": {"name": name, "arguments": json.dumps(args)}}]
    con.execute("insert into messages values ('s1', 'assistant', null, ?, '')", (json.dumps(tc),))
    con.execute("insert into messages values ('s1', 'tool', ?, null, ?)", (f"c{i}", json.dumps(res)))
con.commit()
PY
}
# guard [summary] [extra metadata json]: run the guard on a kanban_complete; sets rc and out.
guard() {
  local md
  md=$(jq -nc --argjson x "${2:-{\}}" '{delegate_exit_code: 0, delegate_output: "Wrote file successfully", files_created: ["phase4-test.md"]} + $x')
  out=$(jq -nc --arg s "${1:-Created phase4-test.md}" --argjson md "$md" --arg cwd "$W" \
        '{tool_name: "kanban_complete", tool_input: {task_id: "t_fbfdaf63", summary: $s, metadata: $md}, session_id: "s1", cwd: $cwd, profile: "builder-local"}' \
        | GUARD_STATE_DB="$T/state.db" python3 "$G"); rc=$?
  [ -z "$out" ] || out=$(jq -r '.message' <<<"$out")   # the refusal text, JSON escapes decoded
}
HEREDOC=$(jq -nc --arg w "$W" '["terminal", {command: ("cat > " + $w + "/phase4-test.md << '"'"'EOF'"'"'\nPhase 4 test OK\nEOF")}, {exit_code: 0, output: ""}]')
OC_OK='["terminal", {"command": "opencode run --standalone --auto '"'"'create phase4-test.md containing Phase 4 test OK'"'"'"}, {"exit_code": 0, "output": "← Write phase4-test.md\nWrote file successfully"}]'
OC_124='["terminal", {"command": "opencode run --standalone --auto '"'"'write it'"'"'"}, {"exit_code": 124, "output": "Error: Transport: The socket connection was closed unexpectedly"}]'
GITRM='["terminal", {"command": "git rm phase4-test.md && git commit -m \"Remove hand-written phase4-test.md\""}, {"exit_code": 0, "output": "rm phase4-test.md"}]'

session "[$OC_OK]"; guard
ok '[ "$rc" = 0 ] && [ -z "$out" ]' "OpenCode wrote the file: completion allowed"

session "[$HEREDOC, $OC_OK]"; guard
ok '[ "$rc" = 2 ] && grep -q "written outside OpenCode" <<<"$out"' "t_fbfdaf63: a heredoc write, even with a later OpenCode run, is refused"
ok 'grep -q "git rm phase4-test.md" <<<"$out" && grep -q "opencode run --standalone --auto" <<<"$out" && grep -q "kind capability" <<<"$out"' "the refusal names the next steps: git rm, OpenCode again, then block with kind capability"
ok 'grep -q "final for this attempt" <<<"$out"' "the refusal says it is final, so the worker does not argue for an override"

session "[$HEREDOC, $GITRM, $OC_OK]"; guard
ok '[ "$rc" = 0 ]' "recovery as the refusal says (git rm, then OpenCode writes it): completion allowed"
session "[$HEREDOC, $OC_OK, $GITRM]"; guard
ok '[ "$rc" = 2 ]' "git rm without a later OpenCode write is not a recovery"

session "[$OC_OK, $OC_124]"; guard
ok '[ "$rc" = 2 ] && grep -q "exited 124" <<<"$out" && grep -q "fails twice, call kanban_block once with kind capability" <<<"$out"' "OpenCode exit 124: refused, with what to do next"

session "[$OC_OK]"
guard "Done. Windows path: /mnt/c/stack/.hermes/profiles/builder-local/cache/scratch/t_fbfdaf63/windows_path"
ok '[ "$rc" = 2 ] && grep -q "/mnt/c/" <<<"$out" && grep -qF "$WIN" <<<"$out"' "a /mnt/c/ path is refused and the computed Windows path is named"
guard "Done. Windows path: $WIN."
ok '[ "$rc" = 0 ]' "the computed Windows path is accepted"
guard "Done." "$(jq -nc --arg p 'C:\stack\.hermes\profiles\builder-local\cache\scratch\t_fbfdaf63\windows_path' '{windows_path: $p}')"
ok '[ "$rc" = 2 ] && grep -q "not the deliverable" <<<"$out"' "a wrong Windows path in the metadata is refused"
printf "OWNER_STACK_PATH_WIN='C:\\\\stack\\\\'\n" >> "$T/owner.env"   # the same path with a trailing backslash: one is dropped
guard "Done. Windows path: $WIN."
ok '[ "$rc" = 0 ]' "a trailing backslash on OWNER_STACK_PATH_WIN is dropped when joining (Python)"
OWNER_CONFIG="$T/missing.env" guard "Done."
ok '[ "$rc" = 2 ] && grep -q "OWNER_CONFIG_MISSING" <<<"$out" && grep -q OWNER_CONFIG_MISSING "$T/escalations.log"' "a missing owner config blocks the completion and is logged"

# S3A-06: a worker that cannot delegate to OpenCode (a `Check: none` card has no files for it to write) is told once, in the
# refusal itself, to block with kind capability and ask for reassignment; the guard is not wrong.
OLD1='no terminal call to `opencode run --standalone --auto` in this session'; NEW1='a `Check: none` card'   # variables: eval'd rows cannot hold backticks
LSC='["terminal", {"command": "ls"}, {"exit_code": 0, "output": "x"}]'
for label in "a session with no OpenCode call" "an empty session"; do
  if [ "$label" = "an empty session" ]; then session "[]"; else session "[$LSC]"; fi
  guard "Decision recorded."
  ok '[ "$rc" = 2 ] && grep -qF "$OLD1" <<<"$out" && grep -q "kind capability" <<<"$out" && grep -q "final for this attempt" <<<"$out"' "$label: refused, the old text and kind capability are still there"
  ok 'grep -qF "$NEW1" <<<"$out" && grep -qF "this worker cannot complete it" <<<"$out" && grep -qF "the guard is not wrong" <<<"$out" && grep -qF "reassigned" <<<"$out" && grep -qF "does not delegate to OpenCode" <<<"$out"' "$label: the refusal says a Check: none card cannot be completed by this worker, the guard is not wrong, and to ask for reassignment (S3A-06)"
done
# the sentence belongs to the no-call refusal only: the other refusals keep their own next steps
session "[$HEREDOC, $OC_OK]"; guard
ok '[ "$rc" = 2 ] && ! grep -qF "Check: none" <<<"$out"' "the heredoc refusal does not carry the reassign sentence"
session "[$OC_OK, $OC_124]"; guard
ok '[ "$rc" = 2 ] && ! grep -qF "Check: none" <<<"$out"' "the exit 124 refusal does not carry the reassign sentence"
session "[$OC_OK]"; guard
ok '[ "$rc" = 0 ] && [ -z "$out" ]' "a session with a successful OpenCode run is still allowed (nothing new refused)"
# Ultrareview finding 1: only a wrong path the worker claims is refused, never tool output or text that looks like a path.
session "[$OC_OK]"
guard "Done." "$(jq -nc --arg o 'print("Usage:\n"); re x:\d; see C:\other\path.txt and /mnt/c/elsewhere' '{delegate_output: $o}')"
ok '[ "$rc" = 0 ]' "delegate_output is OpenCode's own text: escapes, or even a path in it, do not refuse a valid card"
guard 'Prints "Usage:\n" and "Done:\t" and "a:\n\n".'
ok '[ "$rc" = 0 ]' "string escapes in the summary are not Windows paths"
guard "Done. Windows path: c${WIN:1}."
ok '[ "$rc" = 0 ]' "a lower-case drive letter is the same Windows path"
guard "Done. Windows path: $(tr a-z A-Z <<<"$WIN")"
ok '[ "$rc" = 0 ]' "the same path in upper case is the same Windows path"
guard "Done. Windows path: **$WIN**"
ok '[ "$rc" = 0 ]' "Markdown bold around the path is not part of it"
guard "Done. Windows path: $WIN.bak"
ok '[ "$rc" = 2 ] && grep -q "not the deliverable" <<<"$out"' "control: a longer name that only starts with the right path is still refused"
guard 'Done. Windows path: C:\other\report.md'
ok '[ "$rc" = 2 ] && grep -q "not the deliverable" <<<"$out" && grep -qF "then call kanban_complete again" <<<"$out"' "control: a wrong path in the summary is still refused, and the refusal says how to recover"
guard "Done." "$(jq -nc --arg p 'c:\other\report.md' '{windows_path: $p}')"
ok '[ "$rc" = 2 ]' "control: a wrong path in another metadata key is still refused"
printf "OWNER_STACK_PATH_WIN='C:\\\\stack home'\n" >> "$T/owner.env"
SP="C:\\stack home\\${W#/workspace/}"; SP="${SP//\//\\}\\phase4-test.md"
guard "Done. Windows path: $SP."
ok '[ "$rc" = 0 ]' "a stack path with a space is matched whole, not cut at the space"
guard 'Done. Windows path: C:\stack home\other.md'
ok '[ "$rc" = 2 ]' "control: a wrong path with a space is still refused"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
