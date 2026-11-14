# Approval service: the channel-neutral interface

Core contract item 3: approvals and escalations go through one interface. A connected chat thread is one delivery
channel, the host terminal another, the app inbox a later one; channels are optional. Built in F1c (body B2, design D3):
`bin/approvals.py`, the channels file `.stella/channels.json` (index row `channels`, owner-only) and the adapters in
`bin/adapters/`.

## The two shapes

- **Request** (`.stella/schemas/approval-request.schema.json`): `id`, `requested_at`, `requester` (`role`, `channel`,
  `user`), `approval_class` (read, write, post, send, pay, delete, sign_in; the classes come from the connections
  catalog; host_ask is the host ask-first class of the voice entry), `action` (what will happen), `summary` (plain words
  for the person deciding), optional `target`, `card`, `expires_at`. From schema_version 3 (the store record): `action` is
  the exact action object `{op, target, old_digest, new_digest | new}`, `digest` its sha256 (`owner_auth.digest`),
  `nonce` (32 hex, single use), `status` (a note, never proof), `deliveries` {channel id: message ref}, `decision`,
  `ask` (global_id of the agent's ask line, or null).
- **Decision** (`.stella/schemas/approval-decision.schema.json`): `request_id`, `decided_at`, `decision` (`approved`,
  `denied` or `expired`), `decided_by` (`channel`, `user`), `note`; from schema_version 3 also `digest`, and
  `decided_by.user` holds the owner-auth provider ids that proved the answer (never a user id).

Check a message with `python3 bin/stella_data.py validate approval-request <file>` (or `approval-decision`).

## How it runs (host side only)

- A worker never runs `approvals.py` (every subcommand refuses in a worker environment, STL-CFG-312) and never reads or
  writes the store. It asks with `bin/event_untrusted.py append --type approval-ask --what <card> --detail '<JSON {class,
  action, summary, card}>'` and blocks its card with kind needs_input. Text in an ask is data, never an answer.
- `approvals.py intake` makes one request per ask (ttl: the channels file's `ask_ttl_s`) and delivers it on every enabled
  channel whose kind may answer. `request` makes one on the host (`--requester` names the asking profile).
- Store: `<approval_store>/requests/<id>.json`, written only by `approvals.py`, under the store's lock.
- Every request and every accepted decision is one trusted event line (`approval-request`, `approval-decision`). A request
  is approved or denied only by a decision line in `event_log.proof_lines()` that names it and its digest; never by the
  store's `status`, an untrusted line or a copied line. `status` and `wait` read that.
- On a decision the channels file's `resume` argv runs once with the card id and the decision word (shipped:
  `bin/adapters/kanban-resume.sh`, which unblocks the card).
- Expiry is a decision too (fail closed): the first host-side command that sees a pending request past `expires_at`
  (`intake`, `collect`, `deliver`, `answer`, `status`, `wait`) writes ONE trusted decision line `expired` (a denial) under
  the store's lock and runs `resume` once, so the card is never left blocked. A later answer is refused STL-OWN-822.

## Untrusted input

Every value `approvals.py` takes from outside the host is parsed by one rule: a line of the agents' stream (intake), the
`detail` of an ask, and a line an adapter prints (collect). The stream is opened through the event writer's opener (no
link, regular file only, without blocking: a FIFO is refused STL-CFG-318 at once). Each value must be text within the
writer's limits (`WRITE_MAX` bytes, `WRITE_DEPTH` nesting) that parses as JSON; any failure (not JSON, too large, too deep,
wrong shapes, an unexpected exception) costs that value only: it is reported with its code (a stream line: STL-CFG-318; an
ask: STL-OWN-829; an answer line: STL-OWN-830) and the next one is taken. Only a failure of the trusted log ends the run.

## Deciding an answer

An answer is `{request_id, nonce, decision: approved|denied, user, message_ref, digest?}`. The first failing check wins:

