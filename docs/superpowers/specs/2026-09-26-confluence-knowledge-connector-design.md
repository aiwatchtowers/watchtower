# Confluence knowledge connector — design

Date: 2026-09-26. Status: approved in conversation (owner delegated the remaining sections).
Branch: `feature/knowledge-connectors` — the whole feature lands as one PR.

## 1. Goal

Make the owner's Confluence searchable next to Slack, mail, Jira, meetings and
the rest, through the existing knowledge index (`internal/kb`,
`search_knowledge`). The owner picks which spaces to sync; a regular delta
sync keeps them current; pages, blog posts, comments and attachments
(including scanned images, via on-device OCR) are all indexed.

The storage and indexing layers are built source-agnostic (`ext_*`), so a
future "any MCP server → local index" bridge is a second fetcher, not a new
subsystem. That bridge is **not** built here.

### Non-goals (this spec)

- Writing anything to Confluence (read-only forever — EXT-01).
- Page-subtree or free-form CQL selection (spaces only).
- Confluence Server/Data Center (Cloud only, via the Atlassian OAuth we have).
- Permission sync beyond "the owner's token sees it" (single owner app).
- Feeding Confluence into digests, inbox, memory, ideas, Catch-Up (roadmap §11).
- Vectors (roadmap stage 5).
- The MCP recipe fetcher (roadmap stage 5).

## 2. Decisions taken

| Question | Decision |
|---|---|
| Native connector or MCP bridge | Native Confluence REST connector now; the storage/index layers are generic so an MCP fetcher can plug in later |
| Auth | Reuse the Atlassian account in `jira_accounts`: same OAuth client, same token file, Confluence read scopes added; one re-consent (`jira login --account N`) per account |
| Selection granularity | Whole spaces only |
| What is indexed | Pages, blog posts, footer + inline comments, attachments (text formats, Office, PDF, images/scans via OCR) |
| Native sources | Slack/Jira/Gmail/… stay in their own tables; the uniform layer is `kb_documents`, `ext_*` is the uniform *raw* store for index-only sources |
| Pipelines and the index | Pipelines keep reading source tables for input; the index is only ever a *context* provider, never a pipeline's own output (roadmap §11, future KB-04) |

## 3. Architecture

```
jira_accounts + jira_token_<id>.json   (existing; + Confluence read scopes)
        │
internal/jira.Client ── Confluence view (shared token refresh, shared rate limiter)
        │
internal/confluence   ── Fetcher implementation (REST v1 CQL search + REST v2 content)
        │                 storage-format → text converter
internal/extsync      ── generic engine: per-source cursors, budget, version gate,
        │                 reconcile, attachment download → extract → discard
internal/extract      ── text from attachments: plain / OOXML / PDF (Go) + OCR helper (Swift)
        │
ext_sources / ext_documents / ext_comments / ext_users / doc_links   (migration 00074)
        │
internal/kb: extSource{provider:"confluence"}  (one kb.Source per provider)
        │
search_knowledge / get_knowledge_document / get_task_context (unchanged API + new source)
```

Unit boundaries:

- **`internal/extsync`** knows nothing about Confluence. It drives a
  `Fetcher` interface, owns cursors, the cycle budget, the version gate and
  reconcile, and writes `ext_*`. Test it with a fake fetcher.
- **`internal/confluence`** knows nothing about the DB. It turns HTTP into
  `extsync` values, and storage XHTML into sectioned text. Test it with
  recorded HTTP fixtures and XHTML fixtures.
- **`internal/extract`** is a pure `bytes + mime → text` library plus one
  exec of the OCR helper. No DB, no network.
- **`internal/kb` `extSource`** reads `ext_*` only (KB-01: rebuildable from
  local tables, no network in `Build`).

### 3.1 Fetcher interface (`internal/extsync`)

