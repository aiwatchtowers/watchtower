# Knowledge Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A mechanical, local, derived full-text index (`kb_*` tables) over Slack/Gmail/IMAP/Jira/calendar/transcripts and our derived digests/recaps/ideas, exposed as `search_knowledge` / `get_knowledge_document` MCP read tools, a daemon phase, and a `watchtower kb` CLI.

**Architecture:** New package `internal/kb` owns everything: source adapters render documents (title/meta/sections), a chunker packs sections, a store writes `kb_documents`/`kb_chunks` (FTS5 external-content `kb_fts` kept in sync by triggers) behind a content-hash gate, an indexer drives per-source cursors under a time budget, and a searcher runs multi-query bm25 + weighted RRF + bounded recency. Surfaces (`internal/tools`, `cmd/kb.go`, daemon phase, chat prompts) are thin.

**Tech Stack:** Go 1.25, `modernc.org/sqlite` via `database/sql`, SQLite FTS5 (`porter unicode61 remove_diacritics 2`), goose migrations, cobra, testify.

**Spec:** `docs/superpowers/specs/2026-09-26-knowledge-search-design.md`

## Global Constraints

- Worktree: `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/knowledge-search`, branch `feature/knowledge-search`. **Every** shell command starts with `cd /Users/user/PhpstormProjects/watchtower/.claude/worktrees/knowledge-search &&`; every file path you Read/Edit/Write is under that absolute prefix. Before committing, `git branch --show-current` must print `feature/knowledge-search`. Never run `git stash`, `git reset`, `git clean`, `git checkout .`/`restore .`, or `git add -A` — add files by explicit path.
- **One SQLite connection.** `db.Open` sets `MaxOpenConns(1)`. Therefore: (a) inside a transaction, every read MUST go through the `*sql.Tx` (the `Queryer` passed in), never through `*db.DB`; (b) never issue a query while iterating another query's `rows` — scan all rows into a slice, `rows.Close()`, then do follow-up lookups. Violating either deadlocks the test.
- Zero AI: `internal/kb` must not import `internal/digest`, `internal/ai`, `internal/codex`, `internal/ollama`, `internal/providers` (KB-02).
- Constants (verbatim from spec): `ChunkChars = 2000` (runes); Slack rowid range `slackRange = 20000`; Slack tail rescan `48h`; write batch `batchSize = 200` documents per transaction; daemon cycle budget `60s`; per-query candidates `50`; RRF `k = 50`, AND weight `1.0`, OR weight `0.5`; bm25 column weights `4.0, 1.0, 2.0` (title, body, meta); recency `max(1/(1+0.5·age_years), 0.75)`, unknown time → `0.75`; search `limit` default 10, max 25; queries 1–5; `get_knowledge_document` `max_chars` default 12000; config key `knowledge.enabled` default `true`; feature id `knowledge-search`, `CostNone`.
- Text normalization (index and query): `ё→е`, `Ё→Е`.
- Refs (document ids): `slack:thread:<channel_id>:<thread_ts>`, `slack:day:<channel_id>:<YYYY-MM-DD>`, `gmail:<account_id>:<thread_id>` (empty thread id → `m:<message_id>`), `imap:<account_id>:<uidvalidity>:<uid>`, `jira:<account_id>:<KEY>`, `calendar:<event_id>`, `transcript:<id>`, `recap:<id>`, `digest:<digest_id>:<idx>`, `stream_digest:<id>:<idx>`, `idea:<id>`. `channel_id` itself contains a colon (`1:C123`) — parse Slack refs from the **right**.
- Repo text (code, comments, docs, commits) in English. Commits end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Inner loop: `go test ./internal/kb` (no `-count=1`). Lint before each commit: `make lint-diff`.

## Review Focus

1. **A huge channel-day** (the real DB has one with 16 184 messages) — must chunk into many ≤2000-rune chunks, index in bounded time, and never hold all rows' names in N+1 queries per message. Pinned in Task 4 (3 000-message day test).
2. **Hostile query text** — `"`, `(`, `)`, `NEAR`, `-foo`, `*` alone, `:`, emoji, only punctuation — must never produce an FTS5 syntax error; empty → no hits, no error. Pinned in Task 7.
3. **Half-built index** (Slack backfill in progress) — other sources still return hits and `index_note` says `slack NN% indexed`. Pinned in Task 7.
4. **Recent Slack edit/delete in place** (upsert keeps rowid) — reflected on the next run via the 48h tail rescan; an all-deleted thread disappears from the index. Pinned in Task 6.
5. **Unparsable or missing timestamps** (Jira `…+0100` format, empty `updated_at`, `attendees = null`) — indexed anyway, recency floor applies, no panic. Pinned in Tasks 5 and 7.

---

## File Structure

```
internal/db/migrations/00072_knowledge_index.sql   kb tables + FTS + triggers
internal/db/schema.sql                              mirror
internal/kb/doc.go          Doc/Section/Chunk types, BuildChunks, contentHash
internal/kb/normalize.go    Normalize, ResolveSlackMarkup, jsonTexts, parseTime
internal/kb/store.go        Queryer, writeDoc, deleteDoc, cursors, docIDs
internal/kb/source.go       Source interface, allSources(), ref helpers
internal/kb/source_slack.go
internal/kb/source_mail.go      gmail + imap
internal/kb/source_work.go      jira + calendar
internal/kb/source_derived.go   transcript, recap, digest, stream_digest, idea
internal/kb/indexer.go      Run, Reindex, Options, Stats
internal/kb/status.go       Status, SourceStatus, indexNote
internal/kb/query.go        BuildMatch
internal/kb/search.go       Search, Request, Result, Hit, GetDocument, DocView
internal/kb/*_test.go       + contracts_test.go (KB-01..03)
internal/tools/knowledge.go + knowledge_test.go
internal/tools/readtools.go (register)
internal/mcp/server_test.go (lists)
internal/ai/prompt.go + prompt_test.go
internal/config/config.go, defaults.go; cmd/config.go (allowlist)
internal/features/registry.go
internal/daemon/daemon.go (phaseKnowledgeIndex)
cmd/kb.go + cmd/kb_test.go
WatchtowerDesktop/Sources/ViewModels/{Chat,TargetChat,IdeaChat,MeetingChat}ViewModel.swift, Views/Tracks/TrackChatView.swift
docs/inventory/knowledge-search.md, docs/inventory/README.md, CLAUDE.md, docs/app-guide.md
```

Note: the spec's §4 put kb SQL in `internal/db/kb.go`; this plan keeps it inside `internal/kb` (raw SQL in feature packages is established — `internal/inbox/*_detector.go`, `internal/dayplan/gather.go`) so the package is self-contained and KB-01's "nothing else touches kb tables" is easy to see. Task 1 amends the spec line.

---

### Task 1: Migration and schema

**Files:**
- Create: `internal/db/migrations/00072_knowledge_index.sql`
- Modify: `internal/db/schema.sql` (append the same DDL at the end, with a `-- Knowledge search (see 00072)` header comment)
- Modify: `internal/db/db_test.go` (`TestAllTablesExist` `expectedTables`: add `"kb_documents", "kb_chunks", "kb_sources"`)
- Regenerate: `internal/db/testdata/schema_v73.golden` (or whatever `TestSchemaGolden` writes — run with `-update`)
- Modify: `docs/superpowers/specs/2026-09-26-knowledge-search-design.md` §4 line "SQL lives in `internal/db/kb.go`" → "All kb SQL lives in `internal/kb` (feature-package raw SQL, the `internal/inbox` detector precedent)."

**Interfaces:**
- Produces: tables `kb_documents`, `kb_chunks`, `kb_fts`, `kb_sources` exactly as below.

- [ ] **Step 1: Write the migration**

```sql
-- +goose Up
-- Knowledge search (spec docs/superpowers/specs/2026-09-26-knowledge-search-design.md).
-- A derived, rebuildable index (KB-01): nothing here is a source of truth.
CREATE TABLE IF NOT EXISTS kb_documents (
    id            TEXT PRIMARY KEY,
    source        TEXT NOT NULL,
    title         TEXT NOT NULL DEFAULT '',
    doc_time      TEXT NOT NULL DEFAULT '',
    doc_time_unix REAL NOT NULL DEFAULT 0,
    link          TEXT NOT NULL DEFAULT '',
    anchor_json   TEXT NOT NULL DEFAULT '{}',
    meta          TEXT NOT NULL DEFAULT '',
    content_hash  TEXT NOT NULL DEFAULT '',
    chunk_count   INTEGER NOT NULL DEFAULT 0,
    indexed_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_kb_documents_source_time ON kb_documents(source, doc_time_unix);

CREATE TABLE IF NOT EXISTS kb_chunks (
    id      INTEGER PRIMARY KEY,
    doc_id  TEXT NOT NULL REFERENCES kb_documents(id) ON DELETE CASCADE,
    idx     INTEGER NOT NULL,
    title   TEXT NOT NULL DEFAULT '',
    body    TEXT NOT NULL,
    meta    TEXT NOT NULL DEFAULT '',
    anchor  TEXT NOT NULL DEFAULT '',
    UNIQUE(doc_id, idx)
);

CREATE VIRTUAL TABLE IF NOT EXISTS kb_fts USING fts5(
    title, body, meta,
    content='kb_chunks', content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2'
);

-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS kb_chunks_ai AFTER INSERT ON kb_chunks BEGIN
    INSERT INTO kb_fts(rowid, title, body, meta) VALUES (NEW.id, NEW.title, NEW.body, NEW.meta);
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS kb_chunks_ad AFTER DELETE ON kb_chunks BEGIN
    INSERT INTO kb_fts(kb_fts, rowid, title, body, meta) VALUES ('delete', OLD.id, OLD.title, OLD.body, OLD.meta);
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS kb_chunks_au AFTER UPDATE ON kb_chunks BEGIN
    INSERT INTO kb_fts(kb_fts, rowid, title, body, meta) VALUES ('delete', OLD.id, OLD.title, OLD.body, OLD.meta);
    INSERT INTO kb_fts(rowid, title, body, meta) VALUES (NEW.id, NEW.title, NEW.body, NEW.meta);
END;
-- +goose StatementEnd

CREATE TABLE IF NOT EXISTS kb_sources (
    source             TEXT PRIMARY KEY,
    cursor             TEXT NOT NULL DEFAULT '',
    last_reconciled_at TEXT NOT NULL DEFAULT '',
    updated_at         TEXT NOT NULL DEFAULT ''
);

-- +goose Down
DROP TRIGGER IF EXISTS kb_chunks_au;
DROP TRIGGER IF EXISTS kb_chunks_ad;
DROP TRIGGER IF EXISTS kb_chunks_ai;
DROP TABLE IF EXISTS kb_fts;
DROP TABLE IF EXISTS kb_chunks;
DROP TABLE IF EXISTS kb_sources;
DROP TABLE IF EXISTS kb_documents;
```

- [ ] **Step 2: Mirror into `schema.sql`, add tables to `TestAllTablesExist`**
- [ ] **Step 3: Run** `go test ./internal/db/ -run 'TestAllTablesExist|TestSchemaGolden|TestMigrat' ` — expect `TestSchemaGolden` FAIL (drift), others PASS.
- [ ] **Step 4: Regenerate golden** `go test ./internal/db/ -run TestSchemaGolden -update`, then `go test ./internal/db/` — PASS. Check `git status`: only the migration, schema.sql, db_test.go, golden (and spec) changed. If the golden file name changed (e.g. `schema_v74.golden`), follow whatever the test writes and remove nothing by hand.
- [ ] **Step 5: FTS smoke test** — add to `internal/db/db_test.go`:

```go
func TestKBFTSTriggersSync(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO kb_documents(id, source) VALUES ('x:1','idea')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO kb_chunks(doc_id, idx, title, body, meta) VALUES ('x:1',0,'Title','договорились о релизе','')`)
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_fts WHERE kb_fts MATCH '"договор"*'`).Scan(&n))
	assert.Equal(t, 1, n)
	_, err = d.Exec(`DELETE FROM kb_chunks WHERE doc_id='x:1'`)
	require.NoError(t, err)
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_fts WHERE kb_fts MATCH '"договор"*'`).Scan(&n))
	assert.Equal(t, 0, n)
}
```
(Use whatever assert/require imports `db_test.go` already uses; if it uses plain `t.Fatalf`, write it that way instead.) Run `go test ./internal/db/ -run TestKBFTSTriggersSync` — PASS.

- [ ] **Step 6: Commit** `feat(db): knowledge index tables (migration 00072)`.

---

### Task 2: Core types, normalization, chunking

**Files:**
- Create: `internal/kb/doc.go`, `internal/kb/normalize.go`
- Test: `internal/kb/doc_test.go`, `internal/kb/normalize_test.go`

**Interfaces:**
- Produces:
  - `type Section struct{ Text, Anchor string }`
  - `type Doc struct{ ID, Source, Title, Meta, Link string; Time time.Time; Anchor map[string]string; Sections []Section }`
  - `type Chunk struct{ Idx int; Body, Anchor string }`
  - `const ChunkChars = 2000`
  - `func BuildChunks(sections []Section) []Chunk`
  - `func contentHash(d *Doc, chunks []Chunk) string`
  - `func Normalize(s string) string`
  - `func ResolveSlackMarkup(text string, userName func(rawID string) string) string`
  - `func jsonTexts(raw string) []string`
  - `func parseTime(s string) time.Time` (zero on failure)

- [ ] **Step 1: Write failing tests** (`internal/kb/normalize_test.go`)

```go
package kb

