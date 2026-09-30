---
type: bug
title: Approving a chat proposal fails with SQLITE_BUSY
status: open
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

- 2026-09-30: every Go transaction now begins `BEGIN IMMEDIATE` (`_txlock=immediate` in
  `db.Open`). A DEFERRED read-then-write transaction failed at once with
  `SQLITE_BUSY_SNAPSHOT` when another process committed in between — `busy_timeout`
  never covered that upgrade; now it waits for the write lock up front. Pinned by
  `internal/db/txlock_test.go`. Still open: the autocommit `TransitionAgentAction`
  UPDATE in the screenshot is covered by `busy_timeout` only, so a writer holding the
  lock longer than the timeout still fails it (the render-outside-the-tx and longer
  owner-path timeout work addresses that), and the card-level error/Retry and the
  missing second card remain.
