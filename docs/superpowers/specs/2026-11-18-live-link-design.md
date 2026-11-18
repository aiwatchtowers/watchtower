# Live link — the phone talks to its tower over the socket, replication stays underneath

**Board:** #1992. **Research:** [2026-11-18-relay-latency-research.md](2026-11-18-relay-latency-research.md) (approved, ask #1526).
**Notes:** `docs/features/go-hub.md`, `docs/features/relay-client.md`, `docs/features/mobile-companion.md`; relay contract
in the relay repository (`proto/relay/v1/relay.proto`, design `docs/superpowers/specs/2026-10-28-relay-design.md`).

## Why

Every phone ↔ tower exchange today is replication: the phone writes a record into its mailbox zone, the hub reads it,
applies it, writes an echo, re-publishes slice records, and the phone reads them back — five storage round trips and
an HTTPS request for each (the phone sends every op over HTTPS, the socket only carries change notices). After the
app wakes, a socket iOS killed is not noticed for up to 40 s and every first op pays a new TLS handshake. The owner:
creating a target "takes long", waking the app should sync "at once, not in seconds" — the whole thing must feel
instant (ask #1526).

## Goal

| Measure (good network, tower online) | Today (live install, see research) | Target |
|---|---|---|
| tap → change visible on the phone | seconds (p50 several s) | p50 ≤ 300 ms, p90 ≤ 800 ms |
| app becomes active → replica fresh | up to 40–60 s with a dead socket | p50 ≤ 700 ms, p90 ≤ 1.5 s |
| Mac-side change → visible on an open phone | seconds | p50 ≤ 300 ms |

## Two modes

1. **Live** — while the phone's app is active and both it and the tower hold a relay socket: sealed frames go
   device → relay → device, nothing stored. Actions, their results and slice changes travel this way.
2. **Replication** — the zones as today. Always on: it is the durable copy, the offline path, the background (push)
   path, and the only path for CloudKit towers and phones without a relay subscription.

Live is an accelerator over replication, never a replacement: anything sent live is also written to its zone, so a
lost frame costs speed, never data.

## Design

### R1. Relay: a direct frame (relay repository change)

- New op `Direct { to_device, payload ≤ 64 KiB }` → answer `DirectResult { delivered }`; new event
  `Direct { from_device, payload }` on the recipient's socket.
- Allowed only between a phone and a Mac in one of its slots (the relay already knows the pairs: slots and hub
  readers); anything else `FORBIDDEN`. `delivered = false` (`PEER_OFFLINE`-like, not an error) when the recipient
  holds no socket. Nothing is stored; no push is sent for it.
- Counts against the device's 50 ops/s like any op. The payload is opaque (sealed by the devices).
- Implementation: the sender's device Durable Object forwards to the recipient's device DO, which writes to its
  socket. Advertised through a protocol capability in `HelloOk`; a client that does not see it stays replication-only.

### R2. Ops over the socket

Phone and hub send every op over the open socket (`HostedRelayConnection.send` already exists) and fall back to HTTPS
only without one. No TLS handshake per op, one connection to keep warm.

### R3. Live frames

Sealed by `secure.Sealer` (Go) / `SecureTransport` (Kit) with the current epoch's pair keys, as a new envelope kind
`live`. **Replay:** each live session has a random 128-bit `live_session` id the phone picks for its `hello` and the
hub echoes in `welcome`; every frame's authenticated data is `sender ‖ recipient ‖ live_session ‖ direction ‖ counter`,
the counter grows by one per frame and direction. A frame whose `live_session` is not the receiver's current one, or
whose counter is not above the last one accepted, is dropped. A frame from an earlier session therefore never
verifies in a later one, although the epoch key is the same. Frame kinds:

| Frame | From | Content |
|---|---|---|
| `action` | phone | the exact sealed action the mailbox gets (same action id and `action_seq`) |
| `result` | hub | action id, outcome (`applied` / `refused` / `held`), and the slice records the apply changed |
| `records` | hub | slice records (name, kind, payload, `pub_seq`), chunked to fit 64 KiB |
| `hello` | phone | `live_session`, the hub `generation` and highest `pub_seq` it has from this hub, its live protocol version |
| `welcome` | hub | `live_session`, the hub's `generation` and current `pub_seq` (sent after the catch-up `records`) |
| `keepalive` / `bye` | phone | every 20 s while the app is active / when it resigns active (best effort) |

### R4. Actions: write-through

The phone sends the `action` frame and, in parallel, saves the same record into its mailbox as today. The hub applies
whichever copy it reads first through the one `actions.Processor` (ledger exactly-once by `action_seq`); the second
copy is a duplicate and settles as today. Right after the apply commits the hub sends `result` with the changed
records of the nudged kinds, before any echo is written. The phone applies them to its replica at once and drops the
pending row. No `result` within 1.5 s → the phone keeps the "Waiting for your Mac" chip as today and replication
finishes the job. The 1.5 s is a starting value (a named constant), tuned from R9's `live_ms` numbers.

Ops per action: a live action costs two phone ops (the `Direct` and the mailbox `Save`) instead of one. The hub's
side is unchanged (its `result` replaces nothing: one `Direct` per phone). At tap rates (a few per second at most)
that stays far under the relay's 50 ops/s per device.

The hub handles `Direct` events on their own lane, not queued behind the backstop pass, link upkeep or housekeeping;
the lane holds the processor only for the apply transaction.

### R5. Live slice push

Every publish cycle hands each changed record to the live fan-out before its `Save`: phones with a live session get
it as a `records` frame. A phone's live session is open from its `hello` until a `bye`, a `Direct` answered
`delivered = false`, or 45 s without any frame from it (it sends `keepalive` every 20 s while active) — so a socket
iOS killed while the relay still counts it open stops the fan-out within 45 s. A frame sent into such a socket is
lost harmlessly: replication carries the same record. So a change made on the Mac,
by an agent or by another phone reaches an open phone without waiting for the save and the read.

### R6. `pub_seq` — which copy wins

The hub stamps each published record with `(generation, pub_seq)`: `generation` is a random id created together with
the sidecar (a new one whenever the sidecar is created anew, e.g. lost or reset), `pub_seq` a counter that only grows
within a generation (kept in the sidecar, survives restarts and transport switches). The sealed slice payload carries
both on both paths. The phone keeps the pair per record and per hub:

- same `generation`: apply only a higher `pub_seq`; equal = same content;
- a different `generation` (from `welcome` or from any record): the hub was reset — the phone forgets every stored
  `pub_seq` of that hub, adopts the new generation and applies the record; the full catch-up that follows (its `hello`
  carried the old generation, so the hub sends everything) overwrites the rest;
- a record with no `pub_seq` (an old hub): applied as today, by replication order; such a hub never answers `hello`,
  so no live record competes with it. Writers of a phone's replica row: the live path and the replication path, both fed by the one hub
publisher; the higher `pub_seq` wins, whichever path brings it.

### R7. Wake

When the app becomes active:

1. The screens render from the local replica at once (as today).
2. The socket is pinged; if no pong comes within 300 ms a second socket is dialled in parallel and whichever is
   ready first carries on (the other is closed). A slow network therefore costs at most one extra dial, never a
   wait. The session token is reused while valid (login only on `UNAUTHENTICATED`). 300 ms is a starting value
   (named constant), tuned from R9's `wake_ms`.
3. The phone sends `hello` to each of its relay towers; each answers with `records` for every record with a higher
   `pub_seq` (current kinds first: asks, sessions, Now), then `welcome`.
4. In parallel the replication catch-up reads its zones over the socket, as today.

A tower that is offline or on CloudKit answers nothing: the phone stays on replication and shows the existing
freshness line.

### R8. Towers

Each tower (Mac or headless server, up to 4 per phone) is its own live peer over the phone's one socket. CloudKit
towers have no live mode. Nothing changes for phones without a relay subscription.

### R9. Measurements

`hub diagnostics` gains `live_result` (direct frame read → result sent) and `live_fanout` (record changed → frame
sent); the phone's latency rows gain `live_ms` (action sent → result applied) and `wake_ms` (became active →
`welcome` applied). No screen changes in this spec: the numbers are read with `hub diagnostics` and in the phone's
log.