import (
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestNormalize_FoldsYo(t *testing.T) {
	assert.Equal(t, "Договоренность ее", Normalize("Договорённость её"))
	assert.Equal(t, "ЕЖ", Normalize("ЁЖ"))
}

func TestResolveSlackMarkup(t *testing.T) {
	names := map[string]string{"U1": "Anna"}
	lookup := func(id string) string { return names[id] }
	in := "hi <@U1>, see <#C9|general> and <https://x.io/a|the doc> or <https://y.io> <!here> <@U404>"
	got := ResolveSlackMarkup(in, lookup)
	assert.Equal(t, "hi @Anna, see #general and the doc (https://x.io/a) or https://y.io @here @U404", got)
}

func TestResolveSlackMarkup_LabelledMentionKeepsLabel(t *testing.T) {
	got := ResolveSlackMarkup("ping <@U2|Bob>", func(string) string { return "" })
	assert.Equal(t, "ping @Bob", got)
}

func TestJSONTexts(t *testing.T) {
	raw := `[{"text":"Split releases","by":"@v","message_ts":"1.2","importance":"medium"},` +
		`{"text":"Second","status":"open"}]`
	assert.Equal(t, []string{"Split releases", "Second"}, jsonTexts(raw))
	recap := `{"summary":"Sync","key_decisions":["A","B"],"action_items":[{"text":"do X","assignee":"@a"}],"n":3}`
	assert.Equal(t, []string{"Sync", "A", "B", "do X"}, jsonTexts(recap))
	assert.Nil(t, jsonTexts(""))
	assert.Nil(t, jsonTexts("null"))
	assert.Nil(t, jsonTexts("{not json"))
}

func TestParseTime(t *testing.T) {
	cases := map[string]string{
		"2026-04-20T09:37:38.027+0100": "2026-04-20T08:37:38Z",
		"2026-07-22T17:01:54Z":         "2026-07-22T17:01:54Z",
		"2026-09-11":                   "2026-09-11T00:00:00Z",
		"2026-09-11 10:00:00":          "2026-09-11T10:00:00Z",
	}
	for in, want := range cases {
		assert.Equal(t, want, parseTime(in).UTC().Truncate(time.Second).Format(time.RFC3339), in)
	}
	assert.True(t, parseTime("").IsZero())
	assert.True(t, parseTime("garbage").IsZero())
	_ = strings.TrimSpace
}
```

`internal/kb/doc_test.go`:

```go
package kb

import (
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestBuildChunks_PacksSmallSections(t *testing.T) {
	chunks := BuildChunks([]Section{{Text: "a", Anchor: "1"}, {Text: "b", Anchor: "2"}})
	require.Len(t, chunks, 1)
	assert.Equal(t, "a\nb", chunks[0].Body)
	assert.Equal(t, "1", chunks[0].Anchor)
}

func TestBuildChunks_StartsNewChunkAtLimit(t *testing.T) {
	big := strings.Repeat("я", 1500)
	chunks := BuildChunks([]Section{{Text: big, Anchor: "1"}, {Text: big, Anchor: "2"}})
	require.Len(t, chunks, 2)
	assert.Equal(t, "2", chunks[1].Anchor)
	assert.Equal(t, 1, chunks[1].Idx)
}

func TestBuildChunks_SplitsOversizedSectionAtWhitespace(t *testing.T) {
	words := strings.Repeat("слово ", 900) // 5400 runes
	chunks := BuildChunks([]Section{{Text: words, Anchor: "a"}})
	require.GreaterOrEqual(t, len(chunks), 3)
	for _, c := range chunks {
		assert.LessOrEqual(t, utf8.RuneCountInString(c.Body), ChunkChars)
		assert.Equal(t, "a", c.Anchor)
		assert.False(t, strings.HasPrefix(c.Body, " "))
	}
}

func TestBuildChunks_HardSplitWithoutWhitespace(t *testing.T) {
	chunks := BuildChunks([]Section{{Text: strings.Repeat("x", 4100)}})
	require.Len(t, chunks, 3)
	assert.Equal(t, ChunkChars, utf8.RuneCountInString(chunks[0].Body))
}

func TestBuildChunks_SkipsBlankSections(t *testing.T) {
	assert.Empty(t, BuildChunks([]Section{{Text: "  "}, {Text: ""}}))
	assert.Empty(t, BuildChunks(nil))
}

func TestContentHash_ChangesWithContent(t *testing.T) {
	d := &Doc{ID: "idea:1", Title: "T", Time: time.Unix(10, 0), Anchor: map[string]string{"idea_id": "1"}}
	h1 := contentHash(d, BuildChunks([]Section{{Text: "a"}}))
	h2 := contentHash(d, BuildChunks([]Section{{Text: "b"}}))
	assert.NotEqual(t, h1, h2)
	assert.Equal(t, h1, contentHash(d, BuildChunks([]Section{{Text: "a"}})))
}
```

- [ ] **Step 2: Run** `go test ./internal/kb` — FAIL (package/functions undefined).
- [ ] **Step 3: Implement** `internal/kb/normalize.go`:

```go
// Package kb is the knowledge-search index: a mechanical, derived, rebuildable
// full-text index over raw and derived Watchtower data (spec
// docs/superpowers/specs/2026-09-26-knowledge-search-design.md). It makes no
// model calls (KB-02) and never writes a source table (KB-01).
package kb

import (
	"encoding/json"
	"regexp"
	"strings"
	"time"
)

var yoReplacer = strings.NewReplacer("ё", "е", "Ё", "Е")

// Normalize applies the index/query text normalization shared by both sides:
// FTS5's remove_diacritics does not fold ё to е, so we do.
func Normalize(s string) string { return yoReplacer.Replace(s) }

var (
	reUserMention = regexp.MustCompile(`<@([UW][A-Z0-9]+)(?:\|([^>]*))?>`)
	reChannelRef  = regexp.MustCompile(`<#C[A-Z0-9]+(?:\|([^>]*))?>`)
	reSpecial     = regexp.MustCompile(`<!([a-z]+)(?:\|[^>]*)?>`)
	reLabelledURL = regexp.MustCompile(`<(https?://[^|>]+)\|([^>]+)>`)
	reBareURL     = regexp.MustCompile(`<(https?://[^>]+)>`)
)

// ResolveSlackMarkup turns Slack's wire markup into readable, searchable text.
// userName resolves a raw user id ("U123"); "" means unknown and the id stays.
func ResolveSlackMarkup(text string, userName func(rawID string) string) string {
	text = reUserMention.ReplaceAllStringFunc(text, func(m string) string {
		sub := reUserMention.FindStringSubmatch(m)
		if sub[2] != "" {
			return "@" + sub[2]
		}
		if name := userName(sub[1]); name != "" {
			return "@" + name
		}
		return "@" + sub[1]
	})
	text = reChannelRef.ReplaceAllStringFunc(text, func(m string) string {
		sub := reChannelRef.FindStringSubmatch(m)
		if sub[1] != "" {
			return "#" + sub[1]
		}
		return "#channel"
	})
	text = reSpecial.ReplaceAllString(text, "@$1")
	text = reLabelledURL.ReplaceAllString(text, "$2 ($1)")
	text = reBareURL.ReplaceAllString(text, "$1")
	return text
}

// jsonTextKeys are the object keys whose string values are prose worth
// indexing; everything else (authors, ts, statuses, importance) is metadata.
var jsonTextKeys = map[string]bool{
	"text": true, "title": true, "summary": true, "description": true, "decision": true,
	"question": true, "item": true, "what": true, "essence": true, "quote": true, "outcome": true,
}

// jsonTexts extracts the prose strings of a JSON document in document order:
// top-level strings, strings inside arrays, and allow-listed object keys.
// Invalid or empty JSON yields nil.
func jsonTexts(raw string) []string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	dec := json.NewDecoder(strings.NewReader(raw))
	var out []string
	var walk func(take bool) bool
	walk = func(take bool) bool {
		tok, err := dec.Token()
		if err != nil {
			return false
		}
		switch v := tok.(type) {
		case string:
			if take && strings.TrimSpace(v) != "" {
				out = append(out, v)
			}
		case json.Delim:
			switch v {
			case '[':
				for dec.More() {
					if !walk(true) {
						return false
					}
				}
				_, err = dec.Token()
				return err == nil
			case '{':
				for dec.More() {
					kt, err := dec.Token()
					if err != nil {
						return false
					}
					key, _ := kt.(string)
					if !walk(jsonTextKeys[key]) {
						return false
					}
				}
				_, err = dec.Token()
				return err == nil
			}
		}
		return true
	}
	if !walk(true) {
		return nil
	}
	return out
}

var timeLayouts = []string{
	time.RFC3339Nano,
	"2006-01-02T15:04:05.000-0700",
	"2006-01-02T15:04:05-0700",
	"2006-01-02T15:04:05",
	"2006-01-02 15:04:05",
	"2006-01-02",
}

// parseTime accepts the timestamp shapes our source tables hold; zero on failure.
func parseTime(s string) time.Time {
	s = strings.TrimSpace(s)
	for _, l := range timeLayouts {
		if t, err := time.Parse(l, s); err == nil {
			return t.UTC()
		}
	}
	return time.Time{}
}
```

`internal/kb/doc.go`:

```go
package kb

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"time"
	"unicode"
)

// ChunkChars is the chunk budget in runes (~512 tokens, Onyx's chunk size).
const ChunkChars = 2000

// Section is one citable unit of a document (a message, a comment, an utterance).
type Section struct {
	Text   string
	Anchor string // source-native locator of this section (message ts, comment id, start_sec)
}

// Doc is one rendered document. ID is its ref.
type Doc struct {
	ID       string
	Source   string
	Title    string
	Meta     string
	Link     string
	Time     time.Time
	Anchor   map[string]string
	Sections []Section
}

// Chunk is a packed run of sections; Anchor is its first section's anchor.
type Chunk struct {
	Idx    int
	Body   string
	Anchor string
}

// BuildChunks packs sections into chunks of at most ChunkChars runes, never
// overlapping. A section longer than the budget is split at the last
// whitespace before the limit (hard split when there is none).
func BuildChunks(sections []Section) []Chunk {
	var chunks []Chunk
	var cur []rune
	curAnchor := ""
	flush := func() {
		body := strings.TrimSpace(string(cur))
		if body != "" {
			chunks = append(chunks, Chunk{Idx: len(chunks), Body: body, Anchor: curAnchor})
		}
		cur, curAnchor = nil, ""
	}
	for _, s := range sections {
		text := []rune(strings.TrimSpace(s.Text))
		if len(text) == 0 {
			continue
		}
		for len(text) > ChunkChars {
			flush()
			cut := splitPoint(text)
			cur, curAnchor = text[:cut], s.Anchor
			flush()
			text = []rune(strings.TrimLeftFunc(string(text[cut:]), unicode.IsSpace))
		}
		if len(text) == 0 {
			continue
		}
		sep := 0
		if len(cur) > 0 {
			sep = 1
		}
		if len(cur)+sep+len(text) > ChunkChars {
			flush()
			sep = 0
		}
		if sep == 1 {
			cur = append(cur, '\n')
		}
		if len(cur) == 0 {
			curAnchor = s.Anchor
		}
		cur = append(cur, text...)
	}
	flush()
	return chunks
}

// splitPoint returns the cut index for an over-budget rune slice: just after
// the last whitespace within the budget, or the budget itself.
func splitPoint(text []rune) int {
	for i := ChunkChars; i > ChunkChars/2; i-- {
		if unicode.IsSpace(text[i-1]) {
			return i
		}
	}
	return ChunkChars
}

// contentHash fingerprints everything written for a document, so an unchanged
// render skips the write (Onyx's gate 2).
func contentHash(d *Doc, chunks []Chunk) string {
	h := sha256.New()
	anchor, _ := json.Marshal(d.Anchor)
	for _, part := range []string{d.Source, d.Title, d.Meta, d.Link, string(anchor), d.Time.UTC().Format(time.RFC3339)} {
		h.Write([]byte(part))
		h.Write([]byte{0})
	}
	for _, c := range chunks {
		h.Write([]byte(c.Body))
		h.Write([]byte{0})
		h.Write([]byte(c.Anchor))
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))
}
```

- [ ] **Step 4: Run** `go test ./internal/kb` — PASS. Fix the implementation (not the tests) until it does; the `TestBuildChunks_HardSplitWithoutWhitespace` expectation is 2000+2000+100.
- [ ] **Step 5: Commit** `feat(kb): document types, normalization, chunking`.

---

### Task 3: Store and Source contract

**Files:**
- Create: `internal/kb/store.go`, `internal/kb/source.go`
- Test: `internal/kb/store_test.go`

**Interfaces:**
- Consumes: Task 2 types; `db.OpenTestDB(t)` (`internal/db/testhelpers.go`).
- Produces:
  - `type Queryer interface { ExecContext(ctx context.Context, q string, args ...any) (sql.Result, error); QueryContext(ctx context.Context, q string, args ...any) (*sql.Rows, error); QueryRowContext(ctx context.Context, q string, args ...any) *sql.Row }` — satisfied by `*db.DB` and `*sql.Tx`.
  - `func writeDoc(ctx context.Context, q Queryer, d *Doc) (written bool, err error)` — normalizes title/meta/section text with `Normalize`, builds chunks; zero chunks → `deleteDoc`, returns `(false, nil)`; equal `content_hash` → `(false, nil)`; else replaces doc + chunks → `(true, nil)`.
  - `func deleteDoc(ctx context.Context, q Queryer, id string) (deleted bool, err error)`
  - `func docIDs(ctx context.Context, q Queryer, source string) (map[string]bool, error)`
  - `func docIDsWithPrefix(ctx context.Context, q Queryer, prefix string) ([]string, error)`
  - `type sourceState struct{ Cursor, LastReconciledAt, UpdatedAt string }`
  - `func loadState(ctx context.Context, q Queryer, source string) (sourceState, error)` (missing row → zero value)
  - `func saveCursor(ctx context.Context, q Queryer, source, cursor string, now time.Time) error`
  - `func saveReconciled(ctx context.Context, q Queryer, source string, now time.Time) error`
  - In `source.go`: the `Source` interface below, `func allSources() []Source` (order: calendar, idea, digest, stream_digest, recap, transcript, jira, imap, gmail, slack — filled in by Tasks 4–6; start with an empty slice literal and a comment), `func sourceNames() []string`, `func sourceByName(name string) Source`.

```go
// Source renders one kind of document. Implementations read only through the
// Queryer they are given (the single SQLite connection may be inside a tx).
type Source interface {
	Name() string
	// Changed returns the document keys touched since cursor, the next cursor,
	// and whether the source is caught up (false = call again with next).
	Changed(ctx context.Context, q Queryer, cursor string, now time.Time) (keys []string, next string, done bool, err error)
	// Keys lists every document key that currently exists (daily reconcile).
	Keys(ctx context.Context, q Queryer) ([]string, error)
	// Build renders one document; nil means it no longer exists.
	Build(ctx context.Context, q Queryer, key string) (*Doc, error)
}

// progressReporter is implemented by sources whose backfill can be partial
// (Slack): the share of the source already indexed, 0..1.
type progressReporter interface {
	Progress(ctx context.Context, q Queryer, cursor string) (float64, error)
}
```

- [ ] **Step 1: Failing tests** (`internal/kb/store_test.go`)

```go
package kb

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func testDoc() *Doc {
	return &Doc{
		ID: "idea:1", Source: "idea", Title: "Релиз", Meta: "active",
		Time: time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC), Anchor: map[string]string{"idea_id": "1"},
		Sections: []Section{{Text: "договорённость о релизе", Anchor: "1"}},
	}
}

