# Memory Jira Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mechanical Jira issue → episode source behind `memory.sources.jira` plus the `jira:` provenance scheme registered at three sites (builder, situation ingest, belief surface), closing the jira-signal provenance drop (spec: `docs/superpowers/specs/2026-07-22-memory-jira-source-design.md`).

**Architecture:** A calendar-source clone shaped for a permanent, mutable table: `jira_ingest.go` builds one deterministic episode per updated issue (alias `jiraissue:<KEY>`, update-in-place, content-equality no-op), watermarked on parsed `updated_at` with a no-backfill first run; `provenance.go` gains `jiraResolver`; `situationProvenance` mints `jira:` refs for jira-sourced signals.

**Tech Stack:** Go 1.25, SQLite via `modernc.org/sqlite` (`database/sql`), goose migrations, plain `go test`.

## Global Constraints

- Branch: `feature/memory-phase5` (current checkout; verify `git branch --show-current` before committing).
- **Migration number is 00030** — 00028/00029 were taken by the concurrent Slice B merge; this supersedes the spec's "00028" (Task 6 amends the spec text).
- `docs/inventory/memory.md` governs this area. Guard tests must pass UNMODIFIED except the one owner-approved extension: `jira_issues` joins the dump set of `TestMemory14_FullRunNeverWritesOperationalTables` (Task 4). If any other MEM-numbered guard fails, STOP and report BLOCKED.
- The builder makes NO AI call (guarded by the calendar source's noCallGen pattern).
- No-backfill: watermark 0 + rows present → watermark initializes to max parsed `updated_at`, builds nothing.
- `jira_issues` is migration-guaranteed: lookup/read errors PROPAGATE (freeze the step), never read as a clean miss.
- Jira `updated_at` layout: `2006-01-02T15:04:05.000-0700`, RFC3339 fallback; unparseable → skip the row.
- Description snippet cap: 1500 bytes, rune-boundary, code const.
- After schema.sql changes: regenerate the golden (`go test ./internal/db/ -run TestSchemaGolden -update`).
- Never pipe verification output through tail — `> /tmp/x.log 2>&1; echo exit=$?`.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Xo7jXEcJB3kQjpqR7Q4PvH
  ```

---

### Task 1: DB layer — migration 00030, watermark, existence + extract helpers

**Files:**
- Create: `internal/db/migrations/00030_memory_jira_watermark.sql`
- Modify: `internal/db/schema.sql` (workspace table — add the column next to `memory_calendar_last_extracted_ts`)
- Modify: `internal/db/memory.go` (helpers, place them after the calendar watermark/extract block ~line 1282+)
- Test: `internal/db/memory_test.go`

**Interfaces:**
- Consumes: existing `jira_issues` table (columns per `internal/db/schema.sql`), `workspace` singleton row.
- Produces (Tasks 2/3 rely on these exact signatures):
  - `func (db *DB) MemoryJiraWatermark() (float64, error)` / `func (db *DB) SetMemoryJiraWatermark(ts float64) error`
  - `func (db *DB) JiraIssueExists(key string) (bool, error)` — true iff a row with that key and `is_deleted = 0` exists; lookup errors propagate.
  - `type JiraExtractIssue struct { Key, ProjectKey, Summary, DescriptionText, IssueType, Status, StatusCategory, Priority, AssigneeDisplayName, AssigneeSlackID, ReporterDisplayName, ReporterSlackID, SprintName, EpicKey, DueDate string; StoryPoints sql.NullFloat64; UpdatedAtRaw string; UpdatedUnix int64; ResolvedAt string }`
  - `func (db *DB) ListJiraIssuesForExtract(sinceUnix int64, limit int) ([]JiraExtractIssue, error)` — non-deleted rows whose parsed `updated_at` > sinceUnix, sorted by UpdatedUnix ascending, capped at limit; unparseable `updated_at` rows silently skipped.
  - `func (db *DB) MaxJiraUpdatedUnix() (int64, error)` — max parsed `updated_at` among non-deleted rows, 0 when none parse/exist.
  - `func parseJiraTime(s string) (int64, bool)` (unexported, `internal/db/memory.go`).

- [ ] **Step 1: Write the migration**

`internal/db/migrations/00030_memory_jira_watermark.sql`:

```sql
-- +goose Up
-- Secretary memory Jira source (docs/superpowers/specs/2026-07-22-memory-jira-source-design.md):
-- the FIFTH extraction watermark — parsed jira_issues.updated_at (unix seconds)
-- the mechanical issue→episode builder has fully committed through. Distinct
-- from the Slack (memory_last_extracted_ts), Gmail
-- (memory_gmail_last_extracted_ts), calendar (memory_calendar_last_extracted_ts)
-- watermarks and the interaction floor. Additive, no CHECK change — the
-- 00023/00027 ALTER TABLE precedent.
ALTER TABLE workspace ADD COLUMN memory_jira_last_extracted_ts REAL NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE workspace DROP COLUMN memory_jira_last_extracted_ts;
```

Mirror the column into `internal/db/schema.sql`'s `workspace` table directly under `memory_calendar_last_extracted_ts` (same formatting): `memory_jira_last_extracted_ts REAL NOT NULL DEFAULT 0,` — keep comma placement valid.

- [ ] **Step 2: Write the failing tests**

Append to `internal/db/memory_test.go`:

```go
// TestMemoryJiraWatermark: the fifth extraction watermark round-trips on the
// workspace singleton and reads 0 on a fresh workspace.
func TestMemoryJiraWatermark(t *testing.T) {
	db := openTestDB(t)
	seedWorkspace(t, db)
	wm, err := db.MemoryJiraWatermark()
	if err != nil || wm != 0 {
		t.Fatalf("fresh watermark = %v, %v; want 0, nil", wm, err)
	}
	if err := db.SetMemoryJiraWatermark(1784500000); err != nil {
		t.Fatalf("set: %v", err)
	}
	wm, err = db.MemoryJiraWatermark()
	if err != nil || wm != 1784500000 {
		t.Fatalf("watermark = %v, %v; want 1784500000, nil", wm, err)
	}
}

// TestJiraIssueExists: key+is_deleted=0 resolves; a deleted issue 404s (the
// tombstoned-message reasoning); an absent key is a clean false.
func TestJiraIssueExists(t *testing.T) {
	db := openTestDB(t)
	seedJiraIssueRow(t, db, jiraIssueSeed{Key: "CEX-1", ProjectKey: "CEX", Summary: "s", Status: "To Do", StatusCategory: "todo", UpdatedAt: "2026-07-22T10:00:00.000+0000"})
	seedJiraIssueRow(t, db, jiraIssueSeed{Key: "CEX-2", ProjectKey: "CEX", Summary: "s", Status: "To Do", StatusCategory: "todo", UpdatedAt: "2026-07-22T10:00:00.000+0000", IsDeleted: true})

	if ok, err := db.JiraIssueExists("CEX-1"); err != nil || !ok {
		t.Errorf("CEX-1 = %v, %v; want true, nil", ok, err)
	}
	if ok, err := db.JiraIssueExists("CEX-2"); err != nil || ok {
		t.Errorf("deleted CEX-2 = %v, %v; want false, nil", ok, err)
	}
	if ok, err := db.JiraIssueExists("CEX-404"); err != nil || ok {
		t.Errorf("absent = %v, %v; want false, nil", ok, err)
	}
}

// TestListJiraIssuesForExtract: parsed-updated_at filtering and ordering, the
// is_deleted filter, the unparseable-updated_at skip, and the limit cap.
func TestListJiraIssuesForExtract(t *testing.T) {
	db := openTestDB(t)
	seedJiraIssueRow(t, db, jiraIssueSeed{Key: "CEX-1", ProjectKey: "CEX", Summary: "old", Status: "Done", StatusCategory: "done", UpdatedAt: "2026-07-20T10:00:00.000+0000"})
	seedJiraIssueRow(t, db, jiraIssueSeed{Key: "CEX-2", ProjectKey: "CEX", Summary: "new", Status: "To Do", StatusCategory: "todo", UpdatedAt: "2026-07-22T10:00:00.000+0000"})
	seedJiraIssueRow(t, db, jiraIssueSeed{Key: "CEX-3", ProjectKey: "CEX", Summary: "newer", Status: "To Do", StatusCategory: "todo", UpdatedAt: "2026-07-22T11:00:00.000+0000"})
	seedJiraIssueRow(t, db, jiraIssueSeed{Key: "CEX-4", ProjectKey: "CEX", Summary: "deleted", Status: "To Do", StatusCategory: "todo", UpdatedAt: "2026-07-22T12:00:00.000+0000", IsDeleted: true})
	seedJiraIssueRow(t, db, jiraIssueSeed{Key: "CEX-5", ProjectKey: "CEX", Summary: "badts", Status: "To Do", StatusCategory: "todo", UpdatedAt: "not-a-time"})

	since, ok := parseJiraTimeForTest("2026-07-21T00:00:00.000+0000")
	if !ok {
		t.Fatal("test time failed to parse")
	}
	issues, err := db.ListJiraIssuesForExtract(since, 10)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	var keys []string
	for _, is := range issues {
		keys = append(keys, is.Key)
	}
	if strings.Join(keys, ",") != "CEX-2,CEX-3" {
		t.Errorf("keys = %v, want [CEX-2 CEX-3] (old filtered, deleted filtered, unparseable skipped, ascending)", keys)
	}
	// Limit caps from the oldest pending side.
	issues, err = db.ListJiraIssuesForExtract(since, 1)
	if err != nil || len(issues) != 1 || issues[0].Key != "CEX-2" {
		t.Errorf("limited = %v, %v; want just CEX-2", issues, err)
	}
	// Max helper sees the newest parseable non-deleted row (CEX-3).
	maxU, err := db.MaxJiraUpdatedUnix()
	want, _ := parseJiraTimeForTest("2026-07-22T11:00:00.000+0000")
	if err != nil || maxU != want {
		t.Errorf("MaxJiraUpdatedUnix = %v, %v; want %v", maxU, err, want)
	}
}
```

Add the seed helper + test shim in the same file (near the other seed helpers):

```go
// jiraIssueSeed is the minimal jira_issues fixture for memory-source tests.
type jiraIssueSeed struct {
	Key, ProjectKey, Summary, DescriptionText     string
	IssueType, Status, StatusCategory, Priority   string
	AssigneeDisplayName, AssigneeSlackID          string
	ReporterDisplayName, ReporterSlackID          string
	SprintName, EpicKey, DueDate, ResolvedAt      string
	UpdatedAt                                     string
	IsDeleted                                     bool
}

func seedJiraIssueRow(t *testing.T, db *DB, s jiraIssueSeed) {
	t.Helper()
	deleted := 0
	if s.IsDeleted {
		deleted = 1
	}
	_, err := db.Exec(`INSERT INTO jira_issues
		(key, project_key, summary, description_text, issue_type, status, status_category,
		 priority, assignee_display_name, assignee_slack_id, reporter_display_name, reporter_slack_id,
		 sprint_name, epic_key, due_date, resolved_at, created_at, updated_at, synced_at, is_deleted)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		s.Key, s.ProjectKey, s.Summary, s.DescriptionText, s.IssueType, s.Status, s.StatusCategory,
		s.Priority, s.AssigneeDisplayName, s.AssigneeSlackID, s.ReporterDisplayName, s.ReporterSlackID,
		s.SprintName, s.EpicKey, s.DueDate, s.ResolvedAt, "2026-07-01T00:00:00.000+0000", s.UpdatedAt,
		"2026-07-22T00:00:00Z", deleted)
	if err != nil {
		t.Fatalf("seed jira issue %s: %v", s.Key, err)
	}
}

// parseJiraTimeForTest exposes the production parser to tests in this package.
func parseJiraTimeForTest(s string) (int64, bool) { return parseJiraTime(s) }
```

NOTE: `seedWorkspace`/`openTestDB` — use the names this test file ALREADY uses for the workspace/db fixtures (grep for how `TestMemoryCalendarWatermark`-era tests seed; reuse those exact helpers instead of inventing new ones; if the existing helper is named differently, e.g. `newTestDB`/`seedWorkspaceRow`, use that everywhere above).

- [ ] **Step 3: Run tests to verify they fail**

Run: `go test ./internal/db/ -run 'TestMemoryJiraWatermark|TestJiraIssueExists|TestListJiraIssuesForExtract' -v`
Expected: compile FAIL — `undefined: MemoryJiraWatermark` etc. (a compile failure is the expected red).

- [ ] **Step 4: Implement**

Append to `internal/db/memory.go` (after `SetMemoryCalendarWatermark` and the calendar extract block):

```go
// MemoryJiraWatermark reads the Jira episode-extraction watermark — the FIFTH
// extraction watermark (see 00030), unix seconds of the newest fully-committed
// parsed jira_issues.updated_at. A fresh workspace reads 0.
func (db *DB) MemoryJiraWatermark() (float64, error) {
	var ts float64
	err := db.QueryRow(`SELECT COALESCE(memory_jira_last_extracted_ts, 0) FROM workspace LIMIT 1`).Scan(&ts)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("getting memory jira watermark: %w", err)
	}
	return ts, nil
}

// SetMemoryJiraWatermark advances the Jira extraction watermark. Callers only
// move it behind fully-committed issue episodes (MEM-04, adapted).
func (db *DB) SetMemoryJiraWatermark(ts float64) error {
	if _, err := db.Exec(`UPDATE workspace SET memory_jira_last_extracted_ts = ?`, ts); err != nil {
		return fmt.Errorf("setting memory jira watermark: %w", err)
	}
	return nil
}

// JiraIssueExists is the jira: scheme's write-time existence check (MEM-12): a
// jira:<KEY> ref resolves iff a non-deleted jira_issues row carries that key —
// a deleted issue 404s for the owner exactly like a tombstoned Slack message.
// jira_issues is migration-guaranteed, so a lookup failure is a genuine error
// (step freeze), never a clean miss (the CalendarEventExists precedent).
func (db *DB) JiraIssueExists(key string) (bool, error) {
	var one int
	err := db.QueryRow(`SELECT 1 FROM jira_issues WHERE key = ? AND is_deleted = 0`, key).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("checking jira issue %s: %w", key, err)
	}
	return true, nil
}

// jiraUpdatedLayout is Jira Cloud's updated_at format ("+0100" offset — no
// colon, so SQLite's strftime cannot parse it; all time math happens in Go).
const jiraUpdatedLayout = "2006-01-02T15:04:05.000-0700"

// parseJiraTime parses a jira_issues timestamp, RFC3339 fallback. ok=false for
// an unparseable value — the caller skips the row (the Gmail internal_date
// defensive-skip precedent; the sync guarantees the format).
func parseJiraTime(s string) (int64, bool) {
	if t, err := time.Parse(jiraUpdatedLayout, s); err == nil {
		return t.Unix(), true
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.Unix(), true
	}
	return 0, false
}

// JiraExtractIssue is one jira_issues row projected for the mechanical
// issue→episode builder (memory.sources.jira).
type JiraExtractIssue struct {
	Key, ProjectKey, Summary, DescriptionText   string
	IssueType, Status, StatusCategory, Priority string
	AssigneeDisplayName, AssigneeSlackID        string
	ReporterDisplayName, ReporterSlackID        string
	SprintName, EpicKey, DueDate                string
	StoryPoints                                 sql.NullFloat64
	UpdatedAtRaw                                string
	UpdatedUnix                                 int64
	ResolvedAt                                  string
}

// ListJiraIssuesForExtract returns non-deleted issues whose PARSED updated_at
// is strictly above sinceUnix, ascending by UpdatedUnix, capped at limit.
// updated_at carries a "+0100"-style offset SQLite cannot compare reliably, so
// rows are filtered/sorted in Go after parseJiraTime (an unparseable value
// skips the row). The table is small (low thousands), a full scan per run is
// fine.
func (db *DB) ListJiraIssuesForExtract(sinceUnix int64, limit int) ([]JiraExtractIssue, error) {
	rows, err := db.Query(`SELECT key, project_key, summary, description_text, issue_type,
		status, status_category, priority, assignee_display_name, assignee_slack_id,
		reporter_display_name, reporter_slack_id, sprint_name, epic_key, due_date,
		story_points, updated_at, resolved_at
		FROM jira_issues WHERE is_deleted = 0`)
	if err != nil {
		return nil, fmt.Errorf("listing jira issues for extract: %w", err)
	}
	defer rows.Close()

	var out []JiraExtractIssue
	for rows.Next() {
		var is JiraExtractIssue
		if err := rows.Scan(&is.Key, &is.ProjectKey, &is.Summary, &is.DescriptionText, &is.IssueType,
			&is.Status, &is.StatusCategory, &is.Priority, &is.AssigneeDisplayName, &is.AssigneeSlackID,
			&is.ReporterDisplayName, &is.ReporterSlackID, &is.SprintName, &is.EpicKey, &is.DueDate,
			&is.StoryPoints, &is.UpdatedAtRaw, &is.ResolvedAt); err != nil {
			return nil, fmt.Errorf("scanning jira issue for extract: %w", err)
		}
		u, ok := parseJiraTime(is.UpdatedAtRaw)
		if !ok || u <= sinceUnix {
			continue
		}
		is.UpdatedUnix = u
		out = append(out, is)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("jira extract rows: %w", err)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UpdatedUnix < out[j].UpdatedUnix })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// MaxJiraUpdatedUnix is the no-backfill initializer's bound: the newest parsed
// updated_at among non-deleted issues, 0 when none exist or parse.
func (db *DB) MaxJiraUpdatedUnix() (int64, error) {
	rows, err := db.Query(`SELECT updated_at FROM jira_issues WHERE is_deleted = 0`)
	if err != nil {
		return 0, fmt.Errorf("scanning jira updated_at for max: %w", err)
	}
	defer rows.Close()
	var maxU int64
	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			return 0, fmt.Errorf("scanning jira updated_at: %w", err)
		}
		if u, ok := parseJiraTime(raw); ok && u > maxU {
			maxU = u
		}
	}
	return maxU, rows.Err()
}
```

Check imports: `internal/db/memory.go` must import `sort` and `time` (add if missing; `database/sql`, `errors`, `fmt` are already there).

- [ ] **Step 5: Run tests to verify they pass, regenerate golden, package green**

```bash
go test ./internal/db/ -run 'TestMemoryJiraWatermark|TestJiraIssueExists|TestListJiraIssuesForExtract' -v
go test ./internal/db/ -run TestSchemaGolden -update > /tmp/golden.log 2>&1; echo exit=$?
go test ./internal/db/ > /tmp/db30.log 2>&1; echo exit=$?
```
All PASS / exit=0. The golden regen commits the snapshot change together with this task.

- [ ] **Step 6: Commit**

```bash
git add internal/db/migrations/00030_memory_jira_watermark.sql internal/db/schema.sql internal/db/memory.go internal/db/memory_test.go internal/db/testdata
git commit -m "feat(db): jira source substrate — 00030 watermark, JiraIssueExists, extract helpers

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xo7jXEcJB3kQjpqR7Q4PvH"
```
(If `git status` shows the golden snapshot somewhere other than `internal/db/testdata`, add that actual path.)

---

### Task 2: `jiraResolver` — the jira: scheme in the MEM-12 registry

**Files:**
- Modify: `internal/memory/provenance.go` (new resolver after `calResolver`, ~line 230)
- Modify: `internal/memory/pipeline.go:161-165` (register in `p.registry`)
- Test: `internal/memory/provenance_test.go`

**Interfaces:**
- Consumes: Task 1's `db.JiraIssueExists(key string) (bool, error)`.
- Produces (Tasks 3/5 rely on):
  - `const jiraRefPrefix = "jira:"`
  - `type jiraChecker interface { JiraIssueExists(key string) (bool, error) }`
  - `type jiraResolver struct{ db jiraChecker }` with `Scheme() string` → `"jira"` and `Validate(ref episodeRef) (bool, error)`.

- [ ] **Step 1: Write the failing tests**

Append to `internal/memory/provenance_test.go` (model on the existing `TestProvenanceRegistryDispatchesCal` family — reuse its fake-checker style; read that test first and mirror its structure exactly):

```go
// TestProvenanceRegistryDispatchesJira: a jira:<KEY> ref resolves through
// jiraResolver by issue key; a missing/deleted key is a clean non-resolution.
func TestProvenanceRegistryDispatchesJira(t *testing.T) {
	reg := newProvenanceRegistry(jiraResolver{db: fakeJiraChecker{exists: map[string]bool{"CEX-7413": true}}})
	ok, registered, err := reg.Validate(episodeRef{ChannelID: "jira:CEX-7413", TS: "2026-07-22T10:00:00.000+0000"})
	if err != nil || !registered || !ok {
		t.Errorf("existing issue = ok %v registered %v err %v; want true,true,nil", ok, registered, err)
	}
	ok, registered, err = reg.Validate(episodeRef{ChannelID: "jira:CEX-404", TS: "x"})
	if err != nil || !registered || ok {
		t.Errorf("missing issue = ok %v registered %v err %v; want false,true,nil", ok, registered, err)
	}
}

// TestJiraResolverPropagatesLookupError: a jira_issues lookup error propagates
// (registered=true) — the table is migration-guaranteed, never a clean miss.
func TestJiraResolverPropagatesLookupError(t *testing.T) {
	reg := newProvenanceRegistry(jiraResolver{db: fakeJiraChecker{err: errors.New("db down")}})
	_, registered, err := reg.Validate(episodeRef{ChannelID: "jira:CEX-1", TS: "x"})
	if err == nil || !registered {
		t.Errorf("lookup error: registered %v err %v; want true, non-nil", registered, err)
	}
}

// TestJiraRegisteredInPipelineRegistry: the belief surface's registry carries
// the jira scheme so a belief op may cite a jira: episode ref.
func TestJiraRegisteredInPipelineRegistry(t *testing.T) {
	d, v := newTestDB(t), newTestVault(t)
	p := NewPipeline(d, v, nil, pipelineTestConfig(), t.Logf)
	if _, registered, _ := p.registry.Validate(episodeRef{ChannelID: "jira:CEX-1", TS: "x"}); !registered {
		t.Error("jira scheme not registered in the pipeline registry")
	}
}

type fakeJiraChecker struct {
	exists map[string]bool
	err    error
}

func (f fakeJiraChecker) JiraIssueExists(key string) (bool, error) {
	if f.err != nil {
		return false, f.err
	}
	return f.exists[key], nil
}
```

Also extend the existing `TestSchemeOf` with the jira case: input `"jira:CEX-7413"` → scheme `"jira"` (add one case-line to its table, matching the `cal:evt_1` case's shape).

NOTE: `newTestDB`/`newTestVault`/`pipelineTestConfig` — use the constructor names this package's tests actually use (they exist in `digest_compare_test.go`); if `NewPipeline` with a nil generator panics in this fixture, mirror how `TestCalRegisteredInPipelineRegistry` constructs the pipeline instead.

- [ ] **Step 2: Run to verify red**

Run: `go test ./internal/memory/ -run 'TestProvenanceRegistryDispatchesJira|TestJiraResolverPropagatesLookupError|TestJiraRegisteredInPipelineRegistry|TestSchemeOf' -v`
Expected: compile FAIL (`undefined: jiraResolver`).

- [ ] **Step 3: Implement the resolver + registration**

In `internal/memory/provenance.go`, after the `calResolver` block:

```go
// jiraChecker is the write-time jira-ref lookup seam. *db.DB satisfies it;
// tests inject an erroring fake to exercise the freeze path.
type jiraChecker interface {
	JiraIssueExists(key string) (bool, error)
}

// jiraResolver is the scheme-"jira" resolver: a jira:<KEY> ref resolves iff a
// non-deleted jira_issues row carries that key (identity is the issue key; the
// ref's ts carries updated_at for age math but is not re-validated — the
// calResolver shape). jira_issues is a migration-guaranteed base table, so a
// lookup failure is a genuine error (step freeze), not a clean miss.
type jiraResolver struct{ db jiraChecker }

// jiraRefPrefix marks an evidence/episode channel_id as a Jira issue
// reference ("jira:<KEY>").
const jiraRefPrefix = "jira:"

func (jiraResolver) Scheme() string { return strings.TrimSuffix(jiraRefPrefix, ":") }

func (j jiraResolver) Validate(ref episodeRef) (bool, error) {
	return j.db.JiraIssueExists(strings.TrimPrefix(ref.ChannelID, jiraRefPrefix))
}
```

In `internal/memory/pipeline.go` add `jiraResolver{database},` to the `p.registry = newProvenanceRegistry(...)` list (after `calResolver{database},`), and extend that block's doc comment sentence listing base-table resolvers to mention jira (same reasoning as cal/act: base table, registered even while the source is dark).

If `schemeOf` uses an explicit scheme whitelist rather than generic first-colon classification, add `"jira"` there; if it is generic, only the test case is needed — check the function before editing.

- [ ] **Step 4: Run to verify green**

Run: `go test ./internal/memory/ -run 'TestProvenanceRegistryDispatchesJira|TestJiraResolverPropagatesLookupError|TestJiraRegisteredInPipelineRegistry|TestSchemeOf' -v` → PASS.
Then: `go test ./internal/memory/ > /tmp/mem-t2.log 2>&1; echo exit=$?` → exit=0.

- [ ] **Step 5: Commit**

```bash
git add internal/memory/provenance.go internal/memory/provenance_test.go internal/memory/pipeline.go
git commit -m "feat(memory): jira: provenance scheme — resolver + pipeline-registry registration (MEM-12)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xo7jXEcJB3kQjpqR7Q4PvH"
```

---

### Task 3: The mechanical builder — `jira_ingest.go`

**Files:**
- Create: `internal/memory/jira_ingest.go`
- Modify: `internal/memory/calendar_ingest.go` (rename `commitCalendarNodes` → `commitSourceNodes` with an `op string` parameter; neutralize `linkEntity`'s error prefix)
- Test: `internal/memory/jira_ingest_test.go`

**Interfaces:**
- Consumes: Task 1 helpers (`MemoryJiraWatermark`, `SetMemoryJiraWatermark`, `ListJiraIssuesForExtract`, `MaxJiraUpdatedUnix`, `JiraExtractIssue`), Task 2's `jiraResolver`/`jiraRefPrefix`, existing `linkEntity`, `Resolve`, `upsertIndexNode`, `recordSemanticStep`, `stepStatus`, `orDefault`, `oneLine`, `firstNonEmpty`, `ensureAlias`, `NewID`.
- Produces (Task 4 relies on):
  - `func (p *Pipeline) runJiraIngest(runID int64, stepOffset int, stats *RunStats) (int, error)` — same contract as `runCalendarIngest` (returns step rows recorded, 0 or 1).
  - `const jiraIssueAliasPrefix = "jiraissue:"`.
  - `commitSourceNodes(runID int64, op string, byID map[string]*Node, order []string, dirty map[string]bool) error` (method on `*Pipeline`; the renamed calendar commit helper).

- [ ] **Step 1: The shared-helper rename (mechanical, no behavior change)**

In `internal/memory/calendar_ingest.go`:
1. Rename `func (p *Pipeline) commitCalendarNodes(runID int64, byID map[string]*Node, order []string, dirty map[string]bool) error` to `func (p *Pipeline) commitSourceNodes(runID int64, op string, byID map[string]*Node, order []string, dirty map[string]bool) error`; inside, replace the hardcoded `Op: "calendar"` with `Op: op` and `Summary: fmt.Sprintf("%d calendar episode(s)", len(ids))` with `Summary: fmt.Sprintf("%d %s episode(s)", len(ids), op)`; update the doc comment ("writes the dirty nodes of one mechanical source as one vault commit…").
2. Update its caller in `buildCalendarEpisodes`: `p.commitSourceNodes(runID, "calendar", byID, order, dirty)`.
3. In `linkEntity`, change the resolve-error message from `"memory: calendar ingest: resolve %s: %w"` to `"memory: source ingest: resolve %s: %w"` and adjust its doc comment to say it serves the mechanical sources (calendar + jira).

Run: `go test ./internal/memory/ -run 'TestRunCalendarIngest|TestCalendar' -v` → all existing calendar tests PASS unmodified (the rename is invisible to them; if any test calls `commitCalendarNodes` directly, update only the call site name, never assertions).

- [ ] **Step 2: Write the failing builder tests**

Create `internal/memory/jira_ingest_test.go`. Model fixtures on `calendar_ingest_test.go` (read it first; reuse its vault/db constructors and its noCallGen). Seed jira rows via raw `d.Exec` INSERT matching Task 1's `seedJiraIssueRow` column list (that helper lives in package `db`'s tests and is NOT importable — inline a local copy named `seedJiraIssue` here):

```go
package memory

import (
	"fmt"
	"strings"
	"testing"

	"watchtower/internal/db"
)

// seedJiraIssue inserts one jira_issues row for builder tests (the db-package
// seed helper is not importable across test packages).
func seedJiraIssue(t *testing.T, d *db.DB, key, project, summary, desc, status, statusCat, resolvedAt, updatedAt, assigneeSlackID string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO jira_issues
		(key, project_key, summary, description_text, issue_type, status, status_category,
		 priority, assignee_display_name, assignee_slack_id, reporter_display_name, reporter_slack_id,
		 sprint_name, epic_key, due_date, resolved_at, created_at, updated_at, synced_at, is_deleted)
		VALUES (?,?,?,?, 'Task', ?, ?, 'Medium', 'Alice A', ?, 'Bob B', '', 'Sprint 9', '', '', ?, '2026-07-01T00:00:00.000+0000', ?, '2026-07-22T00:00:00Z', 0)`,
		key, project, summary, desc, status, statusCat, assigneeSlackID, resolvedAt, updatedAt)
	if err != nil {
		t.Fatalf("seed jira issue %s: %v", key, err)
	}
}

// TestRunJiraIngestNoBackfillInit: watermark 0 + rows present → the watermark
// initializes to the max parsed updated_at and NOTHING is built (owner scope-B
// decision: the pre-enablement backlog never backfills). No AI call ever.
func TestRunJiraIngestNoBackfillInit(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	seedJiraIssue(t, d, "CEX-1", "CEX", "old backlog", "", "To Do", "todo", "", "2026-07-20T10:00:00.000+0000", "")
	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)

	var stats RunStats
	steps, err := p.runJiraIngest(1, 0, &stats)
	if err != nil {
		t.Fatalf("runJiraIngest: %v", err)
	}
	if steps != 1 {
		t.Errorf("steps = %d, want 1 (the init records a step row)", steps)
	}
	if stats.JiraEpisodes != 0 {
		t.Errorf("JiraEpisodes = %d, want 0 (no backfill)", stats.JiraEpisodes)
	}
	wm, _ := d.MemoryJiraWatermark()
	if wm == 0 {
		t.Error("watermark not initialized")
	}
	// Second run: nothing above the watermark → zero steps, zero episodes.
	steps, err = p.runJiraIngest(2, 0, &stats)
	if err != nil || steps != 0 || stats.JiraEpisodes != 0 {
		t.Errorf("steady state = steps %d, episodes %d, err %v; want 0,0,nil", steps, stats.JiraEpisodes, err)
	}
}

// TestRunJiraIngestBuildsEpisode: an issue updated above the watermark becomes
// one episode with deterministic Story/Outcome/Provenance, aliased
// jiraissue:<KEY>, linked to its project entity and assignee person entity;
// a done+resolved issue is born closed/long.
func TestRunJiraIngestBuildsEpisode(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	seedUserRow(t, d, "U1ALICE", "alice")
	if err := d.SetMemoryJiraWatermark(1); err != nil {
		t.Fatal(err)
	}
	seedJiraIssue(t, d, "CEX-7413", "CEX", "Fix the webhook", "Decision-request handling is broken on prod.",
		"Done", "done", "2026-07-22T09:00:00.000+0000", "2026-07-22T10:00:00.000+0000", "U1ALICE")
	// The project entity the episode must back-link (seedJiraProjects aliases
	// a project entity by its bare key).
	writeEntity(t, v, d, "ent_00000000000000000000000cex", "CEX", []string{"CEX"})
	writeEntity(t, v, d, "ent_0000000000000000000000alice", "Alice A", []string{"U1ALICE"})
	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)

	var stats RunStats
	if _, err := p.runJiraIngest(1, 0, &stats); err != nil {
		t.Fatalf("runJiraIngest: %v", err)
	}
	if stats.JiraEpisodes != 1 {
		t.Fatalf("JiraEpisodes = %d, want 1", stats.JiraEpisodes)
	}
	id, err := d.LookupMemoryAlias("jiraissue:CEX-7413")
	if err != nil {
		t.Fatalf("alias lookup: %v", err)
	}
	n, err := v.ReadNode(id)
	if err != nil {
		t.Fatalf("read node: %v", err)
	}
	if n.Status != "closed" || n.Tier != "long" {
		t.Errorf("done issue: status/tier = %s/%s, want closed/long", n.Status, n.Tier)
	}
	for _, want := range []string{
		"# CEX-7413: Fix the webhook",
		"Type: Task.", "Status: Done (done).", "Priority: Medium.",
		"Assignee: Alice A.", "Reporter: Bob B.", "Sprint: Sprint 9.",
		"Decision-request handling is broken on prod.",
		"Resolved (Done) at 2026-07-22T09:00:00.000+0000",
		"- jira:CEX-7413 2026-07-22T10:00:00.000+0000",
	} {
		if !strings.Contains(n.Body, want) {
			t.Errorf("body missing %q\nbody:\n%s", want, n.Body)
		}
	}
	// Back-links landed on both entities.
	for _, entID := range []string{"ent_00000000000000000000000cex", "ent_0000000000000000000000alice"} {
		en, rerr := v.ReadNode(entID)
		if rerr != nil {
			t.Fatalf("read entity: %v", rerr)
		}
		if !strings.Contains(en.Body, "[["+id+"|") {
			t.Errorf("entity %s missing back-link to %s", entID, id)
		}
	}
	// Watermark advanced to the issue's parsed updated_at.
	wm, _ := d.MemoryJiraWatermark()
	if wm == 1 {
		t.Error("watermark did not advance")
	}
}