## Failure paths

| Case | What happens | Test |
|---|---|---|
| Hub gets `action`, dies before apply | the mailbox copy is applied after restart; the phone shows the waiting chip until then | hub restart between read and apply |
| Hub applies, `result` lost (socket drops) | the echo and slice arrive by replication; ledger has it once | drop the socket after apply |
| Both copies arrive | second one is a duplicate, one ledger row | both orders |
| Live record older than the replicated one | lower `pub_seq` ignored | out-of-order delivery |
| Socket dies mid catch-up | records applied so far stay (each atomic); redial sends `hello` again | cut after N frames |
| Hub restarts | `generation` and `pub_seq` read back from the sidecar; nothing changes for the phone | restart |
| Sidecar lost or reset | new `generation`; the phone drops that hub's stored `pub_seq`s, takes the full catch-up and every later record with the low new numbers | wiped sidecar: catch-up applied, then a new record with `pub_seq` 1 applied |
| A frame replayed from an earlier live session | `live_session` differs → dropped | replay across sessions; replay within a session |
| Phone socket dead, relay still counts it open | live session closes after 45 s without a frame; frames lost meanwhile come by replication | no keepalive for 45 s |
| New phone, old hub (no `pub_seq`, no `welcome`) | no live mode, records applied as today | old-hub fixture |
| Old phone, new hub | no `hello` → no live; the extra payload fields are ignored | old-phone decoder fixture |
| Relay without `Direct` | capability missing → replication only | old-relay stub |
| Epoch rotation mid-session | frames under the old epoch refused, the phone re-sends `hello` after it has the new keybox | rotate during a session |
| App backgrounded mid-send | write-through mailbox copy still goes out (or on the next foreground) | background during send |