func TestWriteDoc_InsertsSkipsUnchangedReplacesChanged(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	w, err := writeDoc(ctx, d, testDoc())
	require.NoError(t, err)
	assert.True(t, w)

	w, err = writeDoc(ctx, d, testDoc())
	require.NoError(t, err)
	assert.False(t, w, "unchanged content must not be rewritten")

	doc := testDoc()
	doc.Sections = append(doc.Sections, Section{Text: "второй", Anchor: "2"})
	w, err = writeDoc(ctx, d, doc)
	require.NoError(t, err)
	assert.True(t, w)

	var body string
	require.NoError(t, d.QueryRow(`SELECT body FROM kb_chunks WHERE doc_id='idea:1'`).Scan(&body))
	assert.Equal(t, "договоренность о релизе\nвторой", body, "text is normalized (ё→е)")
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_fts WHERE kb_fts MATCH '"второй"'`).Scan(&n))
	assert.Equal(t, 1, n)
	require.NoError(t, d.QueryRow(`SELECT chunk_count FROM kb_documents WHERE id='idea:1'`).Scan(&n))
	assert.Equal(t, 1, n)
}

func TestWriteDoc_EmptyDocDeletes(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	_, err := writeDoc(ctx, d, testDoc())
	require.NoError(t, err)
	empty := testDoc()
	empty.Sections = nil
	w, err := writeDoc(ctx, d, empty)
	require.NoError(t, err)
	assert.False(t, w)
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_documents`).Scan(&n))
	assert.Equal(t, 0, n)
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_chunks`).Scan(&n))
	assert.Equal(t, 0, n)
}

func TestSourceState_RoundTrip(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	st, err := loadState(ctx, d, "slack")
	require.NoError(t, err)
	assert.Equal(t, sourceState{}, st)
	now := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	require.NoError(t, saveCursor(ctx, d, "slack", "42", now))
	require.NoError(t, saveReconciled(ctx, d, "slack", now))
	st, err = loadState(ctx, d, "slack")
	require.NoError(t, err)
	assert.Equal(t, "42", st.Cursor)
	assert.Equal(t, "2026-09-26T12:00:00Z", st.LastReconciledAt)
	assert.Equal(t, "2026-09-26T12:00:00Z", st.UpdatedAt)
}

func TestDocIDs(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	_, err := writeDoc(ctx, d, testDoc())
	require.NoError(t, err)
	ids, err := docIDs(ctx, d, "idea")
	require.NoError(t, err)
	assert.Equal(t, map[string]bool{"idea:1": true}, ids)
	pref, err := docIDsWithPrefix(ctx, d, "idea:")
	require.NoError(t, err)
	assert.Equal(t, []string{"idea:1"}, pref)
}
```

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** `internal/kb/store.go`:

```go
package kb

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// Queryer is the read/write surface shared by *db.DB and *sql.Tx.
type Queryer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

const isoLayout = "2006-01-02T15:04:05Z"

// writeDoc writes one rendered document behind the content-hash gate.
func writeDoc(ctx context.Context, q Queryer, d *Doc) (bool, error) {
	d.Title, d.Meta = Normalize(d.Title), Normalize(d.Meta)
	for i := range d.Sections {
		d.Sections[i].Text = Normalize(d.Sections[i].Text)
	}
	chunks := BuildChunks(d.Sections)
	if len(chunks) == 0 {
		_, err := deleteDoc(ctx, q, d.ID)
		return false, err
	}
	hash := contentHash(d, chunks)
	var old string
	err := q.QueryRowContext(ctx, `SELECT content_hash FROM kb_documents WHERE id = ?`, d.ID).Scan(&old)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return false, fmt.Errorf("kb: reading hash of %s: %w", d.ID, err)
	}
	if old == hash {
		return false, nil
	}
	if _, err := deleteDoc(ctx, q, d.ID); err != nil {
		return false, err
	}
	anchor, err := json.Marshal(d.Anchor)
	if err != nil {
		return false, err
	}
	docTime, docUnix := "", 0.0
	if !d.Time.IsZero() {
		docTime = d.Time.UTC().Format(isoLayout)
		docUnix = float64(d.Time.Unix())
	}
	if _, err := q.ExecContext(ctx, `INSERT INTO kb_documents
		(id, source, title, doc_time, doc_time_unix, link, anchor_json, meta, content_hash, chunk_count)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		d.ID, d.Source, d.Title, docTime, docUnix, d.Link, string(anchor), d.Meta, hash, len(chunks)); err != nil {
		return false, fmt.Errorf("kb: inserting %s: %w", d.ID, err)
	}
	for _, c := range chunks {
		if _, err := q.ExecContext(ctx, `INSERT INTO kb_chunks (doc_id, idx, title, body, meta, anchor)
			VALUES (?, ?, ?, ?, ?, ?)`, d.ID, c.Idx, d.Title, c.Body, d.Meta, c.Anchor); err != nil {
			return false, fmt.Errorf("kb: inserting chunk %d of %s: %w", c.Idx, d.ID, err)
		}
	}
	return true, nil
}

// deleteDoc removes a document and its chunks (chunks first: the FTS delete
// trigger fires per chunk row, no reliance on cascade).
func deleteDoc(ctx context.Context, q Queryer, id string) (bool, error) {
	if _, err := q.ExecContext(ctx, `DELETE FROM kb_chunks WHERE doc_id = ?`, id); err != nil {
		return false, fmt.Errorf("kb: deleting chunks of %s: %w", id, err)
	}
	res, err := q.ExecContext(ctx, `DELETE FROM kb_documents WHERE id = ?`, id)
	if err != nil {
		return false, fmt.Errorf("kb: deleting %s: %w", id, err)
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

func docIDs(ctx context.Context, q Queryer, source string) (map[string]bool, error) {
	ids, err := queryStrings(ctx, q, `SELECT id FROM kb_documents WHERE source = ?`, source)
	if err != nil {
		return nil, err
	}
	out := make(map[string]bool, len(ids))
	for _, id := range ids {
		out[id] = true
	}
	return out, nil
}

func docIDsWithPrefix(ctx context.Context, q Queryer, prefix string) ([]string, error) {
	return queryStrings(ctx, q, `SELECT id FROM kb_documents WHERE substr(id, 1, ?) = ? ORDER BY id`, len(prefix), prefix)
}

// queryStrings runs a one-column query and returns every row (rows closed
// before returning — the single-connection rule).
func queryStrings(ctx context.Context, q Queryer, query string, args ...any) ([]string, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

type sourceState struct {
	Cursor           string
	LastReconciledAt string
	UpdatedAt        string
}

func loadState(ctx context.Context, q Queryer, source string) (sourceState, error) {
	var st sourceState
	err := q.QueryRowContext(ctx, `SELECT cursor, last_reconciled_at, updated_at FROM kb_sources WHERE source = ?`, source).
		Scan(&st.Cursor, &st.LastReconciledAt, &st.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return sourceState{}, nil
	}
	return st, err
}

func saveCursor(ctx context.Context, q Queryer, source, cursor string, now time.Time) error {
	_, err := q.ExecContext(ctx, `INSERT INTO kb_sources (source, cursor, updated_at) VALUES (?, ?, ?)
		ON CONFLICT(source) DO UPDATE SET cursor = excluded.cursor, updated_at = excluded.updated_at`,
		source, cursor, now.UTC().Format(isoLayout))
	return err
}

func saveReconciled(ctx context.Context, q Queryer, source string, now time.Time) error {
	ts := now.UTC().Format(isoLayout)
	_, err := q.ExecContext(ctx, `INSERT INTO kb_sources (source, last_reconciled_at, updated_at) VALUES (?, ?, ?)
		ON CONFLICT(source) DO UPDATE SET last_reconciled_at = excluded.last_reconciled_at, updated_at = excluded.updated_at`,
		source, ts, ts)
	return err
}
```

`internal/kb/source.go`: the `Source`/`progressReporter` declarations above, plus:

```go
// allSources is the indexing order: small sources first so everything but
// Slack is searchable after the first budgeted cycle, Slack (the backfill
// giant) last.
func allSources() []Source {
	return []Source{ /* filled by Tasks 4–6 in this order:
		calendarSource{}, ideaSource{}, digestSource{}, streamDigestSource{}, recapSource{},
		transcriptSource{}, jiraSource{}, imapSource{}, gmailSource{}, newSlackSource() */ }
}

func sourceNames() []string {
	var out []string
	for _, s := range allSources() {
		out = append(out, s.Name())
	}
	return out
}

func sourceByName(name string) Source {
	for _, s := range allSources() {
		if s.Name() == name {
			return s
		}
	}
	return nil
}

// splitRef splits "<prefix><rest>" and reports whether prefix matched.
func splitRef(ref, prefix string) (string, bool) {
	if len(ref) <= len(prefix) || ref[:len(prefix)] != prefix {
		return "", false
	}
	return ref[len(prefix):], true
}

// maxString returns the larger of two ISO/number-as-text cursors compared as strings.
func maxString(a, b string) string {
	if b > a {
		return b
	}
	return a
}
```

- [ ] **Step 4: Run** `go test ./internal/kb` — PASS.
- [ ] **Step 5: Commit** `feat(kb): hash-gated document store and source contract`.

---

### Task 4: Slack source

**Files:**
- Create: `internal/kb/source_slack.go`
- Test: `internal/kb/source_slack_test.go`
- Modify: `internal/kb/source.go` (`allSources` gets `newSlackSource()` last)

**Interfaces:**
- Consumes: Task 3 `Source`, `Queryer`, `queryStrings`, `docIDsWithPrefix`; `watchtower/internal/slack` `SplitAccountID(id string) (int64, string, bool)`, `Namespace(accountID int64, rawID string) string`.
- Produces: `func newSlackSource() *slackSource` (implements `Source` and `progressReporter`), `const slackRange = 20000`, `const slackTail = 48 * time.Hour`, `func slackThreadRef(channelID, threadTS string) string`, `func slackDayRef(channelID, day string) string`.

Behaviour (spec §6/§7):
- Thread doc = every `messages` row with `channel_id = ? AND thread_ts = ?` (root has `thread_ts = ts`), `is_deleted = 0`, subtype not in the skip set, ordered by `ts_unix, ts`. Day doc = rows with `thread_ts IS NULL OR thread_ts = ''` and `ts_unix` in `[dayStartUTC, dayStartUTC+86400)`.
- Skip subtypes: `channel_join, channel_leave, channel_purpose, channel_topic, channel_name, channel_archive, channel_unarchive, group_join, group_leave, bot_add, bot_remove, pinned_item, unpinned_item`.
- Section text: `Name: <resolved text>`; section anchor = message `ts`.
- Names: cache per source instance. `userName(namespacedID)` = `COALESCE(NULLIF(display_name,''), NULLIF(real_name,''), name)` from `users WHERE id = ?`, fallback to the raw id. Raw mention ids resolve via `Namespace(accountOfChannel, raw)`; if that misses, fallback `users WHERE id LIKE '%:' || ?`, else "".
- Title: channel `SELECT name, type, dm_user_id FROM channels WHERE id = ?`; `type` in (`dm`,`im`) → `DM with <userName(dm_user_id)>`; else `#<name>`; unknown channel → `#<channel_id>`. Thread title: `<channelTitle> — <first line of root text, ≤80 runes>`; day title: `<channelTitle> · YYYY-MM-DD`.
- Meta: channel title word(s) + distinct participant names, space-joined, in first-seen order.
- Time: max `ts_unix` (UTC). Link: first row's `permalink`. Anchor: thread `{"channel_id","thread_ts"}`, day `{"channel_id","date"}`.
- Changed(cursor = rowid as decimal text, "" = 0): `max := SELECT COALESCE(MAX(rowid),0) FROM messages`; `hi := min(cursor+slackRange, max)`; keys from `SELECT channel_id, COALESCE(thread_ts,''), ts_unix FROM messages WHERE rowid > ? AND rowid <= ?` (thread key if thread_ts ≠ "", else day key of `ts_unix`); `done := hi == max`; when done, also add keys of rows with `ts_unix >= now-48h`. Deduplicate keys, sort for determinism. `next = strconv(hi)`.
- Keys: `SELECT DISTINCT channel_id, thread_ts FROM messages WHERE thread_ts IS NOT NULL AND thread_ts != '' AND is_deleted = 0` → thread refs; `SELECT DISTINCT channel_id, date(ts_unix,'unixepoch') FROM messages WHERE (thread_ts IS NULL OR thread_ts='') AND is_deleted = 0` → day refs.
- Progress(cursor): `cursor / max(rowid)`; empty table → 1.

- [ ] **Step 1: Failing tests** (`internal/kb/source_slack_test.go`). Seed helper and tests:

```go
package kb

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedSlack inserts channels/users/messages with raw SQL (explicit columns only).
func seedSlack(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `INSERT INTO channels (id, name, type) VALUES ('1:C1','general','public'), ('1:D1','','dm')`)
	exec(t, d, `UPDATE channels SET dm_user_id='1:U2' WHERE id='1:D1'`)
	exec(t, d, `INSERT INTO users (id, name, display_name) VALUES ('1:U1','anna','Anna'), ('1:U2','bob','')`)
	// thread root + reply + a join message (skipped) + deleted reply (skipped)
	msg(t, d, "1:C1", "1758000000.000100", "1:U1", "Договорились о релизе <@U2>", "1758000000.000100", "")
	msg(t, d, "1:C1", "1758000100.000200", "1:U2", "ok, пятница", "1758000000.000100", "")
	msg(t, d, "1:C1", "1758000200.000300", "1:U2", "joined", "", "channel_join")
	exec(t, d, `INSERT INTO messages (channel_id, ts, user_id, text, thread_ts, is_deleted) VALUES ('1:C1','1758000300.000400','1:U2','gone','1758000000.000100',1)`)
	// top-level messages on 2025-09-16 UTC in a DM
	msg(t, d, "1:D1", "1758000400.000500", "1:U2", "привет", "", "")
	msg(t, d, "1:D1", "1758000500.000600", "1:U1", "hello", "", "")
}

func exec(t *testing.T, d *db.DB, q string, args ...any) {
	t.Helper()
	_, err := d.Exec(q, args...)
	require.NoError(t, err, q)
}

func msg(t *testing.T, d *db.DB, ch, ts, user, text, threadTS, subtype string) {
	t.Helper()
	var th any
	if threadTS != "" {
		th = threadTS
	}
	exec(t, d, `INSERT INTO messages (channel_id, ts, user_id, text, thread_ts, subtype, permalink) VALUES (?,?,?,?,?,?,?)`,
		ch, ts, user, text, th, subtype, "https://slack.test/"+ts)
}

func TestSlack_BuildThread(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	doc, err := newSlackSource().Build(ctx, d, slackThreadRef("1:C1", "1758000000.000100"))
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "slack", doc.Source)
	assert.Equal(t, "#general — Договорились о релизе @bob", doc.Title)
	require.Len(t, doc.Sections, 2, "join subtype and deleted reply are skipped")
	assert.Equal(t, "Anna: Договорились о релизе @bob", doc.Sections[0].Text)
	assert.Equal(t, "1758000000.000100", doc.Sections[0].Anchor)
	assert.Equal(t, "bob: ok, пятница", doc.Sections[1].Text)
	assert.Equal(t, "https://slack.test/1758000000.000100", doc.Link)
	assert.Equal(t, map[string]string{"channel_id": "1:C1", "thread_ts": "1758000000.000100"}, doc.Anchor)
	assert.Equal(t, int64(1758000100), doc.Time.Unix())
	assert.Contains(t, doc.Meta, "Anna")
}

func TestSlack_BuildDay_DMTitle(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	day := time.Unix(1758000400, 0).UTC().Format("2006-01-02")
	doc, err := newSlackSource().Build(ctx, d, slackDayRef("1:D1", day))
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "DM with bob · "+day, doc.Title)
	require.Len(t, doc.Sections, 2)
	assert.Equal(t, map[string]string{"channel_id": "1:D1", "date": day}, doc.Anchor)
}

func TestSlack_BuildMissingReturnsNil(t *testing.T) {
	d := db.OpenTestDB(t)
	doc, err := newSlackSource().Build(context.Background(), d, slackThreadRef("1:C9", "1.1"))
	require.NoError(t, err)
	assert.Nil(t, doc)
	doc, err = newSlackSource().Build(context.Background(), d, "slack:bogus")
	require.NoError(t, err)
	assert.Nil(t, doc)
}

func TestSlack_ChangedRangesAndTail(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	s := newSlackSource()
	now := time.Unix(1758000600, 0) // all rows within the 48h tail
	keys, next, done, err := s.Changed(ctx, d, "", now)
	require.NoError(t, err)
	assert.True(t, done)
	assert.Equal(t, "6", next)
	day := time.Unix(1758000400, 0).UTC().Format("2006-01-02")
	assert.ElementsMatch(t, []string{
		slackThreadRef("1:C1", "1758000000.000100"),
		slackDayRef("1:C1", day), // the channel_join row is top-level
		slackDayRef("1:D1", day),
	}, keys)
	// caught up + tail: still returns tail keys, cursor unchanged
	keys, next, done, err = s.Changed(ctx, d, "6", now)
	require.NoError(t, err)
	assert.True(t, done)
	assert.Equal(t, "6", next)
	assert.NotEmpty(t, keys)
	// far future: tail empty, nothing new
	keys, _, _, err = s.Changed(ctx, d, "6", now.Add(72*time.Hour))
	require.NoError(t, err)
	assert.Empty(t, keys)
}

func TestSlack_KeysAndProgress(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	s := newSlackSource()
	keys, err := s.Keys(ctx, d)
	require.NoError(t, err)
	assert.Contains(t, keys, slackThreadRef("1:C1", "1758000000.000100"))
	p, err := s.Progress(ctx, d, "3")
	require.NoError(t, err)
	assert.InDelta(t, 0.5, p, 0.001)
	empty := db.OpenTestDB(t)
	p, err = s.Progress(ctx, empty, "")
	require.NoError(t, err)
	assert.Equal(t, 1.0, p)
}

// Review focus #1: a huge channel-day renders into many chunks quickly and
// resolves names from the cache, not one query per message.
func TestSlack_HugeDayChunks(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	exec(t, d, `INSERT INTO channels (id, name, type) VALUES ('1:C2','alerts','public')`)
	exec(t, d, `INSERT INTO users (id, name) VALUES ('1:U1','bot')`)
	tx, err := d.Begin()
	require.NoError(t, err)
	for i := 0; i < 3000; i++ {
		_, err := tx.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C2', ?, '1:U1', ?)`,
			fmt.Sprintf("1758000%03d.%06d", i%1000, i), strings.Repeat("alert payload ", 5))
		require.NoError(t, err)
	}
	require.NoError(t, tx.Commit())
	start := time.Now()
	day := time.Unix(1758000000, 0).UTC().Format("2006-01-02")
	doc, err := newSlackSource().Build(ctx, d, slackDayRef("1:C2", day))
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Len(t, doc.Sections, 3000)
	assert.Greater(t, len(BuildChunks(doc.Sections)), 50)
	assert.Less(t, time.Since(start), 5*time.Second)
}
```

- [ ] **Step 2: Run** `go test ./internal/kb -run TestSlack` — FAIL.
- [ ] **Step 3: Implement** `internal/kb/source_slack.go`:

```go
package kb

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/slack"
)

