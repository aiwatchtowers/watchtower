# Peer messaging round-trip (observed, Claude Code 2.1.295)

Redacted capture from throwaway `claude --model haiku` sessions on macOS (darwin, arm64), driven over a
pty in a scratch folder on 2026-10-10. Nothing here is copied from the CLI binary; the byte layout is
reproduced from what our own sessions sent and received. All ids, pids, uids and paths are placeholders.
Full findings: Appendix B of `docs/superpowers/specs/2026-10-10-session-background-agents-design.md`.
The ping is **not built** (ruling under ask #142, see spec §10); these fixtures record the protocol for a
future owner decision (board #481).

## Files

| File | What it is |
|---|---|
| `peer_request.bin` | What Watchtower sends: one newline-terminated JSON `user` frame, no `auth` line, no `from`. |
| `peer_response.bin` | The on-wire response on that connection: **empty (0 bytes)**. The inbox never writes back. |
| `peer_receipt_held.bin` | Not a response. A `peer_message_status` `held` control frame the receiver opens as a **separate** connection to a sender's `from` address. Captured from a `bypassPermissions` receiver. Watchtower sends no `from`, so it never receives one. |

## The request

Written to the receiver's `messagingSocketPath` (an `AF_UNIX` `SOCK_STREAM` socket named in its
session-registry entry), then the write side is closed. `msgV` is 1; `msg_id` a fresh UUIDv4; `priority`
`next` queues after the current turn (`now` jumps the queue). Every per-mode trial sent exactly this frame.

The receiver checks the connecting process's uid against its own (auth by token is required only on
Windows), wraps the content in a `<cross-session-message>` envelope, prepends a fixed "another Claude
session sent a message … no escalation" preamble, and queues it as a user turn.

## The acknowledgement

None on the wire. An accepted ping starts a turn; that turn's **Stop hook** carries the fresh
`background_tasks` snapshot — the signal Watchtower already consumes.

## Per-mode outcome (idle receiver, observed)

- `manual`, `acceptEdits`, `plan`, `auto`, `dontAsk`: accepted; turn + Stop; status `busy` → `idle`; no
  Notification; owner sees "Another Claude session sent a message: <text>".
- `bypassPermissions`: **held** (`no-mode-asserted`); no turn, no Stop; status → `waiting`; Notification
  "A message from another session needs your approval"; owner gets a Deny / Deliver prompt. Watchtower
  must not ping a session in this mode.

## Failure modes

- Dead socket → `connect()` fails `ECONNREFUSED`; a registry entry with a dead pid is caught first.
- Held / refused / dropped → no Stop within the window.
- Unknown `peerProtocol` / missing `peerFeatures` → version gate skips the ping.
