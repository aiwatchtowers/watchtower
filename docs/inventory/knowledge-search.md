# Behavior Inventory — Knowledge Search

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.

A mechanical, local, derived full-text search index over raw and derived
Watchtower data (Slack threads/channel-days, Gmail/IMAP threads, Jira issues
with comments, calendar events, meeting transcripts and recaps, digest
topics, stream-digest topics, ideas/decisions, and Confluence pages/blog
posts/attachments with their comments — see
`docs/inventory/external-sources.md`), exposed to the chat as
`search_knowledge`/`get_knowledge_document` and to the owner as
`watchtower kb status|reindex|search`. Design:
`docs/superpowers/specs/2026-09-26-knowledge-search-design.md`.

**Module:** `internal/kb/`, `internal/tools/knowledge.go`,
`internal/daemon/daemon.go` (`phaseKnowledgeIndex`), `cmd/kb.go`
**Last full audit:** 2026-09-26

## KB-01 — derived and rebuildable

**Status:** Enforced

**Observable:** The `kb_*` tables (`kb_documents`, `kb_chunks`, `kb_fts`,
`kb_sources`) are an index, never a source of truth — nothing reads them to
make a decision other than search, and the indexer never writes a source
table (`internal/kb`'s adapters read only through the `Queryer` they are
given — except `project_doc`, which also reads the attached files, read-only
and inside the project folder; for it the rebuild equivalence holds over an
unchanged folder). A from-scratch `kb reindex` produces byte-identical
`kb_documents`/`kb_chunks` content to incremental indexing over the same
data, across writes, in-place Slack edits/deletes inside the 48h tail rescan,
thread promotion (a top-level message older than the tail gaining its first
reply: every Slack reply row also marks its root's channel-day, so the day
document the root left is re-rendered), hard deletes (caught by the
reconcile, `reconcileIfDue` in `internal/kb/indexer.go`), and the
content-hash write gate (`writeDoc` in `internal/kb/store.go` skips a write
when the rendered hash is unchanged). Change-marker cursors compare with
`>=`, so a source row written in the same second as the stored cursor is
never missed (re-listing the cursor's own second is write-free behind the
hash gate). A document whose sections are all blank but whose title is not is
indexed as its title; only a nil `Build` means "gone". Deletions leave search
within one daemon cycle for every source but Slack, which reconciles once per
UTC day (its key listing scans every message).

