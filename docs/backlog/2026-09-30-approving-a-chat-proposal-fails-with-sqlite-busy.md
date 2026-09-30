---
type: bug
title: Approving a chat proposal fails with SQLITE_BUSY
status: done
priority: high
tags: [chat, agent-actions, sqlite, locking, daemon, desktop]
context: docs/chat-projects-vision — backlog collection session, item 3 (owner screenshot of the main AI Chat)
created: 2026-09-30
---

In the main AI Chat the assistant proposed a track ("Track this", `create_track`)
and a target. Pressing Approve failed with a red banner at the bottom of the
conversation:

```
watchtower exited with error: transitioning agent action 6 to approved: database is locked (5) (SQLITE_BUSY)
```

The error comes from `db.TransitionAgentAction` (`internal/db/agent_actions.go`),
the `pending → approved` UPDATE run by the CLI approve/apply path. The CLI
connection already sets `PRAGMA busy_timeout=5000` (`internal/db/db.go`), so
some other writer held the SQLite write lock for more than 5 s.

Suspects for the long-held write lock (check `watchtower.log` / `pipeline_runs`
around the failure time):
- the daemon's knowledge index (`kb.Run` — `Build` runs inside the batch write
  transaction, a documented v1 limit) or `extsync` batch commits (Confluence
  attachment extraction inside a batch);
- the Desktop's own GRDB writer holding a write transaction (e.g. the chat VM
  persisting steps/messages) while it spawns the CLI;
- a memory/consolidation phase writing a large transaction.

Expected:
- an owner click on Approve never fails because of a background writer —
  either the long transactions get shorter (no slow work inside a write tx),
  or the approve path retries on `SQLITE_BUSY` with a longer budget;
- if it still fails, the card shows the error on itself with a Retry, not only
  a bare "watchtower exited with error" banner at the bottom of the chat.

Also visible in the same screenshot (check whether it is a separate bug): the
assistant's text announces **two** cards (a track and a target, "both cards
wait for your approval"), but only the "Track this" card is rendered. Either
the second proposal was never recorded, or the card list drops it.

> Original note: «бага» (with screenshot)

## Progress

### 2026-09-30, Go half: render outside the tx, owner-click budget

- **Long writer found by reading the code:** the knowledge index (`kb.Run`)
  rendered each 200-document batch *inside* its write transaction — after
  the batch's first write, every remaining render (Slack channel-days, mail
  threads) ran under SQLite's write lock. The other suspects do their slow
  work outside a transaction: `extsync` fetches, downloads and extracts
  before its batch transaction opens, and the Desktop's approve path holds no
  GRDB transaction while it runs the CLI. Fixed: `buildBatch` renders first,
  `storeBatch` writes in the transaction (`TestRun_RendersOutsideTheWriteLock`).
- **Owner-click budget:** `watchtower actions …` and the writable MCP modes
  (`mcp --chat`, `mcp --project N`) now wait up to 30 s for a write lock
  (`ownerWriteBusyTimeout`) instead of 5 s. AGENT-05 is unchanged: the
  statement waits longer, it is never retried after it ran.
- **Second symptom (two cards announced, one rendered):** not reproducible
  without the live database. The most likely cause is the same lock: the
  chat-mode MCP server records a proposal with an `INSERT` under the same
  5 s budget, so the second proposal's insert could fail with SQLITE_BUSY and
  the tool call return an error the model's prose ignored. The longer budget
  on `mcp --chat` covers it. To confirm on the live install: count
  `agent_actions` rows for that conversation's `turn_id`.
- **Still open:** the Desktop half — show an approve failure on the card
  itself with Retry, not only as the chat's bottom banner. (The deferred
  read-then-write residual is closed by the `BEGIN IMMEDIATE` entry below.)

### 2026-09-30, BEGIN IMMEDIATE

- 2026-09-30: every Go write transaction opened through `db.Open` now begins `BEGIN IMMEDIATE`
  (`_txlock=immediate`; the legacy `RunSchemaUpgrade` pre-flight handle is not covered). A DEFERRED read-then-write transaction failed at once with
  `SQLITE_BUSY_SNAPSHOT` when another process committed in between — `busy_timeout`
  never covered that upgrade; now it waits for the write lock up front. Pinned by
  `internal/db/txlock_test.go`. Still open: the autocommit `TransitionAgentAction`
  UPDATE in the screenshot is covered by `busy_timeout` only, so a writer holding the
  lock longer than the timeout still fails it (the render-outside-the-tx and longer
  owner-path timeout work addresses that), and the card-level error/Retry and the
  missing second card remain.

### 2026-09-30, Desktop half: the error on the card

- A failed Approve/Reject/Retry is kept per row (`AgentActionFeed.rowErrors`)
  and rendered on that row's card (`AgentActionCardView.gestureError`) in the
  main chat, the target chat and the Inbox action strip, instead of the chat's
  bottom banner. On a row the failure left `pending` (the SQLITE_BUSY case)
  Approve becomes **Retry**, which re-runs `watchtower actions approve`; a
  `failed`/`approved` row keeps its Retry → `actions apply`. Both go through
  the CLI, so AGENT-05's claim still decides whether anything executes. The
  bottom banner keeps only feed-wide failures (a failed read).
- Resolution: both symptoms are covered — the lock by the Go half above, the
  card by this entry. The two-cards-one-rendered symptom stays attributed to
  the same lock (unconfirmed on the live install).