// TestRunJiraIngestIdempotentUpdate: re-running with no change commits nothing
// (content-equality no-op); a real update refreshes the SAME node in place.
func TestRunJiraIngestIdempotentUpdate(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	if err := d.SetMemoryJiraWatermark(1); err != nil {
		t.Fatal(err)
	}
	seedJiraIssue(t, d, "CEX-1", "CEX", "First", "", "To Do", "todo", "", "2026-07-22T10:00:00.000+0000", "")
	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)

	var stats RunStats
	if _, err := p.runJiraIngest(1, 0, &stats); err != nil {
		t.Fatal(err)
	}
	firstID, _ := d.LookupMemoryAlias("jiraissue:CEX-1")

	// Same content re-scan: reset the watermark so the row re-lists — commit
	// must be a no-op (JiraEpisodes unchanged).
	if err := d.SetMemoryJiraWatermark(1); err != nil {
		t.Fatal(err)
	}
	before := stats.JiraEpisodes
	if _, err := p.runJiraIngest(2, 0, &stats); err != nil {
		t.Fatal(err)
	}
	if stats.JiraEpisodes != before {
		t.Errorf("unchanged re-scan built %d new episode(s)", stats.JiraEpisodes-before)
	}

	// A real update (status flip) refreshes the same node.
	if _, err := d.Exec(`UPDATE jira_issues SET status='In Progress', status_category='in_progress', updated_at='2026-07-22T12:00:00.000+0000' WHERE key='CEX-1'`); err != nil {
		t.Fatal(err)
	}
	if _, err := p.runJiraIngest(3, 0, &stats); err != nil {
		t.Fatal(err)
	}
	secondID, _ := d.LookupMemoryAlias("jiraissue:CEX-1")
	if secondID != firstID {
		t.Errorf("update minted a new node %s (want in-place update of %s)", secondID, firstID)
	}
	n, _ := v.ReadNode(firstID)
	if !strings.Contains(n.Body, "Status: In Progress (in_progress).") {
		t.Errorf("body not refreshed:\n%s", n.Body)
	}
}

