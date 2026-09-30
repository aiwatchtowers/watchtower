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
(`phaseExternalSync`), `cmd/confluence.go`, `internal/tools/confluence_page*.go`
(EXT-05)
**Last full audit:** 2026-09-26

## EXT-01 — read-only toward the source

**Status:** Enforced (narrowed 2026-09-30 — see below)

**Observable:** The *sync path* — the engine (`internal/extsync`) and the
Confluence fetcher (`internal/confluence`) — is GET-only: every request they
issue is a GET, and neither can even reach a write method. Writes exist only
for the edit tool `edit_confluence_page` (`EXT-05`), which is `External` and
runs only after Approve — see `docs/inventory/agent-actions.md`'s AGENT-03.
`*jira.ConfluenceAPI` (the one Confluence client Watchtower has) now has one
write method, `PutJSON` (method PUT only), alongside the existing
`GetJSON`/`Download`; the fetcher's `confluence.API` seam does not include
it. Its one production caller is the page client in
`internal/tools/confluence_page_client.go` (`PutPage`), which
`cmd/actions_registry.go`'s `confluencePageClientFactory` builds over the
account's `*jira.Client`; `PutPage` in turn is called only by the edit
tool's `Execute` (pinned by EXT-05's `TestEXT05_OnlyEditToolReachesPut`).
`internal/confluenceedit` is a pure text model with no network access.

