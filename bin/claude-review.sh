#!/usr/bin/env bash
# The Claude review call (follow-up 4, item 5). Runs inside the reviewing profile's box with no arguments.
# The question is not written here or by the driver model: the box launcher (bin/box.py _review_prompt) renders the owner's fixed template with the
# card's id and body and the stack's own git evidence into $REVIEW_PROMPT_FILE, and exports the card's committed tree to $REVIEW_EXPORT_DIR, before the box starts. This script only sends that text to Claude
# with the pinned read-only flags and prints the answer (the approval rule reads it: it must start with APPROVE). A copy of what was sent is left
# in $REVIEW_SENT_FILE (the box tmp dir) as evidence that the template is what reached Claude.
set -eu
[ $# = 0 ] || { echo "claude-review.sh takes no arguments: the question is built from the card" >&2; exit 2; }
f=${REVIEW_PROMPT_FILE:-}
[ -n "$f" ] && [ -s "$f" ] || { echo "no review prompt for this card: the box did not render one" >&2; exit 2; }
[ -n "${REVIEW_MODEL:-}" ] || { echo "no model for this review: the box got none from the role table" >&2; exit 2; }
d=${REVIEW_EXPORT_DIR:-}
[ -n "$d" ] && [ -d "$d" ] || { echo "no committed tree to review for this card: the box did not export one" >&2; exit 2; }
cd -- "$d"   # Claude reads the exported committed tree only, whatever workdir the terminal was given
prompt=$(cat -- "$f")
sent=${REVIEW_SENT_FILE:-}
[ -z "$sent" ] || printf '%s\n' "$prompt" >"$sent" 2>/dev/null || true   # what was sent, kept in the box tmp dir as evidence the template is what reached Claude
err=$(mktemp)
# Claude sees no worktree git variables and no project instruction files; only its stdout is the answer
set +e
out=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=1 \
      claude -p "$prompt" --model "$REVIEW_MODEL" --restricted --strict-mcp-config --tools Read,Grep,Glob --allowedTools Read,Grep,Glob 2>"$err")
rc=$?
printf '%s\n' "$out"
[ "$rc" = 0 ] || cat -- "$err"
rm -f -- "$err"
exit "$rc"
