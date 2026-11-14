#!/usr/bin/env bash
# The approval service's resume (F1c D3; .stella/channels.json resume): bin/approvals.py runs it once per accepted decision. It
# unblocks the card that waited on the approval (needs_input), with the decision as the reason; the worker reads it there.
# usage: kanban-resume.sh <card> <approved|denied>   (the decision JSON on stdin is not needed here)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../kanban-board.sh"
cat >/dev/null
[ $# = 2 ] || { echo "usage: kanban-resume.sh <card> <approved|denied>" >&2; exit 2; }
kanban unblock --reason "approval $2 by the owner (bin/approvals.py)" "$1"