1. the channel's kind may answer: owner-auth policy `channel_kinds` true (a kind not listed answers nothing), STL-OWN-826.
   The kind named by the policy's `voice_host_confirmation` entry answers only when the entry is enabled, the request's
   requester is the entry's `profile`, its class is the entry's `action_class`, its ttl is at most `max_ttl_s` and the
   answer carries the request's digest (the details shown), else STL-OWN-827; `channel_kinds` cannot open it. The
   entry's `profile` is data: the shipped `stella-voice` is a placeholder until the voice profile exists (post-1.0).
2. the request exists (STL-OWN-820); 3. it is not decided (replay, STL-OWN-821); 4. not expired (STL-OWN-822);
5. the nonce is the request's (STL-OWN-823); 6. a digest, when given, is the request's (STL-OWN-824);
7. `message_ref` is the ref that channel was given at delivery (STL-OWN-825);
8. `owner_auth.require("channel_answer", ...)` passes with the channel-identity providers of that kind, bound to the stored
   ref (STL-OWN-828, owner_auth's own code in the message).

The host terminal answers with `approvals.py answer <id> --decision approved|denied` (kind: the channels file's
`host_kind`), proved by the owner key (`owner_write`; no key: STL-OWN-806).

## What a delivery channel implements

A row of `.stella/channels.json`: `{id, kind, deliver: [argv], collect: [argv], enabled, global_id, install_id}`; argv[0]
is relative to the stack root or absolute. A new channel, of a known kind or a new one, is a new row: no code change (a
new kind also needs its `channel_kinds` entry and a channel-identity provider in the owner-auth policy).

Every deliver, collect and resume runs with a fixed environment, never the caller's: `PATH` is the file's `env.path`
(absolute folders, in order; folders agents can write go last so they never shadow a system tool), and of the caller's
variables only those `env.pass` names and those the row's argv names (an owner config key such as the Discord channel id)
pass. A program planted on the caller's `PATH`, or `BASH_ENV`, never runs in an adapter (RT2-4).

1. **deliver**: the request on stdin (`id, nonce, summary, approval_class, card, target, expires_at, digest, action`; no
   secret); show it in the channel's own medium and print one message ref. Delivering the same request twice shows it once.
   The owner approves the exact action, never only the agent's words: a channel shows `action` (`{op, target, new}` or
   `{op, target, new_digest}`) and `digest` (the shipped adapters print the action as one line of JSON, then the agent's
   summary as one line). `new` is `***` when the target names a secret (its key matches a `redact_keys` pattern or is a
   secret setting of the registry; a whole-row target of a row with redact keys or a secret setting: a scalar value),
   inside an object the keys those patterns name are `***`, and the whole value is `***` when a value pattern of the
   connections catalog (`redaction_patterns`) matches any part of it, it is too long to check, or it cannot be judged.
   One rule covers all text shown to the owner (`for_owner()` in approvals.py, before anything reaches an adapter): the
   `summary`, `target`, and the action's `op`, `target` and `new` (object keys too) are `***` when a value pattern hides
   any part, and every control character (C0, DEL, C1), line or paragraph separator (U+2028/9) and bidi control
   (U+202A-202E, U+2066-2069) is `?`, so no field can draw a second line or reorder a value. Adapters print it as given.
   The store keeps the action unmasked; the digest is always over it.
2. **collect**: the pending requests delivered on this channel on stdin (`[{id, nonce, message_ref}]`); print one answer
   line per answer. Who answered is the channel's own user id; the owner check is the service's, never the adapter's.
3. **fail closed**: an adapter that fails, times out (`adapter_timeout_s`) or prints a line that is not an answer is
   STL-OWN-830 and decides nothing. No decision before `expires_at` means `expired`, which is a denial.

Shipped: `discord.sh` (one thread per request in the channel the owner config key names; the thread id is the ref; a
human message whose first word is approve/yes or deny/no is an answer), `host-cli.sh` (shows how to answer on the host;
collects nothing). The voice adapter (post-1.0, with the host operator) has the same shape: deliver speaks the details
and returns the utterance's ref; collect returns a confirmation as an answer that carries the request's digest, on a row
of the kind `voice_host_confirmation.channel_kind`.