## Out of scope (v1)

- Direct LAN connection (Bonjour) — the relay hop is tens of ms; revisit after R9's numbers.
- Live terminal streams.
- Screen changes (Diagnostics lines come with a separate spec and mockups).

## Rollout

The paths that change together: the relay (`Direct` + capability), the Go hub (`internal/hub/secure`, `slices`,
`actions`, `transport/relay`, sidecar migration for `generation`/`pub_seq`), the Kit (`WatchtowerRelayProto` re-pin,
`WatchtowerHostedRelay`, `WatchtowerSync` Secure/Replica/Relay) and the phone app (`HubSession` wake). Order:

1. Relay ships `Direct` behind the capability flag (no client uses it yet).
2. Hub ships `generation`/`pub_seq` in slices and answers `hello` (old phones ignore both).
3. Phone ships live mode; it turns on per tower only when the relay advertises the capability and the tower answers
   `welcome` with a live protocol version it knows.

Any mix of versions falls back to replication (failure table above).

## Contract changes (need the owner's approval)

- Relay protocol: the `Direct` op and event, the capability flag (relay repository; both clients re-pin the proto).
- Slice payload: `pub_seq` added (the phone and the hub must ship together; old phones ignore the field).
- The phone writes each action twice (live + mailbox) — double ops per action, inside the relay's limits.

## What happens to the research plan's stages

| Stage | Fate |
|---|---|
| 1 measurements | kept for the replication path; the live part is R9 |
| 2 hub fast path | the event lane is R4; nudge-before-flush, cycle pre-emption and the backoff fix — owner's call, ask #1527 |
| 3 runners on request | kept — a session report still needs its runner |
| 4 inline records | owner's call, ask #1527: still speeds the non-live path (background, CloudKit-free offline catch-up) |
| 5 foreground redial | part of R7 |
| 6 board overlay | owner's call, ask #1527: still needed when `result` does not come (offline tower, CloudKit) |
| 7 ordered actions skip the plain queue | kept (low) |
| 8 error storms | kept |

## Decisions

- Two modes: a live socket for the conversation, replication underneath — ask #1526 (owner's note).
- Wake must sync at once, not in seconds — ask #1526.
- Live rides the relay socket with a new `Direct` op rather than a new server or LAN — proposed by the agent, owner's
  answer pending in ask #1527.
- Write-through of actions (live + mailbox) — proposed by the agent, ask #1527.
- `(generation, pub_seq)` decides between the two copies — proposed by the agent, ask #1527.
- Fate of research stages 2, 4 and 6 — proposed by the agent, ask #1527.
- Replay bound to `live_session`; live session closes after 45 s without a frame — decided by the agent.
- 1.5 s result wait and 300 ms wake ping are starting values tuned from R9 — decided by the agent.
- Ops move onto the socket — decided by the agent.
- No screen changes in this spec — decided by the agent.