const (
	slackRange = 20000
	slackTail  = 48 * time.Hour
)

var slackSkipSubtypes = map[string]bool{
	"channel_join": true, "channel_leave": true, "channel_purpose": true, "channel_topic": true,
	"channel_name": true, "channel_archive": true, "channel_unarchive": true, "group_join": true,
	"group_leave": true, "bot_add": true, "bot_remove": true, "pinned_item": true, "unpinned_item": true,
}

type slackSource struct {
	names    map[string]string // namespaced user id -> display name
	channels map[string]string // channel id -> title
}

func newSlackSource() *slackSource {
	return &slackSource{names: map[string]string{}, channels: map[string]string{}}
}

func (*slackSource) Name() string { return "slack" }

func slackThreadRef(channelID, threadTS string) string {
	return "slack:thread:" + channelID + ":" + threadTS
}

func slackDayRef(channelID, day string) string { return "slack:day:" + channelID + ":" + day }

// parseSlackRef splits a Slack ref from the right: channel ids contain ':'.
func parseSlackRef(ref string) (kind, channelID, tail string, ok bool) {
	for _, k := range []string{"thread", "day"} {
		if rest, found := splitRef(ref, "slack:"+k+":"); found {
			i := strings.LastIndex(rest, ":")
			if i <= 0 || i == len(rest)-1 {
				return "", "", "", false
			}
			return k, rest[:i], rest[i+1:], true
		}
	}
	return "", "", "", false
}

func slackKeyFor(channelID, threadTS string, tsUnix float64) string {
	if threadTS != "" {
		return slackThreadRef(channelID, threadTS)
	}
	return slackDayRef(channelID, time.Unix(int64(tsUnix), 0).UTC().Format("2006-01-02"))
}

func (s *slackSource) Changed(ctx context.Context, q Queryer, cursor string, now time.Time) ([]string, string, bool, error) {
	lo, _ := strconv.ParseInt(cursor, 10, 64)
	var maxID int64
	if err := q.QueryRowContext(ctx, `SELECT COALESCE(MAX(rowid), 0) FROM messages`).Scan(&maxID); err != nil {
		return nil, cursor, false, err
	}
	hi := lo + slackRange
	if hi > maxID {
		hi = maxID
	}
	set := map[string]bool{}
	if hi > lo {
		if err := s.collectKeys(ctx, q, set, `SELECT channel_id, COALESCE(thread_ts, ''), ts_unix FROM messages WHERE rowid > ? AND rowid <= ?`, lo, hi); err != nil {
			return nil, cursor, false, err
		}
	}
	done := hi >= maxID
	if done {
		since := float64(now.Add(-slackTail).Unix())
		if err := s.collectKeys(ctx, q, set, `SELECT channel_id, COALESCE(thread_ts, ''), ts_unix FROM messages WHERE ts_unix >= ?`, since); err != nil {
			return nil, cursor, false, err
		}
	}
	keys := make([]string, 0, len(set))
	for k := range set {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	next := strconv.FormatInt(hi, 10)
	if hi < lo {
		next = cursor
	}
	return keys, next, done, nil
}

func (s *slackSource) collectKeys(ctx context.Context, q Queryer, set map[string]bool, query string, args ...any) error {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var ch, th string
		var tsUnix float64
		if err := rows.Scan(&ch, &th, &tsUnix); err != nil {
			return err
		}
		set[slackKeyFor(ch, th, tsUnix)] = true
	}
	return rows.Err()
}

func (s *slackSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	var out []string
	rows, err := q.QueryContext(ctx, `SELECT DISTINCT channel_id, thread_ts FROM messages
		WHERE thread_ts IS NOT NULL AND thread_ts != '' AND is_deleted = 0`)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var ch, th string
		if err := rows.Scan(&ch, &th); err != nil {
			rows.Close()
			return nil, err
		}
		out = append(out, slackThreadRef(ch, th))
	}
	rows.Close()
	rows, err = q.QueryContext(ctx, `SELECT DISTINCT channel_id, date(ts_unix, 'unixepoch') FROM messages
		WHERE (thread_ts IS NULL OR thread_ts = '') AND is_deleted = 0`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var ch, day string
		if err := rows.Scan(&ch, &day); err != nil {
			return nil, err
		}
		out = append(out, slackDayRef(ch, day))
	}
	return out, rows.Err()
}

func (s *slackSource) Progress(ctx context.Context, q Queryer, cursor string) (float64, error) {
	var maxID int64
	if err := q.QueryRowContext(ctx, `SELECT COALESCE(MAX(rowid), 0) FROM messages`).Scan(&maxID); err != nil {
		return 0, err
	}
	if maxID == 0 {
		return 1, nil
	}
	cur, _ := strconv.ParseInt(cursor, 10, 64)
	if cur >= maxID {
		return 1, nil
	}
	return float64(cur) / float64(maxID), nil
}

type slackRow struct {
	ts, userID, text, subtype, permalink string
	tsUnix                               float64
}

func (s *slackSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	kind, channelID, tail, ok := parseSlackRef(key)
	if !ok {
		return nil, nil
	}
	var rows []slackRow
	var err error
	if kind == "thread" {
		rows, err = s.loadRows(ctx, q, `SELECT ts, user_id, COALESCE(text,''), COALESCE(subtype,''), permalink, ts_unix
			FROM messages WHERE channel_id = ? AND thread_ts = ? AND is_deleted = 0 ORDER BY ts_unix, ts`, channelID, tail)
	} else {
		day, perr := time.Parse("2006-01-02", tail)
		if perr != nil {
			return nil, nil
		}
		from := float64(day.Unix())
		rows, err = s.loadRows(ctx, q, `SELECT ts, user_id, COALESCE(text,''), COALESCE(subtype,''), permalink, ts_unix
			FROM messages WHERE channel_id = ? AND (thread_ts IS NULL OR thread_ts = '') AND is_deleted = 0
			AND ts_unix >= ? AND ts_unix < ? ORDER BY ts_unix, ts`, channelID, from, from+86400)
	}
	if err != nil {
		return nil, fmt.Errorf("kb slack %s: %w", key, err)
	}
	if len(rows) == 0 {
		return nil, nil
	}
	acct, _, _ := slack.SplitAccountID(channelID)
	chTitle, err := s.channelTitle(ctx, q, channelID)
	if err != nil {
		return nil, err
	}
	doc := &Doc{ID: key, Source: "slack", Link: rows[0].permalink}
	var metaNames []string
	seen := map[string]bool{}
	var latest float64
	for _, r := range rows {
		name, err := s.userName(ctx, q, r.userID)
		if err != nil {
			return nil, err
		}
		text, err := s.resolveText(ctx, q, acct, r.text)
		if err != nil {
			return nil, err
		}
		doc.Sections = append(doc.Sections, Section{Text: name + ": " + text, Anchor: r.ts})
		if !seen[name] {
			seen[name] = true
			metaNames = append(metaNames, name)
		}
		if r.tsUnix > latest {
			latest = r.tsUnix
		}
	}
	doc.Time = time.Unix(int64(latest), 0).UTC()
	doc.Meta = strings.Join(append([]string{chTitle}, metaNames...), " ")
	if kind == "thread" {
		first, _ := s.resolveText(ctx, q, acct, rows[0].text)
		doc.Title = chTitle + " — " + firstLine(first, 80)
		doc.Anchor = map[string]string{"channel_id": channelID, "thread_ts": tail}
	} else {
		doc.Title = chTitle + " · " + tail
		doc.Anchor = map[string]string{"channel_id": channelID, "date": tail}
	}
	return doc, nil
}

// loadRows reads all matching rows, dropping skip-listed subtypes.
func (s *slackSource) loadRows(ctx context.Context, q Queryer, query string, args ...any) ([]slackRow, error) {
	rs, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rs.Close()
	var out []slackRow
	for rs.Next() {
		var r slackRow
		if err := rs.Scan(&r.ts, &r.userID, &r.text, &r.subtype, &r.permalink, &r.tsUnix); err != nil {
			return nil, err
		}
		if slackSkipSubtypes[r.subtype] {
			continue
		}
		out = append(out, r)
	}
	return out, rs.Err()
}

func (s *slackSource) userName(ctx context.Context, q Queryer, id string) (string, error) {
	if id == "" {
		return "unknown", nil
	}
	if n, ok := s.names[id]; ok {
		return n, nil
	}
	names, err := queryStrings(ctx, q, `SELECT COALESCE(NULLIF(display_name,''), NULLIF(real_name,''), name) FROM users WHERE id = ?`, id)
	if err != nil {
		return "", err
	}
	name := id
	if _, raw, ok := slack.SplitAccountID(id); ok {
		name = raw
	}
	if len(names) > 0 && names[0] != "" {
		name = names[0]
	}
	s.names[id] = name
	return name, nil
}

// resolveText resolves mention markup; ids are looked up (and cached) before
// the regex replacement so the callback never queries.
func (s *slackSource) resolveText(ctx context.Context, q Queryer, acct int64, text string) (string, error) {
	resolved := map[string]string{}
	for _, m := range reUserMention.FindAllStringSubmatch(text, -1) {
		raw := m[1]
		if _, done := resolved[raw]; done || m[2] != "" {
			continue
		}
		id := slack.Namespace(acct, raw)
		if acct == 0 {
			id = raw
		}
		cached, ok := s.names[id]
		if !ok {
			names, err := queryStrings(ctx, q, `SELECT COALESCE(NULLIF(display_name,''), NULLIF(real_name,''), name) FROM users WHERE id = ? OR id LIKE '%:' || ? ORDER BY id = ? DESC LIMIT 1`, id, raw, id)
			if err != nil {
				return "", err
			}
			if len(names) > 0 {
				cached = names[0]
			}
			s.names[id] = cached
		}
		if cached == id || cached == raw {
			cached = ""
		}
		resolved[raw] = cached
	}
	return ResolveSlackMarkup(text, func(raw string) string { return resolved[raw] }), nil
}

func (s *slackSource) channelTitle(ctx context.Context, q Queryer, channelID string) (string, error) {
	if t, ok := s.channels[channelID]; ok {
		return t, nil
	}
	var name, typ, dmUser string
	err := q.QueryRowContext(ctx, `SELECT COALESCE(name,''), COALESCE(type,''), COALESCE(dm_user_id,'') FROM channels WHERE id = ?`, channelID).
		Scan(&name, &typ, &dmUser)
	title := "#" + channelID
	switch {
	case err != nil:
		// unknown channel: keep the id
	case typ == "dm" || typ == "im":
		who, uerr := s.userName(ctx, q, dmUser)
		if uerr != nil {
			return "", uerr
		}
		title = "DM with " + who
	case name != "":
		title = "#" + name
	}
	s.channels[channelID] = title
	return title, nil
}

