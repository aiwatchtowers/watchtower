# Relay latency — research and speed-up plan

**Board:** #1992. **Status:** research done, plan waiting for the owner's go (no code changed yet).
**Notes read:** `docs/features/go-hub.md`, `docs/features/relay-client.md`, `docs/features/mobile-companion.md`.

## The question

The owner feels the hosted relay is about as slow as CloudKit. The relay itself is fast: the hub's own stand test
(`TestMeasure_HubLatencyOverTheStand`, go-hub.md "Relay ops per action") puts `read_saved` at p50 ~80 ms. A live
install's `hub diagnostics` shows `applied_saved`/`read_saved` far above that, seconds-level (the figures stay out
of this public repo; they are in the board ask). So the time is lost in our own
hub and phone code, not on the wire. This note says where, and what to change.

## The round trip, leg by leg

```
tap ─▶ phone write (1 HTTPS save) ─▶ relay ─▶ hub WS event ─▶ hub worker queue ─▶ mailbox read ─▶ handler + ledger tx
    ─▶ received/applied echo save ─▶ nudge ─▶ publish cycle ─▶ slice save ─▶ relay ─▶ phone WS event
    ─▶ phone HTTPS page read ─▶ ReplicaStore ─▶ UI
```

What the hub measures (`internal/hub/measure`): `read_applied` = page handed over → ledger commit;
`applied_saved` = commit → first save of a nudged kind that **wrote something**. Neither covers the phone legs, the
worker queue before the read, or the relay → phone leg. The phone's own `answer_ms`/`result_ms`
(`ReplicaStore+Latency.swift`) cover write start → echo handled / first matching slice indexed.

## Findings (largest first)

### Hub

1. **The `applied_saved` metric waits on runners, not on the publisher.** A sample resolves only on a save that
   wrote something (`slices/publisher.go:730-734`). Kinds fed by background runners — `session_report_request`,
   `session_chat_request`, `permission_answer`, `chat_turn`, and `session_input`/`session_start` via
   `terminal_session`/`session_timeline` (`handlers/nudge.go:30-72`) — republish an unchanged cache on the nudge, so the
   sample waits for the runner: `runnerMinimumGap` 5 s (`sources/runner.go:19`), report `StateSpacing`/`SummarySpacing`
   5 s, `Timeout` 30 s, `SummaryTimeout` 20 s (`sources/session_report.go:63-65`), session chat tick 2 s
   (`sources/session_chat.go:53`). That floor is consistent with what a live install shows. Part metric artifact, part real: a phone
   request for a session report really does wait ≥ 5 s.
2. **Nudge fires after the whole pass and its echo writes.** `p.nudge(ps)` runs after `flushAll`
   (`actions/processor.go:388-389, 444-446`), one HTTPS save per mailbox (`actions/control.go:522-538`), each through
   `retryUnavailable` (500 ms doubling to 8 s, 30 s budget; `relay/client/client.go:29-36`). Normally +0.1–0.5 s,
   up to 30 s while the relay errs.
3. **Publish cycles are serial and do not yield.** `cycleMu` (`publisher.go:658-664`): a `PublishNow` that lands during
   the 60 s full diff (~34 kinds in `publishOrder`, one HTTPS save per changed kind, asset uploads up to 5 min) waits for
   that cycle to end. Spacing (150 ms) and debounce are not the problem; PublishNow skips debounce.
4. **Failures spread to the nudged kind.** A cycle-wide refusal (`unavailable`, `rate_limited`, …) puts every untried
   kind on that error's backoff, up to 60 s (`publisher.go:489-500, 759-763`). A live install's log had runs of
   `publish cycle failed (error)`, `mailbox pass failed (other)`, `readers not synced (other)` and
   `record_too_large` — these drive the tail.
5. **One worker for everything.** `work()` (`runtime.go:731-772`) runs WS events, the 30 s backstop pass, `linkUpkeep`
   every minute (account read, `set_hub_readers`, a pass over every mailbox), the 2 s `soonTick`, housekeeping — one at
   a time, each up to `opTimeout` 2 min. A phone event queues behind them, unmeasured.
6. **`read_applied` is seconds-level on a live install** (figures kept out of the repo). Handlers run inline and in order; non-idempotent kinds pay a claim tx plus an inline
   `flushMailbox` save before the handler (`actions/order.go:421-457`); `readAt` is stamped per page, so later records
   absorb earlier ones' time (`processor.go:548-557`).
