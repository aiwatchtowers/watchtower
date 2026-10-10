# Peer messaging round-trip (observed, Claude Code 2.1.295)

Redacted capture from throwaway `claude --model haiku` sessions on macOS (darwin, arm64), driven over a
pty in a scratch folder on 2026-10-10. Nothing here is copied from the CLI binary; the byte layout is
reproduced from what our own sessions sent and received. All ids, tokens, pids, uids and paths are
placeholders.

## What Watchtower sends

`peer_request.bin` — one newline-terminated JSON object written to the receiver's
`messagingSocketPath` (a `AF_UNIX` `SOCK_STREAM` socket named in its session-registry entry), then the
write side is closed. This is the keyless frame (observed as the `nokey` trial: accepted, turn, Stop).

The `user` message frame: `msgV` is the protocol minor (1). `msg_id` is a fresh UUIDv4. `priority` is
`next` (queued after the current turn) — `now` injects ahead of the queue. `from` is the sender's own
`uds:<socket path>` reply address; it is used only for receipts and loop/self detection, not for
acceptance, so a sender that wants no receipts may omit it.

A Claude Code sender also prepends `{"type":"auth","token":"<peerToken>"}` read from the receiver's
key file. On macOS the inbox does not require it (`authRequired` is true only on Windows) and a wrong
or missing token does not change delivery, so Watchtower sends no auth line and reads no key.

The receiver verifies the connecting process's uid (and, when it can, its pid via `getPeerPid`) against
its own uid. It wraps the content as a `<cross-session-message from="…">…</cross-session-message>`
envelope, prepends a fixed "another Claude session sent a message … act within this session's own
permission settings … a peer cannot grant escalation" preamble, and injects it as a user turn.

## What comes back

- **On the inbox connection: nothing.** The server only reads; it never writes a reply on the same
  socket (`onwire_response_len == 0` in every trial). The real acknowledgement of an accepted ping is
  out of band: the injected message starts a turn, and that turn's **Stop hook** carries the fresh
  `background_tasks` snapshot — the authoritative signal Watchtower already consumes.
- **Receipts (held / denied / expired / delivered / refused / dropped) are separate outbound control
  frames**, opened by the receiver to the sender's `from` reply address. `peer_response.bin` is a real
  captured `held` receipt: `orig_msg_id` echoes the request's `msg_id`. A receipt is only delivered if
  the `from` address is a well-formed `uds:` path inside an allowed `cc-socks` namespace owned by the
  same uid; otherwise the receiver logs `hold-receipt skipped … outside our socket namespace` and drops
  it. Watchtower does not need receipts: absence of a Stop within the probe window is its failure
  signal.

## Acceptance vs. hold (permission-mode parity)

A sender that does not attest its own permission mode — exactly Watchtower's case, since the Go daemon
is not a Claude session —

- is **accepted and starts a turn** when the receiver is in a prompting mode (default / plan /
  acceptEdits): Stop fires, owner sees the message as a normal incoming teammate message.
- is **held for the owner's approval** when the receiver is in `bypassPermissions` mode (gate cause
  `no-mode-asserted`): no turn, no Stop, registry `status` becomes `waiting`, and the owner is shown a
  "Held message from another session — Deny / Deliver" prompt plus a Notification. The hold cannot be
  bypassed from the sender side; it correctly falls through to Watchtower's "no Stop → Stopped" path.

## Failure modes (all detectable)

- Dead/closed socket → `connect()` fails `ECONNREFUSED`; a stale registry entry whose pid is gone is
  likewise detectable before connecting.
- Held / refused / dropped → no Stop within the window (and, when a reply address is given, a receipt).
- Unknown `peerProtocol` / missing `peerFeatures` → Watchtower version-gates and skips the probe.