// TestRunJiraIngestWatermarkFreezeOnError: a commit-path failure freezes the
// watermark so every pending issue re-scans next run (MEM-04, adapted).
func TestRunJiraIngestWatermarkFreezeOnError(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	if err := d.SetMemoryJiraWatermark(1); err != nil {
		t.Fatal(err)
	}
	seedJiraIssue(t, d, "CEX-1", "CEX", "s", "", "To Do", "todo", "", "2026-07-22T10:00:00.000+0000", "")
	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)
	breakVaultWrites(t, v) // reuse calendar_ingest_test.go's freeze fixture; if it is named differently there, use that name

	var stats RunStats
	_, _ = p.runJiraIngest(1, 0, &stats)
	if stats.JiraIssuesFailed == 0 {
		t.Error("failed counter not bumped")
	}
	wm, _ := d.MemoryJiraWatermark()
	if wm != 1 {
		t.Errorf("watermark moved to %v on a failed commit (must freeze at 1)", wm)
	}
}
```

NOTE on fixtures: `newTestVault`/`newTestDB`/`seedWorkspaceRow`/`seedUserRow`/`noCallGen`/`pipelineTestConfig` and an entity-writing helper (`writeEntity`) all exist in this package's test files (calendar/compare/mirror tests) — read `calendar_ingest_test.go` FIRST and reuse its exact helper names; the freeze fixture (`breakVaultWrites`) must be whatever mechanism the calendar watermark-freeze test uses (e.g. making the vault dir read-only or an erroring vault seam). Mirror it exactly; if calendar has no such test fixture, trigger the freeze via a lookup error instead (drop the `memory_nodes` table copy trick used elsewhere in the package's tests). Adapt mechanically, never weaken the assertions.

- [ ] **Step 3: Run to verify red**

Run: `go test ./internal/memory/ -run TestRunJiraIngest -v`
Expected: compile FAIL (`undefined: (*Pipeline).runJiraIngest`, `RunStats` has no `JiraEpisodes`). Add the two `RunStats` fields now (they belong to this task so the tests compile; Task 4 only wires `Run`):

In `internal/memory/pipeline.go`, next to the calendar counters:

```go
	JiraEpisodes     int // episode nodes built/refreshed by the mechanical jira issue builder
	JiraIssuesFailed int // jira issues dropped (unresolved ref) or frozen (step error)