**Guard (two halves, because the client's base-URL seam is unexported):**
- `TestEXT01_ConfluenceAPIIsGETOnly` (`internal/jira/confluence_contracts_test.go`)
  — every exported `ConfluenceAPI` method is exercised against an
  `httptest` server; a `reflect` check pins the exported method set to
  exactly {`Download`, `GetJSON`, `PutJSON`}, so a new method fails the
  guard until it is exercised here too. `GetJSON`/`Download` are asserted
  GET-only, full stop; `PutJSON` is the one deliberate exception and is
  pinned to issue exactly one PUT, on a separate server.
- `TestEXT01_FetcherReachesOnlyTheGETAPI` (`internal/confluence/fetcher_test.go`)
  — the `API` seam is pinned to {`Download`, `GetJSON`} (no `PutJSON`), the
  `*Fetcher` method set is pinned, every `Fetcher` method is exercised once
  through a fake `API`, and every requested path is under `/wiki/`.
- `TestEXT01_FetcherCannotReachPut` (`internal/confluence/fetcher_test.go`)
  — re-pins the `confluence.API` seam to exactly {`Download`, `GetJSON`}
  and runs `go list -deps watchtower/internal/extsync`, asserting it still
  excludes `internal/jira` (where `PutJSON` lives) — the engine has no way
  to construct a `*jira.ConfluenceAPI` at all, let alone call its write
  method.

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

## EXT-05 — Confluence writes are approved, versioned and bounded

**Status:** Enforced (2026-09-30)

**Observable:** The only Confluence write path is the chat tool
`edit_confluence_page` (`internal/tools/confluence_page_edit.go`), registered
`External` on the main and target surfaces, so it never runs without the
owner's Approve (AGENT-03). At propose time `Normalize` reads the live page,
refuses a `base_version` that no longer matches ("page changed since you read
it (now vN) — re-read with get_confluence_page"), applies the edits through
`internal/confluenceedit` and pins the exact storage to write, the card's
changes, and `base_hash` — the sha256 of the storage the preview was computed
from (ruling R12) — into the stored args. At apply time `Execute` re-reads
the page and writes only if its version still equals `base_version` AND the
sha256 of its storage still equals `base_hash` (a change that did not bump
the version is caught too) — else it fails with `conflict: the page was
edited after the preview (now vN); nothing was written`, or, when the page is
exactly one version on and its storage is exactly this edit's (its own
earlier PUT whose response was lost), `this edit is already saved (vN);
nothing was written now` — and issues no PUT — as one `PUT` of
`base_version + 1` with the message `Edited via Watchtower` (a 409 from
Confluence is re-read and reported the same way). A rich element (a
⟦k:label⟧ marker) is removed only when the approved change lists it under
`removed`. Every byte outside what an edit changes survives: a
`replace_text` re-serialises only its unit's content span, and a
`replace_section` (ruling R11) re-emits the original bytes of every block of
the section whose text the new body keeps, re-rendering from markdown only a
block the edit changed — and refusing, with a message naming the block, a
change to a block whose formatting markdown cannot carry (attributes on a
paragraph/heading/list/table, column widths, noformat, code-macro parameters
other than the language, a multi-paragraph list item, formatting-like
characters in its text). Edits are capped at 20 per call, 60 000 runes per text
field and 120 000 per call; a page whose editable text exceeds 60 000 runes
is shown truncated and its hidden tail cannot be changed. Without the opt-in
write scopes the tool refuses before any network call: `Confluence editing
not granted — run: watchtower jira login --account N --with-confluence-write`.
The companion read `get_confluence_page` is a live network read, so it is
mounted only in chat mode, never on the dev-mode MCP surface (DEV-01).

**Guards:**
- `TestEXT05_WriteRequiresMatchingVersion`
  (`internal/tools/confluence_page_edit_test.go`) — a propose against a stale
  version is refused with no proposal; an approved proposal whose page moved
  on — or whose storage no longer hashes to `base_hash` at the same version
  — fails with the conflict error and zero `PutPage` calls; a 409 on the
  PUT reports the same conflict.
- `TestEXT05_RichElementsSurviveUntouched`
  (`internal/confluenceedit`) — a no-op edit round-trips the storage byte for
  byte, macros and mentions included.
- `TestEXT05_SectionRewriteKeepsUntouchedBlocksByteExact`
  (`internal/confluenceedit/apply_r11_test.go`) — a `replace_section` that
  changes one paragraph leaves every other block of the section byte-exact:
  a centred paragraph, intraword emphasis, literal `2**10`, a wide table
  with column widths, header-row and column-header tables, a multi-paragraph
  list item, a code macro with a title, a noformat block, an attributed
  heading and list. `FuzzApply` extends it to arbitrary input: a section
  rewritten with its own text plus one appended paragraph changes nothing
  but that paragraph.
- `TestEXT05_OnlyEditToolReachesPut`
  (`internal/tools/confluence_contracts_test.go`) — an AST scan of every
  non-test Go file of the module (scan floor 300 files) pins the production
  callers of `PutJSON` to exactly `confluence_page_client.go:PutPage` and of
  `PutPage` to exactly `confluence_page_edit.go:executeConfluenceEdit`, and
  `go list -deps` shows neither `internal/extsync` nor `internal/confluence`
  can import `internal/tools`.

## Knowledge-search contracts

KB-01..03 (`docs/inventory/knowledge-search.md`) extend to the `confluence`
source: it is registered in the KB contract tests (`kbSourceTables` lists
`ext_documents`/`ext_comments`/`ext_users`; the KB-03 fixture covers it), and
every Confluence hit's `link` is the page or attachment URL.

## Changelog

- 2026-09-30 (local-review round 1, rulings R11/R12): EXT-05 now pins
  `base_hash` (sha256 of the propose-time storage) and requires it to match
  at apply time besides the version; "already saved" is told from someone
  else's edit by storage equality at `base_version + 1` (the "possibly
  saved" wording is gone). A `replace_section` keeps the original bytes of
  every block the new body leaves unchanged and refuses to re-render a
  changed block markdown cannot carry faithfully; new guard
  `TestEXT05_SectionRewriteKeepsUntouchedBlocksByteExact`.

- 2026-09-30 (Confluence page editing, task 4): EXT-05 added —
  `get_confluence_page` (live read + comments, chat mode only) and
  `edit_confluence_page` (External, versioned write) in `internal/tools`,
  wired in `cmd/actions_registry.go`. EXT-01's text now names the real
  `PutJSON` caller (the page client in `internal/tools`, built by the cmd
  factory) instead of `internal/confluenceedit`. `extsync.Item` gained
  `ReplyTo` (set by the fetcher's `Comments` for a reply) so the read tool
  can nest comment threads; the engine ignores it.

- 2026-09-30 (Confluence page editing, task 1): EXT-01 narrowed, not
  weakened — the sync engine and fetcher stay GET-only, but
  `*jira.ConfluenceAPI` gained `PutJSON` (method PUT, JSON body) for the
  upcoming edit tool (`EXT-05`, later task). Method pin widened to
  {`Download`, `GetJSON`, `PutJSON`}; new guard
  `TestEXT01_FetcherCannotReachPut` pins that the fetcher's `API` seam and
  the extsync engine's dependency graph still cannot reach it. Also added:
  `ConfluenceWriteScopes` (`write:page:confluence write:blogpost:confluence`,
  opt-in via `jira login|add --with-confluence-write`, implies
  `--with-confluence`) and `HasConfluenceWriteScopes`; a re-login keeps
  granted write scopes the same way it already keeps read scopes.

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
