# Live link — one write over the socket, delivered in the same hop (2026-11-18, board #1992 / #2002)

**Spec:** [2026-11-18-live-link-design.md](../superpowers/specs/2026-11-18-live-link-design.md) (approved, ask #1535).
**Research:** [2026-11-18-relay-latency-research.md](../superpowers/specs/2026-11-18-relay-latency-research.md).
**Plan:** [2026-11-18-live-link.md](../superpowers/plans/2026-11-18-live-link.md). Umbrella branch `feature/live-link`.

## What it is

A tap on the phone (a new target, a status or priority change, a comment, an ask answer) used to cost a chain of
HTTPS requests and change-notice reads before the phone showed it: phone save → notice → hub read → apply → echo save
→ notice → phone read → slice save → notice → phone read. The live link cuts that chain in four places:

| Part | What changed | Where |
|---|---|---|
| R1 | The relay pushes every record of a save inside the `ZoneChanged` event it sends after the write is durable | relay repository (PR #10, `771a99e`) |
| R2 | Phone and hub send every op over the open socket; HTTPS only without one | `internal/hub/transport/relay`, `HostedRelaySession.send` |
| R3 | A receiver applies the event's records without a `changes` read when they continue its cursor | hub: `relay.Transport` `PullEvent`; phone: Task 8 (see below) |
| R4 | The hub handles mailbox events on their own lane, nudges slices before writing echoes, takes a `PublishNow` between a running cycle's kinds | `internal/hub/runtime.go` `eventLane`, `actions`, `slices` |
| R5 | The phone shows the change at tap time as a pending overlay until the replica shows it | `WatchtowerMobile` `PendingOverlay.swift` (`OverlayBook`) |
| R6 | On wake the socket is pinged; a silent one is retired at once and redialled in the background | `HostedRelayConnection.wake()` |
| R7 | New timings: hub `event_read`, `nudge_saved`, per-kind rows; phone `wake_ms`, `confirm_ms` | `internal/hub/measure`, `ReplicaStore+Latency.swift` |

R8 (towers): each tower is its own set of zones over the phone's one socket; a CloudKit tower keeps replication as it
is and gets R5 too (the overlay does not depend on the transport).

## The parts as built

### R1 — inline records (relay)

`ZoneChanged.records` carries every record of a save, up to a 256 KiB framed budget; a larger save is split by record
into several events, and only a single record over the budget goes without its body (the receiver reads it with
`changes`). The event goes out after the write is durable, so a delivered record is always a stored one: one copy of
the truth (the zone) and one order (its `seq`). The old single `record` field stays for old clients;
`HelloOk.capabilities` lists `records_inline`. The hub's vendored client and the generated proto are pinned to relay
`771a99e` (`internal/hub/transport/relay/VERSION`); the Kit's proto pin is a Task 8 matter (below). Details:
[go-hub.md](go-hub.md) (`relaytest`, the hub's R3 rule).

### R2 — ops over the socket

- **Hub** (`relay.Transport.send`): once `Connect` opened the WebSocket every op goes over it; HTTPS before `Connect`,
  after `Close`, for a request the socket refused before writing it (`client.ErrNotSent`) and after `UNAUTHENTICATED`.
  A socket lost after the frame went out leaves the outcome unknown: reads and all-conditional saves/deletes are sent
  again over HTTPS (a landed item comes back as a conflict on the hub's own record); any other op returns
  `transport.ErrUnavailable` and its caller re-reads. An op unanswered for 30 s (`socketOpTimeout`) counts as unknown.
  See [go-hub.md](go-hub.md), "Relay ops over the open socket".
- **Phone** (`HostedRelaySession.send`): `changes`, `save`, `delete`, `create_upload`, `get_download` and every
  `get_account_state` go as `Request` frames on the device's socket; `register`, `challenge`, `login` and `vouch_hub`
  stay HTTPS. The same resend rule as the hub. See [relay-client.md](relay-client.md), "Ops over the socket".

### R3 — applying inline records

- **Hub:** an event whose records run without a gap from the first seq after the token that is not the hub's own up
  to the event's seq is applied as one page (own and already-read records left out), then the token moves; anything
  else (a gap, no records, the resync marker, a zone never read) is a `Pull`. The hub does not look at the capability:
  an event without records reads, whichever relay sent it.
- **Phone:** the Kit's proto is pinned to `771a99e` too. `HostedRelayTransport+Pull.swift` applies an event's records
  without a `changes` read when they cover every seq after the zone cursor up to the event's seq (the hub's covering
  rule), no pull is in flight, no resync is owed and no record carries an attachment or is a deletion; the page goes
  through `bufferRelayPage` like a read. An event at the cursor does nothing; one below it, a gap, a record-less event
  (a phone over its traffic budget, an overflowed event buffer) or cursor 0 is a read. A session owner holds at most
  1 MiB of unread records (framed size); past that its events carry no records and it reads. v1 limit: the connection's
  event buffer is capped by count (256), not bytes.

### R4 — the hub's event lane

The runtime's `eventLane` goroutine runs a mailbox zone's `PassEvent` at once instead of queueing it behind the
backstop pass, link upkeep and housekeeping in `work()`; it also sets the relay's reachability from every event in
arrival order. The processor's locks are split per mailbox (`boxLock`), per control queue (`flushLock`), with
`Processor.mu` held only while a page's records are applied. A pass nudges the slice kinds it applied (`PublishNow`)
before it writes the queued echoes, so the slices' save starts ahead of the applied echo's. A `PublishNow` arriving
while a publisher cycle runs is taken between its kinds. The spec's "echo and slices in one save where they share a
zone" never applies on the relay (echoes go to the mailbox zone, slices to the data zone), so each is its own save.
Full lock order and limits: [go-hub.md](go-hub.md), "Mailbox events on their own lane".

### R5 — optimistic apply on the phone

`OverlayBook` (one per `HubSession`, in memory) holds a `PendingOverlay` per tap, keyed by the action id. Written by
`BoardWriter` and `AskAnswerer` at tap time and by the outbox's echoes; every replica snapshot passes through
`reconcile`, which drops what the replica already shows. Kinds in v1: board create (top-level targets as a card in
their lane; a sub-target's create stays a pending row), status, priority, comment and reply, ask answer. Other
kinds keep today's chip.

**Writers and the winner of what a screen shows.** Two writers: the overlay (the phone, at tap time) and the replica
(the hub's records). The replica wins as soon as it shows the expected effect, whichever of the echo (mailbox zone)
and the slice record (data zone) came first; the echo alone never clears an overlay.

| Case | Overlay goes when |
|---|---|
| Change of an existing entity | the replica's value equals the requested one |
| Applied, but the value differs (overtaken) | the entity's next record after the echo, or 30 s after the echo (`appliedWait`) |
| Create / comment, slice first | a record with the same title and parent (body and target) newer than the tap hides it; the echo's `target_id` / `comment_id` confirms the match |
| Create / comment, echo first | the replica has a record with the echo's id |
| Refused echo, or the save threw | at once; today's refusal line with Dismiss shows |
| No echo | caption "Waiting for your tower" while the heartbeat is stale; after 10 min (`expiry`) the overlay goes and today's pending row takes over |

Writes to one field (a target's status or priority, an ask's answer) are kept in tap order: the newest is shown, only
the oldest is judged against the replica, and a newer write is never cleared while an older one is unsettled (so a
reversal tap cannot flicker back). The captions are today's `BoardWriteText` strings ("Sending…", "Waiting for your
tower", "Your tower could not make this change"); no new strings. Mockups:
[2026-11-18-live-link-mockups.html](../superpowers/specs/2026-11-18-live-link-mockups.html).

### R6 — wake

On the return to the foreground the screens render from the replica at once, then the fetch calls
`LiveTransport.wake()` (a no-op on CloudKit): the live socket is pinged with a 300 ms deadline (`wakePingDeadline`).
A pong keeps it. With no pong the socket is retired at once (its waiters fail as lost, new requests go over HTTPS),
the wake returns and the zone reads go out over HTTPS while a second socket is dialled in the background. The redial
is registered before the old socket ends, so the relay's 1001 close of the old socket is a handover (no
`disconnected`, no backoff). A wake during a reconnect backoff cuts it and dials now. The pull starts the data zone's
read first, then the rest, concurrently. Details: [relay-client.md](relay-client.md), "Wake (live link R6)".

### R7 — measurements

- **Hub** (`hub diagnostics`, sidecar `latency_samples`, migration `00018_latency_steps`): `event_read` (event arrival →
  the start of the read it triggers; the hub's own echoes are not timed), `nudge_saved` (apply → the end of the first
  publisher cycle that handled the nudged kind, written or not), `read_applied` per record, and a `kind` column: the
  all-kinds row first, then one row per action kind.
- **Phone** (replica): `latency_wake` (`wake_ms`, became active → every zone read, one row per activation) and
  `latency_confirm` (`confirm_ms`, tap → applied echo, per action kind), next to `answer_ms`/`result_ms`; also in the
  log. Nothing leaves the device; no screen shows them.
- The relay's external probe on staging (spec R7, Task 2) was dropped by the owner; relay latency is judged from the
  hub and phone samples and the stand run below.

## Failure behaviour

| Case | What happens |
|---|---|
| Socket drops after the save is sent, before its answer | conditional saves are resent over HTTPS; a conflict with the own record is success. Unconditional ops return unavailable and the caller re-reads |
| Event with inline records lost | the next event or the wake read finds a gap and reads `changes` |
| Event arrives before the save's answer | records applied by `seq`; the answer then only confirms |
| Hub dies between reading and applying an action | applied after restart from the mailbox (exactly-once ledger); the overlay stays pending meanwhile |
| Save larger than 256 KiB | split by record; a single oversized record goes bare and is read with `changes` |
| Old relay (no `records_inline`) | single-record inline only, as before; everything works at the old speed |
| Old phone, new relay | reads the old `record` field |
| Socket silent at wake | retired at once; reads over HTTPS; background redial hands over |
| App backgrounded mid-wake | the fetch and its pull are cancelled; the next wake reads from the stored cursor |
| Tower offline | the overlay waits ("Waiting for your tower"), goes after 10 min; the action applies when the tower is back |

## Stand numbers (local relay stand, `wrangler dev`)

Measured 2026-11-18 on the feature branch with the relay at `771a99e`, one Go phone and the hub on one Mac
(`make relay-interop RELAY=<relay checkout> RELAY_INTEROP_RUN='^TestMeasure_'`, 200 actions back to back):

| Step (relay) | p50 | p90 | Samples |
|---|---|---|---|
| `read_applied` | 0 ms | 1 ms | 200 |
| `event_read` | 0 ms | 0 ms | 376 |
| `applied_saved` | 20 ms | 175 ms | 200 |
| `nudge_saved` | 20 ms | 175 ms | 200 |
| `read_saved` | 21 ms | 175 ms | 200 |

Before the live link the same run gave `read_saved` p50 71 ms, p90 140 ms (Task 7, ops over HTTPS). Every op went
over the socket: 4.72 relay ops per action (`ws:save` 2.29, `ws:changes` 1.82, `ws:get_account_state` 0.30,
`ws:set_hub_readers` 0.30), none over HTTPS. The p90 is the same as before the live link: origin/main on the same machine and relay
gave `read_saved` p50 104 ms, p90 178 ms (the 140 ms above is a different run under other load). The run's
FORBIDDEN refusals (about one `save` and one `changes` per second) are link upkeep rewriting the keyboxes of a
pairing slot the phone's `add_slot` already closed (`PublishPairKeyboxes`, up to `pairSlotLifetime`, every
`linkEvery`, 1 s in the test, 1 min in production); main shows the same, and they are off the action path. The Kit phone against the Go hub (`RELAY_INTEROP_CI=1 make relay-interop-kit-hub`): the farewell action was
applied 35–80 ms after the phone began to send it. The relay indicator outage run (`RELAY_INTEROP_RESTART_PAUSE=75`)
still turns `unavailable` at 60 s and `connected` again once the stand is back.

These are loopback numbers: they show the hub's own share, not the Cloudflare hops. The live-install comparison
(`hub diagnostics` `event_read` / `nudge_saved` / `read_saved`, the phone's `wake_ms` / `confirm_ms` against the
150–300 ms tap → confirmed goal) is an owner hand-off after release; a missed goal gets a follow-up target.

## v1 limits

- The overlay book is in memory: a relaunch starts empty and today's pending rows show until the replica catches up.
- A sub-target's create shows as a pending row under its parent, not as a card (the parent's tree is the Mac's).
- The daily `Hygiene` holds every hub pass, the event lane's included, while it runs.
- `Hygiene` and the CloudKit `RelayZone` read stay serialised; a claim's `received` echo is written under
  `Processor.mu`.
- Direct LAN (Bonjour), ephemeral frames and live terminal streams are out of scope (spec, "Out of scope").
- Spec R6's first wording (a second socket dialled in parallel, first ready wins) was simplified during the
  implementation: a silent socket is retired at once and redialled in the background (spec Decisions).

Parked review findings (minor, recorded in the run's ledger, none user-visible):

- Relay: `overCap` re-walks a save's records (bounded by 8 changes / 1 MiB).
- Hub: a definitive error racing the socket op deadline is reported as unknown (resendable ops go over HTTPS, others
  re-read); a mailbox's queue lock may wait past 30 s, bounded by the holding pass.
- Hub: two local changes sit on the vendored relay client and must be put back after a re-pin (`Conn.Connected`, the
  non-200 rule of `post`, #1872 → upstreaming follow-up #2020).
- Kit: a stalled socket close keeps the retired generation's waiters until it ends; a writer queued after `close()`
  may still send although its caller got `.lost`; the `mayUpgrade` guard (a late socket after a cancelled redial) is
  defensive and not covered by a test.
- Tests: two relay-wiring test hygiene items (an await after a bounded loop, an unbounded poll), a test-only hang on
  a failing setup in the wake tests, and a real-clock `created_at` in the phone's demo session seed.
