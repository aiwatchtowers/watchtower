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
`live`; replay is refused by a per-direction counter that restarts with each socket session. Frame kinds:

| Frame | From | Content |
|---|---|---|
| `action` | phone | the exact sealed action the mailbox gets (same action id and `action_seq`) |
| `result` | hub | action id, outcome (`applied` / `refused` / `held`), and the slice records the apply changed |
| `records` | hub | slice records (name, kind, payload, `pub_seq`), chunked to fit 64 KiB |
| `hello` | phone | the highest `pub_seq` it has from this hub |
| `welcome` | hub | the hub's current `pub_seq` (sent after the catch-up `records`) |

### R4. Actions: write-through

The phone sends the `action` frame and, in parallel, saves the same record into its mailbox as today. The hub applies
whichever copy it reads first through the one `actions.Processor` (ledger exactly-once by `action_seq`); the second
copy is a duplicate and settles as today. Right after the apply commits the hub sends `result` with the changed
records of the nudged kinds, before any echo is written. The phone applies them to its replica at once and drops the
pending row. No `result` within 1.5 s → the phone keeps the "Waiting for your Mac" chip as today and replication
finishes the job.

The hub handles `Direct` events on their own lane, not queued behind the backstop pass, link upkeep or housekeeping;
the lane holds the processor only for the apply transaction.

### R5. Live slice push

Every publish cycle hands each changed record to the live fan-out before its `Save`: phones with a live session (a
`hello` on the current socket session, last `Direct` delivered) get it as a `records` frame. So a change made on the Mac,
by an agent or by another phone reaches an open phone without waiting for the save and the read.

### R6. `pub_seq` — which copy wins

The hub stamps each published record with `pub_seq`, a counter of its own that only grows (kept in the sidecar,
survives restarts and transport switches). The sealed slice payload carries it on both paths. The phone keeps the
`pub_seq` per record and applies a record only when its `pub_seq` is higher than the one it holds; equal = same
content. Writers of a phone's replica row: the live path and the replication path, both fed by the one hub
publisher; the higher `pub_seq` wins, whichever path brings it.

### R7. Wake

When the app becomes active:

1. The screens render from the local replica at once (as today).
2. The socket is pinged with a 300 ms deadline; no pong → redial at once. The session token is reused while valid
   (login only on `UNAUTHENTICATED`).
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
| Hub restarts | `pub_seq` read back from the sidecar; a phone's `hello` above it (sidecar lost) gets a full catch-up | restart; wiped sidecar |
| Relay without `Direct` | capability missing → replication only | old-relay stub |
| Epoch rotation mid-session | frames under the old epoch refused, the phone re-sends `hello` after it has the new keybox | rotate during a session |
| App backgrounded mid-send | write-through mailbox copy still goes out (or on the next foreground) | background during send |

## Out of scope (v1)

- Direct LAN connection (Bonjour) — the relay hop is tens of ms; revisit after R9's numbers.
- Live terminal streams.
- Screen changes (Diagnostics lines come with a separate spec and mockups).

## Contract changes (need the owner's approval)

- Relay protocol: the `Direct` op and event, the capability flag (relay repository; both clients re-pin the proto).
- Slice payload: `pub_seq` added (the phone and the hub must ship together; old phones ignore the field).
- The phone writes each action twice (live + mailbox) — double ops per action, inside the relay's limits.

## What happens to the research plan's stages

| Stage | Fate |
|---|---|
| 1 measurements | kept for the replication path; the live part is R9 |
| 2 hub fast path | the event lane is R4; nudge-before-flush and the rest dropped |
| 3 runners on request | kept — a session report still needs its runner |
| 4 inline records | dropped — live records replace it |
| 5 foreground redial | part of R7 |
| 6 board overlay | dropped — `result` makes it moot |
| 7 ordered actions skip the plain queue | kept (low) |
| 8 error storms | kept |

## Decisions

- Two modes: a live socket for the conversation, replication underneath — ask #1526 (owner's note).
- Wake must sync at once, not in seconds — ask #1526.
- Live rides the relay socket with a new `Direct` op rather than a new server or LAN — decided by the agent.
- Write-through of actions (live + mailbox) — decided by the agent.
- `pub_seq` decides between the two copies — decided by the agent.
- Ops move onto the socket — decided by the agent.
- No screen changes in this spec — decided by the agent.
