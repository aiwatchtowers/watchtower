# Corp data — quick steps without feature loss (board #596)

Goal: cheap data minimisation that no reader notices. Part of board group #595
(corporate data on the Mac). Spec: none — the decisions come from the
2026-10-17 owner discussion recorded in the intents of board targets #595–#599.

## Global Constraints

- Go inner loop only: `go test ./internal/<pkg>` for touched packages,
  `make lint-diff`. Swift: `make test-swift FILTER=<Class>` and
  `make lint-swift` (lint-diff is Go-only). The full gate runs once, by the
  controller, before the PR.
- Public repo hygiene (CLAUDE.md): no live-install data in tests, docs or
  commits.
- Behavior inventory: read `docs/inventory/README.md` and the file for every
  module you touch; never weaken a guard test.
- No behaviour change for the user in Tasks 1–2.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Task 1: Stop storing Slack `messages.raw_json` (board #597)

Depends on: none.

Nothing reads Slack `raw_json`: Go selects it into `db.Message.RawJSON`
(`internal/db/messages.go` — `msgSelectCols`, `msgSelectColsAliased` and the
inline SELECT lists, `internal/db/search.go:28`) but no code reads the field;
Swift `Message.rawJSON` (`WatchtowerDesktop/Sources/WatchtowerCore/Models/Message.swift`)
has no consumer.

- Stop writing it: every Slack message write path (`internal/sync/message_sync.go`,
  `search_sync.go`, `orchestrator.go` and any other `db.Message` builder that
  fills `RawJSON`) writes the column default `'{}'`. Keep the column itself —
  no table recreation: it is `NOT NULL DEFAULT '{}'` and the FTS triggers
  (`messages_au` fires only on `text`/`is_deleted`) are untouched by it.
- Remove `RawJSON` from `db.Message` and from every Slack messages SELECT and
  Scan in Go; remove `rawJSON` from the Swift `Message` model (GRDB decoding
  ignores extra columns) and fix any Swift test fixture that sets it.
- New goose migration (next free number in `internal/db/migrations/`):
  `UPDATE messages SET raw_json = '{}' WHERE raw_json != '{}'`; Down is a
  no-op comment (the data cannot come back). Follow the `add-migration`
  project skill; schema.sql gets a comment that the column is kept empty
  (Slack API terms: minimum necessary retention).
- Tests: a db test that a stored message keeps `raw_json = '{}'`, and the
  migration clears a pre-filled value.

## Task 2: Remove dead message-reading code (board #598)

Depends on: Task 1 (same files).

Delete these when a fresh grep confirms no non-test caller (delete their
tests too; if a caller exists, keep the function and say so in the report):

- Go: `GetMessagesByChannel`, `GetAllThreadParents`, `GetThreadRepliesAfterTS`,
  `GetChannelMessagesAfterTS`, `SlackAccountHasMessages`,
  `ComputeUserInteractions`, `GetGmailBody`, and `ai.ContextBuilder`
  (`internal/ai/context_builder.go`) with whatever only it uses.
- Swift: `MessageQueries.fetchByChannel`, `fetchThreadReplies`,
  `fetchInboxThread`, `fetchInboxChannelWindow`, `observeMessages`.

## Task 3: Design — reflect source deletions and edits (board #599)

Depends on: none (research only, no code).

Today Slack `is_deleted` is always written `false` (internal/sync/*), so a
message deleted in Slack — by the author or by the company's retention
policy — stays in our DB, FTS and KB forever. Edits land only if the message
is fetched again. Produce a design note
`docs/superpowers/specs/2026-10-17-source-deletions-design.md`: how each
source (Slack, Gmail, IMAP, Jira comments, Confluence — already reconciled)
can detect deletions and edits under our API limits (Slack non-Marketplace
`conversations.history` 1 req/min for new installs; user tokens; no Events
API), what to do locally (mark `is_deleted` vs delete the row; FTS/KB
follow-through), cost per cycle, and a recommendation. The owner reviews it
before any code.