```

- [ ] **Step 4: Implement `internal/memory/jira_ingest.go`**

```go
package memory

// This file is the mechanical Jira issue → episode builder (behind
// memory.sources.jira, owner scope-B: all issues, watermark-bounded). Like the
// calendar source it makes NO AI call: one updated jira_issues row becomes at
// most one episode built straight from the structured row. It runs as
// mechanical Run step 3d, after operational mirrors (3c) and before Slack
// extraction.
//
// Idempotency is alias-keyed (jiraissue:<KEY>, the calevent:/gmailthread:
// precedent): an issue update re-lists the row (updated_at > watermark) and
// UPDATEs the episode in place; a content-equality check keeps an unchanged
// re-scan a no-op. Its own watermark: memory_jira_last_extracted_ts (the FIFTH
// extraction watermark, parsed updated_at unix). No bounded lookback (unlike
// calendar): jira_issues rows are permanent and every change lifts updated_at
// above the watermark by itself. No backfill: the first gated run initializes
// the watermark to the newest synced updated_at and builds nothing.

import (
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// jiraIssueAliasPrefix marks an episode's stable per-issue identity alias
// ("jiraissue:<KEY>") — the idempotency key.
const jiraIssueAliasPrefix = "jiraissue:"

func jiraIssueAlias(key string) string { return jiraIssueAliasPrefix + key }

// jiraDescriptionCapBytes bounds the description snippet folded into the Story
// (Jira descriptions can be pages long; the episode is a gist, not a mirror).
const jiraDescriptionCapBytes = 1500

// runJiraIngest is Run step 3d (behind memory.sources.jira): the mechanical,
// no-AI fold of updated Jira issues into episode nodes. First gated run with
// rows present initializes the watermark to the newest parsed updated_at and
// builds nothing (no backfill, owner decision). Subsequent runs load issues
// above the watermark, build episodes in one vault commit, and advance the
// watermark only after the commit succeeded (MEM-04-adapted; frozen on any
// build/commit/lookup error). Returns the number of step rows recorded.
func (p *Pipeline) runJiraIngest(runID int64, stepOffset int, stats *RunStats) (int, error) {
	wm, err := p.db.MemoryJiraWatermark()
	if err != nil {
		stats.JiraIssuesFailed++
		step := stepOffset + 1
		p.recordSemanticStep(runID, &step, "jira-ingest", "error", nil, time.Now())
		return 1, err
	}

	if wm == 0 {
		maxU, merr := p.db.MaxJiraUpdatedUnix()
		if merr != nil {
			stats.JiraIssuesFailed++
			step := stepOffset + 1
			p.recordSemanticStep(runID, &step, "jira-ingest", "error", nil, time.Now())
			return 1, merr
		}
		if maxU == 0 {
			return 0, nil // no synced issues yet — retry initialization next run
		}
		if serr := p.db.SetMemoryJiraWatermark(float64(maxU)); serr != nil {
			stats.JiraIssuesFailed++
			step := stepOffset + 1
			p.recordSemanticStep(runID, &step, "jira-ingest", "error", nil, time.Now())
			return 1, serr
		}
		p.logf("memory: jira source initialized at %d, no backfill", maxU)
		step := stepOffset + 1
		p.recordSemanticStep(runID, &step, "jira-ingest", "done", nil, time.Now())
		return 1, nil
	}

	issues, err := p.db.ListJiraIssuesForExtract(int64(wm), orDefault(p.cfg.MaxChunkMessages, 2000))
	if err != nil {
		stats.JiraIssuesFailed++
		step := stepOffset + 1
		p.recordSemanticStep(runID, &step, "jira-ingest", "error", nil, time.Now())
		return 1, err
	}
	if len(issues) == 0 {
		return 0, nil
	}

	// jira: is the only scheme a Jira episode can carry (MEM-12 scheme scoping).
	jiraReg := newProvenanceRegistry(jiraResolver{p.db})

	start := time.Now()
	built, failed, maxUpdated, berr := p.buildJiraEpisodes(runID, jiraReg, issues)
	if berr != nil {
		// A commit/lookup failure freezes the whole step: the watermark stays
		// and every pending issue re-scans next run (MEM-04-adapted).
		stats.JiraIssuesFailed += len(issues)
		p.logf("memory: jira ingest: %v", berr)
	} else {
		stats.JiraEpisodes += built
		stats.JiraIssuesFailed += failed
		if float64(maxUpdated) > wm {
			if serr := p.db.SetMemoryJiraWatermark(float64(maxUpdated)); serr != nil {
				p.logf("memory: jira ingest: set watermark: %v", serr)
			}
		}
	}
	step := stepOffset + 1
	p.recordSemanticStep(runID, &step, "jira-ingest", stepStatus(berr), nil, start)
	return 1, nil
}

// buildJiraEpisodes turns updated issues into episode nodes (plus entity
// back-links) committed as ONE vault commit, keyed by their jiraissue:<KEY>
// alias. Returns built (created-or-refreshed), failed (dropped for an
// unresolved jira: ref — the row was deleted between load and validate,
// MEM-01 drop-and-count), the newest processed updated_at unix (the watermark
// bound), and an error that freezes the whole step.
func (p *Pipeline) buildJiraEpisodes(runID int64, jiraReg *provenanceRegistry, issues []db.JiraExtractIssue) (built, failed int, maxUpdated int64, err error) {
	byID := map[string]*Node{}
	var order []string
	dirty := map[string]bool{}

	for _, is := range issues {
		// maxUpdated lifts BEFORE ref validation on purpose: an issue whose
		// jira: ref fails to resolve was hard-deleted between load and
		// validate; the row is gone and can never be built later.
		if is.UpdatedUnix > maxUpdated {
			maxUpdated = is.UpdatedUnix
		}
		ref := episodeRef{ChannelID: jiraRefPrefix + is.Key, TS: is.UpdatedAtRaw}

		ok, registered, verr := jiraReg.Validate(ref)
		if verr != nil {
			return 0, 0, 0, fmt.Errorf("memory: jira ingest: validate %s: %w", ref.ChannelID, verr)
		}
		if !registered || !ok {
			failed++
			p.logf("memory: jira ingest: issue %s ref unresolved — episode discarded (MEM-01)", is.Key)
			continue
		}

		title := fmt.Sprintf("%s: %s", is.Key, firstNonEmpty(strings.Join(strings.Fields(is.Summary), " "), "(untitled issue)"))
		body := jiraEpisodeBody(title, jiraStory(is), jiraOutcome(is), ref)
		status, tier := "active", "short"
		if is.StatusCategory == "done" && strings.TrimSpace(is.ResolvedAt) != "" {
			status, tier = "closed", "long"
		}

		epNode, changed, berr := p.jiraEpisodeNode(jiraIssueAlias(is.Key), title, body, status, tier)
		if berr != nil {
			return 0, 0, 0, berr
		}
		if _, seen := byID[epNode.ID]; !seen {
			byID[epNode.ID] = &epNode
			order = append(order, epNode.ID)
		}
		if changed {
			dirty[epNode.ID] = true
			built++
		}

		// Entity back-links: the project entity (seeded by seedJiraProjects,
		// aliased by its bare key) + assignee/reporter person entities via
		// their Slack ids — structural, no model judgment.
		link := "- [[" + epNode.ID + "|" + linkLabel(title) + "]]\n"
		refs := []string{is.ProjectKey}
		if sid := strings.TrimSpace(is.AssigneeSlackID); sid != "" {
			refs = append(refs, sid)
		}
		if sid := strings.TrimSpace(is.ReporterSlackID); sid != "" {
			refs = append(refs, sid)
		}
		for _, entRef := range refs {
			if entRef == "" {
				continue
			}
			if lerr := linkEntity(p, byID, &order, dirty, entRef, link); lerr != nil {
				return 0, 0, 0, lerr
			}
		}
	}

	if lerr := p.commitSourceNodes(runID, "jira", byID, order, dirty); lerr != nil {
		return 0, 0, 0, lerr
	}
	return built, failed, maxUpdated, nil
}

// jiraEpisodeNode returns the episode node for one issue: fresh when the
// jiraissue:<KEY> alias has none, else the existing node with Title/Body and
// the deterministic status/tier refreshed (a done+resolved issue is closed/
// long; a reopened issue flips back to active/short). changed reports whether
// anything differs from disk. A LookupMemoryAlias error (not a clean miss)
// fails the step — the alias is the idempotency key.
func (p *Pipeline) jiraEpisodeNode(alias, title, body, status, tier string) (n Node, changed bool, err error) {
	existingID, lerr := p.db.LookupMemoryAlias(alias)
	switch {
	case lerr == nil:
		existing, rerr := p.vault.ReadNode(existingID)
		if rerr != nil {
			return Node{}, false, fmt.Errorf("memory: jira ingest: read %s for %q: %w", existingID, alias, rerr)
		}
		if existing.Title == title && existing.Body == body && existing.Status == status && existing.Tier == tier {
			return existing, false, nil // unchanged — no commit
		}
		existing.Title = title
		existing.Body = body
		existing.Status = status
		existing.Tier = tier
		existing.Aliases = ensureAlias(existing.Aliases, alias)
		return existing, true, nil
	case isNoRows(lerr):
		return Node{
			ID:      NewID("episode"),
			Type:    "episode",
			Tier:    tier,
			Status:  status,
			Title:   title,
			Aliases: []string{alias},
			Body:    body,
		}, true, nil
	default:
		return Node{}, false, fmt.Errorf("memory: jira ingest: alias lookup %q: %w", alias, lerr)
	}
}

// jiraStory renders the mechanical Story: a metadata sentence block (type,
// status, priority, people, sprint/epic/due/points — each only when set) plus
// the capped description snippet.
func jiraStory(is db.JiraExtractIssue) string {
	var b strings.Builder
	if v := strings.TrimSpace(is.IssueType); v != "" {
		fmt.Fprintf(&b, "Type: %s. ", v)
	}
	fmt.Fprintf(&b, "Status: %s (%s).", is.Status, is.StatusCategory)
	if v := strings.TrimSpace(is.Priority); v != "" {
		fmt.Fprintf(&b, " Priority: %s.", v)
	}
	if v := strings.TrimSpace(is.AssigneeDisplayName); v != "" {
		fmt.Fprintf(&b, " Assignee: %s.", v)
	}
	if v := strings.TrimSpace(is.ReporterDisplayName); v != "" {
		fmt.Fprintf(&b, " Reporter: %s.", v)
	}
	if v := strings.TrimSpace(is.SprintName); v != "" {
		fmt.Fprintf(&b, " Sprint: %s.", v)
	}
	if v := strings.TrimSpace(is.EpicKey); v != "" {
		fmt.Fprintf(&b, " Epic: %s.", v)
	}
	if v := strings.TrimSpace(is.DueDate); v != "" {
		fmt.Fprintf(&b, " Due: %s.", v)
	}
	if is.StoryPoints.Valid {
		fmt.Fprintf(&b, " Story points: %g.", is.StoryPoints.Float64)
	}
	if desc := capRunes(oneLine(is.DescriptionText), jiraDescriptionCapBytes); desc != "" {
		b.WriteString("\n" + desc)
	}
	return b.String()
}

// capRunes truncates s to at most capBytes bytes on a rune boundary, appending
// "…" when truncated.
func capRunes(s string, capBytes int) string {
	if len(s) <= capBytes {
		return s
	}
	cut := capBytes
	for cut > 0 && !isRuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + "…"
}

func isRuneStart(b byte) bool { return b&0xC0 != 0x80 }

// jiraOutcome renders the deterministic Outcome: resolution when done, else
// the current status.
func jiraOutcome(is db.JiraExtractIssue) string {
	if is.StatusCategory == "done" && strings.TrimSpace(is.ResolvedAt) != "" {
		return fmt.Sprintf("Resolved (%s) at %s", is.Status, is.ResolvedAt)
	}
	return fmt.Sprintf("Current status: %s", is.Status)
}

// jiraEpisodeBody renders the deterministic episode body (H1, Story, Outcome,
// single jira: Provenance ref) — deterministic so the content-equality check
// can detect an unchanged re-scan.
func jiraEpisodeBody(title, story, outcome string, ref episodeRef) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n## Story\n", title)
	if story != "" {
		b.WriteString(story + "\n")
	}
	b.WriteString("\n## Outcome\n")
	if outcome != "" {
		b.WriteString(outcome + "\n")
	}
	b.WriteString("\n## Provenance\n")
	fmt.Fprintf(&b, "- %s %s\n", ref.ChannelID, ref.TS)
	return b.String()
}
```

IMPORTANT adaptation notes for the implementer:
- `isNoRows(lerr)` — the calendar version matches `errors.Is(lerr, sql.ErrNoRows)`; if no `isNoRows` helper exists in the package, use `errors.Is(lerr, sql.ErrNoRows)` directly and add the `"database/sql"`/`"errors"` imports (mirror `calendarEpisodeNode` exactly).
- `linkLabel`, `oneLine`, `firstNonEmpty`, `ensureAlias`, `orDefault`, `stepStatus`, `recordSemanticStep` all exist (used by calendar_ingest.go) — do not redefine.
- If `capRunes`/`isRuneStart` equivalents already exist in the package (grep for a byte-cap helper, e.g. the map.md `capMapBytes`), reuse the existing helper instead of adding these two.

- [ ] **Step 5: Run to verify green**

Run: `go test ./internal/memory/ -run TestRunJiraIngest -v` → PASS (all four).
Then: `go test ./internal/memory/ > /tmp/mem-t3.log 2>&1; echo exit=$?` → exit=0 (calendar tests still green after the rename).

- [ ] **Step 6: Commit**

```bash
git add internal/memory/jira_ingest.go internal/memory/jira_ingest_test.go internal/memory/calendar_ingest.go internal/memory/pipeline.go
git commit -m "feat(memory): mechanical jira issue→episode builder (jiraissue: alias, fifth watermark, no backfill)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xo7jXEcJB3kQjpqR7Q4PvH"
```

---

### Task 4: Run wiring (step 3d), config gate, dark test, MEM-14 guard extension

**Files:**
- Modify: `internal/config/config.go` (`MemorySourcesConfig` — add `Jira bool`)
- Modify: `internal/memory/pipeline.go` (`Run` — step 3d after mirrors; extend the run-done log line with jira counters)
- Test: `internal/memory/jira_ingest_test.go` (dark test), `internal/memory/mirror_ingest_test.go` (guard extension)

**Interfaces:**
- Consumes: Task 3's `runJiraIngest`.
- Produces: `cfg.Memory.Sources.Jira` (mapstructure `jira`, default false).

- [ ] **Step 1: Config field**

In `internal/config/config.go`, `MemorySourcesConfig`, after `Operational`:

```go
	Jira        bool `mapstructure:"jira"`        // mechanical jira issue->episode builder + jira: provenance scheme, its own Run step (default: false)
