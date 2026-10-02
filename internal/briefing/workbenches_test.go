package briefing

import (
	"context"
	"database/sql"
	"io"
	"log"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/prompts"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func seedWorkbench(t *testing.T, d *db.DB, name string) int64 {
	t.Helper()
	id, err := d.CreateWorkbench(name, t.TempDir())
	require.NoError(t, err)
	return id
}

func seedWorkbenchTarget(t *testing.T, d *db.DB, projectID int64, parent int64, title, status, updatedAt string) int64 {
	t.Helper()
	p := sql.NullInt64{}
	if parent != 0 {
		p = sql.NullInt64{Int64: parent, Valid: true}
	}
	id := db.SeedTestWorkbenchTarget(t, d, projectID, p, title)
	_, err := d.Exec(`UPDATE targets SET status = ?, updated_at = ? WHERE id = ?`, status, updatedAt, id)
	require.NoError(t, err)
	return id
}

func TestGatherProjects_NoProjectsRendersThePlaceholder(t *testing.T) {
	pipe := New(testDB(t), testConfig(), &mockGenerator{}, log.New(io.Discard, "", 0))
	ctx, has := pipe.gatherWorkbenches(time.Now().Add(-24 * time.Hour))
	assert.False(t, has)
	assert.Equal(t, noWorkbenchActivity, ctx)
}

func TestGatherProjects_ReportsActivityAndSkipsQuietProjects(t *testing.T) {
	d := testDB(t)
	since := time.Date(2026, 9, 28, 8, 0, 0, 0, time.UTC)
	busy := seedWorkbench(t, d, "acme")
	quiet := seedWorkbench(t, d, "quiet")

	feature := seedWorkbenchTarget(t, d, busy, 0, "Payments feature", "in_progress", "2026-09-29T09:00:00Z")
	seedWorkbenchTarget(t, d, busy, feature, "Task 3: wire the API", "blocked", "2026-09-29T09:00:00Z")
	seedWorkbenchTarget(t, d, busy, feature, "Task 1: schema", "done", "2026-09-29T07:00:00Z")
	seedWorkbenchTarget(t, d, busy, feature, "Task 0: spike", "done", "2026-09-20T07:00:00Z")
	// Not every open task is blocked, so the feature rolls up to in_progress
	// (PROJ-05) rather than blocked.
	seedWorkbenchTarget(t, d, busy, feature, "Task 2: handlers", "todo", "2026-09-20T07:00:00Z")
	seedWorkbenchTarget(t, d, quiet, 0, "Idle idea", "todo", "2026-09-01T00:00:00Z")

	_, err := d.AddWorkbenchComment(db.WorkbenchComment{
		WorkbenchID: busy, TargetID: sql.NullInt64{Int64: feature, Valid: true},
		Author: "agent", Body: "Which currency list?",
	})
	require.NoError(t, err)
	docID, _, err := d.UpsertWorkbenchDocument(db.WorkbenchDocument{WorkbenchID: busy, RelPath: "docs/plan.md", Kind: "plan", Title: "Payments plan"})
	require.NoError(t, err)
	_, err = d.AddWorkbenchComment(db.WorkbenchComment{
		WorkbenchID: busy, DocumentID: sql.NullInt64{Int64: docID, Valid: true},
		Author: "owner", Body: "Split task 3", AnchorQuote: "Task 3",
	})
	require.NoError(t, err)

	pipe := New(d, testConfig(), &mockGenerator{}, log.New(io.Discard, "", 0))
	pipe.shown = newShownIDs()
	ctx, has := pipe.gatherWorkbenches(since)

	require.True(t, has)
	assert.Contains(t, ctx, "[project_id=")
	assert.Contains(t, ctx, "acme")
	assert.Contains(t, ctx, "In progress (1): Payments feature")
	assert.Contains(t, ctx, "Blocked (1): Task 3: wire the API")
	assert.Contains(t, ctx, "Done since the last briefing (1): Task 1: schema")
	assert.NotContains(t, ctx, "Task 0: spike", "done before the window")
	assert.Contains(t, ctx, "Unread agent comments: 1")
	assert.Contains(t, ctx, "Documents with open owner comments (1): Payments plan")
	assert.NotContains(t, ctx, "quiet", "a project with no activity is omitted")
	assert.True(t, pipe.shown.workbenches[busy])
}

