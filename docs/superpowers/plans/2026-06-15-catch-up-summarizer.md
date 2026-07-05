# Catch-Up Summarizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Catch-Up" feature that produces an on-demand AI rollup of exactly the currently-unread items across digests, tracks, inbox, and briefings, rendered as cross-source thematic stories, with per-section and global bulk "mark read".

**Architecture:** New `internal/catchup` Go package mirrors the `internal/meeting` pipeline pattern — gathers capped/ranked unread rows from the DB, makes one `digest.Generator` call to cluster them into stories, and emits a `Result` JSON. The `sections[]` (clearable item-ID lists) come from the DB gather (ground truth), not from the model. A new `watchtower catchup --json` CLI command exposes it. Desktop `CatchUpView` runs the CLI subprocess (like `MeetingPrepViewModel`), renders TL;DR + stories + per-source sections, and clears indicators via new bulk `markRead(ids:)` queries operating on the rollup's ID snapshot.

**Tech Stack:** Go 1.25 (cobra, modernc.org/sqlite via `database/sql`), SwiftUI macOS (GRDB.swift), `digest.Generator` AI interface.

**No schema migration required** — all read-state columns (`read_at`, `has_updates`) already exist; the rollup is ephemeral (no new table).

---

## File Structure

**Go (backend):**
- `internal/db/catchup.go` (create) — gather queries + bulk mark-read-by-ID funcs
- `internal/db/catchup_test.go` (create) — gather caps + bulk-mark isolation tests
- `internal/catchup/types.go` (create) — `Result`, `Story`, `Section`, `Counts` structs
- `internal/catchup/prompt.go` (create) — `catchup.summarize` system prompt + prompt builder
- `internal/catchup/pipeline.go` (create) — `Pipeline.Run()` gather → AI → parse → fallback
- `internal/catchup/pipeline_test.go` (create) — mockGenerator, fallback, zero-unread tests
- `internal/config/config.go` (modify) — add `CatchupConfig` + viper defaults
- `cmd/catchup.go` (create) — `watchtower catchup --json` command
- `cmd/root.go` (modify) — register `catchupCmd`

**Swift (desktop):**
- `WatchtowerDesktop/Sources/Database/Queries/TrackQueries.swift` (modify) — `markRead(ids:)`
- `WatchtowerDesktop/Sources/Database/Queries/InboxQueries.swift` (modify) — `markRead(ids:)`
- `WatchtowerDesktop/Sources/Database/Queries/DigestQueries.swift` (modify) — `markRead(ids:)`
- `WatchtowerDesktop/Sources/Database/Queries/BriefingQueries.swift` (modify) — `markRead(ids:)`
- `WatchtowerDesktop/Sources/ViewModels/CatchUpViewModel.swift` (create) — Codable result + subprocess + clearing
- `WatchtowerDesktop/Sources/Views/CatchUp/CatchUpView.swift` (create) — UI
- `WatchtowerDesktop/Sources/App/SidebarDestination.swift` (modify) — `.catchUp` case
- `WatchtowerDesktop/Sources/Views/Sidebar/SidebarView.swift` (modify) — badge
- `WatchtowerDesktop/Sources/ViewModels/SidebarCountsViewModel.swift` (modify) — `catchUpTotalCount`
- `WatchtowerDesktop/Sources/App/AppState.swift` (modify) — own `CatchUpViewModel`
- `WatchtowerDesktop/Sources/App/Navigation.swift` (modify) — `.catchUp` → `CatchUpView`
- `WatchtowerDesktop/Tests/.../CatchUpViewModelTests.swift` (create) — parse + clearing tests

---

## Task 1: Config — `CatchupConfig`

**Files:**
- Modify: `internal/config/config.go`

- [ ] **Step 1: Add `CatchupConfig` field to the `Config` struct**

In `internal/config/config.go`, add to the `Config` struct (after the `Targets TargetsConfig` line):

```go
	Catchup         CatchupConfig               `mapstructure:"catchup"`
```

- [ ] **Step 2: Define `CatchupConfig` and its caps**

Add near the other sub-config struct definitions (e.g. after `InboxConfig`):

```go
// CatchupConfig controls the on-demand unread summarizer.
type CatchupConfig struct {
	MaxAgeDays int            `mapstructure:"max_age_days"`
	Caps       CatchupCaps    `mapstructure:"caps"`
}

// CatchupCaps bounds how many unread items per area feed the AI rollup.
type CatchupCaps struct {
	Digests   int `mapstructure:"digests"`
	Tracks    int `mapstructure:"tracks"`
	Inbox     int `mapstructure:"inbox"`
	Briefings int `mapstructure:"briefings"`
}
```

- [ ] **Step 3: Set viper defaults in `Load()`**

In the `Load()` function where other `v.SetDefault(...)` calls live, add:

```go
	v.SetDefault("catchup.max_age_days", 30)
	v.SetDefault("catchup.caps.digests", 40)
	v.SetDefault("catchup.caps.tracks", 20)
	v.SetDefault("catchup.caps.inbox", 30)
	v.SetDefault("catchup.caps.briefings", 5)
```

- [ ] **Step 4: Verify it compiles**

Run: `go build ./internal/config/`
Expected: no output (success).

- [ ] **Step 5: Commit**

```bash
git add internal/config/config.go
git commit -m "feat(catchup): add catchup config with per-area caps"
```

---

## Task 2: DB gather queries

Each gather func returns capped+ranked compact rows **and** the uncapped total (for truncation reporting). Unread predicates per area match the existing sidebar counts.

**Files:**
- Create: `internal/db/catchup.go`
- Test: `internal/db/catchup_test.go`

- [ ] **Step 1: Write the failing test**

Create `internal/db/catchup_test.go`:

```go
package db

import "testing"

func TestCatchup01_GetUnreadDigestsCapAndTotal(t *testing.T) {
	d := openTestDB(t)
	for i := 0; i < 5; i++ {
		if _, err := d.Exec(
			`INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at)
			 VALUES (?, ?, ?, 'channel', ?, NULL)`,
			"C1", float64(i), float64(i+1), "summary text "+itoa(i)); err != nil {
			t.Fatal(err)
		}
	}
	// One already-read digest must be excluded.
	if _, err := d.Exec(
		`INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at)
		 VALUES ('C1', 99, 100, 'channel', 'read one', '2026-01-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}

	items, total, err := d.GetUnreadDigests(3)
	if err != nil {
		t.Fatal(err)
	}
	if total != 5 {
		t.Fatalf("total = %d, want 5", total)
	}
	if len(items) != 3 {
		t.Fatalf("len(items) = %d, want 3 (capped)", len(items))
	}
	if items[0].ID == 0 {
		t.Fatal("expected populated item ID")
	}
}