```go
type Container struct{ Key, Name, ExtID string }       // a space

type ItemKind string // "page" | "blogpost" | "comment" | "attachment"

type ItemRef struct {                                   // enumeration row, no body
    Kind      ItemKind
    ExtID     string
    Version   int
    Modified  time.Time
    ParentID  string // comment → page, attachment → page/blogpost
}

type Item struct {                                      // fetched content
    Ref       ItemRef
    Title     string
    URL       string
    AuthorID  string
    Created   time.Time
    Status    string            // current | archived
    Sections  []Section         // text sections (heading-split body / one per comment)
    Meta      map[string]string // space, ancestors path, labels, mime, size…
    AnchorText string           // inline comment highlighted text
    Resolved  bool              // inline comment state
    Download  string            // attachment download URL (attachments only)
    MediaType string
    Size      int64
}

type Fetcher interface {
    Containers(ctx) ([]Container, error)                            // for the picker
    Changed(ctx, c Container, kind ItemKind, cursor time.Time, page string) (refs []ItemRef, nextPage string, err error)
    All(ctx, c Container, kind ItemKind, page string) (refs []ItemRef, nextPage string, err error) // reconcile
    Fetch(ctx, ref ItemRef) (*Item, error)          // nil = gone
    Comments(ctx, pageID string) ([]Item, error)    // full set for one page
    Download(ctx, it *Item, max int64) (io.ReadCloser, error)
    Users(ctx, ids []string) (map[string]User, error)
}
```

Signatures are indicative; the plan fixes them. The point is the split: the
engine asks "what changed of kind K since T", "give me the content", "give me
every id" — the three operations any source (including an MCP recipe) must
supply.

## 4. Data model — migration `00074_external_sources.sql`

