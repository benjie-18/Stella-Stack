# The board every scripted kanban call uses (F4): the one place that names it, so a `hermes kanban boards switch` never
# points the escalation scripts at another board, and a rename changes this value only. Sourced, not run.
KANBAN_BOARD=ai-stack
kanban() { hermes kanban --board "$KANBAN_BOARD" "$@"; }
