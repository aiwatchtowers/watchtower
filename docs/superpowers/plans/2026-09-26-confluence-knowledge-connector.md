# Confluence Knowledge Connector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync owner-selected Confluence spaces (pages, blog posts, comments, attachments incl. OCR) into a generic local `ext_*` store and index them in `internal/kb`, so `search_knowledge` finds Confluence next to every other source.

**Architecture:** Confluence REST calls ride the Jira account's existing `jira.Client` (one token refresher per account). A source-agnostic engine (`internal/extsync`) drives a `Fetcher` interface (Confluence is the only implementation), owns cursors/budget/version gate/reconcile and writes `ext_*`. `internal/extract` turns attachment bytes into text (Go for text/OOXML/PDF, a Swift Vision helper for OCR). One new `kb.Source` per provider reads `ext_*`.

**Tech Stack:** Go 1.25, `database/sql` + `modernc.org/sqlite`, goose migrations, `golang.org/x/net/html`, `github.com/ledongthuc/pdf` (new, BSD-3), cobra; SwiftUI + GRDB (Desktop); Swift + Vision/PDFKit (OCR helper).

**Spec:** `docs/superpowers/specs/2026-09-26-confluence-knowledge-connector-design.md` — read it before any task; it holds the why.

## Global Constraints

- All repo text (code, comments, docs, commits) in English. Commit per task, ending with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Work only inside the worktree `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/knowledge-connectors`, branch `feature/knowledge-connectors`. Never `git add -A` from a shared tree; add the task's files by path.
- Inner-loop testing only: `go test ./internal/<pkg>` (no reflexive `-count=1`), `make test-swift FILTER=<Class>`. Full gates run once in Task 13.
- Migration number: `00074`. Before writing it, `ls internal/db/migrations | tail -3` — if `00074` is taken on `origin/main`, use the next free number everywhere this plan says 00074.
- Mechanical feature: no AI call anywhere in this plan.
- Caps (code constants, no config keys): cycle budget **90 s**; attachment download **25 MiB**; extracted text **200 000 runes** per attachment; page body **1 000 000 runes**; PDF **300 pages**; OCR **50 pages** per attachment; OCR attempts **3**; OCR timeout **60 s**; fetch concurrency **4**; enumeration page size **100**; users cache TTL **30 days**; engine cursor overlap **1 minute**; Confluence CQL overlap **24 hours** (timezone-safe, Task 6).
- OCR languages: `ru-RU`, `uk-UA`, `en-US`, `.accurate`, language correction on.
- Read-only toward Confluence: only `GET` requests (EXT-01).
- Never persist attachment bytes (EXT-03); temp files live in `Config.WorkspaceDir()/tmp/extract/`, mode 0600, removed after use.
- Doc ids in the KB: `confluence:<ext_sources.id>:<ext_id>`; KB source name `confluence`.
- Swift: follow `docs/review/review-rules.md` "Swift / Desktop conventions"; async state survives navigation (held on AppState).

## Review Focus

1. **Existing Jira account whose token predates the new scopes** → Confluence sources show `needs_consent` with the re-login hint; Jira sync keeps working and the Jira account status is untouched. Test in Task 4 (engine) and Task 1 (`HasConfluenceScopes`).
2. **Backfill cut mid-enumeration by the budget or a daemon restart** → the next cycle resumes from the saved per-stream page token; nothing skipped, nothing fetched twice. Test in Task 3.
3. **Two edits in the same minute as the cursor** (CQL minute precision) → both land; the unchanged one is not re-fetched. Test in Task 3.
4. **A page moved out of a selected space (or restricted)** → it leaves `ext_*` at the next reconcile and leaves the index the KB cycle after. Test in Task 4 + Task 8.
5. **Concurrent 401s across Jira + four Confluence fetches** → exactly one refresh (rotating refresh tokens would otherwise revoke the grant). Test in Task 1.

---

## File Structure

| File | Responsibility |
|---|---|
| `internal/jira/scopes.go` (new) | Jira + Confluence scope strings, `HasConfluenceScopes` |
| `internal/jira/confluence_api.go` (new) | `ConfluenceAPI` view over `Client`: `GetJSON`, `Download` |
| `internal/jira/client.go` (modify) | `do` → `doURL` with a base; single-flight refresh |
| `internal/jira/auth.go` (modify) | auth URL uses `OAuthScopes` |
| `internal/db/migrations/00074_external_sources.sql` (new) | tables from spec §4 |
| `internal/db/ext_sources.go` (new) | `ExtSource` CRUD used by CLI/engine wiring |
| `internal/extsync/types.go` (new) | `Container`, `ItemKind`, `ItemRef`, `Item`, `Section`, `User`, `Fetcher`, `Extractor` |
| `internal/extsync/store.go` (new) | SQL writes for `ext_documents`/`ext_comments`/`ext_users`/cursors (inside a tx) |
| `internal/extsync/engine.go` (new) | `Engine.Run`: per source → streams → reconcile, budget, statuses |
| `internal/extsync/stream.go` (new) | one stream (pages/comments/attachments) delta loop |
| `internal/extsync/reconcile.go` (new) | daily reconcile |
| `internal/extsync/attachments.go` (new) | download → extract → discard, OCR retry |
| `internal/confluence/storage.go` (new) | storage XHTML → sections + Jira keys |
| `internal/confluence/fetcher.go` (new) | `extsync.Fetcher` over REST |
| `internal/confluence/api.go` (new) | response structs + `API` interface |
| `internal/extract/extract.go` (new) | `Text(...)` dispatcher, caps |
| `internal/extract/ooxml.go`, `pdf.go`, `plain.go`, `ocr.go` (new) | per-format extractors |
| `internal/kb/source_ext.go` (new) | `extSource{provider}` |
| `internal/kb/source.go` (modify) | register `extSource{"confluence"}` |
| `internal/config/config.go`, `defaults.go` (modify) | `knowledge.connectors.enabled` |
| `internal/features/registry.go` (modify) | `knowledge-connectors` feature |
| `internal/daemon/daemon.go` (modify) | `SetExternalSync`, `phaseExternalSync` |
| `cmd/sync.go` (modify) | build one `jira.Client` per account, feed Jira syncers + Confluence fetchers |
| `cmd/confluence.go` (new) | `confluence spaces|select|unselect|status|sync` |
| `internal/tools/knowledge.go`, `internal/ai/prompt.go` + 5 Swift prompt copies (modify) | `confluence` source |
| `internal/doclinks/` (new) | detect Jira keys / Confluence URLs → `doc_links` |
| `internal/tools/taskcontext.go` (modify) | Confluence section |
| `WatchtowerDesktop/Sources/OCRHelper/main.swift` (new) | `watchtower-ocr` executable |
| `WatchtowerDesktop/Package.swift`, `scripts/build-app.sh`, `CLIBinaryStore.swift` (modify) | build, bundle, store-copy the helper |
| `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ExtSourceQueries.swift` (new) | read `ext_sources` |
| `WatchtowerDesktop/Sources/ViewModels/ConfluenceSpacesViewModel.swift` (new) | spaces list + select/unselect via CLI |
| `WatchtowerDesktop/Sources/Views/Settings/ConfluenceSpacesSection.swift` (new) | UI in Jira account detail |
| `docs/inventory/external-sources.md` (new) | EXT-01..03 |

---

### Task 1: Atlassian scopes + Confluence view + single-flight refresh

**Files:**
- Create: `internal/jira/scopes.go`, `internal/jira/scopes_test.go`, `internal/jira/confluence_api.go`, `internal/jira/confluence_api_test.go`
- Modify: `internal/jira/client.go` (`do`, `refreshAccessToken`, `getAccessToken`), `internal/jira/auth.go:171`

**Interfaces:**
- Produces:
  - `const JiraScopes string`, `const ConfluenceScopes string`, `var OAuthScopes = JiraScopes + " " + ConfluenceScopes`
  - `func HasConfluenceScopes(tok *OAuthToken) bool`
  - `func (c *Client) Confluence() *ConfluenceAPI`
  - `func (a *ConfluenceAPI) GetJSON(ctx context.Context, path string, q url.Values, out any) error` — `path` relative to `https://api.atlassian.com/ex/confluence/{cloudID}` (e.g. `/wiki/api/v2/pages/1`)
  - `func (a *ConfluenceAPI) Download(ctx context.Context, path string, max int64) (io.ReadCloser, error)` — returns `ErrTooLarge` when `Content-Length > max`; body wrapped in `io.LimitReader(max+1)` and a read past `max` errors with `ErrTooLarge`
  - `func (a *ConfluenceAPI) GrantedScopes() (string, error)` — scope field of the stored token
  - `var ErrTooLarge = errors.New("atlassian: response exceeds size cap")`
  - `type HTTPStatusError struct{ Status int; Body string }` (returned for non-2xx from `GetJSON`; `Error()` includes both). A 403 whose body mentions `scope` is what Task 4 maps to `needs_consent`.

- [ ] **Step 1: Verify the scope list.** Read Atlassian's Confluence REST v2 + v1 scope docs (developer.atlassian.com → Confluence Cloud → Scopes). Required operations: list spaces (v2), get page/blogpost with storage body + labels (v2), CQL content search (v1 `/wiki/rest/api/content/search`), child comments (v1), attachment download (v1), users bulk (v1). Record the exact granular + classic scopes needed. Starting hypothesis: `read:space:confluence read:page:confluence read:blogpost:confluence read:comment:confluence read:attachment:confluence read:user:confluence read:content-details:confluence search:confluence readonly:content.attachment:confluence`. Put the verified list, with a comment linking the doc page, in `scopes.go`.

- [ ] **Step 2: Write failing tests** (`scopes_test.go`, `confluence_api_test.go`):

