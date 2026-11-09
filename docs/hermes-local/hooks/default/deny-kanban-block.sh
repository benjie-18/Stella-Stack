#!/usr/bin/env bash
# Dispatcher role (D35, D46): a dispatcher never blocks a card; the worker blocks its own (pre_tool_call, exit 2 = block).
cat >/dev/null
printf '{"action": "block", "message": "Dispatchers do not block cards: the worker blocks its own card, and the #escalations thread follows automatically."}\n'
exit 2
