#!/usr/bin/env bash
# Discord channel adapter of the approval service (F1c D3; bin/approvals.py, .stella/channels.json), over the stack's own Discord
# helper (its discord_action: Hermes's token loader; the token never leaves that process), whose path the channels row gives.
# One thread per request in the channel whose id the owner config key KEY holds; the thread id is the message ref, so an answer counts
# only inside its request's thread, and only from the owner's id (owner_auth channel-identity, checked by approvals.py, never here).
# usage: <this file> deliver|collect KEY HELPER   (HELPER: the Discord helper, relative to the stack root)
# deliver: the request JSON on stdin (the nonce is never posted); opens the thread, posts the request in it (the exact action and
#   its digest, then the agent's summary), prints the thread id.
# collect: the pending requests delivered here on stdin ([{id, nonce, message_ref}]); in each thread, every human message whose
#   first word is approve/approved/yes or deny/denied/no is one answer line {request_id, nonce, decision, user, message_ref}, oldest
#   first; anything else is no answer. A thread that cannot be read is named on stderr and makes the exit 1; the others still count.
set -uo pipefail
me=${0##*/} card=""
usage() { echo "$me: usage deliver|collect KEY HELPER (KEY: the owner config key of the channel id, set; HELPER: under the stack root)" >&2; exit 2; }
[[ ${2:-} =~ ^[A-Z][A-Z0-9_]*$ && ${3:-} =~ ^[A-Za-z0-9_][A-Za-z0-9_./-]*$ && /${3:-}/ != */../* ]] || usage
. "$(dirname "${BASH_SOURCE[0]}")/../../$3" || exit 1
ch=${!2:-}; [ -n "$ch" ] || usage
case $1 in
  deliver)
    r=$(cat)
    res=$(discord_action create_thread "$ch" "$(name100 "$(jq -r '"Approval \(.id) · \(.summary)"' <<<"$r")")")
    th=$(jq -r '.thread_id // empty' <<<"$res" 2>/dev/null)
    [ -n "$th" ] || { echo "$me: create_thread failed: $(jq -r '.error // "no thread id"' <<<"$res" 2>/dev/null | head -c 300)" >&2; exit 1; }
    # the exact action (JSON: op, target, new or new_digest, masked by approvals.py) and the digest first; the agent's summary
    # last, short enough that the post fits one message; approvals.py for_owner() already masked every field and made each control,
    # bidi control and line separator ?, so no text in it can forge an Action line or reorder one
    res=$(discord_action send_message "$th" "$(jq -r '"Approval \(.id) for card \(.card) (class \(.approval_class))\nAction: \(.action | tojson)\nDigest: \(.digest)\nExpires: \(.expires_at)\nThe agent says: \(.summary[:300])\nReply in this thread with approve or deny."' <<<"$r")")
    jq -e '.success' <<<"$res" >/dev/null 2>&1 || { echo "$me: send_message failed: $(jq -r '.error // "no answer"' <<<"$res" 2>/dev/null | head -c 300)" >&2; exit 1; }
    echo "$th";;
  collect)
    fail=0
    while IFS= read -r p; do
      ref=$(jq -r .message_ref <<<"$p"); res=$(discord_action fetch_messages "$ref")
      jq -e '.messages | type == "array"' <<<"$res" >/dev/null 2>&1 || { echo "$me: thread $ref cannot be read: $(jq -r '.error // "no messages"' <<<"$res" 2>/dev/null | head -c 300)" >&2; fail=1; continue; }
      jq -c --argjson p "$p" '.messages | reverse | .[] | select((.author.bot // false) | not)
        | ((.content // "") | ascii_downcase | (capture("^\\s*(?<w>[a-z]+)") // {w: ""}).w) as $w
        | (if ($w | IN("approve", "approved", "yes")) then "approved" elif ($w | IN("deny", "denied", "no")) then "denied" else empty end) as $d
        | {request_id: $p.id, nonce: $p.nonce, decision: $d, user: ((.author.id // "") | tostring), message_ref: $p.message_ref}' <<<"$res"
    done < <(jq -c '.[]')
    exit $fail;;
  *) usage;;
esac