```go
func TestHasConfluenceScopes(t *testing.T) {
	assert.False(t, HasConfluenceScopes(&OAuthToken{Scope: JiraScopes}))
	assert.True(t, HasConfluenceScopes(&OAuthToken{Scope: JiraScopes + " " + ConfluenceScopes}))
	// order-insensitive, extra scopes fine
	fields := strings.Fields(ConfluenceScopes)
	sort.Sort(sort.Reverse(sort.StringSlice(fields)))
	assert.True(t, HasConfluenceScopes(&OAuthToken{Scope: "x " + strings.Join(fields, " ")}))
	assert.False(t, HasConfluenceScopes(nil))
}

func TestAuthURLRequestsConfluenceScopes(t *testing.T) {
	u := buildAuthURL(JiraOAuthConfig{ClientID: "id"}, "http://localhost/cb", "st")
	parsed, err := url.Parse(u)
	require.NoError(t, err)
	got := strings.Fields(parsed.Query().Get("scope"))
	for _, s := range strings.Fields(ConfluenceScopes) {
		assert.Contains(t, got, s)
	}
}

// Rotating refresh tokens: N concurrent 401s must trigger exactly ONE refresh.
func TestConcurrent401sRefreshOnce(t *testing.T) {
	var refreshes atomic.Int32
	var good atomic.Value
	good.Store("old")
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+good.Load().(string) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = w.Write([]byte(`{}`))
	}))
	defer api.Close()
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		refreshes.Add(1)
		time.Sleep(50 * time.Millisecond)
		good.Store("new")
		_, _ = w.Write([]byte(`{"access_token":"new","refresh_token":"rt2","expires_in":3600,"scope":"s"}`))
	}))
	defer tokenSrv.Close()

	c := newTestClient(t, api.URL, tokenSrv.URL, "stale") // helper: stored token "stale", not expired
	var wg sync.WaitGroup
	for i := 0; i < 5; i++ {
		wg.Add(2)
		go func() { defer wg.Done(); _ = c.getJSONForTest(context.Background(), "/rest/api/3/myself") }()
		go func() { defer wg.Done(); var out map[string]any; _ = c.Confluence().GetJSON(context.Background(), "/wiki/api/v2/spaces", nil, &out) }()
	}
	wg.Wait()
	assert.Equal(t, int32(1), refreshes.Load())
}

func TestConfluenceDownloadCap(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(bytes.Repeat([]byte("a"), 100))
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, "", "tok")
	rc, err := c.Confluence().Download(context.Background(), "/wiki/download/x", 10)
	if err == nil {
		_, err = io.ReadAll(rc)
		rc.Close()
	}
	assert.ErrorIs(t, err, ErrTooLarge)
}

func TestConfluenceGetJSONOnlyGET(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, http.MethodGet, r.Method)
		assert.True(t, strings.HasPrefix(r.URL.Path, "/ex/confluence/cloud1/wiki/"), r.URL.Path)
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()
	c := newTestClient(t, srv.URL, "", "tok")
	var out struct{ OK bool }
	require.NoError(t, c.Confluence().GetJSON(context.Background(), "/wiki/api/v2/spaces", url.Values{"limit": {"1"}}, &out))
	assert.True(t, out.OK)
}
```

`newTestClient(t, apiBase, tokenURL, accessToken)` is a test helper you add in `confluence_api_test.go`: it writes a token file into `t.TempDir()` (`Expiry` one hour ahead), builds `NewClient("cloud1", JiraOAuthConfig{ClientID:"id", ClientSecret:"s"}, store)`, then overrides the test seams added in Step 3: `c.apiRoot = apiBase` (so Jira base = `apiRoot + "/ex/jira/cloud1"`, Confluence base = `apiRoot + "/ex/confluence/cloud1"`) and `c.tokenURL = tokenURL`. `getJSONForTest` is a tiny test-only wrapper over `c.get`.

- [ ] **Step 3: Run tests — expect compile failures** (`go test ./internal/jira`).

- [ ] **Step 4: Implement.**
  - `scopes.go`: the three identifiers; `HasConfluenceScopes` = every field of `ConfluenceScopes` present in `strings.Fields(tok.Scope)`.
  - `auth.go:171`: `"scope": {OAuthScopes}`.
  - `client.go`: add fields `apiRoot string` (default `"https://api.atlassian.com"`) and `tokenURL string` (default: the existing token endpoint constant used by `RefreshToken`; thread it into the refresh call so tests can override). `baseURL` becomes derived: `c.apiRoot + "/ex/jira/" + c.cloudID`. Rename `do(ctx, method, path, body)` to `doURL(ctx, method, fullURL string, body []byte)` and keep `do` as `return c.doURL(ctx, method, c.jiraBase()+path, body)`.
  - **Single-flight refresh:** in `doURL`, remember the access token used for the request. On 401 call `c.refreshIfCurrent(ctx, usedToken)`, which takes `c.mu`, reloads the stored token, and refreshes **only if** the stored access token still equals `usedToken` (another goroutine already refreshed otherwise). `getAccessToken` keeps taking `c.mu`.
  - `confluence_api.go`: `type ConfluenceAPI struct{ c *Client }`; `func (c *Client) Confluence() *ConfluenceAPI { return &ConfluenceAPI{c: c} }`; `base()` = `c.apiRoot + "/ex/confluence/" + c.cloudID`. `GetJSON` builds `base()+path+"?"+q.Encode()` (omit `?` when empty), calls `doURL(GET)`, non-2xx → read up to 4 KiB of body into `*HTTPStatusError`, else `json.NewDecoder(resp.Body).Decode(out)`. `Download` → `doURL(GET)`, non-2xx → `HTTPStatusError`; `resp.ContentLength > max` → close + `ErrTooLarge`; else return a `ReadCloser` over `io.LimitReader(resp.Body, max+1)` that returns `ErrTooLarge` once more than `max` bytes were read. `GrantedScopes` loads the token store.
  - Check `RefreshToken`'s response handling keeps `Scope` (Atlassian returns it on refresh); if the refresh response omits it, carry the old value over so `HasConfluenceScopes` doesn't flip false after a refresh. Add an assertion for that to `TestConcurrent401sRefreshOnce` variant or a separate small test.

- [ ] **Step 5: Run** `go test ./internal/jira` — all pass, including the existing suite (the `do` rename must not change Jira behavior).

- [ ] **Step 6: Commit** `feat(jira): Confluence scopes, Confluence API view, single-flight token refresh`.

---

### Task 2: Migration 00074 + `ext_sources` CRUD

**Files:**
- Create: `internal/db/migrations/00074_external_sources.sql`, `internal/db/ext_sources.go`, `internal/db/ext_sources_test.go`
- Modify: `internal/db/schema.sql` (append the same DDL), `internal/db/db_test.go` (`TestAllTablesExist` list), schema golden (regenerate)

**Interfaces:**
- Produces:

```go
type ExtSource struct {
	ID              int64
	Provider        string // "confluence"
	JiraAccountID   int64  // 0 when connection-owned
	ConnectionID    int64  // 0 when jira-owned
	ContainerKey    string
	ContainerExtID  string
	ContainerName   string
	Enabled         bool
	PageCursor, CommentCursor, AttachmentCursor string
	PageToken, CommentToken, AttachmentToken    string
	BackfillDone    bool
	LastReconcileAt string
	LastSyncedAt    string
	Status          string
	Error           string
	CreatedAt       string
}
func (db *DB) CreateExtSource(provider string, jiraAccountID int64, key, extID, name string) (int64, error) // idempotent: existing row → its id
func (db *DB) ListExtSources(provider string) ([]ExtSource, error)            // all rows, ordered by id
func (db *DB) ListExtSourcesForJiraAccount(provider string, accountID int64) ([]ExtSource, error)
func (db *DB) DeleteExtSource(id int64) error                                  // cascades ext_documents/ext_comments
func (db *DB) SetExtSourceStatus(id int64, status, errMsg string) error
type ExtSourceCounts struct{ Pages, Blogposts, Attachments, Comments int; ByExtractStatus map[string]int }
func (db *DB) ExtSourceCounts(id int64) (ExtSourceCounts, error)
```

- [ ] **Step 1: Write the migration** exactly as spec §4 (with the per-stream token columns and the two partial unique indexes, `ext_link_state`, `doc_links`), wrapped in `-- +goose Up` / `-- +goose Down` (Down drops in reverse FK order). Add a header comment pointing to the spec.

- [ ] **Step 2: Failing tests** (`ext_sources_test.go`):

```go
func TestExtSourceCRUDAndCascade(t *testing.T) {
	d := openTestDB(t) // existing helper in this package; use the one other *_test.go files use
	acct, err := d.CreateJiraAccount(JiraAccount{CloudID: "c1", SiteURL: "https://x.atlassian.net", Enabled: true, Status: "ok"})
	require.NoError(t, err)

	id, err := d.CreateExtSource("confluence", acct, "ENG", "123", "Engineering")
	require.NoError(t, err)
	again, err := d.CreateExtSource("confluence", acct, "ENG", "123", "Engineering")
	require.NoError(t, err)
	assert.Equal(t, id, again, "idempotent")

	_, err = d.Exec(`INSERT INTO ext_documents (source_id, ext_id, kind) VALUES (?, 'p1', 'page')`, id)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO ext_comments (source_id, ext_id, page_ext_id, kind) VALUES (?, 'c1', 'p1', 'footer')`, id)
	require.NoError(t, err)

	require.NoError(t, d.DeleteExtSource(id))
	var n int
	require.NoError(t, d.QueryRow(`SELECT (SELECT COUNT(*) FROM ext_documents) + (SELECT COUNT(*) FROM ext_comments)`).Scan(&n))
	assert.Zero(t, n)
}

