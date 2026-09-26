# Behavior Inventory — External Sources (Confluence)

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.

Selected Confluence spaces are pulled, read-only, into the `ext_*` tables
(`ext_sources`, `ext_documents`, `ext_comments`, `ext_users`; migration
`00074`) by the source-agnostic engine `internal/extsync` driving the
Confluence fetcher `internal/confluence`, over the Jira account's shared
Atlassian grant (`internal/jira/confluence_api.go`). The knowledge index
renders them as the `confluence` source (`internal/kb/source_ext.go`), so
they are searchable through `search_knowledge`. Mechanical: no AI call
anywhere. Design:
`docs/superpowers/specs/2026-09-26-confluence-knowledge-connector-design.md`.

**Module:** `internal/extsync/`, `internal/confluence/`,
`internal/jira/confluence_api.go`, `internal/db/ext_sources.go`,
`internal/kb/source_ext.go`, `internal/daemon/daemon.go`
(`phaseExternalSync`), `cmd/confluence.go`
**Last full audit:** 2026-09-26

## EXT-01 — read-only toward the source

**Status:** Enforced

**Observable:** No code path issues a non-GET request to Confluence. The
only Confluence client is `*jira.ConfluenceAPI`, whose exported methods are
`GetJSON` and `Download` (each one GET) and `GrantedScopes` (reads the local
token store, no request). The fetcher reaches the network only through the
`confluence.API` interface — exactly `GetJSON` and `Download` — and every
path it requests is under `/wiki/`. Nothing in Watchtower can create, edit,
comment on, or delete Confluence content.

**Guard (two halves, because the client's base-URL seam is unexported):**
- `TestEXT01_ConfluenceAPIIsGETOnly` (`internal/jira/confluence_contracts_test.go`)
  — every exported `ConfluenceAPI` method is exercised against an
  `httptest` server that fails the test on any non-GET, and a `reflect`
  check pins the exported method set to exactly
  {`Download`, `GetJSON`, `GrantedScopes`}, so a new method (a write, say)
  fails the guard until it is exercised there too.
- `TestEXT01_FetcherReachesOnlyTheGETAPI` (`internal/confluence/fetcher_test.go`)
  — the `API` seam is pinned to {`Download`, `GetJSON`}, the `*Fetcher`
  method set is pinned, every `Fetcher` method is exercised once through a
  fake `API`, and every requested path is under `/wiki/`.

## EXT-02 — selection is honest

**Status:** Enforced

**Observable:** Only selected spaces are fetched: the engine iterates
`ext_sources` rows and nothing else, so an unselected space is never
requested. Unselecting a space (`confluence unselect`, which deletes its
`ext_sources` row) leaves no `ext_documents`/`ext_comments` row for it (FK
`ON DELETE CASCADE`), and after the next knowledge-index cycle no
`kb_documents`/`kb_chunks` row with its `confluence:<source_id>:` prefix
(the confluence source reconciles on every run). `ext_users` is a
provider-wide display-name cache, not scoped to a space, and is not removed
with one. `jira remove` is non-destructive (the `jira_accounts` row stays,
`status='removed'`), so a removed account's spaces keep their synced rows —
the Slack/Jira "remove keeps history" precedent — but only enabled accounts
get a fetcher, so nothing is fetched for them; a hard delete of the account
row would cascade like an unselect.

**Guard:** `TestEXT02_UnselectLeavesNoRowsAndNoIndex`
(`internal/extsync/contracts_test.go`) — sync a space, index it with
`kb.Run`, `DeleteExtSource`, assert zero `ext_*` rows for it and zero engine
fetcher calls on the next pass, `kb.Run` again, assert zero `kb_documents` /
`kb_chunks` with its prefix.

## EXT-03 — binaries are never persisted

**Status:** Planned — the guard lands with attachment text extraction
(`internal/extract`).

**Observable:** Attachment bytes are streamed into a temp file under
`Config.WorkspaceDir()/tmp/extract/` (mode 0600) only for text extraction
and removed afterwards; no table holds attachment bytes — only extracted
text in `ext_documents.sections_json`.

**Guard:** added with attachment extraction (after a sync pass with
attachments, the extract temp dir is empty and no table holds the bytes).

## Knowledge-search contracts

KB-01..03 (`docs/inventory/knowledge-search.md`) extend to the `confluence`
source: it is registered in the KB contract tests (`kbSourceTables` lists
`ext_documents`/`ext_comments`/`ext_users`; the KB-03 fixture covers it), and
every Confluence hit's `link` is the page or attachment URL.

## Changelog

- 2026-09-26: initial contracts EXT-01..03 (EXT-03 guard pending); EXT-01's
  guard is two-part (controller ruling R4) instead of one end-to-end
  engine test, since the client's base-URL seam is unexported.