```sql
CREATE TABLE ext_sources (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  provider         TEXT NOT NULL CHECK (provider IN ('confluence')),
  jira_account_id  INTEGER REFERENCES jira_accounts(id) ON DELETE CASCADE,
  connection_id    INTEGER REFERENCES external_connections(id) ON DELETE CASCADE,
  container_key    TEXT NOT NULL,          -- space key
  container_ext_id TEXT NOT NULL DEFAULT '',-- space id (REST v2)
  container_name   TEXT NOT NULL DEFAULT '',
  enabled          INTEGER NOT NULL DEFAULT 1,
  page_cursor       TEXT NOT NULL DEFAULT '',  -- RFC3339 lastModified high-water
  comment_cursor    TEXT NOT NULL DEFAULT '',
  attachment_cursor TEXT NOT NULL DEFAULT '',
  page_token        TEXT NOT NULL DEFAULT '',  -- in-flight pagination token per stream
  comment_token     TEXT NOT NULL DEFAULT '',  --   (resume mid-backfill; cleared when
  attachment_token  TEXT NOT NULL DEFAULT '',  --    the stream's enumeration completes)
  backfill_done    INTEGER NOT NULL DEFAULT 0,
  last_reconcile_at TEXT NOT NULL DEFAULT '',
  last_synced_at   TEXT NOT NULL DEFAULT '',
  status           TEXT NOT NULL DEFAULT 'ok' CHECK (status IN ('ok','error','needs_consent','revoked')),
  error            TEXT NOT NULL DEFAULT '',
  created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  CHECK ((jira_account_id IS NULL) != (connection_id IS NULL))
);
-- SQLite treats NULLs as distinct in UNIQUE, so one partial index per owner column.
CREATE UNIQUE INDEX idx_ext_sources_jira ON ext_sources(provider, jira_account_id, container_key)
  WHERE jira_account_id IS NOT NULL;
CREATE UNIQUE INDEX idx_ext_sources_conn ON ext_sources(provider, connection_id, container_key)
  WHERE connection_id IS NOT NULL;

CREATE TABLE ext_documents (
  source_id     INTEGER NOT NULL REFERENCES ext_sources(id) ON DELETE CASCADE,
  ext_id        TEXT NOT NULL,
  kind          TEXT NOT NULL CHECK (kind IN ('page','blogpost','attachment')),
  parent_ext_id TEXT NOT NULL DEFAULT '',
  title         TEXT NOT NULL DEFAULT '',
  url           TEXT NOT NULL DEFAULT '',
  version       INTEGER NOT NULL DEFAULT 0,
  status        TEXT NOT NULL DEFAULT 'current',
  author_id     TEXT NOT NULL DEFAULT '',
  created_at    TEXT NOT NULL DEFAULT '',
  modified_at   TEXT NOT NULL DEFAULT '',
  sections_json TEXT NOT NULL DEFAULT '[]',   -- [{"heading":..,"anchor":..,"text":..}]
  meta_json     TEXT NOT NULL DEFAULT '{}',
  media_type    TEXT NOT NULL DEFAULT '',
  size_bytes    INTEGER NOT NULL DEFAULT 0,
  extract_status TEXT NOT NULL DEFAULT 'ok'
      CHECK (extract_status IN ('ok','skipped_type','too_large','ocr_pending','ocr_unavailable','failed')),
  extract_attempts INTEGER NOT NULL DEFAULT 0,
  children_changed_at TEXT NOT NULL DEFAULT '',  -- a comment moved: re-render the page
  synced_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (source_id, ext_id)
);
CREATE INDEX idx_ext_documents_synced ON ext_documents(synced_at);
CREATE INDEX idx_ext_documents_parent ON ext_documents(source_id, parent_ext_id);

CREATE TABLE ext_comments (
  source_id    INTEGER NOT NULL REFERENCES ext_sources(id) ON DELETE CASCADE,
  ext_id       TEXT NOT NULL,
  page_ext_id  TEXT NOT NULL,
  kind         TEXT NOT NULL CHECK (kind IN ('footer','inline')),
  author_id    TEXT NOT NULL DEFAULT '',
  created_at   TEXT NOT NULL DEFAULT '',
  version      INTEGER NOT NULL DEFAULT 0,
  body_text    TEXT NOT NULL DEFAULT '',
  anchor_text  TEXT NOT NULL DEFAULT '',
  resolved     INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_id, ext_id)
);
CREATE INDEX idx_ext_comments_page ON ext_comments(source_id, page_ext_id);

CREATE TABLE ext_users (
  provider     TEXT NOT NULL,
  ext_user_id  TEXT NOT NULL,          -- Atlassian accountId for Confluence
  display_name TEXT NOT NULL DEFAULT '',
  email        TEXT NOT NULL DEFAULT '',
  fetched_at   TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (provider, ext_user_id)
);

CREATE TABLE doc_links (
  from_kind TEXT NOT NULL,   -- 'confluence' | 'slack' | 'gmail' | 'jira'
  from_ref  TEXT NOT NULL,   -- kb-style ref of the mentioning document
  to_kind   TEXT NOT NULL,   -- 'jira_issue' | 'confluence_page'
  to_ref    TEXT NOT NULL,   -- 'PROJ-123' | '<cloud_id>:<page_id>'
  detected_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (from_kind, from_ref, to_kind, to_ref)
);
CREATE INDEX idx_doc_links_to ON doc_links(to_kind, to_ref);

CREATE TABLE ext_link_state (          -- doc_links detection watermark per scanned kind
  from_kind TEXT PRIMARY KEY,          -- 'slack' | 'gmail' | 'imap' | 'jira'
  cursor    TEXT NOT NULL DEFAULT ''   -- rowid / synced_at high-water, per kind
);
```

Notes:

- `ext_*` are **source data**, not derived: `kb reindex` rebuilds Confluence
  documents from them without the network (KB-01 holds).
- Attachment binaries are **never stored** (EXT-03); only extracted text in
  `sections_json`.
- `ext_users` is separate from `jira_user_map` on purpose: that table is the
  Jira↔Slack mapping surface (Settings → Jira user mapping lists its rows).
  Readers join the two on the Atlassian account id to get Slack identity.
- `connection_id` and the `provider` CHECK expansion are for the future MCP
  fetcher; nothing writes a `connection_id` row in this spec.
- Mirror everything into `internal/db/schema.sql`, `TestAllTablesExist`, the
  schema golden; Swift `TestDatabase.swift` if a Swift test reads them.