func TestExtSourceOwnerCheck(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO ext_sources (provider, container_key) VALUES ('confluence', 'X')`)
	assert.Error(t, err, "neither owner set must violate the CHECK")
}

func TestExtSourceCascadesFromJiraAccount(t *testing.T) {
	d := openTestDB(t)
	acct, _ := d.CreateJiraAccount(JiraAccount{CloudID: "c1", Enabled: true, Status: "ok"})
	_, err := d.CreateExtSource("confluence", acct, "ENG", "1", "E")
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM jira_accounts WHERE id = ?`, acct)
	require.NoError(t, err)
	srcs, err := d.ListExtSources("confluence")
	require.NoError(t, err)
	assert.Empty(t, srcs)
}
```

(Match `CreateJiraAccount`'s real field names from `internal/db/jira_accounts.go`; foreign keys must be ON in `db.Open` — they are, other cascades rely on it.)

- [ ] **Step 3: Run** `go test ./internal/db -run 'TestExtSource'` → FAIL (no functions).
- [ ] **Step 4: Implement** `ext_sources.go` (plain `database/sql`, the style of `jira_accounts.go`; `CreateExtSource` = `INSERT ... ON CONFLICT DO NOTHING` is not usable with partial indexes in all SQLite versions — do `SELECT id ... WHERE provider=? AND jira_account_id=? AND container_key=?` then `INSERT` in one tx). Append DDL to `schema.sql`, add the five tables to `TestAllTablesExist`, run `go test ./internal/db/ -run TestSchemaGolden -update`.
- [ ] **Step 5: Run** `go test ./internal/db` → PASS.
- [ ] **Step 6: Commit** `feat(db): ext_* tables for external knowledge sources (migration 00074)`.

---

### Task 3: `extsync` engine core — types, store, pages/blogposts delta

**Files:**
- Create: `internal/extsync/types.go`, `store.go`, `engine.go`, `stream.go`, `fake_test.go`, `engine_test.go`

**Interfaces:**
- Consumes: Task 2 tables and `db.ExtSource`, `(*db.DB).ListExtSources`.
- Produces (`package extsync`):

```go
type Section struct {
	Heading string `json:"heading,omitempty"`
	Anchor  string `json:"anchor,omitempty"`
	Text    string `json:"text"`
}
type Container struct{ Key, Name, ExtID string }
type ItemKind string
const (KindPage ItemKind = "page"; KindBlogpost ItemKind = "blogpost"; KindComment ItemKind = "comment"; KindAttachment ItemKind = "attachment")
type ItemRef struct {
	Kind     ItemKind
	ExtID    string
	Version  int
	Modified time.Time
	ParentID string
}
type Item struct {
	Ref        ItemRef
	Title      string
	URL        string
	AuthorID   string
	Created    time.Time
	Status     string            // "current" | "archived"
	Sections   []Section
	Meta       map[string]string
	CommentKind string           // "footer" | "inline" (comments only)
	AnchorText string
	Resolved   bool
	Download   string            // attachments: API path for Download
	MediaType  string
	Size       int64
	MentionedUserIDs []string    // author ids referenced in the body (for the users cache)
}
type User struct{ ID, DisplayName, Email string }
type Fetcher interface {
	Containers(ctx context.Context) ([]Container, error)
	// Changed lists refs of one kind modified at or after since, ascending by
	// Modified; page is an opaque pagination token ("" = first page), next ""
	// means the enumeration is complete.
	Changed(ctx context.Context, c Container, kind ItemKind, since time.Time, page string) (refs []ItemRef, next string, err error)
	All(ctx context.Context, c Container, kind ItemKind, page string) (refs []ItemRef, next string, err error)
	Fetch(ctx context.Context, c Container, ref ItemRef) (*Item, error) // nil,nil = gone
	Comments(ctx context.Context, c Container, pageID string) ([]Item, error)
	Download(ctx context.Context, it *Item, max int64) (io.ReadCloser, error)
	Users(ctx context.Context, ids []string) (map[string]User, error)
}
// Extractor turns attachment bytes into sections (Task 9 supplies internal/extract).
type Extractor interface {
	Extract(ctx context.Context, mediaType, name string, r io.Reader) (sections []Section, status string, err error)
}
type Options struct {
	Budget    time.Duration // 0 = unbounded
	Now       func() time.Time
	Logger    *log.Logger
	Extractor Extractor     // nil → attachments stored as skipped_type
}
type Stats struct{ Fetched, Unchanged, Deleted, Comments int; Incomplete bool }
type Engine struct{ /* db, fetchers map[int64]Fetcher, opts */ }
func New(d *db.DB, opts Options) *Engine
func (e *Engine) SetFetcher(jiraAccountID int64, f Fetcher)
func (e *Engine) Run(ctx context.Context) (Stats, error)
func (e *Engine) RunSource(ctx context.Context, src db.ExtSource) (Stats, error) // used by CLI `confluence sync`
```

Behavior in this task (comments, reconcile, attachments, statuses come in Tasks 4 and 9 — leave their stream calls out for now):

- `Run` loads `ListExtSources("confluence")`, skips `!Enabled` and sources without a fetcher, calls `RunSource` for each until the budget is exhausted (`Stats.Incomplete = true`).
- `RunSource` runs the **pages stream** then the **blogposts stream**. Both are one stream over kind list `{page, blogpost}` sharing `page_cursor`/`page_token` (the Confluence fetcher's CQL covers both types in one query; the fake fetcher mirrors that by accepting `KindPage` and returning both kinds).
- Stream loop: `since = cursor − 1 minute` (zero time when cursor empty). `refs, next := Changed(since, token)`. For the batch: load local `(ext_id → version)` for these ids in one query; refs with equal version count as `Unchanged`; others `Fetch` with up to 4 in flight (`errgroup` with `SetLimit(4)`), results in ref order. Then **one tx**: upsert fetched items (nil item = delete row), set `page_cursor = max(cursor, max Modified in batch)` (RFC3339 UTC), `page_token = next`. Loop while `next != ""` and budget not exceeded (check between batches only). When `next == ""` after a pass that started from an empty token, the stream is done for this cycle; set `backfill_done = 1` the first time a pass completes from an empty cursor.
- Upsert writes `sections_json` (JSON of `[]Section`), `meta_json`, `synced_at = now`.

- [ ] **Step 1: Write the fake fetcher** (`fake_test.go`): in-memory `map[ItemKind][]fakeDoc{ref, item}`; `Changed` filters `Modified >= since`, sorts ascending, pages by `pageSize` (field, default 2) with the token being the next index as a decimal string; counts `Fetch` calls per ext id (`fetches map[string]int`); `All` returns all ids. A `mutate(extID, version, modified)` helper.

- [ ] **Step 2: Failing tests** (`engine_test.go`):

```go
func TestPagesBackfillThenVersionGate(t *testing.T) {
	d, src := newSourceDB(t) // helper: db + jira account + ext source "ENG"
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addPage("p1", 1, t0)
	f.addPage("p2", 1, t0.Add(time.Hour))
	f.addBlog("b1", 1, t0.Add(2*time.Hour))
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)

	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 3, countDocs(t, d, src.ID))
	assert.Equal(t, map[string]int{"p1": 1, "p2": 1, "b1": 1}, f.fetches)

	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, map[string]int{"p1": 1, "p2": 1, "b1": 1}, f.fetches, "unchanged versions are never re-fetched")
}

func TestSameMinuteEditsAreNotMissed(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 30, 0, time.UTC)
	f.addPage("p1", 1, t0)
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)
	_, _ = e.Run(context.Background())

	f.addPage("p2", 1, t0.Add(-20*time.Second)) // same minute, earlier second than the cursor
	f.mutate("p1", 2, t0)                        // same timestamp, new version
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, f.fetches["p2"])
	assert.Equal(t, 2, f.fetches["p1"])
}

func TestBudgetCutResumesFromPageToken(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	f.pageSize = 2
	base := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	for i := 0; i < 7; i++ {
		f.addPage(fmt.Sprintf("p%d", i), 1, base.Add(time.Duration(i)*time.Hour))
	}
	clock := &stepClock{t: base, step: time.Minute} // each Now() call advances one minute
	e := New(d, Options{Budget: 90 * time.Second, Now: clock.Now})
	e.SetFetcher(src.JiraAccountID, f)

	st, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.True(t, st.Incomplete)
	first := countDocs(t, d, src.ID)
	assert.Less(t, first, 7)

	for i := 0; i < 10 && countDocs(t, d, src.ID) < 7; i++ {
		_, err = e.Run(context.Background())
		require.NoError(t, err)
	}
	assert.Equal(t, 7, countDocs(t, d, src.ID))
	for id, n := range f.fetches {
		assert.Equal(t, 1, n, "%s fetched once across resumed cycles", id)
	}
}