func itoa(i int) string { return string(rune('0' + i)) }
```

(`openTestDB` is the existing test helper in `internal/db` — confirm its name by grepping the package's `_test.go` files; if it differs, use the package's standard in-memory DB constructor.)

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/db/ -run TestCatchup01 -v`
Expected: FAIL — `d.GetUnreadDigests undefined`.

- [ ] **Step 3: Implement the gather queries**

Create `internal/db/catchup.go`:

```go
package db

import "fmt"

// UnreadItem is a compact representation of one unread row for the catch-up rollup.
type UnreadItem struct {
	ID       int
	Title    string
	Snippet  string
	Priority string // "" when the area has no priority concept
}

// GetUnreadDigests returns up to limit unread digests (read_at IS NULL),
// newest first, plus the uncapped total count.
func (db *DB) GetUnreadDigests(limit int) ([]UnreadItem, int, error) {
	var total int
	if err := db.QueryRow(`SELECT COUNT(*) FROM digests WHERE read_at IS NULL`).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("counting unread digests: %w", err)
	}
	rows, err := db.Query(`
		SELECT id, type, channel_id, substr(summary, 1, 280)
		FROM digests WHERE read_at IS NULL
		ORDER BY period_to DESC LIMIT ?`, limit)
	if err != nil {
		return nil, 0, fmt.Errorf("querying unread digests: %w", err)
	}
	defer rows.Close()
	var items []UnreadItem
	for rows.Next() {
		var it UnreadItem
		var dtype, channel string
		if err := rows.Scan(&it.ID, &dtype, &channel, &it.Snippet); err != nil {
			return nil, 0, fmt.Errorf("scanning digest: %w", err)
		}
		it.Title = dtype + " digest " + channel
		items = append(items, it)
	}
	return items, total, rows.Err()
}

// GetUnreadTracks returns up to limit tracks with pending updates
// (has_updates=1, not dismissed), ranked by priority then recency.
func (db *DB) GetUnreadTracks(limit int) ([]UnreadItem, int, error) {
	var total int
	if err := db.QueryRow(`SELECT COUNT(*) FROM tracks WHERE has_updates = 1 AND dismissed_at = ''`).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("counting unread tracks: %w", err)
	}
	rows, err := db.Query(`
		SELECT id, text, substr(context, 1, 280), priority
		FROM tracks WHERE has_updates = 1 AND dismissed_at = ''
		ORDER BY CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, updated_at DESC
		LIMIT ?`, limit)
	if err != nil {
		return nil, 0, fmt.Errorf("querying unread tracks: %w", err)
	}
	defer rows.Close()
	var items []UnreadItem
	for rows.Next() {
		var it UnreadItem
		if err := rows.Scan(&it.ID, &it.Title, &it.Snippet, &it.Priority); err != nil {
			return nil, 0, fmt.Errorf("scanning track: %w", err)
		}
		items = append(items, it)
	}
	return items, total, rows.Err()
}

// GetUnreadInboxItems returns up to limit pending, unarchived, unread inbox
// items, ranked by priority then recency.
func (db *DB) GetUnreadInboxItems(limit int) ([]UnreadItem, int, error) {
	const where = `status = 'pending' AND archived_at IS NULL AND (read_at IS NULL OR read_at = '')`
	var total int
	if err := db.QueryRow(`SELECT COUNT(*) FROM inbox_items WHERE ` + where).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("counting unread inbox: %w", err)
	}
	rows, err := db.Query(`
		SELECT id, trigger_type, substr(snippet, 1, 280), priority
		FROM inbox_items WHERE `+where+`
		ORDER BY CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, updated_at DESC
		LIMIT ?`, limit)
	if err != nil {
		return nil, 0, fmt.Errorf("querying unread inbox: %w", err)
	}
	defer rows.Close()
	var items []UnreadItem
	for rows.Next() {
		var it UnreadItem
		var trigger string
		if err := rows.Scan(&it.ID, &trigger, &it.Snippet, &it.Priority); err != nil {
			return nil, 0, fmt.Errorf("scanning inbox item: %w", err)
		}
		it.Title = trigger
		items = append(items, it)
	}
	return items, total, rows.Err()
}

// GetUnreadBriefings returns up to limit unread briefings (read_at IS NULL),
// newest first, plus the uncapped total.
func (db *DB) GetUnreadBriefings(limit int) ([]UnreadItem, int, error) {
	var total int
	if err := db.QueryRow(`SELECT COUNT(*) FROM briefings WHERE read_at IS NULL`).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("counting unread briefings: %w", err)
	}
	rows, err := db.Query(`
		SELECT id, date FROM briefings WHERE read_at IS NULL
		ORDER BY date DESC LIMIT ?`, limit)
	if err != nil {
		return nil, 0, fmt.Errorf("querying unread briefings: %w", err)
	}
	defer rows.Close()
	var items []UnreadItem
	for rows.Next() {
		var it UnreadItem
		var date string
		if err := rows.Scan(&it.ID, &date); err != nil {
			return nil, 0, fmt.Errorf("scanning briefing: %w", err)
		}
		it.Title = "Briefing " + date
		items = append(items, it)
	}
	return items, total, rows.Err()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/db/ -run TestCatchup01 -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/db/catchup.go internal/db/catchup_test.go
git commit -m "feat(catchup): add unread gather queries with caps and totals"
```

---

## Task 3: DB bulk mark-read by ID

Bulk variants that mark exactly the given IDs (the rollup snapshot). Tracks cascade to linked digests like the single-ID `MarkTrackRead`.

**Files:**
- Modify: `internal/db/catchup.go`
- Test: `internal/db/catchup_test.go`

- [ ] **Step 1: Write the failing test**

Append to `internal/db/catchup_test.go`:

```go
func TestCatchup02_MarkDigestsReadOnlySnapshot(t *testing.T) {
	d := openTestDB(t)
	var ids []int
	for i := 0; i < 3; i++ {
		res, err := d.Exec(
			`INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at)
			 VALUES ('C1', ?, ?, 'channel', 'x', NULL)`, float64(i), float64(i+1))
		if err != nil {
			t.Fatal(err)
		}
		id, _ := res.LastInsertId()
		ids = append(ids, int(id))
	}

	// Mark only the first two; the third must stay unread.
	if err := d.MarkDigestsRead(ids[:2]); err != nil {
		t.Fatal(err)
	}

	_, total, err := d.GetUnreadDigests(100)
	if err != nil {
		t.Fatal(err)
	}
	if total != 1 {
		t.Fatalf("unread total = %d, want 1 (third untouched)", total)
	}

	// Idempotent: re-marking already-read IDs is a no-op, not an error.
	if err := d.MarkDigestsRead(ids[:2]); err != nil {
		t.Fatalf("re-mark errored: %v", err)
	}
	// Empty slice is a safe no-op.
	if err := d.MarkDigestsRead(nil); err != nil {
		t.Fatalf("nil slice errored: %v", err)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/db/ -run TestCatchup02 -v`
Expected: FAIL — `d.MarkDigestsRead undefined`.

- [ ] **Step 3: Implement the bulk mark funcs**

Append to `internal/db/catchup.go` (add `"encoding/json"` and `"strings"` to the import block):

```go
// inClause builds a "(?,?,?)" placeholder string and the matching args slice.
func inClause(ids []int) (string, []any) {
	ph := make([]string, len(ids))
	args := make([]any, len(ids))
	for i, id := range ids {
		ph[i] = "?"
		args[i] = id
	}
	return strings.Join(ph, ","), args
}

// MarkDigestsRead marks the given digests read. No-op on empty input. Idempotent.
func (db *DB) MarkDigestsRead(ids []int) error {
	if len(ids) == 0 {
		return nil
	}
	ph, args := inClause(ids)
	q := `UPDATE digests SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
	      WHERE id IN (` + ph + `) AND read_at IS NULL`
	if _, err := db.Exec(q, args...); err != nil {
		return fmt.Errorf("bulk marking digests read: %w", err)
	}
	return nil
}

// MarkTracksRead marks the given tracks read (read_at set, has_updates cleared)
// and cascades to each track's related digests. No-op on empty input.
func (db *DB) MarkTracksRead(ids []int) error {
	for _, id := range ids {
		if err := db.MarkTrackRead(id); err != nil {
			return fmt.Errorf("bulk marking track %d: %w", id, err)
		}
	}
	return nil
}

// MarkInboxReadBulk marks the given inbox items read. No-op on empty input. Idempotent.
func (db *DB) MarkInboxReadBulk(ids []int) error {
	if len(ids) == 0 {
		return nil
	}
	ph, args := inClause(ids)
	q := `UPDATE inbox_items SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
	      WHERE id IN (` + ph + `) AND (read_at IS NULL OR read_at = '')`
	if _, err := db.Exec(q, args...); err != nil {
		return fmt.Errorf("bulk marking inbox read: %w", err)
	}
	return nil
}

// MarkBriefingsRead marks the given briefings read. No-op on empty input. Idempotent.
func (db *DB) MarkBriefingsRead(ids []int) error {
	if len(ids) == 0 {
		return nil
	}
	ph, args := inClause(ids)
	q := `UPDATE briefings SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
	      WHERE id IN (` + ph + `) AND read_at IS NULL`
	if _, err := db.Exec(q, args...); err != nil {
		return fmt.Errorf("bulk marking briefings read: %w", err)
	}
	return nil
}

// ensure encoding/json is referenced (MarkTrackRead cascade uses it indirectly);
// remove this if json is already imported for other funcs in this file.
var _ = json.Marshal
```

