#!/usr/bin/env bash
# host-cli channel adapter of the approval service (F1c D3; bin/approvals.py, .stella/channels.json). The host terminal answers
# with `bin/approvals.py answer <id> --decision approved|denied`, proved by the owner key, so this adapter only shows the request.
# deliver: the request JSON on stdin; shows on stderr the summary (control characters made spaces), the exact action (JSON) and
#          its digest, and how to answer; prints the message ref host-cli:<id>.   collect: prints nothing (no answer comes through it).
set -euo pipefail
jq() { env -u HOME jq "$@"; }   # RT-RTA-02: ~/.jq is worker-writable
case "${1:-}" in
  deliver) jq -r '"approval \(.id) for card \(.card): \(.summary | explode | map(if . < 32 or . == 127 then 32 else . end) | implode)\naction: \(.action | tojson)\ndigest: \(.digest)\nanswer on the host: bin/approvals.py answer \(.id) --decision approved|denied"' >&2 <<<"${r:=$(cat)}"
           printf 'host-cli:%s\n' "$(jq -r .id <<<"$r")";;
  collect) cat >/dev/null;;
  *) echo "usage: host-cli.sh deliver|collect" >&2; exit 2;;
esac