```

- [ ] **Step 2: Write the failing dark test**

Append to `internal/memory/jira_ingest_test.go`:

```go
// TestRunJiraIngestDarkByDefault: with memory.sources.jira off, a full Run
// never touches the jira path — no jiraissue: alias appears and the jira
// watermark stays 0 even with pending issues present.
func TestRunJiraIngestDarkByDefault(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	seedJiraIssue(t, d, "CEX-1", "CEX", "pending", "", "To Do", "todo", "", "2026-07-22T10:00:00.000+0000", "")
	cfg := pipelineTestConfig() // Sources.Jira is false by default
	p := NewPipeline(d, v, emptyExtractGen(t), cfg, t.Logf)

	if _, err := p.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if _, err := d.LookupMemoryAlias("jiraissue:CEX-1"); err == nil {
		t.Error("dark run built a jira episode")
	}
	wm, _ := d.MemoryJiraWatermark()
	if wm != 0 {
		t.Errorf("dark run moved the jira watermark to %v", wm)
	}
}
```

NOTE: `emptyExtractGen` stands for whatever generator fixture the package's full-Run tests use for a run with no AI expectations (the mirror/calendar dark tests have one — reuse their exact fixture and `Run` invocation shape, including any required context/config fields). Read `TestMemory14_FullRunNeverWritesOperationalTables` first and mirror its Run setup.

- [ ] **Step 3: Wire Run step 3d**

In `internal/memory/pipeline.go`, directly after the mirrors block (`mirrorSteps` assignment) and before the extraction comment `// (4) Episode extraction from raw text.`:

