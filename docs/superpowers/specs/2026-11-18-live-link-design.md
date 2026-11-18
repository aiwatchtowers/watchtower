# Live link — one write over the socket, the relay stores and delivers it in the same hop

**Board:** #1992 / #2002. **Research:** [2026-11-18-relay-latency-research.md](2026-11-18-relay-latency-research.md) (approved, ask #1526).
**Notes:** `docs/features/go-hub.md`, `docs/features/relay-client.md`, `docs/features/mobile-companion.md`; relay contract
in the relay repository (`proto/relay/v1/relay.proto`, design `docs/superpowers/specs/2026-10-28-relay-design.md`).

## Why

Every phone ↔ tower exchange is replication through relay zones, and the phone sends every op as its own HTTPS request
(the socket carries only change notices, `HostedRelayClient.post`). One action costs: phone save → notice → hub read →
apply → echo save → notice → phone read → slice save → notice → phone read. After the app wakes, a socket iOS killed
is not noticed for up to 40 s, and each first op pays a new TLS handshake. The owner: creating a target "takes long",
waking must sync "at once, not in seconds", the whole thing must feel instant (ask #1526).

## Is a socket enough for a responsive UI? (ask #1527)

No — alone it is not. What the owner feels is the sum of four parts, and the socket fixes only two:

| Part | Today | Fixed by |
|---|---|---|
| The phone shows the change only after the round trip | yes, for everything but answers | **R5 optimistic apply** — the change shows at tap time (0 ms) |
| Extra round trips (HTTPS per op, a `changes` read after every notice) | 2–4 per action | **R1 + R2** — ops over the socket, records delivered inside the event |
| The hub's own queue and handlers (`read_applied` p50 ~1 s on the live install) | ~1 s | **R4 hub event lane** — a socket does nothing for it |
| Relay hops (phone → Cloudflare edge → device DOs → peer) | not measured — the external probe has never run (`PROBE_URL_STAGING` unset in the relay repo) | **R7** measures it first; estimate 20–60 ms per one-way hop in one region |

Estimated after the change, good network, tower online: tap → visible **0 ms** (optimistic), tap → confirmed by the
tower ~150–300 ms (two one-way hops each way + apply). R7 runs before tuning anything, so the estimate is checked, not
trusted.

## Design

### R1. The relay multiplexes: one write, stored and delivered in the same hop (relay repository change)

The owner's format (ask #1527): a client writes once over its socket; the relay persists the write **and** pushes the
written records to every subscribed peer socket in the same step. Clients never send anything twice.

- Today `ZoneChanged` carries a record inline only when the save wrote exactly one record of ≤ 64 KiB. New: it
  carries **every record of the save** (`repeated Record records`), up to a 256 KiB frame budget; a save larger than
  that is split into several events by record, and only a single record over the budget goes without its body (the
  receiver reads it with `changes`, as today).
- The event goes out after the write is durable, so a delivered record is always a stored one: there is one copy of
  the truth, the zone, and one order, its `seq`. No second path, no tie-break between copies.
- Old field `record` kept for one release for old clients; a protocol capability in `HelloOk` tells a client the new
  field is there.
- No new op: "direct" is this delivery mode of the existing `save`.

### R2. Ops over the socket

Phone and hub send every op over the open socket (the relay already serves `Request` frames on it,
`worker/src/do/device/ws.ts`; the Kit has `HostedRelayConnection.send`) and use HTTPS only without a socket.

### R3. Receiving inline records

Both sides apply the records of an event without a read when the event continues their cursor (`seq` = token + count
of records, the same rule as the hub's `PullEvent` today, `relay/transport.go:736`); anything else is a `changes` read
of that zone, as today. The phone gains this path (today it ignores the inline record and always reads,
`HostedRelayTransport.swift:281-285`).

### R4. Hub event lane

Mailbox events are handled on their own lane, not queued behind the backstop pass, link upkeep or housekeeping in
`work()` (`runtime.go:731-772`); the lane holds the processor only for the apply transaction. Right after an apply
commits: the nudge (before the echo flush), and the echo + nudged slice kinds saved in one save where they share a
zone. A `PublishNow` arriving during a running cycle is taken between kinds instead of after the cycle.

### R5. Optimistic apply on the phone

At tap time the phone applies the action's expected effect to its replica as a **pending overlay** (a new target
appears, a moved card moves, an answered ask shows its answer), marked pending. The echo (mailbox zone) and the
slice records (data zone) are different zones and may arrive in either order, so the echo alone never clears an
overlay:

An overlay is dropped as soon as the **replica already shows the expected effect**, whichever of the echo and the
slice record came first:

- **Change of an existing entity** (move, status, priority, ask answer, comment on a target): the overlay is dropped
  when the replica's value equals the requested one (the status is `done`, the ask is no longer open, the comment
  with this action's `client_key` is listed). If the echo says `applied` but the replica's value differs (someone
  changed it again right after), the overlay is dropped at the first slice record of that entity after the echo, or
  30 s after the echo if none comes.
- **Create** (a new target): there is no id at tap time. The overlay is keyed by the action id; the `applied` echo
  carries the new `target_id` (`handlers/board.go:251` already returns it), and the overlay is dropped once the
  replica has a record for that id — at once if the slice came first. Before the echo, a replica target that appeared
  after the tap with the same title and parent hides the overlay (no duplicate card); the echo then confirms the
  match.
- echo refused / the action fails → the overlay is removed at once and the existing refusal line with Dismiss shows.
- no echo while the tower's heartbeat is stale → the caption turns to "Waiting for your tower"; after 10 min the
  overlay is dropped and today's pending row takes over (an offline tower).

Writers of what a screen shows: the overlay (phone) and the replica (hub's records); the replica wins as soon as it
shows the expected effect, or, for an applied action whose effect was overtaken, at its next record of that entity.

**How it looks** — [2026-11-18-live-link-mockups.html](2026-11-18-live-link-mockups.html), one frame per state: new
task just tapped, card moved and waiting for its slice, confirmed, tower slow/offline, refused, ask answered. The
change shows in place on the existing card; the captions are today's strings in `BoardWriteModel` ("Sending…",
"Waiting for your tower", "Your tower could not make this change"), tones as today. No new strings; the overlay's
caption choice lives in the model and is covered by its tests.

Kinds covered in v1: board create / move / priority / status, ask answer (today's `AppliedAnswer` folds into it),
comment. Other kinds keep today's chip.

### R6. Wake

When the app becomes active:

1. Screens render from the local replica at once (as today).
2. The socket is pinged; if no pong comes within 300 ms a second socket is dialled in parallel and whichever is ready
   first carries on (the other is closed): a slow network costs at most an extra dial, never a wait. The session
   token is reused while valid. 300 ms is a starting value (named constant), tuned from R7's `wake_ms`.
3. The `changes` reads of all its zones go out at once over that socket, pipelined, current kinds' zones first.

### R7. Measurements first

- Turn the relay's external probe on for staging (set `PROBE_URL_STAGING`) and run `relayprobe` from the Mac's network
  for a day: one-way delivery p50/p90 for `data` and `mailbox`.
- Hub: `nudge_saved` (cycle end for a nudged kind, written or not), `event_read` (event arrival → mailbox read),
  per-record `readAt`, by action kind, in `hub diagnostics`.
- Phone: `wake_ms` (became active → all zones read) and `confirm_ms` (tap → echo applied) next to the existing
  `answer_ms`/`result_ms`, in the phone's latency rows and log. No screen changes.

### R8. Towers

Each tower (Mac or headless server, up to 4 per phone) is its own set of zones over the phone's one socket. CloudKit
towers keep replication as it is, plus R5 (optimistic apply works on any transport).

## Failure paths

| Case | What happens | Test |
|---|---|---|
| Socket drops after the save is sent, before its answer | the save is resent with its precondition; a conflict with its own record is success (as today) | drop between send and answer |
| Event with inline records lost (socket died) | the next event or the wake read finds a gap and reads `changes` | gap after a lost event |
| Event arrives before the save's answer | records applied by `seq`; the answer then only confirms | event-before-answer order |
| Hub dies after reading the action, before apply | applied after restart from the mailbox (exactly-once ledger); the phone's overlay stays pending meanwhile | restart between read and apply |
| Action refused by the hub | overlay removed, refusal line shown | refused echo |
| Echo arrives before the slice record | overlay kept until the replica shows the effect; no flicker back | echo-then-slice |
| Slice record arrives before the echo | overlay dropped at once when the replica shows the effect | slice-then-echo (no 30 s wait) |
| Create: slice before echo | the new card replaces the overlay by title and parent; the echo's `target_id` confirms | create, slice-then-echo; no duplicate card |
| Create: echo before slice | overlay kept until the replica has the echo's `target_id` | create, echo-then-slice |
| Effect overtaken by another change | overlay dropped at the entity's next record after the echo | concurrent Mac change |
| Echo applied, effect never visible | overlay dropped 30 s after the echo | no-op apply |
| Tower offline for long | overlay dropped after 10 min, waiting chip stays; the action applies when the tower is back | 10-min expiry |
| Save larger than the frame budget | split by record; an oversized record has no body, receiver reads it | 300 KiB save; one 300 KiB record |
| Old relay (no capability) | single-record inline only, as today; everything still works | old-relay stub |
| Old phone, new relay | reads the old `record` field, as today | old-client fixture |
| App backgrounded mid-wake read | the next wake reads from the stored cursor | background during read |

## Rollout

Paths that change together: relay (`ZoneChanged.records`, capability), Go hub (`internal/hub/transport/relay`,
`actions`, `slices`, `runtime`), Kit (`WatchtowerRelayProto` re-pin, `WatchtowerHostedRelay`, `WatchtowerSync`
Replica/Relay), phone app (`HubSession` wake, overlays). Order: relay (R1, R2 already works) → hub (R3, R4) → phone
(R2, R3, R5, R6). Each side checks the capability; any mix of versions works at today's speed.

## Out of scope (v1)

- Direct LAN connection (Bonjour) — revisit after R7's numbers.
- Ephemeral (unstored) frames — nothing in v1 needs them.
- Live terminal streams. Screen changes beyond the overlays on existing screens (mockups linked in R5).

## What happens to the research plan's stages (ask #1527: "Да, так")

| Stage | Fate |
|---|---|
| 1 measurements | R7 |
| 2 hub fast path | R4 keeps the event lane, the early nudge and the in-cycle `PublishNow`; the rest dropped |
| 3 runners on request | kept, separate target |
| 4 inline records | dropped as a separate stage; its effect is R1 + R3 |
| 5 foreground redial | R6 |
| 6 board overlay | dropped as a separate stage; R5 is the general version (see Decisions) |
| 7 ordered actions skip the plain queue | kept (low) |
| 8 error storms | kept |

## Decisions

- Two modes → one: a socket for every op, the relay delivers records in the same hop as it stores them — ask #1526
  (owner's note) and ask #1527 ("multiplexing inside the relay, clients don't send twice").
- Direct is needed, but as a delivery mode of the relay, not a separate client frame — ask #1527.
- Write-through by the client rejected — ask #1527.
- `pub_seq` approved in ask #1527, **dropped by the agent** in this revision: with one path (the zone, ordered by
  `seq`) there are no two copies to decide between. Pending the owner's confirmation in the review ask.
- Stages 1, 3, 7, 8 kept, 2, 4, 6 closed, 5 into wake — ask #1527.
- R5 optimistic apply — decided by the agent (it is what makes a tap feel instant; the owner closed stage 6 under the
  assumption that live results replace it). Pending the owner's confirmation in the review ask.
- Frame budget 256 KiB, 300 ms wake ping, 10-min overlay expiry — decided by the agent, starting values tuned from R7.