func firstLine(s string, max int) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	r := []rune(strings.TrimSpace(s))
	if len(r) > max {
		r = r[:max]
	}
	return string(r)
}
```

Implementation notes: check the real `channels` column names (`dm_user_id`, `type`) and the DM type value used by the codebase (`grep -n "'dm'\|\"dm\"\|\"im\"" internal/db/channels.go internal/sync/*.go | head`) — keep both `dm` and `im` if unsure. If `users.real_name` does not exist, drop it from the COALESCE. `channel_join` is in the Changed key set (key derivation doesn't filter subtypes) but Build drops it — that day doc for `1:C1` then has zero sections → Build must return `nil`: make sure `len(rows) == 0` is checked **after** subtype filtering (it is, since `loadRows` filters). Then add `newSlackSource()` to `allSources()`.

- [ ] **Step 4: Run** `go test ./internal/kb` — PASS.
- [ ] **Step 5: Commit** `feat(kb): slack thread and channel-day documents`.

---

### Task 5: Mail and work sources (Gmail, IMAP, Jira, Calendar)

**Files:**
- Create: `internal/kb/source_mail.go`, `internal/kb/source_work.go`
- Test: `internal/kb/source_mail_test.go`, `internal/kb/source_work_test.go`
- Modify: `internal/kb/source.go` (`allSources`: add `calendarSource{}` first, then after the derived ones `jiraSource{}`, `imapSource{}`, `gmailSource{}` before slack — final order per Task 3)

**Interfaces:**
- Consumes: Tasks 2–3.
- Produces: `gmailSource{}`, `imapSource{}`, `jiraSource{}`, `calendarSource{}` implementing `Source`. Shared helper in `source_mail.go`: `func changedByColumn(ctx, q, query, cursor string) (keys []string, next string, err error)` — runs a query returning `(key, marker)` rows for `marker > cursor`, returns distinct keys (sorted) and `maxString(cursor, max marker)`; callers return `done = true`.

Behaviour (spec §6):
- **Gmail** key `gmail:<acct>:<tid>` where `tid = thread_id` or `m:<id>` when `thread_id = ''`. Changed: `SELECT 'gmail:' || account_id || ':' || CASE WHEN thread_id = '' THEN 'm:' || id ELSE thread_id END, updated_at FROM gmail_messages WHERE updated_at > ?`. Keys: same key expression, DISTINCT. Build: rows `WHERE account_id = ? AND ((? NOT LIKE 'm:%' AND thread_id = ?) OR ('m:' || id = ?)) ORDER BY internal_date, id`. Section per message: `From <from_name> <from_email> · <internal_date first 16 chars>\nSubject: <subject>\n<body_text, or snippet when body empty>`; anchor = message id. Title = first non-empty subject (else `(no subject)`). Meta = distinct from names + from emails + to/cc emails (JSON arrays of strings) space-joined. Time = max parsed `internal_date` (fallback `updated_at`). Link = last non-empty `permalink`. Anchor `{"account_id","thread_id"}` (thread_id = tid).
- **IMAP** key `imap:<acct>:<uidvalidity>:<uid>`. Changed on `updated_at`. One section (same header shape). Anchor `{"account_id","uidvalidity","uid"}`.
- **Jira** key `jira:<acct>:<KEY>`. Changed: `SELECT 'jira:' || account_id || ':' || key, synced_at FROM jira_issues WHERE synced_at > ? UNION ALL SELECT 'jira:' || account_id || ':' || issue_key, synced_at FROM jira_comments WHERE synced_at > ?` (pass cursor twice — make `changedByColumn` take variadic args instead: `changedByColumn(ctx, q, cursor, query, args...)`). Keys: `SELECT 'jira:' || account_id || ':' || key FROM jira_issues WHERE is_deleted = 0`. Build: issue row (`is_deleted = 0`, else nil) + comments `ORDER BY created_at, id` + `SELECT site_url FROM jira_accounts WHERE id = ?`. Title `KEY summary`. Sections: description (anchor KEY, skipped if empty) then `Author: body` (anchor comment id). Meta: project_key, status, priority, issue_type, assignee_display_name, reporter_display_name, epic_key, sprint_name, labels (JSON string array) — non-empty, space-joined. Time = max(parse(updated_at), parse(comment updated_at…)); zero if none parse. Link `strings.TrimRight(site_url, "/") + "/browse/" + KEY` when site_url ≠ "". Anchor `{"account_id","key"}`. The key itself contains no colon; parse `jira:<acct>:<KEY>` by splitting after the prefix at the **first** colon.
- **Calendar** key `calendar:<id>`. Changed on `synced_at`. Keys all ids. Build: title, description, location, start/end, organizer_email, attendees (JSON; may be `null`, `[]`, array of strings or of objects with `email`/`displayName`/`display_name`/`name`), html_link. One section: `When: <start> – <end>\nWhere: <location>\nOrganizer: <organizer>\nAttendees: a, b\n\n<description>` (omit empty lines). Time = parse(start_time). Anchor `{"event_id"}`. Meta = organizer + attendees.

- [ ] **Step 1: Failing tests.** `internal/kb/source_mail_test.go`:

```go
package kb

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func seedGmail(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `INSERT INTO google_accounts (id, email) VALUES (1, 'me@x.io')`)
	exec(t, d, `INSERT INTO gmail_messages (account_id, id, thread_id, from_email, from_name, to_json, subject, body_text, internal_date, permalink, updated_at)
		VALUES (1,'m1','t1','a@x.io','Anna','["me@x.io"]','Бюджет Q4','Предлагаю урезать','2026-09-01T10:00:00Z','https://mail/m1','2026-09-01T10:00:05Z'),
		       (1,'m2','t1','me@x.io','Me','["a@x.io"]','Re: Бюджет Q4','','2026-09-02T10:00:00Z','https://mail/m2','2026-09-02T10:00:05Z'),
		       (1,'m3','','b@x.io','Bob','[]','Solo','solo body','2026-09-03T10:00:00Z','','2026-09-03T10:00:05Z')`)
	exec(t, d, `UPDATE gmail_messages SET snippet='snippet two' WHERE id='m2'`)
}

func TestGmail_BuildThread(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedGmail(t, d)
	doc, err := gmailSource{}.Build(ctx, d, "gmail:1:t1")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "Бюджет Q4", doc.Title)
	require.Len(t, doc.Sections, 2)
	assert.Contains(t, doc.Sections[0].Text, "From Anna a@x.io")
	assert.Contains(t, doc.Sections[0].Text, "Предлагаю урезать")
	assert.Contains(t, doc.Sections[1].Text, "snippet two", "empty body falls back to snippet")
	assert.Equal(t, "https://mail/m2", doc.Link)
	assert.Equal(t, map[string]string{"account_id": "1", "thread_id": "t1"}, doc.Anchor)
	assert.Contains(t, doc.Meta, "a@x.io")
}

func TestGmail_ThreadlessMessageAndChanged(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedGmail(t, d)
	doc, err := gmailSource{}.Build(ctx, d, "gmail:1:m:m3")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "Solo", doc.Title)
	keys, next, done, err := gmailSource{}.Changed(ctx, d, "2026-09-01T12:00:00Z", testNow())
	require.NoError(t, err)
	assert.True(t, done)
	assert.Equal(t, []string{"gmail:1:m:m3", "gmail:1:t1"}, keys)
	assert.Equal(t, "2026-09-03T10:00:05Z", next)
	missing, err := gmailSource{}.Build(ctx, d, "gmail:1:nope")
	require.NoError(t, err)
	assert.Nil(t, missing)
}
```

(Add `func testNow() time.Time { return time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC) }` to `store_test.go`.) Before writing the INSERTs, check the real NOT NULL columns of `google_accounts`, `email_accounts` (IMAP), `jira_accounts`, `calendar_calendars` in `internal/db/schema.sql` and add any required columns to the fixture — never weaken the assertions.

Also an IMAP test (`imap:1:7:42` builds with subject/body, Changed on updated_at) — write it in the same shape.

`internal/kb/source_work_test.go`:

```go
package kb

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func seedJira(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `INSERT INTO jira_accounts (id, cloud_id, site_url) VALUES (1, 'c1', 'https://acme.atlassian.net/')`)
	exec(t, d, `INSERT INTO jira_issues (account_id, key, project_key, summary, description_text, status, status_category, assignee_display_name, labels, created_at, updated_at, synced_at)
		VALUES (1,'PROJ-123','PROJ','Stage environment','Нужен второй стейдж','In Progress','indeterminate','Anna','["infra"]','2026-04-01T09:00:00.000+0100','2026-04-20T09:37:38.027+0100','2026-04-20T11:00:01Z')`)
	exec(t, d, `INSERT INTO jira_comments (account_id, issue_key, id, author, body_text, created_at, updated_at, synced_at)
		VALUES (1,'PROJ-123','c2','Bob','second','2026-04-21T10:00:00.000+0000','2026-04-21T10:00:00.000+0000','2026-04-21T11:00:00Z'),
		       (1,'PROJ-123','c1','Anna','first','2026-04-20T10:00:00.000+0000','2026-04-20T10:00:00.000+0000','2026-04-21T11:00:00Z')`)
}

func TestJira_Build(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedJira(t, d)
	doc, err := jiraSource{}.Build(ctx, d, "jira:1:PROJ-123")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "PROJ-123 Stage environment", doc.Title)
	require.Len(t, doc.Sections, 3)
	assert.Equal(t, "Anna: first", doc.Sections[1].Text, "comments ordered by created_at")
	assert.Equal(t, "https://acme.atlassian.net/browse/PROJ-123", doc.Link)
	assert.Contains(t, doc.Meta, "infra")
	assert.Equal(t, "2026-04-21T10:00:00Z", doc.Time.Format("2006-01-02T15:04:05Z"))
	keys, next, done, err := jiraSource{}.Changed(ctx, d, "2026-04-21T00:00:00Z", testNow())
	require.NoError(t, err)
	assert.True(t, done)
	assert.Equal(t, []string{"jira:1:PROJ-123"}, keys, "a comment sync alone marks the issue changed")
	assert.Equal(t, "2026-04-21T11:00:00Z", next)
}

func TestJira_DeletedIssueIsNil(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedJira(t, d)
	exec(t, d, `UPDATE jira_issues SET is_deleted = 1`)
	doc, err := jiraSource{}.Build(ctx, d, "jira:1:PROJ-123")
	require.NoError(t, err)
	assert.Nil(t, doc)
}

// Review focus #5: unparsable dates and null attendees still index.
func TestCalendar_BuildToleratesNullAttendees(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	exec(t, d, `INSERT INTO calendar_calendars (id, name) VALUES ('cal1','Work')`)
	exec(t, d, `INSERT INTO calendar_events (id, calendar_id, title, description, location, start_time, end_time, organizer_email, attendees, html_link)
		VALUES ('e1','cal1','Release sync','Обсудить стейдж','Room 1','2026-09-11T10:00:00Z','2026-09-11T11:00:00Z','boss@x.io','null','https://cal/e1'),
		       ('e2','cal1','Obj attendees','','','not-a-date','','','[{"email":"a@x.io","displayName":"Anna"},"b@x.io"]','')`)
	doc, err := calendarSource{}.Build(ctx, d, "calendar:e1")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Contains(t, doc.Sections[0].Text, "Organizer: boss@x.io")
	assert.Contains(t, doc.Sections[0].Text, "Обсудить стейдж")
	assert.NotContains(t, doc.Sections[0].Text, "Attendees:")
	doc2, err := calendarSource{}.Build(ctx, d, "calendar:e2")
	require.NoError(t, err)
	require.NotNil(t, doc2)
	assert.True(t, doc2.Time.IsZero())
	assert.Contains(t, doc2.Sections[0].Text, "Anna")
	assert.Contains(t, doc2.Sections[0].Text, "b@x.io")
}
```

- [ ] **Step 2: Run** `go test ./internal/kb` — FAIL.
- [ ] **Step 3: Implement** the four sources to the behaviour list above. Shared shape (write each fully — do not abstract beyond `changedByColumn`):

```go
// changedByColumn returns the distinct keys whose marker column moved past
// cursor, and the new cursor (the max marker seen, never below cursor).
func changedByColumn(ctx context.Context, q Queryer, cursor, query string, args ...any) ([]string, string, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, cursor, err
	}
	defer rows.Close()
	set := map[string]bool{}
	next := cursor
	for rows.Next() {
		var key, marker string
		if err := rows.Scan(&key, &marker); err != nil {
			return nil, cursor, err
		}
		set[key] = true
		next = maxString(next, marker)
	}
	if err := rows.Err(); err != nil {
		return nil, cursor, err
	}
	keys := make([]string, 0, len(set))
	for k := range set {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys, next, nil
}
```

Each `Build` loads its rows into structs, closes the rows, then does follow-up lookups (site_url), per the single-connection rule. JSON email arrays: `var xs []string; _ = json.Unmarshal([]byte(raw), &xs)`. Attendees: unmarshal into `[]any`; for `string` use it, for `map[string]any` prefer `displayName`/`display_name`/`name`, then append `email`.

- [ ] **Step 4: Run** `go test ./internal/kb` — PASS.
- [ ] **Step 5: Commit** `feat(kb): gmail, imap, jira and calendar documents`.

---

### Task 6: Derived sources + indexer

**Files:**
- Create: `internal/kb/source_derived.go`, `internal/kb/indexer.go`
- Test: `internal/kb/source_derived_test.go`, `internal/kb/indexer_test.go`
- Modify: `internal/kb/source.go` (final `allSources()` order: `calendarSource{}, ideaSource{}, digestSource{}, streamDigestSource{}, recapSource{}, transcriptSource{}, jiraSource{}, imapSource{}, gmailSource{}, newSlackSource()`)

**Interfaces:**
- Consumes: Tasks 2–5.
- Produces:
  - `transcriptSource{}`, `recapSource{}`, `digestSource{}`, `streamDigestSource{}`, `ideaSource{}`.
  - `type Options struct { Budget time.Duration; Sources []string; Now time.Time }` (zero `Now` → `time.Now()`; zero Budget = unlimited; nil Sources = all).
  - `type Stats struct { Written, Deleted int; Incomplete bool }`
  - `func Run(ctx context.Context, d *db.DB, opts Options) (Stats, error)` — returns `errors.Join` of per-source errors; one source's error never stops the others.
  - `func Reindex(ctx context.Context, d *db.DB, sources []string, now time.Time) (Stats, error)` — deletes those sources' documents (all when nil) and `kb_sources` rows, then `Run` unbounded. Unknown source name → error before deleting anything.
  - `const batchSize = 200`

Derived behaviour (spec §6):
- **transcript** `transcript:<id>`; Changed on `updated_at`. Build: `title, created_at, transcript_text, segments_json`. Segments JSON: `[{"idx","start_sec","end_sec","speaker","text","deleted"}]` → non-deleted → section `[speaker] text`, anchor `strconv.FormatFloat(start_sec,'f',0,64)`; if segments NULL/invalid/empty → one section per non-empty line of `transcript_text`, anchor "". Title `title + " · " + created_at[:10]`. Time `created_at`. Anchor `{"transcript_id"}`.
- **recap** `recap:<id>`; Changed on `updated_at`. Build: `SELECT r.recap_json, r.created_at, COALESCE(r.event_id,''), COALESCE(e.title,'') FROM meeting_recaps r LEFT JOIN calendar_events e ON e.id = r.event_id WHERE r.id = ?`. Sections: one per `jsonTexts(recap_json)` entry. Title = event title or `Meeting recap`. Time `created_at`. Anchor `{"recap_id","event_id"}` (event_id omitted when empty).
- **digest** `digest:<digest_id>:<idx>`. Changed: `SELECT 'digest:' || t.digest_id || ':' || t.idx, d.created_at FROM digest_topics t JOIN digests d ON d.id = t.digest_id WHERE d.created_at > ?` **plus**, for every digest id among those keys, the existing kb ids with prefix `digest:<id>:` (`docIDsWithPrefix`) so a topic dropped on re-upsert gets rebuilt → nil → deleted. Keys: all topic keys. Build: topic `title, summary, decisions, action_items` + digest `type, channel_id, period_to`; sections: summary, then each `jsonTexts(decisions)` as `Decision: …`, each `jsonTexts(action_items)` as `Action: …`. Meta = channel title (`SELECT name FROM channels WHERE id = ?` → `#name`, empty for cross-channel) + digest type. Time = `period_to` unix. Anchor `{"digest_id","idx","channel_id"}`.
- **stream_digest** `stream_digest:<id>:<idx>` over `topics_json` array entries (index in array). Changed on `created_at` with the same prefix trick. Build: parse `topics_json` into `[]json.RawMessage`; out-of-range idx → nil; title = the entry's `title` string field if present, else `<source> digest`; sections = `jsonTexts(entry)` (skip the one equal to the title). Meta = source + scope. Time = parse(period_to). Anchor `{"stream_digest_id","idx","source"}`.
- **idea** `idea:<id>`. Changed: `SELECT 'idea:' || id, updated_at FROM ideas WHERE updated_at > ? UNION ALL SELECT 'idea:' || idea_id, created_at FROM idea_mentions WHERE created_at > ?`. Build: `kind, status, title, essence, last_mention_at, updated_at` + mentions `author, quote ORDER BY said_at, id`. Sections: essence, then `author: quote` (or `quote` when author empty). Meta = kind + status. Time = parse(last_mention_at) else parse(updated_at). Anchor `{"idea_id"}`.

Indexer algorithm (`indexer.go`):

```go
func Run(ctx context.Context, d *db.DB, opts Options) (Stats, error) {
	now := opts.Now
	if now.IsZero() {
		now = time.Now()
	}
	start := time.Now()
	overBudget := func() bool { return opts.Budget > 0 && time.Since(start) > opts.Budget }
	var st Stats
	var errs []error
	for _, src := range selectSources(opts.Sources) {
		if ctx.Err() != nil {
			errs = append(errs, ctx.Err())
			break
		}
		if overBudget() {
			st.Incomplete = true
			break
		}
		caughtUp, err := runSource(ctx, d, src, now, overBudget, &st)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", src.Name(), err))
			continue
		}
		if !caughtUp {
			st.Incomplete = true
			break
		}
		if err := reconcileIfDue(ctx, d, src, now, &st); err != nil {
			errs = append(errs, fmt.Errorf("%s reconcile: %w", src.Name(), err))
		}
	}
	return st, errors.Join(errs...)
}
```

- `selectSources(names)`: nil → `allSources()`; else keep `allSources()` order, filtered. (Create fresh sources each Run so the Slack name cache never outlives a run.)
- `runSource`: loop { `st := loadState`; `keys, next, done, err := src.Changed(ctx, d, st.Cursor, now)`; process keys in batches of `batchSize`, each batch one transaction: `tx, _ := d.BeginTx(ctx, nil)`; for each key `doc, err := src.Build(ctx, tx, key)`; nil → `deleteDoc` (count Deleted when it removed a row) else `writeDoc` (count Written); on error rollback and return it; after the **last** batch of this range, `saveCursor(tx, name, next, now)` in the same transaction (if keys empty, save the cursor in its own tx when `next != st.Cursor`); commit. Between batches, if `overBudget()` → return `(false, nil)` without saving the cursor (the range is redone next time — idempotent via the hash gate). After the range: `if done { return true, nil }`; `if overBudget() { return false, nil }`; loop. }
- `reconcileIfDue`: `st := loadState`; if `st.LastReconciledAt` has the same UTC date prefix (`[:10]`) as `now` → skip. Else `keys := src.Keys(ctx, d)`; `ids := docIDs(ctx, d, name)`; in one tx delete every id not in keys (count Deleted); `saveReconciled`; commit.

- [ ] **Step 1: Failing tests** — `source_derived_test.go`: one Build test per source (transcript with a deleted segment skipped and anchor `12`; transcript with NULL segments falls back to lines; recap flattening + event title; digest topic with decisions/action items and `#general` meta; stream digest idx out of range → nil; idea with two mentions ordered by said_at). Use the real JSON shapes: digest `decisions` = `[{"text":"…","by":"@v","message_ts":"1.2","importance":"medium"}]`, `action_items` = `[{"text":"…","assignee":"@a","status":"open"}]`; segments = `[{"deleted":false,"end_sec":20,"idx":0,"speaker":"anna@x.io","start_sec":12,"text":"…"}]`.

`indexer_test.go`:

```go
package kb

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func countDocs(t *testing.T, d *db.DB, source string) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_documents WHERE source = ?`, source).Scan(&n))
	return n
}

func TestRun_IndexesAndIsIdempotent(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	seedJira(t, d)
	now := time.Unix(1758000600, 0)
	st, err := Run(ctx, d, Options{Now: now})
	require.NoError(t, err)
	assert.False(t, st.Incomplete)
	assert.Equal(t, 3, st.Written) // slack thread + DM day + jira issue (C1 day has only a join row → nil)
	assert.Equal(t, 2, countDocs(t, d, "slack"))
	st, err = Run(ctx, d, Options{Now: now})
	require.NoError(t, err)
	assert.Equal(t, 0, st.Written, "second run over unchanged data writes nothing")
}

// Review focus #4: an in-place edit/delete within the tail is picked up.
func TestRun_TailRescanCatchesInPlaceDelete(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	now := time.Unix(1758000600, 0)
	_, err := Run(ctx, d, Options{Now: now})
	require.NoError(t, err)
	exec(t, d, `UPDATE messages SET is_deleted = 1 WHERE channel_id = '1:D1'`)
	st, err := Run(ctx, d, Options{Now: now})
	require.NoError(t, err)
	assert.Equal(t, 1, st.Deleted)
	assert.Equal(t, 1, countDocs(t, d, "slack"))
}

func TestRun_BudgetStopsAndResumes(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	seedJira(t, d)
	st, err := Run(ctx, d, Options{Now: time.Unix(1758000600, 0), Budget: time.Nanosecond})
	require.NoError(t, err)
	assert.True(t, st.Incomplete)
	st, err = Run(ctx, d, Options{Now: time.Unix(1758000600, 0)})
	require.NoError(t, err)
	assert.False(t, st.Incomplete)
	assert.Equal(t, 2, countDocs(t, d, "slack"))
	assert.Equal(t, 1, countDocs(t, d, "jira"))
}

func TestRun_ReconcileDeletesVanishedOncePerDay(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedJira(t, d)
	day1 := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	_, err := Run(ctx, d, Options{Now: day1})
	require.NoError(t, err)
	exec(t, d, `DELETE FROM jira_comments`)
	exec(t, d, `DELETE FROM jira_issues`) // hard delete: no marker moves
	_, err = Run(ctx, d, Options{Now: day1.Add(time.Hour)})
	require.NoError(t, err)
	assert.Equal(t, 1, countDocs(t, d, "jira"), "same day: reconcile already ran")
	st, err := Run(ctx, d, Options{Now: day1.Add(24 * time.Hour)})
	require.NoError(t, err)
	assert.Equal(t, 1, st.Deleted)
	assert.Equal(t, 0, countDocs(t, d, "jira"))
}

func TestRun_EmptyDatabase(t *testing.T) {
	st, err := Run(context.Background(), db.OpenTestDB(t), Options{Now: testNow()})
	require.NoError(t, err)
	assert.Equal(t, Stats{}, st)
}

func TestReindex_UnknownSourceFailsFirst(t *testing.T) {
	d := db.OpenTestDB(t)
	_, err := Reindex(context.Background(), d, []string{"nope"}, testNow())
	assert.Error(t, err)
}

func TestReindex_RebuildsSource(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedJira(t, d)
	_, err := Run(ctx, d, Options{Now: testNow()})
	require.NoError(t, err)
	st, err := Reindex(ctx, d, []string{"jira"}, testNow())
	require.NoError(t, err)
	assert.Equal(t, 1, st.Written)
}
```

Note on `TestRun_IndexesAndIsIdempotent`: the first run's reconcile runs too; `Written` counts only writes. If the arithmetic in a test disagrees with the spec'd behaviour, fix the code, not the expectation — but if the fixture itself is miscounted (e.g. you find the `C1` day doc legitimately has a non-join row), correct the number and say so in your report.

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** derived sources and `indexer.go` (full code per the behaviour list and skeleton above).
- [ ] **Step 4: Run** `go test ./internal/kb` — PASS.
- [ ] **Step 5: Commit** `feat(kb): derived documents and budgeted incremental indexer`.

---

### Task 7: Search, status, query builder, contracts

**Files:**
- Create: `internal/kb/query.go`, `internal/kb/search.go`, `internal/kb/status.go`, `internal/kb/contracts_test.go`
- Test: `internal/kb/query_test.go`, `internal/kb/search_test.go`

**Interfaces:**
- Consumes: Tasks 2–6.
- Produces:
  - `func BuildMatch(query string) (and, or string)`
  - `type Request struct { Queries []string; Sources []string; From, To time.Time; Limit int; Now time.Time }`
  - `type Hit struct { Ref string \`json:"ref"\`; Source string \`json:"source"\`; Title string \`json:"title"\`; When string \`json:"when,omitempty"\`; Link string \`json:"link,omitempty"\`; Anchor map[string]string \`json:"anchor"\`; Snippets []string \`json:"snippets"\`; score float64 }`
  - `type Result struct { Hits []Hit \`json:"hits"\`; IndexNote string \`json:"index_note,omitempty"\` }`
  - `func Search(ctx context.Context, d *db.DB, req Request) (Result, error)` — validation errors are `*RequestError` (`type RequestError struct{ Msg string }` with `Error()`).
  - `type DocView struct { Ref, Source, Title, When, Link string; Anchor map[string]string; Text string; Truncated bool }` (json tags snake_case: `ref, source, title, when, link, anchor, text, truncated`)
  - `var ErrNotFound = errors.New("kb: document not found")`
  - `func GetDocument(ctx context.Context, d *db.DB, ref string, maxChars int) (DocView, error)`
  - `type SourceStatus struct { Source string; Docs, Chunks int; Cursor string; Progress float64; LastReconciledAt, UpdatedAt string }` (json snake_case)
  - `func Status(ctx context.Context, d *db.DB) ([]SourceStatus, error)` — one row per `sourceNames()` entry.
  - `func indexNote(ctx context.Context, d *db.DB, now time.Time) string`
  - `const DefaultLimit = 10`, `const MaxLimit = 25`, `const MaxQueries = 5`, `const DefaultDocChars = 12000`
  - `func SourceNames() []string` (exported wrapper of `sourceNames` for the tool/CLI validation)

Search algorithm (spec §8): validate (1–5 queries, each non-empty after trim; sources ⊆ `SourceNames()`; limit 0 → 10, >25 → 25, <0 → error); for each query `and, or := BuildMatch(q)`; skip empty; run `retrieve(and)`; if `len < 50` and `or != and` run `retrieve(or)` as a 0.5-weight list. `retrieve`:

```sql
SELECT c.id, c.doc_id, snippet(kb_fts, 1, '', '', '…', 40), d.source, d.title, d.doc_time, d.doc_time_unix, d.link, d.anchor_json
FROM kb_fts JOIN kb_chunks c ON c.id = kb_fts.rowid JOIN kb_documents d ON d.id = c.doc_id
WHERE kb_fts MATCH ? {AND d.source IN (?,…)} {AND d.doc_time_unix >= ?} {AND d.doc_time_unix < ?}
ORDER BY bm25(kb_fts, 4.0, 1.0, 2.0) LIMIT 50
```

Fuse: `chunkScore[chunkID] += w / (50 + rank)` (rank 1-based); document score = max chunk score; keep the two best-scoring chunks' snippets per document (dedupe identical snippet strings). Multiply by recency `max(1/(1+0.5*ageYears), 0.75)` where `ageYears = (now - doc_time_unix)/(365.25*86400)`, `doc_time_unix == 0` → 0.75, future → 1. Sort desc (ties: newer `doc_time_unix`, then ref), cut to limit. `When` = `doc_time` (RFC3339 string). `IndexNote = indexNote(...)`. An FTS error from a sanitized MATCH is a bug: return it wrapped (tests below pin that hostile input never reaches that path).

`indexNote`: if `SELECT count(*) FROM kb_documents` = 0 → `"knowledge index is empty — it builds in the background after sync; use list_messages and the source tools meanwhile"`. Else collect: for every source with a `progressReporter` whose progress < 1 → `"<name> NN% indexed"` (floor percent); if max `kb_sources.updated_at` is older than 24h before now → `"index last updated <that time>"`. Join with `"; "`.

`BuildMatch`: for each whitespace-separated word: `Normalize`; `prefix := strings.HasSuffix(word, "*")`; split the word on runes that are not letter/digit/`-`/`_`/`.`; trim `-_.` from each piece's ends; drop empty pieces and pieces whose upper-case form is `AND`, `OR`, `NOT`, `NEAR`; each piece → `"` + piece + `"`; the **last** piece of a prefix word gets `*` appended. `and = strings.Join(terms, " ")`, `or = strings.Join(terms, " OR ")`; no terms → `"", ""`.

`GetDocument`: unknown ref → `ErrNotFound`; `maxChars <= 0` → `DefaultDocChars`; text = chunk bodies by idx joined with `"\n"`, truncated to `maxChars` runes with `Truncated = true`.

`Status`: per source name: docs + chunks counts (`SELECT count(*), COALESCE(SUM(chunk_count),0) FROM kb_documents WHERE source = ?`), state, progress (reporter or 1 when cursor set / 0 when never run and source has Keys — keep it simple: non-reporter → 1).

- [ ] **Step 1: Failing tests.** `query_test.go`:

```go
package kb

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestBuildMatch(t *testing.T) {
	and, or := BuildMatch(`договор* релиз`)
	assert.Equal(t, `"договор"* "релиз"`, and)
	assert.Equal(t, `"договор"* OR "релиз"`, or)
	and, _ = BuildMatch(`PROJ-123`)
	assert.Equal(t, `"PROJ-123"`, and)
	and, _ = BuildMatch(`Договорённость`)
	assert.Equal(t, `"Договоренность"`, and)
	and, _ = BuildMatch(`foo/bar NEAR and`)
	assert.Equal(t, `"foo" "bar"`, and)
}

// Review focus #2: hostile input never produces an FTS syntax error.
func TestBuildMatch_HostileInputIsSafe(t *testing.T) {
	d := db.OpenTestDB(t)
	for _, q := range []string{`"`, `(`, `)`, `NEAR`, `-foo`, `*`, `:`, `a:b`, `"unbalanced`, `^x`, `🙂`, `!!!`, `OR AND`, `x**`, `{a}`, `col:val`} {
		and, or := BuildMatch(q)
		for _, m := range []string{and, or} {
			if m == "" {
				continue
			}
			_, err := d.QueryContext(context.Background(), `SELECT rowid FROM kb_fts WHERE kb_fts MATCH ?`, m)
			require.NoError(t, err, "query %q → match %q", q, m)
		}
	}
	and, or := BuildMatch(`!!! ???`)
	assert.Equal(t, "", and)
	assert.Equal(t, "", or)
}
```

(`d.QueryContext` returns rows; close them — `rows, err := …; if err == nil { rows.Close() }`.)

`search_test.go` (fixture: `seedAll(t, d)` = seedSlack + seedGmail + seedJira + a calendar event + a transcript + an idea, then `Run`):

```go
func TestSearch_MorphologyAndYo(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedAll(t, d)
	res, err := Search(ctx, d, Request{Queries: []string{"договор*"}, Now: testNow()})
	require.NoError(t, err)
	require.NotEmpty(t, res.Hits)
	assert.Equal(t, slackThreadRef("1:C1", "1758000000.000100"), res.Hits[0].Ref)
	res, err = Search(ctx, d, Request{Queries: []string{"стейдж"}, Now: testNow()})
	require.NoError(t, err)
	refs := hitRefs(res)
	assert.Contains(t, refs, "jira:1:PROJ-123")
	assert.Contains(t, refs, "calendar:e1")
}

func TestSearch_SourceAndTimeFilters(t *testing.T) { /* sources:["jira"] → only jira; From after the jira time → excluded */ }