```go
	// (3d) Mechanical Jira issue → episode builder (dark behind
	// memory.sources.jira, owner scope-B: all issues, watermark-bounded, no
	// backfill). Runs after mirrors and before Slack extraction. No AI call.
	// Source-isolated: a jira-step error is logged, never fatal, and never
	// touches another watermark.
	jiraSteps := 0
	if p.cfg.Sources.Jira {
		n, jerr := p.runJiraIngest(runID, calSteps+mirrorSteps, &stats)
		if jerr != nil {
			p.logf("memory: jira ingest: %v", jerr)
		}
		jiraSteps = n
	}
```

Then find every subsequent use of `calSteps+mirrorSteps` as a step offset (the extraction call right below — read the actual code) and add `+jiraSteps` so later steps number after it. Extend the run-done `p.logf` (the line referencing `stats.CalendarEpisodes, stats.CalendarEventsFailed, ...` around pipeline.go:346) with `jira: %d built (%d failed)` fed by `stats.JiraEpisodes, stats.JiraIssuesFailed` — match the existing log line's phrasing style exactly.

- [ ] **Step 4: MEM-14 guard extension (owner-approved)**

In `internal/memory/mirror_ingest_test.go`, `TestMemory14_FullRunNeverWritesOperationalTables`: add `"jira_issues"` to the dumped-table list (find the slice/loop of table names whose dumps are compared byte-identical) and — if the fixture supports it — seed one jira issue row before the run so the dump is non-empty. Also flip the full-run config to `Sources.Jira = true` in that test so the guard exercises the new step doing real work while proving `jira_issues` is untouched (this matches how the test already enables the other slice-4 gates; if it seeds no jira rows the step is a no-op, which still proves read-only but weaker — seed one row AND set the watermark to 1 first so the step actually builds).