## 5. Auth and the Confluence client

- `internal/jira/auth.go` scope string gains the Confluence read scopes
  (granular: `read:page:confluence read:blogpost:confluence
  read:comment:confluence read:attachment:confluence read:space:confluence
  read:user:confluence`, plus classic `search:confluence` for CQL search).
  **Plan task 1 verifies this exact list against the Atlassian docs** and
  pins it in a test; the list above is the starting hypothesis.
- **Owner prerequisite (outside the code):** in developer.atlassian.com, add
  the Confluence API with these scopes to every OAuth app we ship (main,
  corporate, partner flavors). Without it consent silently omits them.
- Existing accounts keep syncing Jira untouched. Confluence for an account
  whose token lacks the scopes → every `ext_sources` row of that account gets
  `status='needs_consent'`, `error="re-run: watchtower jira login --account N"`.
  The Jira account's own status is never touched by Confluence failures.
  Granted scopes are read from the token response's `scope` field, which we
  persist in the token file (add the field if absent).
- **One refresher per account.** Atlassian refresh tokens rotate; two
  independent clients refreshing the same token file would revoke each other.
  So Confluence calls go through the account's existing `jira.Client`: add a
  product-scoped request path (`https://api.atlassian.com/ex/confluence/{cloud_id}`)
  that shares the client's token mutex, refresh, 401/`ErrAuthRevoked`
  handling, 429 backoff and rate limiter. Implementation: generalize `do` to
  take a base (jira | confluence); expose a small `Confluence()` view type.
- Downloads use the same authenticated path with a size guard
  (`Content-Length` check + `io.LimitReader`).

## 6. Sync algorithm (`internal/extsync`)

Daemon phase `phaseExternalSync`, right after `phaseJiraSync`, gated by the
`knowledge-connectors` feature (§9). Mechanical, no AI. Budget 90 s per cycle
checked between batches (a started batch always completes, the KB rule).
Wrapped in `trackedPipelineRun("external-sync", …)`; benign shutdown not
recorded as error (`isBenignShutdownErr`).

Per enabled `ext_sources` row, in order:

1. **Pages + blog posts delta.** CQL
   `space = "KEY" AND type IN (page, blogpost) AND lastmodified >= "<cursor − 1 min>" ORDER BY lastmodified ASC`,
   100 per page, ids + version + lastModified only. CQL dates are minute
   precision, hence the one-minute overlap; the version gate removes the
   duplicates. For each ref: local `version` equal → skip (no fetch). Else
   `Fetch` (REST v2, `body-format=storage`), convert (§7), upsert, then
   reload the page's full comment set (`Comments`) in the same batch. The
   cursor advances to the batch's max `lastModified` **in the same
   transaction** as the batch's rows; the pagination token is saved too, so a
   cycle that runs out of budget mid-backfill resumes from the same page.
2. **Comments delta.** CQL `type = comment` with the same shape. Upsert into
   `ext_comments`; stamp the parent document's `children_changed_at` so the
   KB re-renders it (a new comment does not bump the page version).
3. **Attachments delta.** CQL `type = attachment`. Version gate as for pages.
   New version → `Download` (≤ 25 MiB, else `too_large`), `extract.Text`
   (§8), discard bytes, upsert. Unsupported type → row with `skipped_type`
   and no sections (still findable by file name + parent page).
4. **OCR retry.** Rows in `ocr_pending` / `ocr_unavailable` with
   `extract_attempts < 3` are retried (re-download, OCR) within the budget.
5. **Reconcile** once per UTC day per source (`last_reconcile_at`): `All`
   for each kind (ids + versions, no bodies). Local rows absent remotely are
   deleted; `trashed` = deleted; `archived` stays with `status='archived'`.
   A page the owner lost access to disappears from `All` and is deleted —
   that is the whole permission model. Comments are also reconciled per page
   on every page re-fetch (full reload replaces the set).
