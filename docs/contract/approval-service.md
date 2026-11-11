# Approval service: the channel-neutral interface

Core contract item 3: approvals and escalations go through one interface. A connected chat thread is one delivery
channel, the app inbox is another; channels are optional. This file and two schemas are the interface. There is no
service yet: nothing here is built or running.

## The two shapes

- **Request** (`.stella/schemas/approval-request.schema.json`): `id`, `requested_at`, `requester` (`role`, `channel`,
  `user`), `approval_class` (read, write, post, send, pay, delete, sign_in; the classes come from the connections
  catalog), `action` (what will happen), `summary` (plain words for the person deciding), optional `target`, `card`,
  `expires_at`.
- **Decision** (`.stella/schemas/approval-decision.schema.json`): `request_id`, `decided_at`, `decision` (`approved`,
  `denied` or `expired`), `decided_by` (`channel`, `user`), `note`.

Check a message with `python3 bin/stella_data.py validate approval-request <file>` (or `approval-decision`).

## Gate rules live once

Which requests need a decision (everything above class `read`; `sign_in` is an escalation), who may decide, and what
expiry means are defined in one place and read from data. A delivery channel never re-implements them. No secret value
is ever in a request, a decision or a delivery.

## What a delivery channel implements

1. **deliver(request)**: show the request to the owner in its own medium, with the summary and the class.
2. **collect()**: return decisions in the decision shape, each tied to a `request_id`; a reply that cannot be tied to one
   is ignored.
3. **identify**: prove the decider is the owner (for example by an owner id kept in owner settings); anyone else's reply is ignored.
4. **idempotent**: delivering the same request twice shows it once; a second decision for the same request is ignored.
5. **fail closed**: no decision before `expires_at` means `expired`, which is a denial. A channel that is down or
   unreadable raises its catalog code and decides nothing.

The first channel to implement this is the connected chat channel the stack uses today; the app inbox is the main one
later. Every request and decision is one event-log line (`.stella/schemas/event.schema.json`).