- [ ] **Step 5: Run**

```bash
go test ./internal/memory/ -run 'TestRunJiraIngestDarkByDefault|TestMemory14_FullRunNeverWritesOperationalTables' -v
go test ./internal/memory/ ./internal/config/ > /tmp/mem-t4.log 2>&1; echo exit=$?
```
PASS / exit=0.

- [ ] **Step 6: Commit**

```bash
git add internal/config/config.go internal/memory/pipeline.go internal/memory/jira_ingest_test.go internal/memory/mirror_ingest_test.go
git commit -m "feat(memory): wire jira source as Run step 3d behind memory.sources.jira; extend MEM-14 dump set with jira_issues (owner-approved)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xo7jXEcJB3kQjpqR7Q4PvH"
```

---

### Task 5: Situation-ingest jira refs — close the provenance drop

**Files:**
- Modify: `internal/memory/ingest.go` (`situationProvenance` ~line 295-330 and its validation path; the two call sites pass whatever new parameter is added)
- Test: `internal/memory/ingest_test.go`

**Interfaces:**
- Consumes: Task 2's `jiraRefPrefix`, `jiraResolver`; the existing `messageResolver`, `newProvenanceRegistry`, `validateRefsVia` (grep its exact signature — it exists per MEM-12's inventory text; if the actual name differs, e.g. only `validateRefs` exists with a checker, add a registry-based sibling rather than changing `validateRefs`' other callers).
- Produces: jira-sourced situation signals mint validated `jira:<KEY>` refs into episode `## Provenance`; entity hints carry the project key.

- [ ] **Step 1: Write the failing test**

Append to `internal/memory/ingest_test.go` (reuse this file's existing situation fixtures — read how `TestMemory05_InboxUntouched` / the ingest tests seed situations + signals, and mirror those helpers exactly):

```go
// TestIngestSituationJiraSignalMintsJiraRef: a situation carrying a
// jira-detector signal (trigger_type jira_*, channel_id = the issue key) mints
// a validated jira:<KEY> ref into the episode's ## Provenance instead of
// dropping it against the messages table; the entity hint is the PROJECT key.
// A jira signal whose issue no longer exists drops-and-counts (MEM-01).
func TestIngestSituationJiraSignalMintsJiraRef(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	seedJiraIssue(t, d, "CEX-7413", "CEX", "webhook fix", "", "In Progress", "in_progress", "", "2026-07-22T10:00:00.000+0000", "")
	// A project entity so the hint resolves.
	writeEntity(t, v, d, "ent_00000000000000000000000cex", "CEX", []string{"CEX"})

	sitID := seedSituation(t, d, "Webhook broken", "open")
	seedSituationSignal(t, d, sitID, inboxItemSeed{
		ChannelID: "CEX-7413", MessageTS: "2026-07-22T10:00:00.000+0000",
		SenderUserID: "CEX-7413", TriggerType: "jira_assigned", Snippet: "webhook fix",
	})

	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)
	var stats RunStats
	if err := p.IngestSituations(1, &stats); err != nil {
		t.Fatalf("IngestSituations: %v", err)
	}

	id, err := d.LookupMemoryAlias(fmt.Sprintf("situation:%d", sitID))
	if err != nil {
		t.Fatalf("situation alias: %v", err)
	}
	n, err := v.ReadNode(id)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !strings.Contains(n.Body, "- jira:CEX-7413 2026-07-22T10:00:00.000+0000") {
		t.Errorf("episode missing the jira ref:\n%s", n.Body)
	}
	// The project entity got the back-link (hint resolved to CEX, not CEX-7413).
	en, _ := v.ReadNode("ent_00000000000000000000000cex")
	if !strings.Contains(en.Body, "[["+id+"|") {
		t.Errorf("project entity missing back-link:\n%s", en.Body)
	}
}

// TestIngestSituationJiraSignalMissingIssueDrops: the jira ref of a ghost
// issue is dropped-and-counted, never written (MEM-01 discipline unchanged).
func TestIngestSituationJiraSignalMissingIssueDrops(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	sitID := seedSituation(t, d, "Ghost", "open")
	seedSituationSignal(t, d, sitID, inboxItemSeed{
		ChannelID: "CEX-404", MessageTS: "2026-07-22T10:00:00.000+0000",
		SenderUserID: "CEX-404", TriggerType: "jira_assigned", Snippet: "gone",
	})
	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)
	var stats RunStats
	if err := p.IngestSituations(1, &stats); err != nil {
		t.Fatalf("IngestSituations: %v", err)
	}
	id, err := d.LookupMemoryAlias(fmt.Sprintf("situation:%d", sitID))
	if err != nil {
		t.Fatalf("situation alias: %v", err)
	}
	n, _ := v.ReadNode(id)
	if strings.Contains(n.Body, "jira:CEX-404") {
		t.Errorf("ghost jira ref written:\n%s", n.Body)
	}
}
```

NOTE: `seedSituation`/`seedSituationSignal`/`inboxItemSeed`/`writeEntity` stand for THIS file's actual situation/signal/entity fixtures — read `ingest_test.go` first and reuse its exact helpers (the file necessarily has them for the existing ingest tests; `IngestSituations`' real signature — argument list and return — must be copied from an existing test's call). Never invent parallel fixtures; adapt the calls, keep the assertions.

- [ ] **Step 2: Run to verify red**

Run: `go test ./internal/memory/ -run 'TestIngestSituationJiraSignal' -v`
Expected: after fixture adaptation compiles — FAIL on the missing `- jira:CEX-7413 ...` provenance line (today the ref is dropped against `messages`).

- [ ] **Step 3: Implement**

In `internal/memory/ingest.go`:

1. Add the project-key helper:

```go
// jiraProjectKey derives the project key from an issue key ("CEX-7413" →
// "CEX") — the entity-hint identity for jira-sourced signals (the project
// entity is what seedJiraProjects aliases; the issue itself is not an entity).
func jiraProjectKey(issueKey string) string {
	if i := strings.IndexByte(issueKey, '-'); i > 0 {
		return issueKey[:i]
	}
	return ""
}
```

2. In `situationProvenance`'s signal loop, branch on the jira trigger prefix:

```go
	for _, it := range items {
		if strings.HasPrefix(it.TriggerType, "jira_") {
			// A jira-detector signal: channel_id carries the issue key, which
			// never resolves in messages — mint a jira: ref instead (MEM-12)
			// and hint the PROJECT entity.
			refs = append(refs, episodeRef{ChannelID: jiraRefPrefix + it.ChannelID, TS: it.MessageTS})
			addHint(jiraProjectKey(it.ChannelID))
			continue
		}
		refs = append(refs, episodeRef{ChannelID: it.ChannelID, TS: it.MessageTS})
		addHint(it.ChannelID)
		addHint(it.SenderUserID)
	}
```

3. Validation: `situationProvenance` currently calls `validateRefs(checker, ...)` (message-only). Switch it to validate through a message+jira scoped registry. Concretely: find how `validateRefs` dispatches (per MEM-12 it routes through a registry built from the `checkMsg` seam — `validateRefsVia(reg, ...)` or equivalent); build the ingest registry ONCE where `situationProvenance`'s caller constructs its checker (e.g. `ingestReg := newProvenanceRegistry(messageResolver{checker: checker}, jiraResolver{p.db})`) and pass it down (change `situationProvenance`'s `checker messageChecker` parameter to the registry type, updating its two call sites in this file). Keep the disposition byte-identical: lookup ERROR → propagate (situation skipped-and-logged by the caller, unchanged); positive not-found → drop-and-count with the same `refs_rejected` log line.