(If `json` ends up unused in this file, drop the import and the `var _` line — `MarkTrackRead` lives in `tracks.go`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/db/ -run TestCatchup02 -v`
Expected: PASS.

- [ ] **Step 5: Run the whole db package to confirm no regressions**

Run: `go test ./internal/db/`
Expected: `ok  watchtower/internal/db`.

- [ ] **Step 6: Commit**

```bash
git add internal/db/catchup.go internal/db/catchup_test.go
git commit -m "feat(catchup): add bulk mark-read-by-id with snapshot isolation"
```

---

## Task 4: `internal/catchup` types

**Files:**
- Create: `internal/catchup/types.go`

- [ ] **Step 1: Write the types**

Create `internal/catchup/types.go`:

```go
// Package catchup builds an on-demand AI rollup of currently-unread items
// across digests, tracks, inbox, and briefings, clustered into thematic stories.
package catchup

// Ref links a story back to a source item.
type Ref struct {
	Area  string `json:"area"`  // digests|tracks|inbox|briefings
	ID    int    `json:"id"`
	Label string `json:"label"`
}

// Story is a cross-source thematic cluster of unread items.
type Story struct {
	Title     string `json:"title"`
	Narrative string `json:"narrative"`
	Priority  string `json:"priority"` // high|medium|low
	NeedsYou  bool   `json:"needs_you"`
	Refs      []Ref  `json:"refs"`
}

// SectionItem is one clearable unread row.
type SectionItem struct {
	ID      int    `json:"id"`
	Title   string `json:"title"`
	Snippet string `json:"snippet"`
}

// Section is the raw per-area unread set; its item IDs drive clearing.
type Section struct {
	Area     string        `json:"area"`
	Total    int           `json:"total"`
	Included int           `json:"included"`
	Items    []SectionItem `json:"items"`
}

// AreaCount reports included vs uncapped totals per area.
type AreaCount struct {
	Included int `json:"included"`
	Total    int `json:"total"`
}

// Counts aggregates per-area and overall unread totals.
type Counts struct {
	Digests       AreaCount `json:"digests"`
	Tracks        AreaCount `json:"tracks"`
	Inbox         AreaCount `json:"inbox"`
	Briefings     AreaCount `json:"briefings"`
	TotalUnread   int       `json:"total_unread"`
	TotalIncluded int       `json:"total_included"`
}

// Result is the full catch-up rollup emitted as JSON by the CLI.
type Result struct {
	TLDR      string    `json:"tldr"`
	Counts    Counts    `json:"counts"`
	Truncated bool      `json:"truncated"`
	Stories   []Story   `json:"stories"`
	Sections  []Section `json:"sections"`
}

// aiOutput is the narrow shape the model returns; sections come from the DB,
// not the model, so the model only produces the reading layer.
type aiOutput struct {
	TLDR    string  `json:"tldr"`
	Stories []Story `json:"stories"`
}
```

- [ ] **Step 2: Verify it compiles**

Run: `go build ./internal/catchup/`
Expected: success (no output).

- [ ] **Step 3: Commit**

```bash
git add internal/catchup/types.go
git commit -m "feat(catchup): add result and story types"
```

---

## Task 5: `internal/catchup` prompt

**Files:**
- Create: `internal/catchup/prompt.go`

- [ ] **Step 1: Write the prompt + builder**

Create `internal/catchup/prompt.go`:

```go
package catchup

import (
	"fmt"
	"strings"
)

const systemPrompt = `You are a chief-of-staff catching the operator up on everything they missed while away.

You receive the operator's currently-unread items grouped by source (digests, tracks, inbox, briefings). Each item has a stable numeric id within its area.

Your job: cluster related items into a small set of THEMATIC STORIES that span sources. One real-world topic that shows up in a digest AND a track AND an inbox mention is ONE story, not three. Merge aggressively; prefer 3-8 strong stories over a long shallow list.

For each story:
- title: short, concrete (e.g. "Payments migration blocked on infra review").
- narrative: 2-4 sentences synthesizing what happened and where it stands.
- priority: "high" | "medium" | "low".
- needs_you: true only if it requires the operator's own action/decision/reply.
- refs: the source items that belong to the story, each as {area, id, label}. Use ONLY ids that appear in the input. Never invent ids.

Also write a "tldr": 2-3 sentences capturing the most important things overall. If a targets line is provided, fold its counts into the tldr verbatim.

Respond with ONLY a JSON object, no markdown fences:
{"tldr": "...", "stories": [{"title": "...", "narrative": "...", "priority": "high", "needs_you": true, "refs": [{"area": "track", "id": 1, "label": "..."}]}]}`

// buildUserMessage renders the gathered sections (and optional targets context)
// into the user message for the model.
func buildUserMessage(sections []Section, targetsLine string) string {
	var b strings.Builder
	if targetsLine != "" {
		b.WriteString("TARGETS CONTEXT (read-only, fold into tldr): ")
		b.WriteString(targetsLine)
		b.WriteString("\n\n")
	}
	for _, s := range sections {
		if len(s.Items) == 0 {
			continue
		}
		fmt.Fprintf(&b, "=== %s (showing %d of %d) ===\n", strings.ToUpper(s.Area), s.Included, s.Total)
		for _, it := range s.Items {
			fmt.Fprintf(&b, "[id=%d] %s — %s\n", it.ID, it.Title, oneLine(it.Snippet))
		}
		b.WriteString("\n")
	}
	return b.String()
}

func oneLine(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
```

- [ ] **Step 2: Verify it compiles**

Run: `go build ./internal/catchup/`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add internal/catchup/prompt.go
git commit -m "feat(catchup): add summarize prompt and user-message builder"
```

---

## Task 6: `internal/catchup` pipeline

**Files:**
- Create: `internal/catchup/pipeline.go`
- Test: `internal/catchup/pipeline_test.go`

- [ ] **Step 1: Write the failing test**

Create `internal/catchup/pipeline_test.go`:

```go
package catchup

import (
	"context"
	"testing"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// mockGenerator returns canned output and records that it was called.
type mockGenerator struct {
	out    string
	called bool
}

func (m *mockGenerator) Generate(_ context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	m.called = true
	return m.out, &digest.Usage{}, "", nil
}

func newCfg() *config.Config {
	c := &config.Config{}
	c.Catchup.Caps = config.CatchupCaps{Digests: 40, Tracks: 20, Inbox: 30, Briefings: 5}
	return c
}

func seedUnreadDigest(t *testing.T, d *db.DB) {
	t.Helper()
	if _, err := d.Exec(
		`INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at)
		 VALUES ('C1', 1, 2, 'channel', 'something happened', NULL)`); err != nil {
		t.Fatal(err)
	}
}

func TestCatchup10_RunBuildsStoriesAndSections(t *testing.T) {
	d := db.OpenTestDB(t) // use the db package's exported/!test helper; adjust name if needed
	seedUnreadDigest(t, d)
	gen := &mockGenerator{out: `{"tldr":"You missed one thing.","stories":[{"title":"S","narrative":"N","priority":"high","needs_you":true,"refs":[{"area":"digests","id":1,"label":"x"}]}]}`}

	res, err := New(d, newCfg(), gen).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !gen.called {
		t.Fatal("generator not called for non-empty backlog")
	}
	if res.TLDR != "You missed one thing." {
		t.Fatalf("tldr = %q", res.TLDR)
	}
	if len(res.Stories) != 1 || res.Stories[0].Title != "S" {
		t.Fatalf("stories = %+v", res.Stories)
	}
	if res.Counts.TotalUnread != 1 {
		t.Fatalf("total unread = %d, want 1", res.Counts.TotalUnread)
	}
	// Sections come from the DB, not the model.
	if got := sectionItems(res, "digests"); len(got) != 1 || got[0].ID != 1 {
		t.Fatalf("digest section = %+v", got)
	}
}

func TestCatchup11_ZeroUnreadSkipsAI(t *testing.T) {
	d := db.OpenTestDB(t)
	gen := &mockGenerator{out: `{"tldr":"x"}`}
	res, err := New(d, newCfg(), gen).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if gen.called {
		t.Fatal("generator must not be called when nothing is unread")
	}
	if res.Counts.TotalUnread != 0 || len(res.Stories) != 0 {
		t.Fatalf("expected empty result, got %+v", res)
	}
}

func TestCatchup12_AIFailureFallsBackToSections(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d)
	gen := &mockGenerator{out: `not json at all`}
	res, err := New(d, newCfg(), gen).Run(context.Background())
	if err != nil {
		t.Fatalf("fallback must not error: %v", err)
	}
	if len(res.Stories) != 0 {
		t.Fatal("expected no stories on parse failure")
	}
	if sec := sectionItems(res, "digests"); len(sec) != 1 {
		t.Fatalf("sections must still populate on AI failure, got %+v", sec)
	}
}

func sectionItems(r *Result, area string) []SectionItem {
	for _, s := range r.Sections {
		if s.Area == area {
			return s.Items
		}
	}
	return nil
}
```

> Note on `db.OpenTestDB`: the `internal/db` package already has an in-memory test-DB helper (grep `_test.go` in that package). If it is unexported (e.g. `openTestDB`), add a thin exported wrapper `func OpenTestDB(t *testing.T) *DB` in a new `internal/db/testhelpers.go` guarded for test use, or move these pipeline tests to reuse an exported constructor. Pick whichever matches the repo's existing convention — do not duplicate DB setup logic.

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/catchup/ -run TestCatchup1 -v`
Expected: FAIL — `New` / `Run` undefined.

- [ ] **Step 3: Implement the pipeline**

Create `internal/catchup/pipeline.go`:

```go
package catchup

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// Pipeline assembles the catch-up rollup.
type Pipeline struct {
	db  *db.DB
	cfg *config.Config
	gen digest.Generator
}

// New constructs a catch-up Pipeline.
func New(database *db.DB, cfg *config.Config, gen digest.Generator) *Pipeline {
	return &Pipeline{db: database, cfg: cfg, gen: gen}
}

// Run gathers unread items, builds sections (ground truth), and—if anything is
// unread—asks the AI to cluster them into stories. AI failure degrades to a
// sections-only result; it never blocks the rollup.
func (p *Pipeline) Run(ctx context.Context) (*Result, error) {
	caps := p.cfg.Catchup.Caps

	dItems, dTotal, err := p.db.GetUnreadDigests(caps.Digests)
	if err != nil {
		return nil, err
	}
	tItems, tTotal, err := p.db.GetUnreadTracks(caps.Tracks)
	if err != nil {
		return nil, err
	}
	iItems, iTotal, err := p.db.GetUnreadInboxItems(caps.Inbox)
	if err != nil {
		return nil, err
	}
	bItems, bTotal, err := p.db.GetUnreadBriefings(caps.Briefings)
	if err != nil {
		return nil, err
	}

	sections := []Section{
		toSection("digests", dItems, dTotal),
		toSection("tracks", tItems, tTotal),
		toSection("inbox", iItems, iTotal),
		toSection("briefings", bItems, bTotal),
	}

	res := &Result{
		Sections: sections,
		Counts: Counts{
			Digests:   AreaCount{Included: len(dItems), Total: dTotal},
			Tracks:    AreaCount{Included: len(tItems), Total: tTotal},
			Inbox:     AreaCount{Included: len(iItems), Total: iTotal},
			Briefings: AreaCount{Included: len(bItems), Total: bTotal},
		},
	}
	res.Counts.TotalUnread = dTotal + tTotal + iTotal + bTotal
	res.Counts.TotalIncluded = len(dItems) + len(tItems) + len(iItems) + len(bItems)
	res.Truncated = res.Counts.TotalIncluded < res.Counts.TotalUnread

	// Nothing unread → empty result, no AI call.
	if res.Counts.TotalUnread == 0 {
		return res, nil
	}

	user := buildUserMessage(sections, p.targetsLine())
	raw, _, _, err := p.gen.Generate(ctx, systemPrompt, user, "")
	if err != nil {
		return res, nil // degrade: sections still clearable
	}
	if ai, perr := parseAIOutput(raw); perr == nil {
		res.TLDR = ai.TLDR
		res.Stories = ai.Stories
	}
	return res, nil
}

func toSection(area string, items []db.UnreadItem, total int) Section {
	sec := Section{Area: area, Total: total, Included: len(items)}
	for _, it := range items {
		sec.Items = append(sec.Items, SectionItem{ID: it.ID, Title: it.Title, Snippet: it.Snippet})
	}
	return sec
}

// targetsLine renders a read-only summary of active targets for the tldr.
func (p *Pipeline) targetsLine() string {
	c, err := p.db.GetTargetCounts()
	if err != nil {
		return ""
	}
	return fmt.Sprintf("%d active targets, %d overdue, %d due today", c.Active, c.Overdue, c.DueToday)
}

// parseAIOutput extracts the {tldr, stories} object, tolerating markdown fences.
func parseAIOutput(raw string) (aiOutput, error) {
	var out aiOutput
	s := raw
	if i := strings.Index(s, "{"); i >= 0 {
		if j := strings.LastIndex(s, "}"); j >= i {
			s = s[i : j+1]
		}
	}
	if err := json.Unmarshal([]byte(s), &out); err != nil {
		return aiOutput{}, fmt.Errorf("parsing catchup AI output: %w", err)
	}
	return out, nil
}
```

> `GetTargetCounts` and its `TargetCounts` fields (`Active`, `Overdue`, `DueToday`) are referenced from `internal/db/targets.go` (per CLAUDE.md). Confirm the exact field names by reading that file before implementing `targetsLine`; if `DueToday` is named differently, match the real field. If `GetTargetCounts` returns an error-free struct or a different signature, adapt the call — the targets line is best-effort and must never fail the rollup.

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/catchup/ -v`
Expected: PASS (all three tests).

- [ ] **Step 5: Commit**

```bash
git add internal/catchup/pipeline.go internal/catchup/pipeline_test.go
git commit -m "feat(catchup): add rollup pipeline with AI clustering and fallback"
```

---

## Task 7: CLI command `watchtower catchup`

**Files:**
- Create: `cmd/catchup.go`
- Modify: `cmd/root.go`

- [ ] **Step 1: Write the command**

Create `cmd/catchup.go`:

```go
package cmd

import (
	"encoding/json"
	"fmt"

	"github.com/spf13/cobra"

	"watchtower/internal/catchup"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

var catchupFlagJSON bool

var catchupCmd = &cobra.Command{
	Use:   "catchup",
	Short: "Summarize everything unread across digests, tracks, inbox, and briefings",
	RunE:  runCatchup,
}

func init() {
	catchupCmd.Flags().BoolVar(&catchupFlagJSON, "json", false, "output result as JSON")
	rootCmd.AddCommand(catchupCmd)
}

func runCatchup(cmd *cobra.Command, _ []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return err
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	gen := cliGenerator(cfg)
	result, err := catchup.New(database, cfg, gen).Run(cmd.Context())
	if err != nil {
		return err
	}

	out := cmd.OutOrStdout()
	if catchupFlagJSON {
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		return enc.Encode(result)
	}

	fmt.Fprintf(out, "Catch-Up — %d unread (%d shown)\n\n", result.Counts.TotalUnread, result.Counts.TotalIncluded)
	if result.TLDR != "" {
		fmt.Fprintf(out, "%s\n\n", result.TLDR)
	}
	for _, s := range result.Stories {
		flag := ""
		if s.NeedsYou {
			flag = " [needs you]"
		}
		fmt.Fprintf(out, "• (%s)%s %s\n  %s\n", s.Priority, flag, s.Title, s.Narrative)
	}
	return nil
}
```

> Verify the global flag names `flagConfig` and `flagWorkspace` and the provider-override pattern by reading `cmd/root.go` and `cmd/meeting.go`; match exactly what those commands do (including any `applyProviderOverride()` call if `meeting-prep` uses one).

- [ ] **Step 2: Verify it builds**

Run: `go build ./...`
Expected: success.

- [ ] **Step 3: Smoke-test against the active workspace**

Run: `go run . catchup --json | head -40`
Expected: a JSON object with `counts`, `sections`, and (if backlog non-empty and AI available) `stories`. If the workspace is empty, `total_unread` is 0 and `stories` is empty — that's correct.

- [ ] **Step 4: Commit**

```bash
git add cmd/catchup.go cmd/root.go
git commit -m "feat(catchup): add watchtower catchup CLI command"
```

---

## Task 8: Swift bulk `markRead(ids:)` queries

Mirror the Go bulk funcs. GRDB write idiom matches the existing single-ID `markRead`.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Database/Queries/TrackQueries.swift`
- Modify: `WatchtowerDesktop/Sources/Database/Queries/InboxQueries.swift`
- Modify: `WatchtowerDesktop/Sources/Database/Queries/DigestQueries.swift`
- Modify: `WatchtowerDesktop/Sources/Database/Queries/BriefingQueries.swift`

- [ ] **Step 1: Add `markRead(ids:)` to TrackQueries**

In `TrackQueries.swift`, add below the existing `markRead(_:id:)`:

```swift
    /// Marks multiple tracks read in one write, cascading to related digests per track.
    static func markRead(_ db: Database, ids: [Int]) throws {
        for id in ids {
            try markRead(db, id: id)
        }
    }
```

- [ ] **Step 2: Add `markRead(ids:)` to InboxQueries**

In `InboxQueries.swift`, below the existing `markRead(_:id:)`:

```swift
    /// Marks multiple inbox items read in one write. No-op on empty input.
    static func markRead(_ db: Database, ids: [Int]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.execute(
            sql: """
                UPDATE inbox_items SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id IN (\(placeholders)) AND (read_at IS NULL OR read_at = '')
                """,
            arguments: StatementArguments(ids)
        )
    }
```

- [ ] **Step 3: Add `markRead(ids:)` to DigestQueries**

In `DigestQueries.swift`, below the existing `markDigestRead`:

```swift
    /// Marks multiple digests read in one write. No-op on empty input.
    static func markRead(_ db: Database, ids: [Int]) throws {
        guard !ids.isEmpty else { return }
        let columns = try db.columns(in: "digests")
        guard columns.contains(where: { $0.name == "read_at" }) else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.execute(
            sql: """
                UPDATE digests SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id IN (\(placeholders)) AND read_at IS NULL
                """,
            arguments: StatementArguments(ids)
        )
    }
```

- [ ] **Step 4: Add `markRead(ids:)` to BriefingQueries**

In `BriefingQueries.swift`, below the existing `markRead(_:id:)`:

```swift
    /// Marks multiple briefings read in one write. No-op on empty input.
    static func markRead(_ db: Database, ids: [Int]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.execute(
            sql: """
                UPDATE briefings SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id IN (\(placeholders)) AND read_at IS NULL
                """,
            arguments: StatementArguments(ids)
        )
    }
```

- [ ] **Step 5: Verify it builds**

Run: `cd WatchtowerDesktop && swift build`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/Database/Queries/
git commit -m "feat(catchup): add bulk markRead(ids:) GRDB queries"
```

---

## Task 9: `CatchUpViewModel`

**Files:**
- Create: `WatchtowerDesktop/Sources/ViewModels/CatchUpViewModel.swift`
- Test: `WatchtowerDesktop/Tests/WatchtowerDesktopTests/CatchUpViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `WatchtowerDesktop/Tests/WatchtowerDesktopTests/CatchUpViewModelTests.swift`:

```swift
import XCTest
@testable import WatchtowerDesktop

@MainActor
final class CatchUpViewModelTests: XCTestCase {
    func testParsesResultJSON() throws {
        let json = """
        {"tldr":"Caught up.","truncated":true,
         "counts":{"digests":{"included":1,"total":3},"tracks":{"included":0,"total":0},
                   "inbox":{"included":0,"total":0},"briefings":{"included":0,"total":0},
                   "total_unread":3,"total_included":1},
         "stories":[{"title":"S","narrative":"N","priority":"high","needs_you":true,
                     "refs":[{"area":"digests","id":1,"label":"x"}]}],
         "sections":[{"area":"digests","total":3,"included":1,
                      "items":[{"id":1,"title":"t","snippet":"s"}]}]}
        """
        let result = try JSONDecoder().decode(CatchUpResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.tldr, "Caught up.")
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.stories.count, 1)
        XCTAssertEqual(result.stories[0].priority, "high")
        XCTAssertEqual(result.sections.first?.items.first?.id, 1)
        XCTAssertEqual(result.counts.totalUnread, 3)
    }

    func testSnapshotIDsPerArea() throws {
        let json = """
        {"tldr":"","truncated":false,
         "counts":{"digests":{"included":2,"total":2},"tracks":{"included":1,"total":1},
                   "inbox":{"included":0,"total":0},"briefings":{"included":0,"total":0},
                   "total_unread":3,"total_included":3},
         "stories":[],
         "sections":[{"area":"digests","total":2,"included":2,
                      "items":[{"id":7,"title":"a","snippet":""},{"id":8,"title":"b","snippet":""}]},
                     {"area":"tracks","total":1,"included":1,
                      "items":[{"id":42,"title":"c","snippet":""}]}]}
        """
        let result = try JSONDecoder().decode(CatchUpResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.ids(for: "digests"), [7, 8])
        XCTAssertEqual(result.ids(for: "tracks"), [42])
        XCTAssertEqual(result.ids(for: "inbox"), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter CatchUpViewModelTests`
Expected: FAIL — `CatchUpResult` undefined.

- [ ] **Step 3: Implement the ViewModel**

Create `WatchtowerDesktop/Sources/ViewModels/CatchUpViewModel.swift`:

```swift
import Foundation
import GRDB

// MARK: - Catch-Up Result (matches Go catchup.Result)

struct CatchUpRef: Codable, Identifiable, Equatable {
    var id: String { "\(area)-\(refID)" }
    let area: String
    let refID: Int
    let label: String

    enum CodingKeys: String, CodingKey {
        case area, label
        case refID = "id"
    }
}

struct CatchUpStory: Codable, Identifiable, Equatable {
    var id: String { title }
    let title: String
    let narrative: String
    let priority: String
    let needsYou: Bool
    let refs: [CatchUpRef]

    enum CodingKeys: String, CodingKey {
        case title, narrative, priority, refs
        case needsYou = "needs_you"
    }
}

struct CatchUpSectionItem: Codable, Identifiable, Equatable {
    let id: Int
    let title: String
    let snippet: String
}

struct CatchUpSection: Codable, Identifiable, Equatable {
    var id: String { area }
    let area: String
    let total: Int
    let included: Int
    let items: [CatchUpSectionItem]
}

struct CatchUpAreaCount: Codable, Equatable {
    let included: Int
    let total: Int
}

struct CatchUpCounts: Codable, Equatable {
    let digests: CatchUpAreaCount
    let tracks: CatchUpAreaCount
    let inbox: CatchUpAreaCount
    let briefings: CatchUpAreaCount
    let totalUnread: Int
    let totalIncluded: Int

    enum CodingKeys: String, CodingKey {
        case digests, tracks, inbox, briefings
        case totalUnread = "total_unread"
        case totalIncluded = "total_included"
    }
}

struct CatchUpResult: Codable, Equatable {
    let tldr: String
    let counts: CatchUpCounts
    let truncated: Bool
    let stories: [CatchUpStory]
    let sections: [CatchUpSection]

    /// The snapshot item IDs for one area — the authoritative set to clear.
    func ids(for area: String) -> [Int] {
        sections.first { $0.area == area }?.items.map(\.id) ?? []
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class CatchUpViewModel {
    var result: CatchUpResult?
    var isLoading = false
    var error: String?

    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// Runs `watchtower catchup --json` and parses the rollup.
    func generate() {
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }
        isLoading = true
        error = nil

        Task.detached {
            let cliResult = await Self.runCLI(path: cliPath, arguments: ["catchup", "--json"])
            await MainActor.run {
                self.isLoading = false
                if cliResult.exitCode == 0, !cliResult.stdout.isEmpty {
                    self.parse(cliResult.stdout)
                } else {
                    self.error = cliResult.stderr.isEmpty
                        ? "Catch-up failed (exit \(cliResult.exitCode))"
                        : String(cliResult.stderr.prefix(300))
                }
            }
        }
    }

    /// Marks one area's snapshot IDs read, then refreshes the in-memory result
    /// so that section drops out of the UI.
    func markSectionRead(_ area: String) async {
        guard let result else { return }
        let ids = result.ids(for: area)
        guard !ids.isEmpty else { return }
        try? await dbPool.write { db in
            switch area {
            case "digests": try DigestQueries.markRead(db, ids: ids)
            case "tracks": try TrackQueries.markRead(db, ids: ids)
            case "inbox": try InboxQueries.markRead(db, ids: ids)
            case "briefings": try BriefingQueries.markRead(db, ids: ids)
            default: break
            }
        }
        clearSectionLocally(area)
    }

    /// Marks every snapshot ID across all areas read.
    func markAllRead() async {
        guard let result else { return }
        let digestIDs = result.ids(for: "digests")
        let trackIDs = result.ids(for: "tracks")
        let inboxIDs = result.ids(for: "inbox")
        let briefingIDs = result.ids(for: "briefings")
        try? await dbPool.write { db in
            try DigestQueries.markRead(db, ids: digestIDs)
            try TrackQueries.markRead(db, ids: trackIDs)
            try InboxQueries.markRead(db, ids: inboxIDs)
            try BriefingQueries.markRead(db, ids: briefingIDs)
        }
        self.result = nil
    }

    private func clearSectionLocally(_ area: String) {
        guard let r = result else { return }
        let remaining = r.sections.filter { $0.area != area }
        result = CatchUpResult(
            tldr: r.tldr, counts: r.counts, truncated: r.truncated,
            stories: r.stories, sections: remaining
        )
    }

    private func parse(_ output: String) {
        guard let data = output.data(using: .utf8) else {
            error = "Invalid CLI output encoding"
            return
        }
        do {
            result = try JSONDecoder().decode(CatchUpResult.self, from: data)
        } catch {
            self.error = "Failed to parse catch-up: \(error.localizedDescription)"
        }
    }

    nonisolated private static func runCLI(
        path: String, arguments: [String]
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = Constants.resolvedEnvironment()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd WatchtowerDesktop && swift test --filter CatchUpViewModelTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels/CatchUpViewModel.swift WatchtowerDesktop/Tests/
git commit -m "feat(catchup): add CatchUpViewModel with subprocess and snapshot clearing"
```

---

## Task 10: `CatchUpView`

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/CatchUp/CatchUpView.swift`

- [ ] **Step 1: Implement the view**

Create `WatchtowerDesktop/Sources/Views/CatchUp/CatchUpView.swift`:

```swift
import SwiftUI

struct CatchUpView: View {
    @Bindable var vm: CatchUpViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if vm.isLoading {
                    ProgressView("Summarizing everything you missed…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else if let error = vm.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else if let result = vm.result {
                    content(result)
                } else {
                    emptyState
                }
            }
            .padding(20)
        }
        .navigationTitle("Catch Up")
        .onAppear { if vm.result == nil { vm.generate() } }
    }

    private var header: some View {
        HStack {
            Text("Catch Up").font(.largeTitle.bold())
            Spacer()
            Button {
                vm.generate()
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
            .disabled(vm.isLoading)
        }
    }

    @ViewBuilder
    private func content(_ result: CatchUpResult) -> some View {
        if result.counts.totalUnread == 0 {
            emptyState
        } else {
            if !result.tldr.isEmpty {
                Text(result.tldr)
                    .font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if !result.stories.isEmpty {
                Text("What you missed").font(.title2.bold())
                ForEach(result.stories) { story in
                    storyCard(story)
                }
            }

            Text("By source").font(.title2.bold()).padding(.top, 8)
            ForEach(result.sections.filter { !$0.items.isEmpty }) { section in
                sectionCard(section)
            }

            Button(role: .destructive) {
                Task { await vm.markAllRead() }
            } label: {
                Label("Mark everything read", systemImage: "checkmark.circle.fill")
            }
            .padding(.top, 8)
        }
    }

    private func storyCard(_ story: CatchUpStory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(priorityColor(story.priority)).frame(width: 8, height: 8)
                Text(story.title).font(.headline)
                if story.needsYou {
                    Text("needs you")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            Text(story.narrative).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func sectionCard(_ section: CatchUpSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(section.area.capitalized).font(.headline)
                if section.included < section.total {
                    Text("+\(section.total - section.included) not shown")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Mark read") {
                    Task { await vm.markSectionRead(section.area) }
                }
                .controlSize(.small)
            }
            ForEach(section.items) { item in
                Text("• \(item.title)").font(.subheadline)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(.green)
            Text("Всё разгребено").font(.title3)
            Text("Нет непрочитанного по дайджестам, трекам, инбоксу и брифингам.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func priorityColor(_ p: String) -> Color {
        switch p {
        case "high": return .red
        case "medium": return .orange
        default: return .secondary
        }
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `cd WatchtowerDesktop && swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/CatchUp/CatchUpView.swift
git commit -m "feat(catchup): add CatchUpView UI"
```

---

## Task 11: Sidebar + AppState + Navigation wiring

**Files:**
- Modify: `WatchtowerDesktop/Sources/App/SidebarDestination.swift`
- Modify: `WatchtowerDesktop/Sources/ViewModels/SidebarCountsViewModel.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Sidebar/SidebarView.swift`
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift`
- Modify: `WatchtowerDesktop/Sources/App/Navigation.swift`

- [ ] **Step 1: Add the `.catchUp` destination**

In `SidebarDestination.swift`:
- Add `case catchUp` right after `case chat`.
- In the `title` switch add: `case .catchUp: return "Catch Up"`.
- In the `icon` switch add: `case .catchUp: return "tray.and.arrow.down"`.
- In `mainItems` add `.catchUp` immediately after `.chat` (top of the list).

- [ ] **Step 2: Add `catchUpTotalCount` to SidebarCountsViewModel**

In `SidebarCountsViewModel.swift`, add a computed property after the stored count properties (after line 15):

```swift
    /// Total unread feeding the Catch-Up badge: digests + tracks + inbox + briefings.
    var catchUpTotalCount: Int {
        unreadDigestCount + updatedTrackCount + inboxPendingCount + unreadBriefingCount
    }
```

(No new query — it sums counts the view model already maintains.)

- [ ] **Step 3: Render the Catch-Up badge**

In `SidebarView.swift`, in the `badgeCount(for:)` switch, add:

```swift
        case .catchUp: return catchUpTotalCount
```

where `catchUpTotalCount` reads from the same `SidebarCountsViewModel` instance the other cases use (match how `unreadDigestCount` etc. are referenced in that function).

- [ ] **Step 4: Own the ViewModel in AppState**

In `AppState.swift`:
- Declare near the other view models (around line 35): `private(set) var catchUpViewModel: CatchUpViewModel?`
- Add an init helper:

```swift
    private func initCatchUp(dbPool: DatabasePool) {
        catchUpViewModel = CatchUpViewModel(dbPool: dbPool)
    }
```

- Call `initCatchUp(dbPool: manager.dbPool)` from `initialize()` alongside the other `init*` calls (match the exact dbPool accessor the neighboring inits use, e.g. `manager.dbPool`).

- [ ] **Step 5: Map the destination to the view**

In `Navigation.swift`, in the `detailView` switch, add after `case .chat`:

```swift
        case .catchUp:
            if let vm = appState.catchUpViewModel {
                CatchUpView(vm: vm)
            } else {
                Text("Catch Up unavailable")
            }
```

- [ ] **Step 6: Verify it builds and tests pass**

Run: `cd WatchtowerDesktop && swift build && swift test --filter CatchUpViewModelTests`
Expected: build succeeds, tests pass.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/App/ WatchtowerDesktop/Sources/Views/Sidebar/ WatchtowerDesktop/Sources/ViewModels/SidebarCountsViewModel.swift
git commit -m "feat(catchup): wire Catch-Up into sidebar, AppState, and navigation"
```

---

## Task 12: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Go — build, vet, test**

Run: `go build ./... && go vet ./... && go test ./internal/catchup/ ./internal/db/ ./internal/config/`
Expected: all succeed.

- [ ] **Step 2: Swift — build + full test suite**

Run: `cd WatchtowerDesktop && swift build && swift test`
Expected: build succeeds, all tests pass.

- [ ] **Step 3: End-to-end CLI smoke test**

Run: `go run . catchup --json | head -60`
Expected: valid JSON; if backlog non-empty, `stories` populated; `counts.total_unread` matches reality.

- [ ] **Step 4: Manual desktop check**

Run the desktop app, open the new **Catch Up** sidebar entry (top), confirm: badge shows total unread; rollup renders TL;DR + stories + per-source sections; "Mark read" on one section drops it and lowers the badge; "Mark everything read" clears all and the badge goes to 0; newly-arrived unread (simulate by inserting a row / running a sync) is NOT cleared by a prior rollup's mark-read.

---

## Self-review notes (for the implementer)

- **Spec coverage:** stories+sections (§1) → Tasks 4–6, 10; backend pipeline (§2) → Tasks 1–7; desktop (§3) → Tasks 8–11; edge cases (§4): snapshot-by-ID → Tasks 3/9 (mark by explicit ID list), zero-unread → Task 6 test 11, AI fallback → Task 6 test 12, truncation → Task 6 `Truncated`/`Counts` + Task 10 "+N not shown", idempotent marking → Task 3 test 02; tests (§5) → Tasks 2/3/6/9.
- **Unverified-name guardrails to resolve at implementation time (do not skip):** the `internal/db` test-DB helper name (Task 2/6), `GetTargetCounts`/`TargetCounts` field names (Task 6), global CLI flag names + provider-override pattern (Task 7), `badgeCount(for:)` exact shape and how it reaches the counts VM (Task 11 step 3), and the `detailView` switch location (Task 11 step 5). Each task flags its assumption inline; confirm against the real file before writing.
- **Behavior inventory:** this feature adds new code paths and new bulk funcs; it does not weaken any guard test in `docs/inventory/`. Marking-by-ID preserves the track→digest cascade (`MarkTracksRead` delegates to existing `MarkTrackRead`). If `swift test` surfaces an inventory guard for sidebar/destinations, read `docs/inventory/README.md` before adjusting.
```
