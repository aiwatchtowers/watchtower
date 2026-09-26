# Behavior Inventory — Knowledge Search

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.

A mechanical, local, derived full-text search index over raw and derived
Watchtower data (Slack threads/channel-days, Gmail/IMAP threads, Jira issues
with comments, calendar events, meeting transcripts and recaps, digest
topics, stream-digest topics, and ideas/decisions), exposed to the chat as
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
given). A from-scratch `kb reindex` produces byte-identical
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
whole source on its first backfill; and `Build` runs inside the batch's write
transaction (the daemon's connection is held while a batch renders).
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
— a fixture covering all ten `SourceNames()` entries, asserting every one of
their documents is reachable by search and every hit from every source
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

- 2026-09-26: initial contracts KB-01..03 (spec `docs/superpowers/specs/2026-09-26-knowledge-search-design.md`).
- 2026-09-26 (final-review fixes): KB-01 extended — thread promotion re-renders the root's channel-day (guard mutation added), cursors compare with `>=` (the same-second-writer limit is gone), title-only documents are indexed (the "title-only docs dropped" limit is gone), non-Slack sources reconcile every run; new documented limits (non-Slack one-range backfill overshoot, `Build` inside the write tx) and the `kb reindex` daemon refusal. KB-03 extended — hits carry `chunk`/`chunk_anchor`, `get_knowledge_document` opens at `from_chunk` (guard extended), and the prompts' link rule no longer builds links from namespaced ids.