Preserve exactly: the `messageResolver` construction must reuse the SAME checker seam the callers already pass (so the MEM-01 lookup-freeze tests still bite), and non-jira signals' behavior must stay byte-identical (guard: every pre-existing `TestMemory01_*`/ingest test passes unmodified).

- [ ] **Step 4: Run to verify green + package sweep**

```bash
go test ./internal/memory/ -run 'TestIngestSituationJiraSignal' -v
go test ./internal/memory/ > /tmp/mem-t5.log 2>&1; echo exit=$?
```
PASS / exit=0 — with `TestMemory01_*` and every pre-existing ingest test unmodified.

- [ ] **Step 5: Commit**

```bash
git add internal/memory/ingest.go internal/memory/ingest_test.go
git commit -m "feat(memory): situation ingest mints validated jira: refs for jira-detector signals

Closes the MEM-01 review finding: jira signals' provenance was dropped
against the messages table; now it resolves through the jira: scheme
(MEM-12) and hints the project entity.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xo7jXEcJB3kQjpqR7Q4PvH"
```

---

### Task 6: Inventory + spec amendment + full sweep

**Files:**
- Modify: `docs/inventory/memory.md` (MEM-12 section, changelog, known limitations)
- Modify: `docs/superpowers/specs/2026-07-22-memory-jira-source-design.md` (migration number)

- [ ] **Step 1: MEM-12 section updates**

In `docs/inventory/memory.md`, MEM-12 section:
1. In the Observable's scheme list, after the `cal` entry, add: `` and — **Jira source, 2026-07-22** — `jira` (a non-deleted `jira_issues` row, `JiraIssueExists`, `jiraResolver`) ``.
2. In the scoped-registry paragraph, add after the calendar-builder clause: `` the mechanical **jira builder a jira-only registry** (`newProvenanceRegistry(jiraResolver{p.db})`, so a Jira episode can carry only `jira:` refs); **situation ingest a message+jira registry** (jira-detector signals mint `jira:<KEY>` refs instead of dropping against `messages` — the 2026-07-20 owner-review finding closed); ``
3. Replace the section's `**Future (2026-07-20 owner review):**` paragraph opener with `**Delivered (2026-07-22):**` and rewrite its first sentence to past tense (`a jira:<issue_key> resolver against jira_issues SHIPPED — registered by the jira builder, situation ingest (a site the note did not anticipate — owner-approved in the design session), and the pipeline's belief-surface registry; NOT by the Slack extractor`), keeping the misattribution rationale and the multi-scheme/honesty notes verbatim.
4. Update `**Locked since:**` to append `(jira scheme added: 2026-07-22)`.

- [ ] **Step 2: Known-limitations bullets**

Append to the `## Known v1 limitations` list:

```markdown
- **A fifth independent extraction watermark, and the jira builder makes NO AI call.** `memory_jira_last_extracted_ts` (migration 00030) tracks parsed `jira_issues.updated_at` (unix); the source (`memory.sources.jira`, default false) is mechanical (`jira_ingest.go`/`runJiraIngest`, Run step 3d): one updated issue → at most one episode built from the structured row (status/people/sprint/epic + a 1500-byte description snippet), alias-keyed `jiraissue:<KEY>` with update-in-place and content-equality no-op; a done+resolved issue is born (or refreshed) closed/long, a reopened one flips back. **No backfill (owner scope-B):** the first gated run initializes the watermark to the newest synced `updated_at` and builds nothing; there is deliberately NO owner/assignee filter — like the Slack source, the trail is workspace-wide. No bounded lookback: rows are permanent and every change lifts `updated_at` itself. An unparseable `updated_at` skips the row (the Gmail `internal_date` precedent); Jira's `+0100`-style offsets defeat SQLite's strftime, so all time math happens in Go (`parseJiraTime`). The live workspace's Jira sync is currently dead (newest row 2026-04-24) — the source sleeps behind its gate until the sync revives.
```

- [ ] **Step 3: Changelog entry**

Insert at the top of `## Changelog` (above the current first entry, blank line between):

```markdown
- 2026-07-22 (memory Jira source — spec `docs/superpowers/specs/2026-07-22-memory-jira-source-design.md`, owner scope-B): the `jira:` provenance scheme SHIPPED as a MEM-12 extension (no new contract number, per the header rule): `jiraResolver` (`jira:<KEY>` ⇔ non-deleted `jira_issues` row; lookup errors freeze, the table is migration-guaranteed) registered at three scoped sites — the mechanical jira builder (jira-only), situation ingest (message+jira — jira-detector signals now mint validated `jira:` refs instead of dropping against `messages`, with the PROJECT key as the entity hint), and the belief-surface registry. New mechanical source `memory.sources.jira` (default false, Run step 3d, NO AI call): updated issues → deterministic episodes (`jiraissue:<KEY>` alias, update-in-place, done→closed/long), fifth watermark `memory_jira_last_extracted_ts` (00030) on parsed `updated_at`, no backfill, no owner filter (scope-B, Slack-source symmetry). Guard extension (owner-approved): `jira_issues` joined `TestMemory14_FullRunNeverWritesOperationalTables`'s dump set. Shared-helper rename: `commitCalendarNodes` → `commitSourceNodes(op)` (calendar behavior byte-identical).
```

- [ ] **Step 4: Spec amendment**

In `docs/superpowers/specs/2026-07-22-memory-jira-source-design.md`, replace `migration 00028, additive` with `migration 00030 — 00028/00029 were taken by the concurrent Slice B merge; additive` (the Selection + watermark section).

- [ ] **Step 5: Full sweep**

```bash
gofmt -l internal/ | tee /tmp/fmt.log            # expect empty
go vet ./... > /tmp/vet.log 2>&1; echo exit=$?
go build ./... > /tmp/build.log 2>&1; echo exit=$?
go test ./internal/db/ ./internal/memory/ ./internal/inbox/ ./internal/config/ ./internal/dayplan/ ./internal/meeting/ ./internal/briefing/ > /tmp/sweep.log 2>&1; echo exit=$?
```
All exit=0 / empty gofmt.

- [ ] **Step 6: Commit**

```bash
git add docs/inventory/memory.md docs/superpowers/specs/2026-07-22-memory-jira-source-design.md
git commit -m "docs(memory): inventory + spec — jira: scheme delivered (MEM-12), fifth watermark, changelog

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xo7jXEcJB3kQjpqR7Q4PvH"
```