func TestSearch_ORFallbackRanksBelowAND(t *testing.T) {
	// a doc matching both words outranks one matching only one word
}

func TestSearch_RecencyFloor(t *testing.T) {
	// two docs with identical text, one 10 years old: the old one ranks second but its
	// score is ≥ 0.75 × the new one's (assert via the unexported score field)
}

func TestSearch_Validation(t *testing.T) {
	d := db.OpenTestDB(t)
	for _, req := range []Request{
		{}, {Queries: []string{"a", "b", "c", "d", "e", "f"}}, {Queries: []string{"  "}},
		{Queries: []string{"a"}, Sources: []string{"nope"}}, {Queries: []string{"a"}, Limit: -1},
	} {
		_, err := Search(context.Background(), d, req)
		var re *RequestError
		assert.ErrorAs(t, err, &re, "%+v", req)
	}
	res, err := Search(context.Background(), d, Request{Queries: []string{"!!!"}, Limit: 500})
	require.NoError(t, err)
	assert.Empty(t, res.Hits)
}

// Review focus #3: a half-built index still answers and says so.
func TestSearch_IndexNoteWhileSlackBackfills(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedAll(t, d)
	exec(t, d, `UPDATE kb_sources SET cursor = '3' WHERE source = 'slack'`)
	res, err := Search(ctx, d, Request{Queries: []string{"стейдж"}, Now: testNow()})
	require.NoError(t, err)
	assert.NotEmpty(t, res.Hits)
	assert.Contains(t, res.IndexNote, "slack 50% indexed")
	empty, err := Search(ctx, db.OpenTestDB(t), Request{Queries: []string{"x"}, Now: testNow()})
	require.NoError(t, err)
	assert.Contains(t, empty.IndexNote, "knowledge index is empty")
}