func TestGoneItemIsDeleted(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addPage("p1", 1, t0)
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)
	_, _ = e.Run(context.Background())
	f.markGone("p1", 2, t0.Add(time.Hour)) // Changed lists it, Fetch returns nil
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Zero(t, countDocs(t, d, src.ID))
}
```

`stepClock`, `countDocs`, `newSourceDB` live in `fake_test.go`. The engine must read the clock only through `Options.Now` (default `time.Now`) and check the budget only between batches.

- [ ] **Step 3: Run** `go test ./internal/extsync` → FAIL.
- [ ] **Step 4: Implement** `types.go`, `store.go` (functions taking a `kb`-style `Queryer` = `interface{ ExecContext; QueryContext; QueryRowContext }`: `localVersions(ctx, q, sourceID, ids) (map[string]int, error)`, `upsertDocument(ctx, q, sourceID, *Item, now)`, `deleteDocument(ctx, q, sourceID, extID)`, `saveStream(ctx, q, sourceID, stream streamName, cursor, token string)`, `markBackfillDone`), `stream.go` (the loop), `engine.go`. Keep each function under the repo's complexity gate (split the loop body into `processBatch`).
- [ ] **Step 5: Run** `go test ./internal/extsync` → PASS.
- [ ] **Step 6: Commit** `feat(extsync): generic external-source sync engine (pages/blogposts delta)`.

---

### Task 4: `extsync` — comments, reconcile, users, statuses

**Files:**
- Create: `internal/extsync/comments.go`, `reconcile.go`, `users.go`, `status.go`, `comments_test.go`, `reconcile_test.go`, `status_test.go`
- Modify: `internal/extsync/engine.go`, `stream.go`, `fake_test.go`

**Interfaces:**
- Consumes: Task 3 types; `jira.ErrAuthRevoked`, `*jira.HTTPStatusError` (Task 1).
- Produces: `RunSource` now runs pages → comments → (attachments, Task 9) → OCR retry (Task 10) → reconcile-if-due → users; status writes via `db.SetExtSourceStatus`.

Behavior:
- **Page re-fetch reloads comments:** after upserting a page/blogpost, `Comments(pageID)` → replace the page's rows in `ext_comments` (delete where `page_ext_id` + insert) in the same tx.
- **Comments stream:** `Changed(kind=comment)` with `comment_cursor`/`comment_token`; each comment ref carries `ParentID`. For each distinct parent present locally: `Comments(parent)` → replace set, stamp parent `children_changed_at = now`. Parents not present locally are skipped (their page will arrive via the pages stream).
- **Reconcile** when `last_reconcile_at` is not today (UTC): `All(kind)` for page+blogpost (one enumeration, like Changed) and attachment; delete local rows of those kinds whose ext_id is absent; `status` from the enumeration is not needed — `All` omits trashed items by contract. Stamp `last_reconcile_at`. Runs after the streams, and only if budget remains (else next cycle).
- **Users:** collect `AuthorID`s + `MentionedUserIDs` of items written this run plus comment authors; ids missing from `ext_users` or with `fetched_at` older than 30 days → `Users(ids)` in batches of 100 → upsert.
- **Statuses:** any error from a fetcher call →
  - `errors.Is(err, jira.ErrAuthRevoked)` → `revoked`, error text `"Atlassian sign-in expired — run: watchtower jira login --account N"`; stop all sources of that account for this run;
  - `*jira.HTTPStatusError` with `Status == 403` and body containing `scope` (case-insensitive) → `needs_consent`, text `"Confluence access not granted — run: watchtower jira login --account N"`; stop that account's sources for this run;
  - `ctx.Err() != nil` → return without writing any status;
  - anything else → `error` with `err.Error()`; continue with the next source.
  - A source whose `RunSource` completes without error writes `ok` / `""` if its status was not already `ok` (no write otherwise).
  - Before calling a fetcher for an account, the engine may be given a scope check: `Options.ScopesOK func(jiraAccountID int64) bool` (nil = assume ok). When it returns false → `needs_consent` without any network call. Task 7 wires it to `HasConfluenceScopes`.
- Run returns `errors.Join` of per-source errors (excluding the ones only recorded as `needs_consent`/`revoked`, which are expected states, not failures).

- [ ] **Step 1: Extend the fake** with comments (`addComment(id, pageID, version, modified, text)`), `failWith(err)` for the next call, and `removeFromAll(id)`.
- [ ] **Step 2: Failing tests:**

```go
func TestNewCommentStampsParentAndReplacesSet(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	t0 := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addPage("p1", 1, t0)
	f.addComment("c1", "p1", 1, t0, "first")
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)
	_, _ = e.Run(context.Background())
	assert.Equal(t, []string{"first"}, commentTexts(t, d, src.ID, "p1"))
	before := childrenChangedAt(t, d, src.ID, "p1")

	f.addComment("c2", "p1", 1, t0.Add(time.Hour), "second")
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"first", "second"}, commentTexts(t, d, src.ID, "p1"))
	assert.NotEqual(t, before, childrenChangedAt(t, d, src.ID, "p1"))
	assert.Equal(t, 1, f.fetches["p1"], "a new comment does not re-fetch the page")
}

func TestReconcileDeletesMovedOrRestrictedPages(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	f.addPage("p1", 1, now.Add(-time.Hour))
	f.addPage("p2", 1, now.Add(-time.Hour))
	e := New(d, Options{Now: func() time.Time { return now }})
	e.SetFetcher(src.JiraAccountID, f)
	_, _ = e.Run(context.Background())
	f.removeFromAll("p2") // moved to another space / restricted: absent from All, never in Changed

	now = now.Add(24 * time.Hour)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"p1"}, docIDs(t, d, src.ID))
}

func TestReconcileRunsOncePerDay(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	now := time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)
	e := New(d, Options{Now: func() time.Time { return now }})
	e.SetFetcher(src.JiraAccountID, f)
	_, _ = e.Run(context.Background())
	_, _ = e.Run(context.Background())
	assert.Equal(t, 1, f.allCalls[KindPage])
}

func TestStatusTransitions(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want string
	}{
		{"revoked", fmt.Errorf("wrap: %w", jira.ErrAuthRevoked), "revoked"},
		{"scope", &jira.HTTPStatusError{Status: 403, Body: `{"message":"scope does not match"}`}, "needs_consent"},
		{"other", errors.New("boom"), "error"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d, src := newSourceDB(t)
			f := newFake()
			f.failWith(tc.err)
			e := New(d, Options{})
			e.SetFetcher(src.JiraAccountID, f)
			_, _ = e.Run(context.Background())
			assert.Equal(t, tc.want, sourceStatus(t, d, src.ID))
			// a clean pass writes ok back
			_, err := e.Run(context.Background())
			require.NoError(t, err)
			assert.Equal(t, "ok", sourceStatus(t, d, src.ID))
		})
	}
}

func TestMissingScopesMeansNoNetwork(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	e := New(d, Options{ScopesOK: func(int64) bool { return false }})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "needs_consent", sourceStatus(t, d, src.ID))
	assert.Zero(t, f.calls, "no fetcher call when scopes are missing")
	var jiraStatus string
	require.NoError(t, d.QueryRow(`SELECT status FROM jira_accounts WHERE id = ?`, src.JiraAccountID).Scan(&jiraStatus))
	assert.Equal(t, "ok", jiraStatus, "Confluence never touches the Jira account status")
}

func TestCancelledContextRecordsNothing(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	f.failWith(context.Canceled)
	e := New(d, Options{})
	e.SetFetcher(src.JiraAccountID, f)
	_, _ = e.Run(ctx)
	assert.Equal(t, "ok", sourceStatus(t, d, src.ID))
}

