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

**Module:** `internal/extsync/`, `internal/extract/`, `internal/confluence/`,
`internal/jira/confluence_api.go`, `internal/db/ext_sources.go`,
`internal/kb/source_ext.go`, `internal/daemon/daemon.go`
(`phaseExternalSync`), `cmd/confluence.go`
**Last full audit:** 2026-09-26

## EXT-01 — read-only toward the source

**Status:** Enforced

**Observable:** No code path issues a non-GET request to Confluence. The
only Confluence client is `*jira.ConfluenceAPI`, whose only exported
methods are `GetJSON` and `Download` (each one GET). The fetcher reaches the network only through the
`confluence.API` interface — exactly `GetJSON` and `Download` — and every
path it requests is under `/wiki/`. Nothing in Watchtower can create, edit,
comment on, or delete Confluence content.

**Guard (two halves, because the client's base-URL seam is unexported):**
- `TestEXT01_ConfluenceAPIIsGETOnly` (`internal/jira/confluence_contracts_test.go`)
  — every exported `ConfluenceAPI` method is exercised against an
  `httptest` server that fails the test on any non-GET, and a `reflect`
  check pins the exported method set to exactly
  {`Download`, `GetJSON`}, so a new method (a write, say)
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

**Status:** Enforced

**Observable:** The engine's attachments stream downloads an attachment
(≤ 25 MiB) only to hand the body to `extract.Extractor`. Formats that need
random access (OOXML, PDF, images for OCR) are spooled into a temp file
under `Config.WorkspaceDir()/tmp/extract/` (dir 0700, file 0600) that is
removed before `Extract` returns on every path — errors and parser panics
included; plain text and HTML are read in memory. A file a crash left
behind (a process killed mid-extraction runs no cleanup) is swept at the
start of the next engine run: every `att-*` file there older than 10
minutes is removed (`Extractor.SweepStale`). PDFs are parsed by a helper
process (the hidden `watchtower extract-pdf-text`), and scans and images
are recognized by the `watchtower-ocr` helper (Vision, on device); each
reads only that temp file, is killed after 60 s, and exits on its own 10 s
later should its parent have been SIGKILLed. Only the extracted text is
written, to `ext_documents.sections_json` (and from there into the
knowledge index); no `ext_*` column, `kb_chunks` or `kb_documents` row
ever holds attachment bytes, their base64 form, or a BLOB.

**Guard:** `TestEXT03_BinariesNeverPersisted`
(`internal/extsync/ext03_contract_test.go`) — a full engine pass with the
real `extract.Extractor` (fake OCR) over a PDF and a PNG attachment, then:
(a) the extract temp dir holds no file, (b) no stored value contains the
attachments' raw leading bytes (`%PDF-`, the PNG magic) or their base64
forms (`JVBERi0`, `iVBORw0K`), (c) no column of any `ext_*` table, of
`kb_chunks` or of `kb_documents` (after a `kb.Run` over the synced rows)
holds a BLOB value. It also asserts both attachments were really extracted
through files under the temp dir and reached `kb_chunks`, so it cannot pass
vacuously. Per-format cleanup is additionally pinned by
`TestTempDirEmptyAfterExtract` (`internal/extract/extract_test.go`), the
crash sweep by `TestSweepStaleRemovesCrashLeftovers`
(`internal/extract/sweep_test.go`) and `TestEngineSweepsTempFilesEachRun`
(`internal/extsync/ocr_retry_test.go`).

## EXT-04 — the sync engine stays generic

**Status:** Enforced

**Observable:** `internal/extsync` depends on no Atlassian-, link- or
AI-specific package: not `internal/jira`, `internal/confluence`,
`internal/doclinks`, `internal/kb`, `internal/ai` or `internal/digest`,
directly or transitively. Provider behavior comes in through interfaces
(`Fetcher`, `Extractor`) and cross-source links through the injected
`Options.Relink` (cmd wires `doclinks.LinkConfluenceDoc`; nil = no links).
The Jira key pattern lives in the dependency-free `internal/jirakey`, which
`internal/jira` re-exports, so the linker does not pull the AI stack either.

**Guard:** `TestEXT04_EngineImportsNoLinkOrAIPackages`
(`internal/extsync/links_backfill_test.go`) — runs `go list -deps
watchtower/internal/extsync` and asserts none of the packages above (or
their subpackages) appears; a scan floor requires `internal/db` in the list
so an empty or failed listing cannot pass.

## Knowledge-search contracts

KB-01..03 (`docs/inventory/knowledge-search.md`) extend to the `confluence`
source: it is registered in the KB contract tests (`kbSourceTables` lists
`ext_documents`/`ext_comments`/`ext_users`; the KB-03 fixture covers it), and
every Confluence hit's `link` is the page or attachment URL.

## Changelog

- 2026-09-27 (T13 docs pass): EXT-01..04 re-checked against the code —
  wording unchanged, no drift found. `EXPLAIN QUERY PLAN` guards added for
  the extsync hot queries (`localVersions`/`localCommentVersions`, comments
  by page, the attachment revisit listing — `internal/extsync/plan_test.go`)
  and the Confluence `Changed` docs-arm join
  (`internal/kb/source_ext_changed_test.go`); every one already resolved
  through an index (no `+col` fix needed). `docs/superpowers/specs/2026-09-26-confluence-knowledge-connector-design.md`
  §6/§12 corrected to match (24h CQL overlap vs the engine's own 1-minute
  cursor overlap; opt-in `--with-confluence` scopes; the real v1/v2 endpoint
  split; the archived-page gap; the EXT-02 wording below).

- 2026-09-27: EXT-04 added — the engine's doc_links hook is injected
  (`Options.Relink`), the Jira key pattern moved to `internal/jirakey`, and
  the Slack/mail/Jira link scanner lives in `internal/doclinks/linkscan`.

- 2026-09-26: EXT-03 extended to crash residue (stale temp files swept at
  the start of every engine run) and to the `watchtower-ocr` helper; both
  helpers now exit on their own after their parent's timeout + 10 s.

- 2026-09-26: EXT-03 guard widened to base64 forms and the knowledge
  index (`kb_chunks`, `kb_documents`); PDFs now parse in a helper process
  (review fix round 1).
- 2026-09-26: EXT-03 enforced — attachment text extraction
  (`internal/extract`) and the engine's attachments stream landed with
  `TestEXT03_BinariesNeverPersisted`.
- 2026-09-26: initial contracts EXT-01..03 (EXT-03 guard pending); EXT-01's
  guard is two-part (controller ruling R4) instead of one end-to-end
  engine test, since the client's base-URL seam is unexported.