func TestGetDocument(t *testing.T) { /* full text, truncation at maxChars with Truncated=true, unknown ref → ErrNotFound */ }

func TestStatus(t *testing.T) { /* one row per source name; slack docs count matches */ }
```

Write every `/* … */` body out fully (fixture rows, calls, assertions) — the comments state exactly what each asserts. Note `seedSlack` data is dated 2025-09-16: for `TestSearch_IndexNoteWhileSlackBackfills` set the slack cursor with `saveCursor` semantics — the fixture has 6 message rows, so cursor `3` → 50%. `kb_sources.updated_at` for the "last updated" note is set by the Run inside `seedAll` with `Now: testNow()`, so no staleness note appears.

`contracts_test.go`:

```go
// TestKB01_IncrementalEqualsRebuild — KB-01: the index is derived. Two
// incremental passes over changing data end in exactly the state a
// from-scratch rebuild produces, and indexing never writes a source table.
func TestKB01_IncrementalEqualsRebuild(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedAll(t, d) // seeds + Run(Now: day1)
	sourceBefore := dumpSourceTables(t, d)
	// mutate: new reply, deleted DM message, gmail thread update, jira hard delete, idea mention
	...
	_, err := Run(ctx, d, Options{Now: day2}) // next UTC day: reconcile runs
	require.NoError(t, err)
	incremental := dumpKB(t, d)
	_, err = Reindex(ctx, d, nil, day2)
	require.NoError(t, err)
	assert.Equal(t, incremental, dumpKB(t, d))
	// indexing wrote no source table (compare against the mutated state, dumped right after mutating)
}
```

Implement it concretely: dump the source tables **after** mutating and before the second Run, and compare to a dump after the Run + Reindex (must be equal). `dumpKB` = `SELECT id, source, title, doc_time, link, anchor_json, meta, content_hash, chunk_count FROM kb_documents ORDER BY id` + `SELECT doc_id, idx, title, body, meta, anchor FROM kb_chunks ORDER BY doc_id, idx` rendered to a string (exclude `indexed_at` and `kb_chunks.id`). `dumpSourceTables` covers `messages, gmail_messages, jira_issues, jira_comments, calendar_events, meeting_transcripts, meeting_recaps, digests, digest_topics, stream_digests, ideas, idea_mentions` (`SELECT * … ORDER BY 1,2` → `fmt.Sprint` of each row's `[]any`).

```go
// TestKB02_NoGeneratorImports — KB-02: internal/kb makes no model calls, so it
// imports none of the generator packages.
func TestKB02_NoGeneratorImports(t *testing.T) {
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, ".", func(fi fs.FileInfo) bool { return !strings.HasSuffix(fi.Name(), "_test.go") }, parser.ImportsOnly)
	require.NoError(t, err)
	forbidden := []string{"watchtower/internal/digest", "watchtower/internal/ai", "watchtower/internal/codex", "watchtower/internal/ollama", "watchtower/internal/providers"}
	files := 0
	for _, p := range pkgs {
		for name, f := range p.Files {
			files++
			for _, imp := range f.Imports {
				path := strings.Trim(imp.Path.Value, `"`)
				for _, bad := range forbidden {
					assert.False(t, path == bad || strings.HasPrefix(path, bad+"/"), "%s imports %s", name, path)
				}
			}
		}
	}
	assert.GreaterOrEqual(t, files, 10, "scan floor: the kb package files must actually be walked")
}

// TestKB03_EveryHitOpensAndAnchors — KB-03: every hit, from every source,
// opens via GetDocument and carries a non-empty source-native anchor.
func TestKB03_EveryHitOpensAndAnchors(t *testing.T) {
	// seedAll covers all ten sources (add recap, digest, stream_digest rows to seedAll
	// if not already there); search one distinctive word per source, and a broad OR query;
	// assert every source name appears among the hits at least once, and for every hit:
	// GetDocument(ref) succeeds with non-empty Text, and len(hit.Anchor) > 0 with no empty values.
}
```

Write TestKB03 fully. `seedAll` lives in `search_test.go` and must seed rows for **all ten** sources.

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** `query.go`, `search.go`, `status.go`.
- [ ] **Step 4: Run** `go test ./internal/kb` — PASS; `go vet ./internal/kb`.
- [ ] **Step 5: Commit** `feat(kb): multi-query search with rank fusion, status, KB-01..03 guards`.

---

### Task 8: MCP tools + Go chat prompt

**Files:**
- Create: `internal/tools/knowledge.go`, `internal/tools/knowledge_test.go`
- Modify: `internal/tools/readtools.go` (append `NewSearchKnowledge(), NewGetKnowledgeDocument()` to `ReadTools()` after `NewGetTaskContext()`)
- Modify: `internal/mcp/server_test.go` — `TestToolsList` `want` += `"search_knowledge", "get_knowledge_document"`; `TestAllToolsAreReadOnly` `readVerbs` += `"search_knowledge": true` with a comment line ("search_knowledge is a pure FTS read over the derived kb index"); `readOnlyGuardCalls()` += `{Name: "search_knowledge", Arguments: map[string]any{"queries": []any{"guard"}}}` and a `get_knowledge_document` call on a ref that exists after `seedGuardFixture` runs `kb.Run` (add `kb.Run(ctx, database, kb.Options{})` at the end of `seedGuardFixture`, then use the ref of the guard fixture's Jira issue — confirm the account id in the fixture, e.g. `jira:1:ABC-1`); add `"kb_documents", "kb_chunks"` to `guardTables`.
- Modify: `internal/ai/prompt.go` (tool list + workflow line), `internal/ai/prompt_test.go` (`TestBuildSystemPrompt_NamesRegisteredTools` list += both names)

**Interfaces:**
- Consumes: `kb.Search`, `kb.Request`, `kb.Result`, `kb.GetDocument`, `kb.ErrNotFound`, `kb.RequestError`, `kb.SourceNames`, `kb.MaxQueries`, `kb.MaxLimit`.
- Produces: `func NewSearchKnowledge() *Tool`, `func NewGetKnowledgeDocument() *Tool`.

```go
package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/kb"
)

type searchKnowledgeArgs struct {
	Queries []string `json:"queries" jsonschema:"1-5 search queries: the key terms, synonyms, both Russian and English variants, and word stems ending in * for Russian word forms (e.g. договор*)"`
	Sources []string `json:"sources,omitempty" jsonschema:"optional filter: slack, gmail, imap, jira, calendar, transcript, recap, digest, stream_digest, idea"`
	From    string   `json:"from,omitempty" jsonschema:"only documents active on/after this date (YYYY-MM-DD)"`
	To      string   `json:"to,omitempty" jsonschema:"only documents active on/before this date (YYYY-MM-DD)"`
	Limit   int      `json:"limit,omitempty" jsonschema:"max documents, 0 = default (10), capped at 25"`
}

type getKnowledgeDocumentArgs struct {
	Ref      string `json:"ref" jsonschema:"document ref from search_knowledge"`
	MaxChars int    `json:"max_chars,omitempty" jsonschema:"max characters of text, 0 = default (12000)"`
}

// NewSearchKnowledge is the topical search over every indexed source.
func NewSearchKnowledge() *Tool {
	return &Tool{
		Name: "search_knowledge",
		Description: "Search everything Watchtower has seen — Slack threads and DMs, mail, Jira issues with " +
			"comments, calendar events, meeting transcripts and recaps, digests, decisions and ideas — ranked by " +
			"relevance. Pass several queries (synonyms, Russian and English variants, stems with *). Returns " +
			"documents with snippets, a ref for get_knowledge_document, and a source anchor for links.",
		InputSchema: mustSchema[searchKnowledgeArgs]("search_knowledge"),
		Access:      AccessRead,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a searchKnowledgeArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			req := kb.Request{Queries: a.Queries, Sources: a.Sources, Limit: a.Limit}
			var err error
			if req.From, err = parseDay(a.From, false); err != nil {
				return nil, &ValidationError{Msg: "from must be YYYY-MM-DD"}
			}
			if req.To, err = parseDay(a.To, true); err != nil {
				return nil, &ValidationError{Msg: "to must be YYYY-MM-DD"}
			}
			res, err := kb.Search(ctx, d, req)
			var re *kb.RequestError
			if errors.As(err, &re) {
				return nil, &ValidationError{Msg: re.Msg}
			}
			if err != nil {
				return nil, fmt.Errorf("searching knowledge: %w", err)
			}
			return res, nil
		},
	}
}

// parseDay parses YYYY-MM-DD in UTC; endOfDay returns the next midnight (exclusive bound).
func parseDay(s string, endOfDay bool) (time.Time, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}, nil
	}
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		return time.Time{}, err
	}
	if endOfDay {
		t = t.AddDate(0, 0, 1)
	}
	return t, nil
}