7. Slow sources (git status, session report summary) run in their own goroutines and feed a cache
   (`git_refresher.go:100-160`, `session_report.go:321-336`) — they do **not** block a save. Their log lines are noise,
   not latency.

### Phone

8. **The phone ignores the inline record.** The relay's `ZoneChanged` carries the record when it is ≤ 64 KiB
   (`relay.proto:168-173`, field `record`); the Go hub uses it (`relay/transport.go:270, 736, 811`), the phone does not:
   every event costs an HTTPS `changes` read (`HostedRelayTransport.swift:281-285`, `+Pull.swift:14-80`). Two extra
   round trips per action (echo + slice). No relay change needed.
9. **A dead socket after the app returns to the foreground.** iOS suspends the app, the socket dies quietly, and
   `setActive(true)` neither redials nor pings (`HubSession.swift:1270-1294`). Up to 40 s until the ping notices, and
   only the 60 s safety poll (`SessionCadence.swift:16`) catches changes meanwhile. This is the case that feels like
   CloudKit.
10. **The board shows the old state after the echo.** `BoardWriter.receiveApplied` (`BoardWriter.swift:60+`) drops the
    pending row on `applied`, so a moved target or a changed priority shows the old value with no chip until the slice
    lands. Asks bridge the gap with `AppliedAnswer`; the board does not.
11. **An ordered action can wait for the plain queue.** `beforeDirectWrite` (`HostedRelayTransport+Save.swift:197-202`)
    flushes the plain queue first, one row per request — a recording upload in it holds the tap.
12. No timers or debounce elsewhere on the phone path (write is immediate, UI uses GRDB `ValueObservation`).

## Plan

Each stage is its own board sub-target, its own worktree, review and PR into `main` (the workbench procedure).
Stage 1 goes first: it tells whether stages 2–3 hit the real cause.

| # | Stage | Side | What changes | Expected effect |
|---|---|---|---|---|
| 1 | Honest measurements | hub + phone | `nudge_saved` sample (the nudged kind's cycle ends, written or not); `event_read` (WS event arrival → mailbox read, covers the worker queue); `readAt` per record; break both down by action kind in `hub diagnostics`; Settings → Mobile → Diagnostics shows the hub legs next to the phone's `answer_ms`/`result_ms` | separates hub, runner and phone time; no speed change |
| 2 | Hub fast path | hub | nudge right after the apply commits, before `flushAll`; a pending `PublishNow` jumps into a running cycle (checked between kinds); a nudged kind skips a spread backoff once; mailbox events get priority over backstop/link upkeep/housekeeping in `work()` | −0.5…5 s typical, much less p90 |
| 3 | Runners on request | hub | a phone request signals the session report / session chat / permission runners without the 5 s floor (the floor stays for background refresh) | −2…5 s on session actions |
| 4 | Phone: inline records | phone (Kit) | apply `ZoneChanged.record` like the hub's `PullEvent` (next seq + inline = no read; anything else = read as now) | −2 round trips per action (~0.2–0.6 s) |
| 5 | Phone: foreground redial | phone | on `setActive(true)` ping at once and redial when no pong, then fetch | removes the 40–60 s stale window |
| 6 | Phone: board overlay | phone | keep a board write's new value shown after `applied` until a newer slice of that target is indexed | the board feels instant |
| 7 | Phone: ordered actions skip the plain queue | phone (Kit) | an ordered action does not wait for plain rows; attachment rows on their own lane | no tap held behind an upload |
| 8 | Error storms | hub | find the cause of the error runs in a live install's log (`record_too_large`, `error`, `mailbox pass failed (other)`, `readers not synced`) and whether they still happen (failure lines are rate-limited since #1873) | p90 |

Order: 1 → (2, 3, 8 in parallel lanes) and (4, 5, 6, 7 in parallel lanes, independent of the hub stages). Each stage's
spec/plan lands before its code, as the workbench rules say; stage 2 and 4 change transport behaviour and get
failure tests (relay drops mid-cycle, hub restart with a nudge pending, socket dies mid-read).

## Decisions

- Research scope = hub + phone, relay server untouched — decided by the agent (the relay already carries what we need).
- Measure first, then tune — decided by the agent; open for the owner in the plan review ask.
- Live numbers stay out of the repo (public repo hygiene) — CLAUDE.md.