**Accepted v1 limits that qualify "derived":** a Slack in-place edit/delete
older than the 48h tail (outside thread promotion) is caught only by
`kb reindex`; a name joined in at render time from another table (digest
channel name, recap event title) refreshes only on the parent row's own next
change or a `kb reindex`, not on a rename of the joined row; every non-Slack
source is one change-range, so the 60s cycle budget can be overshot by a
whole source on its first backfill. (`Build` used to run inside the batch's
write transaction; since 2026-09-30 a batch is rendered first and only its
writes run in the transaction — `buildBatch`/`storeBatch`.)
For the `confluence` source, a renamed user (a refreshed `ext_users` row)
re-renders the documents that user authored or commented on — every one,
paged 5000 (user, document) pairs per `Changed` call through a key-based
continuation (`extUserPageSize`, `internal/kb/source_ext_changed.go`). Its
cursor (docs marker + users continuation) compares strictly and lists only
seconds that are already over, so an idle install re-renders nothing (a row
written in the current second waits one cycle). The race this does not
cover is wider than one second: `resolveUsers` (`internal/extsync/users.go`)
reads `now` **once**, before its batch loop, and stamps every resolved
user's `fetched_at` with that same value regardless of how many
`usersBatchSize`-sized batches the call makes — so a `confluence sync
--force` resolving many users can write rows carrying an identical
`fetched_at` for as long as the whole refresh takes, not just for an
instant. If the daemon's users-arm cursor (which orders by `(fetched_at,
ext_user_id, key)`) advances past part of that timestamp while the refresh
is still writing more rows under it, a later-written row that sorts earlier
in `(ext_user_id, key)` order is silently skipped — for the rest of that
`sync --force`'s duration, not just for the racing second. `kb reindex`
repairs it (a full rebuild has no cursor to outrun). A user who is only
@mentioned, and an attachment's parent-page title, refresh only on the
document's own next change or a `kb reindex`.
`kb reindex` refuses while the sync daemon is running (unless `--force`) —
the daemon's knowledge-index phase would otherwise race the rebuild's cursor
resets.

**Guard:** `TestKB01_IncrementalEqualsRebuild` (`internal/kb/contracts_test.go`)

## KB-02 — mechanical (no model calls)

**Status:** Enforced

**Observable:** `internal/kb`'s package doc states the zero-AI intent
directly, and every source adapter (`source_slack.go`, `source_mail.go`,
`source_work.go`, `source_derived.go`) is plain SQL plus Go string/JSON
handling — no prompt is rendered, no generator is constructed, no
subprocess is shelled out to. A `go/parser` import scan enforces this
structurally: no non-test `.go` file under `internal/kb/` may import
`internal/digest`, `internal/ai`, `internal/codex`, `internal/ollama`, or
`internal/providers` (or any subpackage of them).

**Guard:** `TestKB02_NoGeneratorImports` (`internal/kb/contracts_test.go`) —
a scan-floor assertion (≥10 files walked) guards against the test silently
passing over an empty or wrong directory.

## KB-03 — every hit is resolvable

**Status:** Enforced

**Observable:** Every `Hit` returned by `kb.Search` carries a `ref` that
`kb.GetDocument` opens successfully — both from the start and at the hit's
best-matching `chunk` (`from_chunk`) — and a non-empty, non-empty-valued
`anchor` map (a source-native locator: Slack `channel_id` plus `thread_ts` or
`date`, Jira `account_id`+`key`, transcript id, event id, etc.) — never a hit
with nowhere to click through to and nothing to build a link from. The opened
document's `Anchor` matches the hit's `Anchor` exactly. A hit also carries
its best chunk's `chunk_anchor` (e.g. a Slack message ts) and, when the
source has one, a `link` permalink. The chat prompts link a hit through its
`link` when present; for a specific Slack message they strip the `N:`
account prefix from `anchor.channel_id` and take the ts from
`anchor.thread_ts` (threads) or `chunk_anchor` (channel-days) — the Go
prompt `internal/ai/prompt.go` and Swift `ChatViewModel.knowledgeLinkRule`
state the same rule.

**Guard:** `TestKB03_EveryHitOpensAndAnchors` (`internal/kb/contracts_test.go`)
— a fixture covering all twelve `SourceNames()` entries, asserting every one
of their documents is reachable by search and every hit from every source
resolves.

## Read-only-ness

Not a Knowledge Search contract — `search_knowledge` and
`get_knowledge_document` are `tools.Tool{Access: AccessRead}` registry
entries, covered by DEV-01 (`docs/inventory/dev-surface.md`): both are in
`readOnlyGuardCalls` (`internal/mcp/server_test.go`), so
`TestNoToolMutatesDatabase` and the `query_only=ON` connection-level fence
apply to them the same as every other read tool. This file does not restate
DEV-01.

## Changelog

- 2026-10-01 (board target #89): a twelfth source, `project_doc` (attached project documents read from the project folder, `internal/kb/source_project.go`), visible only to its own project's session — `Request.ProjectID`/`DocOptions.ProjectID`, contract PROJ-08 in `projects.md`. The guards only grow: KB-01's `kbSourceTables` gains `projects`/`project_documents` and its incremental pass revises a project document on disk (an mtime-only change); KB-03's fixture covers the new source, searched and opened as the fixture project's session (`ProjectID` changes nothing for the other sources). KB-01's Observable now names the one exception to "adapters read only through the Queryer": this source also reads the attached files (read-only, inside the folder; the daemon skips folders macOS guards — `kb.IndexProjectDocs` is the explicit per-project trigger). `projects`'s delete also removes the project's entries (PROJ-02).

- 2026-10-01 (board target #90): `kb.Request.Scope`/`ScopeOnly` and `kb.Recent` — a project session's `search_knowledge` boosts (or, with `project_scope: only`, restricts to) the documents of the project's Slack channels, Jira projects and Confluence spaces, via one SQL predicate over `anchor_json` (`Scope.predicate`); the boost is a second, scope-restricted retrieval per query fused in at the same weights, and `Hit.in_scope` marks such hits. Outside a project session nothing changes. KB-01..03 unchanged (in-scope hits open and anchor like any other).

- 2026-09-30: a batch's documents are rendered before its write transaction opens (`buildBatch`), and only the writes run inside it (`storeBatch`) — the render used to hold SQLite's write lock for up to a whole 200-document batch, long enough to fail an owner's Approve click in another process with SQLITE_BUSY (backlog `2026-09-30-approving-a-chat-proposal-fails-with-sqlite-busy.md`). Guard `TestRun_RendersOutsideTheWriteLock`. The "Build runs inside the write transaction" v1 limit is retired; KB-01..03 unchanged.

- 2026-09-27 (T13 docs pass): KB-01's Confluence users-arm wording corrected
  — the missed writer is not bounded to "the same second"; `resolveUsers`
  takes `now` once for its whole batch loop, so a `confluence sync --force`
  resolving many users can leave the race open for the entire refresh, not
  an instant. `EXPLAIN QUERY PLAN` guards added for the extsync hot queries
  and the Confluence `Changed` docs-arm join (`internal/extsync/plan_test.go`,
  `internal/kb/source_ext_changed_test.go`); no plan needed a `+col` fix.
- 2026-09-26: initial contracts KB-01..03 (spec `docs/superpowers/specs/2026-09-26-knowledge-search-design.md`).
- 2026-09-26 (final-review fixes): KB-01 extended — thread promotion re-renders the root's channel-day (guard mutation added), cursors compare with `>=` (the same-second-writer limit is gone), title-only documents are indexed (the "title-only docs dropped" limit is gone), non-Slack sources reconcile every run; new documented limits (non-Slack one-range backfill overshoot, `Build` inside the write tx) and the `kb reindex` daemon refusal. KB-03 extended — hits carry `chunk`/`chunk_anchor`, `get_knowledge_document` opens at `from_chunk` (guard extended), and the prompts' link rule no longer builds links from namespaced ids.
- 2026-09-26 (Confluence connector): no contract changed and no guard relaxed — the new `confluence` source (`internal/kb/source_ext.go`, over `ext_*`) joins all three guards: `kbSourceTables` gains `ext_documents`/`ext_comments`/`ext_users` (KB-01's "never writes a source table"), KB-01's incremental-vs-rebuild pass now also renames a comment author, drops a comment and hard-deletes an attachment, and KB-03's fixture covers eleven sources. KB-01 gains the documented Confluence cursor rules (strict, complete-seconds-only, paged users continuation) and re-render limits (mentions, attachment parent title). Contracts for the connector itself: `docs/inventory/external-sources.md` (EXT-01..03).