6. **Users.** Author ids seen in the batch and missing/older than 30 days in
   `ext_users` are resolved in bulk and cached.
7. **doc_links** for the batch (§10).

Concurrency: page bodies and downloads fetched with up to 4 in flight, all
through the account's shared rate limiter. Errors: `ErrAuthRevoked` → source
`status='revoked'`, stop this account's sources for the cycle; missing scope
(403 with a scope message) → `needs_consent`; other errors → logged, the
source's `error` set, `status='error'`; the next clean pass writes `ok` back
(unlike Jira, the engine *can* write `ok`: it owns the whole pass result).
Cancelled ctx is never recorded as an error.

**Selecting a space** inserts the row with empty cursors (backfill starts
next cycle). **Unselecting** deletes the row → cascade removes `ext_*`; the
next KB cycle's reconcile for the `confluence` source removes its documents
(the confluence source is small enough to reconcile every cycle, like the
non-Slack KB sources). Removing the Jira account cascades the same way.

## 7. Storage format → text (`internal/confluence/storage.go`)

Parse the storage XHTML with `golang.org/x/net/html` (already a dependency).

- Split into **sections at h1–h3**; each section = heading + following
  content; anchor = Confluence's heading anchor (`#Heading-Text` slug rule,
  pinned by fixtures) so `chunk_anchor` deep-links into the page.
- Tables → one line per row, cells joined with ` | `, header row kept.
- Lists → `- ` items with indentation. Code/noformat macros → text kept.
- `ac:link` to a user (`ri:user ri:account-id`) → `@<display name>` via
  `ext_users` (resolved at sync time; unresolved → `@user`).
- `ac:link` to a page → its title. Jira macro → the issue key
  (feeds `doc_links`). Expand/panel/info/note/tip/warning macros → their body.
- Images, attachments-macro, TOC, children-display and other structural
  macros → dropped.
- Whitespace normalized; body capped at 1 000 000 runes per page (a
  truncation marker section is appended when cut).

Blog posts render the same way. Comments are converted with the same
converter into a single section each.

## 8. Attachment text extraction (`internal/extract`)

`Text(ctx, mediaType, name string, r io.Reader) (sections []Section, status string, err error)`

| Type | How |
|---|---|
| `text/plain`, md, csv, json, xml, html | read (html via the same stripper), UTF-8 validate |
| docx / xlsx / pptx | stdlib `archive/zip` + `encoding/xml`: paragraphs; sheets → rows (`a | b`); slides → one section per slide |
| PDF | pure-Go text layer (`github.com/ledongthuc/pdf`, BSD-3; one section per page). Pages with no text layer → OCR |
| png / jpeg / heic / tiff / gif | OCR |
| everything else (zip, video, audio, doc/xls legacy, …) | `skipped_type` |

Caps: download ≤ 25 MiB; extracted text ≤ 200 000 runes per attachment;
PDF ≤ 300 pages; OCR ≤ 50 pages per attachment.

### 8.1 OCR helper

- New SwiftPM executable target `watchtower-ocr` in `WatchtowerDesktop`
  depending only on Vision + PDFKit + ImageIO (no ML stack, no GRDB). Input:
  a file path and `--pages` for PDFs; output: JSON
  `{"pages":[{"index":0,"text":"…"}]}` on stdout. `VNRecognizeTextRequest`,
  `.accurate`, languages `ru-RU, uk-UA, en-US`, language correction on.
  PDF pages are rendered via PDFKit at 2× and recognized.
- No TCC: it reads only a file Watchtower itself wrote into
  `Config.WorkspaceDir()/tmp/extract/` (0600, deleted after), never a
  protected location; Vision on in-memory images needs no permission.
- Bundled at `Watchtower.app/Contents/MacOS/watchtower-ocr` (next to the CLI);
  `CLIBinaryStore` copies it next to the stored CLI with the same
  size+SHA256 validation. The Go side resolves it as a sibling of
  `os.Executable()`, overridable by `WATCHTOWER_OCR_HELPER`.
