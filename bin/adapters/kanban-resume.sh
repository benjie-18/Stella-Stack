#!/usr/bin/env bash
# The approval service's resume (F1c D3; .stella/channels.json resume): bin/approvals.py runs it once per decision (an accepted answer, or the expiry). It
# unblocks the card that waited on the approval (needs_input), with the decision as the reason; the worker reads it there.
# usage: kanban-resume.sh <card> <approved|denied|expired>   (the decision JSON on stdin is not needed here)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../kanban-board.sh"
cat >/dev/null
[ $# = 2 ] || { echo "usage: kanban-resume.sh <card> <approved|denied|expired>" >&2; exit 2; }
kanban unblock --reason "approval request $2 (bin/approvals.py; expired = denied)" "$1"