// NewGetKnowledgeDocument opens one search hit in full.
func NewGetKnowledgeDocument() *Tool {
	return &Tool{
		Name:        "get_knowledge_document",
		Description: "Open one search_knowledge hit by its ref: the whole document text (capped), title, time, link and source anchor.",
		InputSchema: mustSchema[getKnowledgeDocumentArgs]("get_knowledge_document"),
		Access:      AccessRead,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a getKnowledgeDocumentArgs
			if err := json.Unmarshal(call.Args, &a); err != nil || strings.TrimSpace(a.Ref) == "" {
				return nil, &ValidationError{Msg: "ref is required"}
			}
			doc, err := kb.GetDocument(ctx, d, a.Ref, a.MaxChars)
			if errors.Is(err, kb.ErrNotFound) {
				return nil, &ValidationError{Msg: "no document with that ref — search again"}
			}
			if err != nil {
				return nil, fmt.Errorf("opening knowledge document: %w", err)
			}
			return doc, nil
		},
	}
}
```

If `internal/tools` already has a date helper with the same semantics, reuse it instead of `parseDay` and say so. Check whether `ValidationError` is how other read tools report bad args to the model (it is in `transcripts.go`).

Prompt (`internal/ai/prompt.go`): in the TOOLS list, insert as the **first** bullet:
`- search_knowledge / get_knowledge_document: relevance search across Slack, mail, Jira, calendar, transcripts, recaps, digests, decisions and ideas; open a hit in full by its ref.`
and replace the WORKFLOW line `1. Look the data up with the tools above (start with list_messages for raw Slack traffic)` with
`1. Look the data up with the tools above. For a topical question (what was decided / discussed / happened about X) start with search_knowledge: pass 2-5 queries — the key terms, synonyms, both Russian and English variants, and word stems ending in * for Russian word forms — then open the best hits with get_knowledge_document or the source tools. Use list_messages for "latest from a person/channel" questions.`
Keep any existing line that tells the model how to build Slack links; add after it: `- search_knowledge hits carry an anchor (channel_id + ts/thread_ts for Slack, issue key for Jira) — build links from it exactly as for list_messages.` Read the surrounding prompt text first and keep its style; if prompt tests assert the exact old workflow wording, update them to the new wording (this is a deliberate change, not a guard relaxation).

- [ ] **Step 1: Failing tests** `internal/tools/knowledge_test.go`: register both tools on `New(d)`; seed one Jira issue and run `kb.Run`; `callReadString(t, reg, "search_knowledge", `{"queries":["стейдж*"]}`)` contains `"ref":"jira:1:PROJ-123"` and `"anchor"`; `{"queries":[]}` → `reg.CallRead` returns an error whose message the model sees (assert `errors.As(err, &ve)` with `*ValidationError`); `{"queries":["x"],"from":"26-09-2026"}` → ValidationError; `get_knowledge_document` with the hit's ref contains `"text"`; with `{"ref":"nope"}` → ValidationError.
- [ ] **Step 2: Run** `go test ./internal/tools ./internal/mcp ./internal/ai ./cmd -run 'Knowledge|ToolsList|ReadOnly|NoToolMutates|Agent06|SystemPrompt|BuildToolRegistry|ToolsList_Shows'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same command — PASS. Then `go test ./internal/tools ./internal/mcp ./internal/ai` — PASS.
- [ ] **Step 5: Commit** `feat(tools): search_knowledge and get_knowledge_document; chat prompt routes topical questions`.

---

### Task 9: Config, feature, daemon phase, CLI

**Files:**
- Modify: `internal/config/config.go` (`KnowledgeConfig`, field `Knowledge KnowledgeConfig \`mapstructure:"knowledge"\``, `v.SetDefault("knowledge.enabled", DefaultKnowledgeEnabled)`), `internal/config/defaults.go` (`DefaultKnowledgeEnabled = true`), `cmd/config.go` (allowlist `"knowledge.enabled": true`)
- Modify: `internal/features/registry.go` (new entry), and any test that enumerates feature ids/config keys (grep `secretary-inbox` in `internal/features/*_test.go`, `cmd/features*_test.go` and extend lists that must stay exhaustive)
- Modify: `internal/daemon/daemon.go` (`phaseKnowledgeIndex`, call after `d.phaseTranscriptAudioCleanup()`)
- Create: `cmd/kb.go`, `cmd/kb_test.go`
- Test: `internal/daemon/knowledge_test.go` (or the file where other phase tests live — follow the package's convention)

**Interfaces:**
- Consumes: `kb.Run`, `kb.Options`, `kb.Reindex`, `kb.Status`, `kb.Search`, `kb.Request`, `kb.SourceNames`.
- Produces: `config.KnowledgeConfig{Enabled bool}`, feature `knowledge-search`, daemon method `phaseKnowledgeIndex(ctx context.Context)`, const `kbCycleBudget = 60 * time.Second`, cobra `kbCmd` with `status`, `reindex`, `search`.

Config:

```go
// KnowledgeConfig gates the knowledge-search index (spec 2026-09-26). Mechanical: no AI cost.
type KnowledgeConfig struct {
	Enabled bool `mapstructure:"enabled"` // index sources into kb_* for search_knowledge (default: true)
}
```

`knowledge.enabled` is **not** added to `legacyDigestOffFeatureKeys`/`ApplyLegacyDigestOff` (those model "all AI off"; this feature has no AI). If a test asserts every non-core feature key is in that list, extend its exemption set with a one-line reason instead.

Feature entry (place after `secretary-inbox`):

```go
{
	ID:          "knowledge-search",
	Title:       "Knowledge search",
	Description: "Keeps a local search index over Slack, mail, Jira, calendar, meeting transcripts and recaps, digests, decisions and ideas, so the chat finds what you ask about on the first try — no AI, nothing leaves your Mac.",
	Tagline:     "Ask about anything you've seen",
	Benefits: []string{
		"The chat finds the right thread, mail or ticket by topic",
		"Understands Russian word forms and mixed-language questions",
		"Runs locally in the background, no AI cost",
	},
	Icon:      "text.magnifyingglass",
	ConfigKey: "knowledge.enabled",
	Cost:      CostNone,
	Enabled:   func(cfg *config.Config) bool { return cfg.Knowledge.Enabled },
},
```

Daemon:

```go
// kbCycleBudget bounds one cycle's indexing so the first Slack backfill spreads
// across cycles instead of delaying every later phase.
const kbCycleBudget = 60 * time.Second

// phaseKnowledgeIndex brings the knowledge-search index up to date. Mechanical
// (no AI, KB-02); off = no indexing, the existing index stays readable (FEAT-01/02).
func (d *Daemon) phaseKnowledgeIndex(ctx context.Context) {
	if !d.config.Knowledge.Enabled {
		return
	}
	if d.db == nil {
		return
	}
	d.trackedPipelineRun("knowledge-index", func() pipelineRunStats {
		st, err := kb.Run(ctx, d.db, kb.Options{Budget: kbCycleBudget})
		if err != nil {
			d.logger.Printf("knowledge index: %v", err)
		}
		if st.Incomplete {
			d.logger.Printf("knowledge index: cycle budget reached (%d written, %d deleted), continuing next cycle", st.Written, st.Deleted)
		}
		return pipelineRunStats{items: st.Written + st.Deleted, err: err}
	})
}
```

Daemon test: build a daemon the way neighbouring phase tests do (grep `phaseTranscriptAudioCleanup\|phaseUnsnooze` in `internal/daemon/*_test.go` for the constructor/helper), seed one Jira issue, `cfg.Knowledge.Enabled = true` → after `phaseKnowledgeIndex(ctx)` `kb_documents` has 1 row and `pipeline_runs` has a `knowledge-index` row; with `Enabled = false` → no kb row and **no** `pipeline_runs` row (FEAT-01).

CLI `cmd/kb.go`:

```go
var kbCmd = &cobra.Command{Use: "kb", Short: "Local knowledge search index"}

var kbStatusCmd = &cobra.Command{Use: "status", Short: "Show per-source index state", RunE: runKBStatus}
var kbReindexCmd = &cobra.Command{Use: "reindex", Short: "Rebuild the index (all sources, or --source)", RunE: runKBReindex}
var kbSearchCmd = &cobra.Command{Use: "search <query>...", Short: "Search the index; each argument is one query", Args: cobra.MinimumNArgs(1), RunE: runKBSearch}

var (
	kbJSON    bool
	kbSources []string
	kbFrom    string
	kbTo      string
	kbLimit   int
)

func init() {
	rootCmd.AddCommand(kbCmd)
	kbCmd.AddCommand(kbStatusCmd, kbReindexCmd, kbSearchCmd)
	kbStatusCmd.Flags().BoolVar(&kbJSON, "json", false, "JSON output")
	kbReindexCmd.Flags().StringSliceVar(&kbSources, "source", nil, "source to rebuild (repeatable); default all")
	kbSearchCmd.Flags().StringSliceVar(&kbSources, "source", nil, "restrict to source (repeatable)")
	kbSearchCmd.Flags().StringVar(&kbFrom, "from", "", "YYYY-MM-DD")
	kbSearchCmd.Flags().StringVar(&kbTo, "to", "", "YYYY-MM-DD (inclusive)")
	kbSearchCmd.Flags().IntVar(&kbLimit, "limit", 0, "max documents (default 10, max 25)")
	kbSearchCmd.Flags().BoolVar(&kbJSON, "json", false, "JSON output")
}
```

- `runKBStatus`: `openDBFromConfig()`; `kb.Status`; JSON (`json.NewEncoder(out).Encode`) or a tab-aligned table (`text/tabwriter`): `SOURCE DOCS CHUNKS PROGRESS LAST RECONCILE`.
- `runKBReindex`: prints `Rebuilding …`; `kb.Reindex(ctx, db, kbSources, time.Now())`; prints `Done: N written, M deleted in <dur>`. Uses `cmd.Context()`.
- `runKBSearch`: parse `--from/--to` like the tool (to = next midnight); `kb.Search`; a `*kb.RequestError` → return it as the command error; JSON or text: `N. [source] title — when\n   ref: …\n   link: …\n   snippet…` and the index note on top when set.
- `cmd/kb_test.go`: follow an existing cmd test that runs a command against a temp workspace DB (grep `openDBFromConfig` users' tests, e.g. `cmd/*_test.go` calling `rootCmd.SetArgs`); cover `kb search` happy path, `kb reindex --source nope` → error, `kb status --json` shape.

Also update `internal/features` docs of FastForward only if a test requires every feature to be listed (it should not — no hook needed, spec §7).

- [ ] **Step 1: Failing tests** (config default, registry validity, daemon phase on/off, CLI).
- [ ] **Step 2: Run** `go test ./internal/config ./internal/features ./internal/daemon ./cmd -run 'Knowledge|KB|Registry|Feature|Config'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same — PASS; then `go build ./...` and `go test ./internal/config ./internal/features ./internal/daemon` — PASS. (Do not run the whole `./cmd` package with `-race`; plain `go test ./cmd -run 'KB|Feature|Config|Tools'` is enough here.)
- [ ] **Step 5: Commit** `feat: knowledge-search feature, daemon phase and kb CLI`.

---

### Task 10: Swift chat prompts

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift` (~:453 tool list, ~:525-528 workflow line), `TargetChatViewModel.swift` (~:1105), `IdeaChatViewModel.swift` (~:308), `MeetingChatViewModel.swift` (~:338), `WatchtowerDesktop/Sources/Views/Tracks/TrackChatView.swift` (~:381)
- Test: whatever Swift tests pin those prompts (grep `list_messages` under `WatchtowerDesktop/Tests`)

The Go prompt (`internal/ai/prompt.go`) and these copies are a deliberate dual path. In each tool list add, as the first tool bullet and in that file's bullet style:
`- search_knowledge / get_knowledge_document — relevance search across Slack, mail, Jira, calendar, transcripts, recaps, digests, decisions and ideas; open a hit in full by its ref. Pass 2-5 queries: key terms, synonyms, Russian and English variants, stems ending in * for Russian word forms.`
In `ChatViewModel` replace the workflow text `start with list_messages for raw Slack traffic` with `for a topical question start with search_knowledge; use list_messages for "latest from a person/channel"`, keeping the surrounding sentence and the code comment above it accurate (update the comment that explains why the line says what it says). In `TargetChatViewModel` and `TrackChatView`, next to the existing "`list_messages returns channel_id, ts, and thread_ts…`" line add `search_knowledge hits carry the same anchor fields, so build links from them the same way`. Draft-only chats (Idea, Meeting, Track) get only the tool bullet — they already receive the MCP read tools.

- [ ] **Step 1:** grep Swift tests asserting prompt text; update expectations that literally quote the changed workflow line; add one assertion per edited VM that its prompt contains `search_knowledge` (in the existing test class for that VM; if a VM has no prompt test, add it to the nearest existing one — do not create a new test target).
- [ ] **Step 2: Run** `make test-swift FILTER=<each touched test class>` (one run per class, or a regex FILTER covering them) — expect the new assertions FAIL.
- [ ] **Step 3: Edit the prompts.**
- [ ] **Step 4: Run** the same — PASS. Check the exit code explicitly (`echo $?` after writing output to a log file, not through `| tail`).
- [ ] **Step 5: Commit** `feat(desktop): chat prompts route topical questions through search_knowledge`.

---

### Task 11: Contracts, docs, final gate

**Files:**
- Create: `docs/inventory/knowledge-search.md`
- Modify: `docs/inventory/README.md` (module row), `CLAUDE.md` (Feature Notes: new `### Knowledge search (2026-09-26)` section, ≤12 lines, placed after "Attention detection"), `docs/app-guide.md` (chat section: mention that the chat searches all sources; Settings → Features: the new toggle — follow the file's existing structure)

`docs/inventory/knowledge-search.md` format follows `docs/inventory/dev-surface.md`: header, one `## KB-0N — <name>` per contract with **Status:** Enforced, **Observable:**, **Guard:** (test name + file), then a `## Changelog` with `- 2026-09-26: initial contracts KB-01..03 (spec docs/superpowers/specs/2026-09-26-knowledge-search-design.md).` Contract text is spec §10 verbatim-in-substance. State explicitly that read-only-ness is DEV-01's (both tools are in `readOnlyGuardCalls`).

README row: `| Knowledge Search | [knowledge-search.md](knowledge-search.md) | \`internal/kb/\`, \`internal/tools/knowledge.go\`, \`internal/daemon/daemon.go\` (\`phaseKnowledgeIndex\`), \`cmd/kb.go\` |`

CLAUDE.md section content: what it is (derived FTS index, tables, units), daemon phase + budget + cursors + daily reconcile, search algorithm in one line, surfaces (tools, CLI, prompts dual path Go↔Swift), feature `knowledge-search` default on, contracts pointer, v1 limits (no vectors; Slack edits older than 48h caught only by `kb reindex`; memory not indexed).

- [ ] **Step 1:** Write the docs.
- [ ] **Step 2: Gate:** `make lint-diff`; `go test ./internal/kb ./internal/tools ./internal/mcp ./internal/ai ./internal/config ./internal/features ./internal/daemon ./internal/db`; `go build ./...`. All green (logs to files, check exit codes).
- [ ] **Step 3: Commit** `docs: knowledge search contracts KB-01..03, CLAUDE.md, app guide`.

---

## Controller-only steps (not subagent tasks)

After Task 11: full gate (`make test`, `make lint-all`, `make test-swift` — exit codes checked), the real-data smoke on the owner DB **against a copy** (`cp ~/.local/share/watchtower/<corp-workspace>/watchtower.db` into the scratchpad, point a temp config/workspace at it or use `db.Open` via a tiny `go run` harness — never write the live DB), measuring `kb reindex` time and DB growth and running ~10 topical questions through `kb search`; then the local-review/debate-review pass and the PR.