- Helper missing (CLI-only install, `swift run`) → `ocr_unavailable`, the
  attachment still indexed by name; retried when the helper appears.
  Timeout 60 s per invocation; failure → `ocr_pending` with attempts++.

## 9. Feature flag, config, CLI, Desktop

- **Feature** `knowledge-connectors` ("Confluence in search"), config
  `knowledge.connectors.enabled`, default **true** (nothing happens until a
  space is selected), `CostNone`, `FeedsInto` knowledge-search. Off = the
  phase returns early (FEAT-01), `ext_*` and the index stay (FEAT-02). No
  fast-forward hook: re-enabling resumes from stored cursors (the
  knowledge-search precedent; FEAT-03 is about AI backfills).
- **CLI** `watchtower confluence`:
  - `spaces [--account N] [--json]` — lists spaces visible to the account
    (live API) with a `selected` flag;
  - `select <KEY>… [--account N]`, `unselect <KEY>… [--account N]`;
  - `status [--json]` — per selected space: status/error, backfill progress
    (local count vs last remote count), last sync, extract-status counts;
  - `sync` — one foreground pass, refuses while the daemon runs unless
    `--force` (the `kb reindex` rule); otherwise the daemon picks changes up
    (`watchtower sync --now`).
  `--account` defaults to the single enabled Jira account.
- **Desktop** Settings → Jira → account detail gains a **Confluence**
  section (`ConfluenceSpacesSection`, `ConfluenceSpacesViewModel`,
  `ExtSourceQueries`): space list with toggles (from `confluence spaces
  --json`, selection via `select`/`unselect`), per-space status, a
  "Re-consent for Confluence" button when `needs_consent` (runs the existing
  Jira login flow), feature-off caption. Async state on a center/VM held by
  AppState (house rule: survives navigation).
- **Search surfaces:** `search_knowledge`'s `sources` enum gains
  `confluence`; the Go chat prompt and the five Swift chat prompt copies name
  Confluence among the indexed sources (dual path); hits link via the page
  URL (+ heading anchor from `chunk_anchor`).

## 10. Cross-source links (`doc_links`)

- Confluence text (pages, comments, attachments) → Jira keys via the
  existing key detector → `(confluence, <doc ref>, jira_issue, KEY)`.
- Slack messages, Gmail/IMAP bodies, Jira descriptions/comments → Confluence
  page URLs (`/wiki/spaces/<KEY>/pages/<id>` and `/wiki/x/<tiny>` resolved
  lazily only if a page with that id is synced) →
  `(<source>, <ref>, confluence_page, <cloud_id>:<id>)`. Detected by the
  external-sync phase over rows newer than a per-kind watermark in
  `ext_link_state` (Slack by `messages.rowid`, the others by their
  `synced_at`), bounded per cycle by the same budget. Mechanical, no AI.
  Existing history is scanned once as a backfill from an empty cursor.
- `get_task_context` gains a "Confluence" section: pages linking the key
  (`doc_links` to_ref = KEY) plus the top `kb.Search` hits for the key
  limited to `confluence` (capped, omitted when empty — DEV-03 shape).
- `get_knowledge_document` for a Confluence page lists its inbound links
  ("discussed in: Slack thread …") in the document meta.

## 11. Roadmap beyond this spec

Recorded here so later specs have one source; each stage gets its own spec.

- **Stage 0 — done.** KB v1; chat asks `search_knowledge` first.
- **Stage 1 — this spec.** Confluence into `ext_*` + KB + `doc_links`.
- **Stage 2 — mechanical tools on `kb.Search`**, each switched behind a
  shadow-compare on a small real query set (the `memory/retrieve_compare`
  precedent), only when recall is not worse: `find_experts` (today
  `SearchMessages` over Slack only, `internal/tools/experts.go`),
  `get_task_context` transcript lookup (`SearchTranscripts`,
  `internal/tools/taskcontext.go`), `ai query` context builder
  (`internal/ai/context_builder.go` Slack-only "Search Results").
  Structural tools (`list_messages`, `list_transcripts`) and `memory_recall`
  stay as they are.