func TestGatherProjects_ListsTargetsInReview(t *testing.T) {
	d := testDB(t)
	pid := seedWorkbench(t, d, "acme")
	seedWorkbenchTarget(t, d, pid, 0, "Task 2: review me", "in_review", "2026-09-29T09:00:00Z")
	pipe := New(d, testConfig(), &mockGenerator{}, log.New(io.Discard, "", 0))
	ctx, has := pipe.gatherWorkbenches(time.Now().Add(-24 * time.Hour))
	require.True(t, has)
	assert.Contains(t, ctx, "In review (1): Task 2: review me")
}

func TestGatherProjects_CapsItemsPerLine(t *testing.T) {
	d := testDB(t)
	pid := seedWorkbench(t, d, "acme")
	for i := 0; i < maxWorkbenchItems+2; i++ {
		seedWorkbenchTarget(t, d, pid, 0, "Task "+strings.Repeat("x", i+1), "in_progress", "2026-09-29T09:00:00Z")
	}
	pipe := New(d, testConfig(), &mockGenerator{}, log.New(io.Discard, "", 0))
	ctx, _ := pipe.gatherWorkbenches(time.Now().Add(-24 * time.Hour))
	assert.Contains(t, ctx, "(+2 more)")
}

func TestBriefingHasDataWithProjectsOnly(t *testing.T) {
	d := testDB(t)
	require.NoError(t, d.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test"}))
	_, err := d.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
	require.NoError(t, err)
	pid := seedWorkbench(t, d, "acme")
	seedWorkbenchTarget(t, d, pid, 0, "Payments feature", "in_progress", time.Now().UTC().Format("2006-01-02T15:04:05Z"))

	gen := &capturingGenerator{response: `{"attention":[],"your_day":[],"what_happened":[],"team_pulse":[],"coaching":[]}`}
	pipe := New(d, testConfig(), gen, log.New(io.Discard, "", 0))
	id, err := pipe.RunForDate(context.Background(), time.Now().Format("2006-01-02"))
	require.NoError(t, err)
	assert.Greater(t, id, 0, "project activity alone is enough for a briefing")
	assert.Contains(t, gen.systemMsg, "=== WORKBENCHES ===")
	assert.Contains(t, gen.systemMsg, "Payments feature")
	assert.NotContains(t, gen.systemMsg, "%!", "every verb got exactly one argument")
}

// A briefing.daily row the owner customized before v8 carries one %s fewer.
// Formatting it with the v8 arguments would shift WORKBENCHES into the MEMORY
// REVISIONS slot and append %!(EXTRA ...) to the prompt; getPrompt must fall
// back to the shipped default instead.
func TestGetPrompt_CustomizedTemplateWithOldVerbCountFallsBackToDefault(t *testing.T) {
	d := testDB(t)
	require.NoError(t, d.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test"}))
	_, err := d.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
	require.NoError(t, err)
	pid := seedWorkbench(t, d, "acme")
	seedWorkbenchTarget(t, d, pid, 0, "Payments feature", "in_progress", time.Now().UTC().Format("2006-01-02T15:04:05Z"))

	const sentinel = "SENTINEL-PRE-V8-BRIEFING-7C21"
	verbs := countVerbs(prompts.Defaults[prompts.BriefingDaily])
	require.Equal(t, 16, verbs, "v8 carries 16 verbs")
	old := sentinel + "\n" + strings.Repeat("%s\n", verbs-1)

	store := prompts.New(d, nil)
	require.NoError(t, store.Seed())
	require.NoError(t, store.Update(prompts.BriefingDaily, old, "customized before v8"))

	gen := &capturingGenerator{response: `{"attention":[],"your_day":[],"what_happened":[],"team_pulse":[],"coaching":[]}`}
	pipe := New(d, testConfig(), gen, log.New(io.Discard, "", 0))
	pipe.SetPromptStore(store)
	id, err := pipe.RunForDate(context.Background(), time.Now().Format("2006-01-02"))
	require.NoError(t, err)

	assert.NotContains(t, gen.systemMsg, sentinel, "the mismatched template must not be used")
	assert.NotContains(t, gen.systemMsg, "%!")
	assert.Contains(t, gen.systemMsg, "=== WORKBENCHES ===")
	stored, err := d.GetBriefingByID(id)
	require.NoError(t, err)
	assert.Equal(t, 0, stored.PromptVersion, "a fallback records the default arm's version 0")
}

func TestCountVerbs_IgnoresEscapedPercent(t *testing.T) {
	assert.Equal(t, 2, countVerbs("a %s b %s c 100%%s"))
}

func TestValidateIDs_ProjectSourceMustBeShown(t *testing.T) {
	s := newShownIDs()
	s.addWorkbench(3)
	r := &BriefingResult{Attention: []AttentionItem{
		{Text: "a", SourceType: "project", SourceID: "3"},
		{Text: "b", SourceType: "project", SourceID: "9"},
	}}
	assert.Equal(t, 1, s.validateIDs(r))
	assert.Equal(t, "3", r.Attention[0].SourceID)
	assert.Equal(t, "", r.Attention[1].SourceID)
}

func TestBriefingDailyVersionAtLeastEight(t *testing.T) {
	// v8 introduced the PROJECTS block.
	assert.GreaterOrEqual(t, prompts.DefaultVersions[prompts.BriefingDaily], 8)
}

// Workbench rename (spec 2026-10-02 A8): v9 heads the block WORKBENCHES with
// the same verb count, and attention items keep the stored source_type
// "project".
func TestBriefingDailyV9_WorkbenchesHeaderSameVerbsLegacySourceType(t *testing.T) {
	tmpl := prompts.Defaults[prompts.BriefingDaily]
	assert.GreaterOrEqual(t, prompts.DefaultVersions[prompts.BriefingDaily], 9, "the reworded template must auto-upgrade stored v8 rows")
	assert.Contains(t, tmpl, "\n=== WORKBENCHES ===\n%s\n")
	assert.NotContains(t, tmpl, "=== PROJECTS ===")
	assert.Equal(t, 16, countVerbs(tmpl), "v9 keeps v8's 16 verbs")
	assert.Contains(t, tmpl, `source_type="project"`)
	assert.Contains(t, tmpl, noWorkbenchActivity, "the placeholder the template names is the one rendered")
}

// A briefing.daily row the owner customized at v8 keeps its own wording
// (Seed never upgrades a customized row) and still renders: same verb count,
// so the workbench block lands in its PROJECTS slot.
func TestGetPrompt_CustomizedV8TemplateStillRenders(t *testing.T) {
	d := testDB(t)
	require.NoError(t, d.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test"}))
	_, err := d.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
	require.NoError(t, err)
	pid := seedWorkbench(t, d, "acme")
	seedWorkbenchTarget(t, d, pid, 0, "Payments feature", "in_progress", time.Now().UTC().Format("2006-01-02T15:04:05Z"))

	const sentinel = "SENTINEL-CUSTOM-V8-BRIEFING-4E19"
	v8 := strings.Replace(prompts.Defaults[prompts.BriefingDaily], "=== WORKBENCHES ===", "=== PROJECTS ===", 1)
	require.NotEqual(t, prompts.Defaults[prompts.BriefingDaily], v8)
	custom := sentinel + "\n" + v8

	store := prompts.New(d, nil)
	require.NoError(t, store.Seed())
	require.NoError(t, store.Update(prompts.BriefingDaily, custom, "customized at v8"))
	require.NoError(t, store.Seed(), "a later seed must leave the customized row alone")

	gen := &capturingGenerator{response: `{"attention":[],"your_day":[],"what_happened":[],"team_pulse":[],"coaching":[]}`}
	pipe := New(d, testConfig(), gen, log.New(io.Discard, "", 0))
	pipe.SetPromptStore(store)
	_, err = pipe.RunForDate(context.Background(), time.Now().Format("2006-01-02"))
	require.NoError(t, err)

	assert.Contains(t, gen.systemMsg, sentinel, "the customized template is used")
	assert.Contains(t, gen.systemMsg, "=== PROJECTS ===\n--- [project_id=")
	assert.Contains(t, gen.systemMsg, "Payments feature")
	assert.NotContains(t, gen.systemMsg, "%!")
}