func TestUsersCachedAndRefreshedAfterTTL(t *testing.T) { /* author "u1" on a page → Users called with ["u1"]; second run same day → not called; now+31d and a changed page → called again */ }
```

Write `TestUsersCachedAndRefreshedAfterTTL` fully in the same style (the comment states its exact assertions).

- [ ] **Step 3: Run** → FAIL. **Step 4: Implement.** **Step 5: Run** `go test ./internal/extsync` → PASS.
- [ ] **Step 6: Commit** `feat(extsync): comments, daily reconcile, users cache, source statuses`.

---

### Task 5: Confluence storage format → sections

**Files:**
- Create: `internal/confluence/storage.go`, `internal/confluence/storage_test.go`, `internal/confluence/testdata/storage/*.xhtml` + `*.golden.json`

**Interfaces:**
- Produces:

```go
// StorageToSections converts Confluence storage-format XHTML into sections
// split at h1–h3. User mentions become "@[~<accountId>]" tokens (resolved to
// names at index time from ext_users); returned userIDs lists them. jiraKeys
// lists issue keys from Jira macros and plain text (deduped, in order).
func StorageToSections(xhtml string, maxRunes int) (sections []extsync.Section, userIDs []string, jiraKeys []string)
// HeadingAnchor is Confluence Cloud's in-page anchor for a heading text.
func HeadingAnchor(heading string) string
const MentionPrefix = "@[~" // token shape: @[~<accountId>]
```

Rules (spec §7): sections at h1–h3 (content before the first heading → a section with empty heading); heading text is the section's first line; `HeadingAnchor`: trim, collapse internal whitespace to `-`, keep letters/digits (Unicode incl. Cyrillic) and `-_.`, drop other punctuation — pin with fixtures, document in a comment that it approximates Confluence's anchor rule; tables → header row + rows, cells ` | `; lists → `- ` with two-space indent per level; `ac:structured-macro` `code`/`noformat` → body text; `jira` macro → `ac:parameter[name=key]` text as `KEY` (collected); `expand`/`panel`/`info`/`note`/`tip`/`warning`/`excerpt` → body; `toc`/`children`/`attachments`/`gallery`/images (`ac:image`) → dropped; `ac:link` + `ri:user ri:account-id` → `@[~id]`; `ac:link` + `ri:page ri:content-title` → the title (or link body when present); plain text Jira keys detected with the existing pattern (reuse `jira.KeyPattern` if exported; otherwise export the regex from `internal/jira/key_detector.go` as `KeyRegexp` in this task); whitespace normalized; when total runes exceed `maxRunes`, cut and append a section `{Text: "[truncated]"}`.

- [ ] **Step 1: Fixtures.** Create six XHTML fixtures: `headings.xhtml` (intro + h1/h2/h3 with Cyrillic heading), `table.xhtml`, `macros.xhtml` (code, panel, expand, toc, jira macro, image), `mentions.xhtml` (user link + page link), `lists.xhtml` (nested), `huge.xhtml` (generated in the test instead of committed: 3000 paragraphs). Each committed fixture has a `.golden.json` of the expected `{sections, userIDs, jiraKeys}`.
- [ ] **Step 2: Failing test:**

```go
func TestStorageToSectionsGolden(t *testing.T) {
	files, _ := filepath.Glob("testdata/storage/*.xhtml")
	require.NotEmpty(t, files)
	for _, f := range files {
		t.Run(filepath.Base(f), func(t *testing.T) {
			raw, err := os.ReadFile(f)
			require.NoError(t, err)
			secs, users, keys := StorageToSections(string(raw), 1_000_000)
			got, _ := json.MarshalIndent(map[string]any{"sections": secs, "userIDs": users, "jiraKeys": keys}, "", "  ")
			golden := strings.TrimSuffix(f, ".xhtml") + ".golden.json"
			if *update {
				require.NoError(t, os.WriteFile(golden, got, 0o644))
			}
			want, err := os.ReadFile(golden)
			require.NoError(t, err)
			assert.JSONEq(t, string(want), string(got))
		})
	}
}

func TestStorageCap(t *testing.T) {
	var b strings.Builder
	for i := 0; i < 3000; i++ {
		fmt.Fprintf(&b, "<p>paragraph %d with some words in it</p>", i)
	}
	secs, _, _ := StorageToSections(b.String(), 5000)
	total := 0
	for _, s := range secs {
		total += utf8.RuneCountInString(s.Text)
	}
	assert.LessOrEqual(t, total, 5000+len("[truncated]"))
	assert.Equal(t, "[truncated]", secs[len(secs)-1].Text)
}

func TestHeadingAnchor(t *testing.T) {
	assert.Equal(t, "Release-plan", HeadingAnchor("Release plan"))
	assert.Equal(t, "План-релиза", HeadingAnchor(" План  релиза "))
	assert.Equal(t, "Q3-goals", HeadingAnchor("Q3: goals!"))
}
```

`var update = flag.Bool("update", false, "rewrite golden files")`. Write the golden files by hand from the rules first (do not generate them with `-update` and trust the output) — the golden file is the spec of the converter.

- [ ] **Step 3: Run** → FAIL. **Step 4: Implement** with `golang.org/x/net/html` tokenizer/parser (namespaced tags like `ac:structured-macro` arrive as element names containing `:`). **Step 5: Run** `go test ./internal/confluence` → PASS.
- [ ] **Step 6: Commit** `feat(confluence): storage-format to sectioned text converter`.

---

### Task 6: Confluence fetcher over REST

**Files:**
- Create: `internal/confluence/api.go`, `fetcher.go`, `fetcher_test.go`, `testdata/http/*.json`

**Interfaces:**
- Consumes: `extsync` types (Task 3), `StorageToSections` (Task 5), `jira.ConfluenceAPI` shape (Task 1).
- Produces:

```go
// API is the slice of *jira.ConfluenceAPI the fetcher needs (tests fake it).
type API interface {
	GetJSON(ctx context.Context, path string, q url.Values, out any) error
	Download(ctx context.Context, path string, max int64) (io.ReadCloser, error)
}
func NewFetcher(api API, siteURL string) *Fetcher // implements extsync.Fetcher
```

Endpoint mapping (verify each against Atlassian docs while recording fixtures; the doc link goes in a comment above each call):

| Fetcher method | Request |
|---|---|
| `Containers` | `GET /wiki/api/v2/spaces?limit=250` (+ `cursor` from `_links.next`) → `Container{Key: key, Name: name, ExtID: id}` |
| `Changed(kind=page)` | `GET /wiki/rest/api/content/search?cql=space="KEY" AND type IN (page,blogpost) AND lastmodified >= "YYYY/MM/DD HH:mm" ORDER BY lastmodified ASC&limit=100&expand=version,container` (+ `cursor`); zero `since` → CQL without the `lastmodified` clause, ordered the same |
| `Changed(kind=comment)` | same with `type = comment`, `expand=version,container`; `ParentID` = `container.id` |
| `Changed(kind=attachment)` | same with `type = attachment`, `expand=version,container,metadata.mediaType,extensions` |
| `All(kind)` | same CQLs without the date clause, `expand=version` (ids + versions only) |
| `Fetch(page)` | `GET /wiki/api/v2/pages/{id}?body-format=storage&include-labels=true`; `blogpost` → `/wiki/api/v2/blogposts/{id}`; 404 → `nil, nil`; `status=trashed` → `nil, nil` |
| `Fetch(attachment)` | `GET /wiki/rest/api/content/{id}?expand=version,container,metadata.mediaType,extensions` → `Download` = `/wiki` + `_links.download`, `Size` = `extensions.fileSize`, `MediaType` = `metadata.mediaType` / `extensions.mediaType` |
| `Comments(pageID)` | `GET /wiki/rest/api/content/{pageID}/child/comment?depth=all&expand=body.storage,version,history,extensions.inlineProperties,extensions.resolution&limit=100` (+ pagination) → `CommentKind` from `extensions.location` (`inline`/`footer`), `AnchorText` from `extensions.inlineProperties.originalSelection`, `Resolved` from `extensions.resolution.status == "resolved"`; body via `StorageToSections` joined into one section |
| `Download` | `api.Download(it.Download, max)` |
| `Users(ids)` | `GET /wiki/rest/api/user/bulk?accountId=a&accountId=b…` (≤100 per call) → `User{ID: accountId, DisplayName: publicName or displayName, Email: email}` |

- CQL time format: `"yyyy/MM/dd HH:mm"`, and CQL interprets it in the **requesting user's timezone**, which the fetcher does not know. **Decision:** the fetcher subtracts **24 hours** from `since` when building the CQL (the engine's own 1-minute overlap stays — it is source-agnostic). A day of overlap covers any timezone; the engine's version gate makes the extra rows cost enumeration only, never re-fetches. Pinned by a test on the generated CQL string.
- Page `URL` = `siteURL + "/wiki" + _links.webui`. `Meta`: `space` (key), `ancestors` (`" / "`-joined titles if returned; v2 page returns `parentId` only — fetch ancestors via `GET /wiki/rest/api/content/{id}?expand=ancestors` **only** for pages, one extra call; acceptable), `labels` (comma-joined), `status`.
- `MentionedUserIDs` = userIDs from `StorageToSections`; `Item.Meta["jira_keys"]` = comma-joined jiraKeys (Task 12 consumes it).

- [ ] **Step 1: Record fixtures.** Create JSON fixtures by hand from the Atlassian API reference examples (no live calls in tests): `spaces.json`, `search_pages_p1.json` (with `_links.next` containing `cursor=abc`), `search_pages_p2.json`, `page_1.json`, `ancestors_1.json`, `blogpost_2.json`, `comments_1.json` (one footer, one inline resolved reply), `attachment_3.json`, `users_bulk.json`.
- [ ] **Step 2: Failing tests** (`fetcher_test.go`) with a `fakeAPI` mapping `path + sorted query` → fixture file and recording every request:

```go
func TestChangedPagesPaginatesAndMaps(t *testing.T) {
	api := newFakeAPI(t)
	f := NewFetcher(api, "https://acme.atlassian.net")
	c := extsync.Container{Key: "ENG", ExtID: "10"}
	since := time.Date(2026, 9, 2, 12, 30, 0, 0, time.UTC)
	refs, next, err := f.Changed(context.Background(), c, extsync.KindPage, since, "")
	require.NoError(t, err)
	assert.Equal(t, "abc", next)
	require.Len(t, refs, 2)
	assert.Equal(t, extsync.KindPage, refs[0].Kind)
	assert.Equal(t, extsync.KindBlogpost, refs[1].Kind)
	cql := api.lastQuery().Get("cql")
	assert.Contains(t, cql, `space = "ENG"`)
	assert.Contains(t, cql, `lastmodified >= "2026/09/01 12:30"`, "24h timezone-safe overlap")
	assert.Contains(t, cql, "ORDER BY lastmodified ASC")
}

func TestFetchPageRendersSectionsURLMeta(t *testing.T) {
	api := newFakeAPI(t)
	f := NewFetcher(api, "https://acme.atlassian.net")
	it, err := f.Fetch(context.Background(), extsync.Container{Key: "ENG"}, extsync.ItemRef{Kind: extsync.KindPage, ExtID: "1", Version: 3})
	require.NoError(t, err)
	require.NotNil(t, it)
	assert.Equal(t, "https://acme.atlassian.net/wiki/spaces/ENG/pages/1/Release+plan", it.URL)
	assert.Equal(t, "ENG", it.Meta["space"])
	assert.Equal(t, "Engineering / Releases", it.Meta["ancestors"])
	assert.NotEmpty(t, it.Sections)
	assert.Contains(t, it.MentionedUserIDs, "acc-1")
}

func TestFetchTrashedOr404IsGone(t *testing.T) { /* page_trashed.json → nil,nil; unknown id (fakeAPI returns &jira.HTTPStatusError{Status:404}) → nil,nil */ }
func TestCommentsMapsInlineAndResolved(t *testing.T) { /* two items; inline one has AnchorText and Resolved=true; ParentID = "1" */ }
func TestUsersBatchesBy100(t *testing.T) { /* 150 ids → 2 requests, merged map */ }
func TestFetcherIssuesOnlyGET(t *testing.T) { /* fakeAPI records methods; the fetcher's API interface has no non-GET method — assert by exercising every Fetcher method once and checking api.paths all start with /wiki/ */ }
```

Fill in the four stubbed tests completely — the comments are their exact assertions.

- [ ] **Step 3: Run** → FAIL. **Step 4: Implement** `api.go` (response structs) and `fetcher.go`. **Step 5: Run** `go test ./internal/confluence` → PASS.
- [ ] **Step 6: Commit** `feat(confluence): REST fetcher implementing extsync.Fetcher`.

---

### Task 7: Feature flag, daemon phase, wiring, `confluence` CLI

**Files:**
- Modify: `internal/config/config.go` (`KnowledgeConfig`), `internal/config/defaults.go`, `internal/features/registry.go`, `internal/features/*_test.go` (if they pin the list), `internal/daemon/daemon.go`, `cmd/sync.go`
- Create: `cmd/confluence.go`, `cmd/confluence_test.go`, `internal/daemon/external_sync_test.go`

**Interfaces:**
- Consumes: `extsync.New/SetFetcher/Run/RunSource`, `confluence.NewFetcher`, `jira.Client.Confluence`, `jira.HasConfluenceScopes`, `db` ext source CRUD.
- Produces:
  - `KnowledgeConfig.Connectors struct{ Enabled bool \`mapstructure:"enabled"\` } \`mapstructure:"connectors"\``; default `knowledge.connectors.enabled = true` (`DefaultKnowledgeConnectorsEnabled`).
  - Feature `{ID: "knowledge-connectors", Title: "Confluence in search", ConfigKey: "knowledge.connectors.enabled", Cost: CostNone, FeedsInto: []string{"knowledge-search"}, Icon: "doc.text.magnifyingglass", Tagline/Benefits/Description in the registry's user-facing style}`.
  - `func (d *Daemon) SetExternalSync(e ExternalSyncRunner)` with `type ExternalSyncRunner interface{ Run(ctx context.Context) (extsync.Stats, error) }`; `phaseExternalSync(ctx)` right after `d.phaseJiraSync(ctx)`.
  - `cmd/sync.go`: `wireJiraSyncers` is split: `buildAtlassianClients(cfg, database, logger) map[int64]*jira.Client` builds one client per enabled account with a token + cloud_id (moving the existing "error" status write there); Jira syncers are built from that map **only when** `cfg.Jira.Enabled`; `wireExternalSync(d, cfg, database, clients, logger)` builds the engine when `cfg.Knowledge.Connectors.Enabled`, sets one `confluence.NewFetcher(client.Confluence(), acct.SiteURL)` per account, `Options{Budget: 90 * time.Second, Logger: subLogger(logger, "[ext-sync] "), ScopesOK: <token scope check via jira.NewTokenStore(...).Load() + HasConfluenceScopes>}`.
  - CLI (`cmd/confluence.go`, cobra, the `cmd/jira.go` shape, `--account` via `resolveJiraAccount`):
    - `confluence spaces [--account N] [--json]` — live `Containers()`, marks `selected` from `ListExtSourcesForJiraAccount`; JSON: `[{"key","name","id","selected"}]`.
    - `confluence select KEY… [--account N]` — resolves each key against `Containers()` (unknown key → error naming it, nothing written), `CreateExtSource`.
    - `confluence unselect KEY… [--account N]` — `DeleteExtSource` for each selected key (unknown → error).
    - `confluence status [--json]` — every source: account, key, name, status, error, backfill_done, last_synced_at, counts (`ExtSourceCounts`).
    - `confluence sync [--account N] [--force]` — refuses while the daemon runs (reuse the `kb reindex` check from `cmd/kb.go`) unless `--force`; runs `RunSource` for the account's sources, prints stats.
    - Missing Confluence scopes on the token → `spaces`/`select` exit non-zero with `Confluence access not granted — run: watchtower jira login --account N`.

- [ ] **Step 1: Failing tests.**
  - `internal/daemon/external_sync_test.go`: phase off when `Knowledge.Connectors.Enabled=false` (fake runner not called, no `pipeline_runs` row); on → runner called once, a `pipeline_runs` row named `external-sync`; runner returning `context.Canceled` after ctx cancel → no `error` row (use the existing daemon test harness the `phaseKnowledgeIndex` tests use — find it with `grep -rn "knowledge-index" internal/daemon/*_test.go`).
  - `cmd/confluence_test.go`: with a fake fetcher injected through a package-level `var newConfluenceFetcher = func(...) extsync.Fetcher` seam: `select ENG` writes a row; `select NOPE` errors and writes nothing; `unselect ENG` removes the row and its documents; `spaces --json` marks selected; token without scopes → the re-login message. Run under the package's isolated `HOME` (`TestMain` already sets one).
  - `internal/features`: whatever list/golden test pins the registry gets the new entry; `features disable knowledge-connectors --dry-run` shows no dependents cascade surprises.
- [ ] **Step 2: Run** `go test ./internal/daemon ./cmd -run 'ExternalSync|Confluence' ./internal/features ./internal/config` → FAIL.
- [ ] **Step 3: Implement.** In `phaseExternalSync`: `if !d.config.Knowledge.Connectors.Enabled || d.externalSync == nil { return }`, then `trackedPipelineRun("external-sync", …)` with the `isBenignShutdownErr` handling copied from `phaseKnowledgeIndex`, logging `Incomplete` like it does.
- [ ] **Step 4: Run** the same packages → PASS. Also `go test ./cmd -run 'Jira'` to prove the wiring split didn't change Jira.
- [ ] **Step 5: Commit** `feat: knowledge-connectors feature, external-sync daemon phase, confluence CLI`.

---

### Task 8: KB integration, search surfaces, contracts

**Files:**
- Create: `internal/kb/source_ext.go`, `internal/kb/source_ext_test.go`, `docs/inventory/external-sources.md`, `internal/extsync/contracts_test.go`
- Modify: `internal/kb/source.go` (`allSources`), `internal/kb/contracts_test.go` (`kbSourceTables` += `ext_documents`, `ext_comments`, `ext_users`; any per-source list), `internal/tools/knowledge.go:17` (enum text), `internal/ai/prompt.go`, `internal/ai/prompt_test.go`, the five Swift chat prompt copies (`ChatViewModel.swift`, `TargetChatViewModel.swift`, `IdeaChatViewModel.swift`, `MeetingChatViewModel.swift`, `TrackChatView.swift`), `docs/inventory/README.md`, `docs/inventory/knowledge-search.md` (changelog line)

**Interfaces:**
- Consumes: `ext_*` tables, `extsync.Section` JSON shape, `confluence.MentionPrefix` token shape `@[~id]`.
- Produces: `type extSource struct{ provider string }` implementing `kb.Source`, `Name() = provider`.

Behavior:
- `Changed`: `changedByColumn` over `SELECT '<p>:' || d.source_id || ':' || d.ext_id, MAX(d.synced_at, d.children_changed_at) FROM ext_documents d JOIN ext_sources s ON s.id = d.source_id WHERE s.provider = ? AND (d.synced_at >= ? OR d.children_changed_at >= ?)` plus a `UNION ALL` over `ext_users.fetched_at >= ?` mapped to every document whose `author_id` is that user (so a renamed user re-renders) — keep that second arm bounded with `LIMIT 5000` and document it.
- `Keys`: all `ext_documents` ids for the provider (every cycle — not a `dailyReconciler`).
- `Build(key)`: parse `<provider>:<source_id>:<ext_id>`; load the row (+ source's `container_key`/`container_name`); `nil` if absent.
  - page/blogpost: `Title` = title; `Meta` = space name, space key, ancestors, labels, author display name, `archived` when status is archived; `Link` = url; `Time` = `modified_at`; `Anchor` = `{"source_id","ext_id","space"}`; sections = stored sections (each section's `Anchor` = `url + "#" + anchor` when the heading anchor is set, else the ext id) followed by one section per comment `"<author>: <body>"` (inline: `"<author> on “<anchor_text>”: <body>"`, resolved suffix ` (resolved)`), comment anchor = `url + "?focusedCommentId=" + comment id`.
  - attachment: `Title` = file name; `Meta` = parent page title + space + media type + `extract_status` when not `ok`; sections = stored sections; zero sections → the title-only rule of `writeDoc` indexes the name.
  - Replace every `@[~id]` in section text with `@<display_name>` from `ext_users` (unknown → `@user`).
- `search_knowledge` enum text gains `confluence`; Go chat prompt + five Swift copies list Confluence among the indexed sources and say a Confluence hit links via its `link` (the chunk anchor already carries the heading/comment deep link) — keep the Go ↔ Swift wording identical (dual path).
- **Contracts** (`docs/inventory/external-sources.md`, format of `docs/inventory/knowledge-search.md`): EXT-01 read-only (guard `TestEXT01_OnlyGETDuringFullPass`: a full engine pass through the real `confluence.Fetcher` over an `httptest` server that fails the test on any non-GET), EXT-02 selection honesty (guard `TestEXT02_UnselectLeavesNoRowsAndNoIndex`: sync a source, index with `kb.Run`, `DeleteExtSource`, `kb.Run` again → zero `ext_*` rows for it and zero `kb_documents` with its prefix), EXT-03 binaries never persisted (guard added in Task 9). Register the file in `docs/inventory/README.md`.

- [ ] **Step 1: Failing tests** (`source_ext_test.go`): seed `ext_sources` + page with two sections + inline comment + a user; `kb.Run(... Sources: ["confluence"])`; assert the document's title/link/meta, that the comment text appears in a chunk, `@[~u1]` renders as `@Alice`, the heading chunk anchor ends with `#Release-plan`; then update the user's name + `fetched_at` → rerun → chunk shows the new name; delete the ext row → rerun → document gone; `kb.Search` for a word from the page returns it with `Source == "confluence"`. Contract tests as above. `prompt_test.go` pin for the new wording.
- [ ] **Step 2: Run** `go test ./internal/kb ./internal/extsync ./internal/ai ./internal/tools` → FAIL.
- [ ] **Step 3: Implement.** **Step 4: Run** → PASS; `make test-swift FILTER=ChatViewModel` (and any prompt-pin test class for the Swift copies — find with `grep -rln "search_knowledge" WatchtowerDesktop/Tests`).
- [ ] **Step 5: Commit** `feat(kb): index Confluence from ext_*; search surfaces; EXT-01..02 contracts`.

---

### Task 9: Attachments — download, extract (plain/OOXML/PDF), statuses, EXT-03

**Files:**
- Create: `internal/extract/extract.go`, `plain.go`, `ooxml.go`, `pdf.go`, `extract_test.go`, `testdata/*` (small `sample.docx`, `sample.xlsx`, `sample.pptx`, `sample.pdf`, `scanned.pdf` (image-only page), `sample.csv`, `sample.html`); `internal/extsync/attachments.go`, `attachments_test.go`
- Modify: `go.mod`/`go.sum` (`github.com/ledongthuc/pdf`), `internal/extsync/engine.go`, `cmd/sync.go` (`Options.Extractor`)

**Interfaces:**
- Produces (`package extract`):

```go
const (
	MaxDownload     = 25 << 20
	MaxTextRunes    = 200_000
	MaxPDFPages     = 300
	MaxOCRPages     = 50
)
const (
	StatusOK = "ok"; StatusSkippedType = "skipped_type"; StatusTooLarge = "too_large"
	StatusOCRPending = "ocr_pending"; StatusOCRUnavailable = "ocr_unavailable"; StatusFailed = "failed"
)
type OCR interface { // Task 10 implements it; nil = unavailable
	Recognize(ctx context.Context, path string, pages []int) (map[int]string, error)
}
type Extractor struct { TempDir string; OCR OCR }
func (x *Extractor) Extract(ctx context.Context, mediaType, name string, r io.Reader) ([]extsync.Section, string, error)
```

Dispatch by media type, then by extension as fallback. Text/csv/json/xml/md → one section (UTF-8 validated, invalid → `failed`); html → text via `x/net/html` (strip tags, keep block breaks); docx → paragraphs from `word/document.xml` (`w:p` → line, `w:tab` → tab), headings (`w:pStyle` `Heading1..3`) start new sections; xlsx → per sheet a section, rows from `xl/worksheets/sheet*.xml` with shared strings from `xl/sharedStrings.xml`, cells ` | `; pptx → one section per slide from `ppt/slides/slide*.xml` (`a:t`), numeric slide order; PDF → write to a temp file in `TempDir` (0600, removed via defer), `ledongthuc/pdf` per page up to `MaxPDFPages`; pages with < 20 non-space runes are collected for OCR; if any such pages and `OCR == nil` → status `ocr_unavailable` (text pages still returned); OCR error → `ocr_pending`; images (png/jpeg/heic/tiff/gif) → OCR of the temp file (nil → `ocr_unavailable`); others → `skipped_type`. Enforce `MaxTextRunes` across sections. Every temp file lives under `TempDir` and is removed before `Extract` returns.

Engine side (`attachments.go`): the **attachments stream** (`attachment_cursor`/`attachment_token`) — version gate; `Fetch` → if `Size > MaxDownload` → row with `too_large`, no download; else `Download(max)` → `Extractor.Extract` → upsert with sections + `extract_status`; `ErrTooLarge` during read → `too_large`. `Options.Extractor == nil` → `skipped_type`. Attachment rows get `parent_ext_id`.

- [ ] **Step 1: Fixtures.** Generate the Office/PDF fixtures with a tiny Go program in `internal/extract/testdata/gen/main.go` (build-tag `ignore`) using `archive/zip` for OOXML and a minimal handwritten PDF for `sample.pdf`; commit both the generator and outputs. `scanned.pdf`: a single page with an embedded image and no text operators (the generator writes it).
- [ ] **Step 2: Failing tests** (`extract_test.go`): one test per format asserting exact extracted strings; `TestPDFTextlessPageWithoutOCR` → `ocr_unavailable`; `TestPDFTextlessPageWithFakeOCR` → OCR text present, fake received page index 0; `TestUnknownTypeSkipped`; `TestTextCap` (300k-rune txt → ≤ 200k); `TestTempDirEmptyAfterExtract` for every fixture (walk `TempDir`, expect no files). Engine (`attachments_test.go`): version gate for attachments; size above cap → `too_large` and `Download` never called; nil extractor → `skipped_type`; **`TestEXT03_BinariesNeverPersisted`**: after a full pass with a PDF + image attachment, (a) the temp dir is empty, (b) no `ext_documents.sections_json` contains the attachment's raw leading bytes (`%PDF-`, PNG magic), (c) `SELECT typeof(...)` shows no BLOB column values anywhere in `ext_*`. Add EXT-03 to `docs/inventory/external-sources.md`.
- [ ] **Step 3: Run** `go test ./internal/extract ./internal/extsync` → FAIL. **Step 4: Implement.** **Step 5: Run** → PASS.
- [ ] **Step 6: Commit** `feat(extract,extsync): attachment text extraction (plain/OOXML/PDF), EXT-03`.

---

### Task 10: OCR helper (`watchtower-ocr`) + Go invoker + retry

**Files:**
- Create: `WatchtowerDesktop/Sources/OCRHelper/main.swift`, `WatchtowerDesktop/Sources/OCRHelper/OCRRecognizer.swift`, `WatchtowerDesktop/Tests/OCRHelperTests/OCRRecognizerTests.swift`, `internal/extract/ocr.go`, `internal/extract/ocr_test.go`, `internal/extsync/ocr_retry.go`, `internal/extsync/ocr_retry_test.go`
- Modify: `WatchtowerDesktop/Package.swift` (executable target `watchtower-ocr` from `Sources/OCRHelper`, **no dependencies**; test target), `scripts/build-app.sh` (build it in release, `cp` to `Contents/MacOS/watchtower-ocr`, codesign with the same identity/flags as the CLI at lines ~355/363), `WatchtowerDesktop/Sources/WatchtowerCore/Utilities/CLIBinaryStore.swift` (+ `Constants.swift`: `bundledOCRHelperPath()`; `sync` copies the helper next to the stored CLI with the same size+SHA256 validation; the CLI and the helper are validated independently — a helper mismatch never blocks the CLI), `cmd/sync.go` (wire `extract.NewHelperOCR`)

**Interfaces:**
- Produces:
  - Helper CLI: `watchtower-ocr <file> [--pages 0,2,5]` → stdout `{"pages":[{"index":0,"text":"…"}]}`, exit 0; unreadable file → exit 2 + stderr message; images ignore `--pages` (index 0).
  - Go: `func NewHelperOCR(path string, timeout time.Duration) OCR` (nil-safe constructor returns nil OCR when `path == ""`); `func ResolveHelperPath() string` — `$WATCHTOWER_OCR_HELPER` if set and executable, else `filepath.Join(filepath.Dir(os.Executable()), "watchtower-ocr")` if executable, else `""`.
  - Engine: `retryOCR(ctx, src)` — rows with `extract_status IN ('ocr_pending','ocr_unavailable') AND extract_attempts < 3`, re-download + re-extract, `extract_attempts++`; runs after the attachments stream, within budget. `ocr_unavailable` rows are retried only when the extractor now has OCR (skip entirely otherwise — no pointless downloads).

- [ ] **Step 1: Swift failing test** (`OCRRecognizerTests`): render "Hello Watchtower 42" into a 1200×300 `CGImage` with CoreText (no files), run `OCRRecognizer.recognize(image:)`, assert the result contains `Watchtower` and `42`. PDF test: build a one-page PDF with PDFKit from that image, `recognize(pdfURL:pages:[0])` returns the same text at index 0.
- [ ] **Step 2: Run** `make test-swift FILTER=OCRRecognizerTests` → FAIL. **Step 3: Implement** `OCRRecognizer` (`VNRecognizeTextRequest`, `.accurate`, `recognitionLanguages = ["ru-RU","uk-UA","en-US"]`, `usesLanguageCorrection = true`; PDF pages rendered via `PDFPage.thumbnail(of:for:)` at 2× the media box) and `main.swift` (arg parsing, JSON via `JSONEncoder`, `MaxOCRPages` = 50 enforced here too). **Step 4: Run** → PASS.
- [ ] **Step 5: Go failing tests** (`ocr_test.go`): a fake helper script written to `t.TempDir()` (`#!/bin/sh` echoing fixed JSON; another variant sleeping past a 200 ms timeout; another exiting 2) → parsed map / timeout error / exit error; `ResolveHelperPath` honors the env var. `ocr_retry_test.go`: pending row with attempts 0 → retried, text stored, status ok; attempts 3 → not retried; `ocr_unavailable` with extractor lacking OCR → no download.
- [ ] **Step 6: Run** `go test ./internal/extract ./internal/extsync` → FAIL → implement → PASS.
- [ ] **Step 7: Bundle.** Update `build-app.sh`, `CLIBinaryStore`, run `make test-swift FILTER=CLIBinaryStore` (extend its tests: helper copied; helper mismatch leaves CLI resolution intact). Verify `make app-dev` produces `Contents/MacOS/watchtower-ocr` (ls the bundle) — do **not** rebuild while a Watchtower app/daemon from this bundle is running (memory: rebuilding under a live binary breaks Security.framework).
- [ ] **Step 8: Commit** `feat(ocr): watchtower-ocr Vision helper, bundling, Go invoker and retry`.

---

### Task 11: Desktop — Confluence section in Jira account settings

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/ExtSource.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ExtSourceQueries.swift`, `WatchtowerDesktop/Sources/ViewModels/ConfluenceSpacesViewModel.swift`, `WatchtowerDesktop/Sources/Views/Settings/ConfluenceSpacesSection.swift`, `WatchtowerDesktop/Tests/Core/ExtSourceQueriesTests.swift`, `WatchtowerDesktop/Tests/ConfluenceSpacesViewModelTests.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/JiraConnectionDetail.swift` (embed the section per account), `AppState` (hold `ConfluenceSpacesViewModel`s keyed by Jira account id so a running select/sync survives navigation), `WatchtowerDesktop/Tests/.../TestDatabase.swift` (ext tables DDL, mirroring `schema.sql`), `docs/app-guide.md`

**Interfaces:**
- Consumes: CLI `confluence spaces --json --account N`, `confluence select/unselect KEY --account N`, `confluence status --json`; tables `ext_sources` + counts.
- Produces: `struct ExtSource: FetchableRecord, Decodable` (columns of `ext_sources` used by the UI: id, jira_account_id, container_key, container_name, status, error, backfill_done, last_synced_at); `ExtSourceQueries.fetchForJiraAccount(_ db: Database, accountID: Int64) throws -> [ExtSource]` and `documentCount(_ db:, sourceID:) throws -> Int`; `@Observable final class ConfluenceSpacesViewModel` with `spaces: [SpaceRow]` (`key`, `name`, `selected`, `status`, `error`, `docCount`, `backfillDone`), `isLoading`, `errorMessage`, `needsConsent: Bool`, `func load() async`, `func setSelected(_ key: String, _ on: Bool) async`, `func reconsent()` (invokes the existing Jira login flow used by `JiraConnectionDetail` for that account).

UI: section header "Confluence"; feature-off caption with an "Enable" button (`FeatureManagerService.enableNow("knowledge-connectors")`, the Reaction cheat-sheet precedent); `needsConsent` → explanation + "Grant Confluence access" button → `reconsent()`; otherwise a searchable list of spaces with toggles, each selected row showing status (Syncing… while `!backfillDone`, error text in red, `N documents · synced <relative time>`). Use the house CLI runner used by `JiraAccountsViewModel` (same env, same `Constants.findCLIPath()`).

- [ ] **Step 1: Failing Core test** (`ExtSourceQueriesTests`): in-memory `TestDatabase` with two sources for account 1 and one for account 2 → `fetchForJiraAccount(1)` returns two, ordered by `container_name`; `documentCount` counts pages+blogposts+attachments.
- [ ] **Step 2: Failing VM test** (`ConfluenceSpacesViewModelTests`) with an injected CLI runner fake: `load()` merges `spaces --json` with DB statuses; the runner returning the re-login message → `needsConsent == true`; `setSelected("ENG", true)` calls `confluence select ENG --account 1` then reloads; a failed select sets `errorMessage` and leaves `selected` false; start `setSelected`, drop the view reference, VM still completes (VM owned by AppState — the navigation rule).
- [ ] **Step 3: Run** `make test-swift FILTER=ExtSourceQueriesTests` and `FILTER=ConfluenceSpacesViewModelTests` → FAIL. **Step 4: Implement** (use the `add-desktop-feature` skill's stack order: Model → Queries → VM → View). **Step 5: Run** → PASS.
- [ ] **Step 6:** Update `docs/app-guide.md` (Settings → Jira → Confluence). **Commit** `feat(desktop): Confluence spaces picker in Jira account settings`.

---

### Task 12: `doc_links` + `get_task_context` Confluence section

**Files:**
- Create: `internal/doclinks/detect.go`, `internal/doclinks/detect_test.go`, `internal/db/doc_links.go`, `internal/db/doc_links_test.go`
- Modify: `internal/extsync/engine.go` (call link detection for written Confluence docs/comments), `internal/daemon/daemon.go` (`phaseExternalSync` also runs `doclinks.ScanSources` when the feature is on), `internal/tools/taskcontext.go` (+ test), `internal/kb/source_ext.go` (inbound links in meta for pages)

**Interfaces:**
- Produces:

```go
// package doclinks
var confluenceURL = regexp.MustCompile(`https://[a-z0-9-]+\.atlassian\.net/wiki/spaces/[^/\s]+/pages/(\d+)`)
func JiraKeys(text string) []string                                   // wraps the exported jira key regexp
func ConfluencePageIDs(text string, siteHosts map[string]string) []string // host → cloud_id; returns "<cloud_id>:<page_id>"
func LinkConfluenceDoc(ctx context.Context, q Queryer, fromRef string, texts ...string) error // replace links of fromRef
func ScanSources(ctx context.Context, d *db.DB, budget time.Duration) (int, error) // Slack/Gmail/IMAP/Jira since ext_link_state cursors
// package db
func (db *DB) DocLinksTo(toKind, toRef string, limit int) ([]DocLink, error)
func (db *DB) DocLinksFrom(fromKind, fromRef string) ([]DocLink, error)
type DocLink struct{ FromKind, FromRef, ToKind, ToRef, DetectedAt string }
```

- Confluence doc/comment/attachment text → `(confluence, confluence:<source_id>:<ext_id>, jira_issue, KEY)`; replaced wholesale per `fromRef` on every write (removed mentions disappear).
- `ScanSources`: per kind, rows after the cursor in `ext_link_state` — Slack `messages` by `rowid` (`from_ref` = the KB slack ref of its thread/channel-day, reuse the KB helper that builds it, or `slack:<channel_id>:<ts>` if no helper is reusable — pick one and pin it in a test), Gmail `gmail_messages` / IMAP / Jira comments+issues by their `synced_at`; each finds Confluence page URLs whose host belongs to a connected Jira account (`jira_accounts.site_url` → `cloud_id`), inserts `(<kind>, <ref>, confluence_page, <cloud_id>:<page_id>)`. Batches of 1000 rows, budget-checked between batches, cursor saved in the batch tx. First run backfills from an empty cursor.
- `get_task_context`: new section `confluence` (cap 5): pages from `DocLinksTo("jira_issue", KEY)` + top `kb.Search` hits for the key with `Sources: ["confluence"]`, deduped, each `{title, link, space, snippet}`; omitted when empty (DEV-03 shape, the existing sections' pattern).
- Confluence page KB meta: `Discussed in: <n> Slack threads, <m> emails` from `DocLinksTo("confluence_page", "<cloud_id>:<page_id>")` — counts only, so meta stays stable for the content hash unless counts change.

- [ ] **Step 1: Failing tests:** detector unit tests (keys; URLs on connected vs foreign hosts; `/wiki/x/tiny` ignored in v1 — assert it's ignored); `LinkConfluenceDoc` replace semantics; `ScanSources` over seeded Slack/Gmail rows with cursor resume across two calls with a tiny budget; `get_task_context` for a key linked from a seeded Confluence page includes the section, and a key with no links omits it (existing taskcontext test harness).
- [ ] **Step 2: Run** `go test ./internal/doclinks ./internal/db ./internal/tools ./internal/extsync` → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: cross-source doc_links (Jira keys, Confluence URLs) and task-context Confluence section`.

---

### Task 13: Docs, real-data smoke, plan guards, gates

**Files:**
- Modify: `CLAUDE.md` (new "Confluence knowledge connector (2026-09-26)" feature note in the house style: tables, phase, feature flag, contracts, v1 limits), `docs/inventory/knowledge-search.md` (changelog), `docs/app-guide.md` (if Task 11 didn't cover all), `internal/extsync/plan_test.go` (new)

- [ ] **Step 1: EXPLAIN guards** (`plan_test.go`, the KB precedent): for the hot queries — `localVersions` (by `source_id` + `ext_id IN (...)`), comments by page (`idx_ext_comments_page`), KB `extSource.Changed` (`idx_ext_documents_synced`), `DocLinksTo` (`idx_doc_links_to`) — assert `EXPLAIN QUERY PLAN` uses the intended index and has no `SCAN ext_documents` without an index. Fix queries with `+col` if the planner picks a wrong index.
- [ ] **Step 2: Real-data smoke** (owner's machine, copy of the DB, never the live one): `cp` the workspace DB to the scratchpad; `WATCHTOWER_DB=<copy>` (or the flag the CLI uses — check `cmd/root.go`) → `watchtower jira login --account 1` (re-consent; needs the Atlassian app to have Confluence scopes — **owner prerequisite**, spec §5; if not done, stop and report), `watchtower confluence spaces`, `select` one mid-sized space, `watchtower confluence sync --force` repeatedly until backfill is done, `watchtower kb reindex --force` / let `kb` run, `watchtower kb search "<a phrase from a known page>"`. Record timings, DB growth, counts per `extract_status`, and any errors in the PR description.
- [ ] **Step 3: Full gates:** `make test` (log to a file, check `$?` explicitly — memory: never trust `tail`), `make test-swift`, `make lint-all`. Fix what fails.
- [ ] **Step 4: Commit** `docs: Confluence connector feature note, inventory; extsync plan guards`.
- [ ] **Step 5:** Hand over for the `local-review` skill (final PR into `main` → debate-review panel) — do not open the PR before the review converges.

---

## Self-review notes (plan author)

- Spec §5 "scope persisted in the token file" — `OAuthToken.Scope` already exists; Task 1 guards refresh keeping it.
- Spec §6 "writes ok back" — Task 4 status tests.
- Spec §6 step 6 users cache — Task 4. Step 7 doc_links — Task 12.
- Spec §8.1 no TCC — helper reads only files under `WorkspaceDir()/tmp/extract` (Task 9 temp dir) and uses no protected API.
- CQL timezone ambiguity is resolved in Task 6 by a 24 h overlap inside the fetcher (spec said 1 min; the version gate keeps it free of re-fetches). Update spec §6 in Task 6's commit to say so.