- **Stage 3 — KB as context for AI pipelines**, each a dark flag with a
  sentinel prompt slot (byte-identical off): meeting prep → target
  brief/next step → briefing → memory entity rewrite (the last only after a
  compare against `memory_recall`). New contract **KB-04**, added with the
  first consumer: pipeline *input* comes from source tables with their own
  watermarks; the index is only *context*; a pipeline never searches sources
  derived from its own output (enforced by a `kinds` exclusion + test).
- **Stage 4 — attention signals from `ext_*`**: an @mention of the owner in
  a Confluence comment → inbox `confluence_mention` → Catch-Up. Input from
  `ext_comments`, never from the index.
- **Stage 5 — quality and reach**: hybrid vectors (bm25 + cosine) improve
  every consumer without code changes; `MCPRecipeFetcher` (declarative
  per-server recipe: enumerate tool + cursor arg, fetch tool, field mapping)
  as the second `extsync.Fetcher`.

Never moves onto the index: pipeline inputs and watermarks, provenance
validation, `memory_recall`.

## 12. Contracts — `docs/inventory/external-sources.md`

- **EXT-01 — read-only toward the source.** No code path issues a
  non-GET request to Confluence (guard: a test transport that fails any
  non-GET during a full sync pass).
- **EXT-02 — selection is honest.** Only selected spaces are fetched;
  unselecting (or removing the account) leaves no `ext_*` row and, after the
  next KB cycle, no `kb_documents` row for that space (guard test).
- **EXT-03 — binaries are never persisted.** After a sync pass with
  attachments, the extract temp dir is empty and no table holds attachment
  bytes (guard test).

KB-01..03 extend to the new source (the confluence source is registered in
the existing KB contract tests; KB-03 resolvability: every hit's `link` is the
page/attachment URL).

## 13. Testing

- `extsync`: fake fetcher — version gate (unchanged version never fetched),
  cursor + page-token resume after budget cut, same-minute overlap no
  duplicates, reconcile deletes, archived kept, trashed deleted,
  `children_changed_at` on comment, auth/scope/error status transitions incl.
  writing `ok` back, cancelled ctx not recorded.
- `confluence`: `httptest` server with recorded JSON (CQL search pages, v2
  page/blogpost/comments/attachments, users bulk); storage converter golden
  fixtures (headings/anchors, tables, macros, mentions, jira macro, cap).
- `extract`: small committed fixtures per format; OCR helper invoked through
  a fake executable in Go tests; Swift unit test for the helper on a
  generated image with known text.
- `kb`: extSource Build/Changed/Keys, registration in contract tests.
- `jira`: shared-refresh test — Jira and Confluence views refresh once under
  concurrent 401s.
- Migration: schema golden, `TestAllTablesExist`.
- Real-data smoke before PR: sync one real space end to end on a copy of the
  real DB, `EXPLAIN QUERY PLAN` guards for the new hot queries (the KB lesson:
  only real data caught the planner regression).

## 14. Slices (implementation order, all on this branch)

1. **Auth + client:** scopes, scope persistence, shared-refresh Confluence
   view, `needs_consent` detection.
2. **Storage + engine:** migration 00074, `extsync` with fake fetcher,
   feature flag, daemon phase.
3. **Confluence pages/blogposts/comments:** fetcher, storage converter,
   users cache, CLI `confluence spaces|select|unselect|status|sync`.
4. **KB integration:** `extSource`, `search_knowledge` enum, prompts (Go +
   Swift copies), contracts EXT-01..03 + KB registration.
5. **Attachments:** download guard, `extract` (plain/OOXML/PDF), statuses.
6. **Desktop:** Confluence section in Jira account settings.
7. **OCR:** `watchtower-ocr` helper, bundling + `CLIBinaryStore`, Go
   invoker, retry.
8. **doc_links + `get_task_context` section.**
9. Docs: CLAUDE.md feature note, `docs/app-guide.md`, inventory, smoke.
