package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// reviewFixture: a workbench bound to a git repo (main + README.md, branch
// feature, from gitBranchRepo) and a session row on it.
func reviewFixture(t *testing.T) (database *db.DB, wbID, sessionID int64, repo string) {
	t.Helper()
	database = writeActionsConfig(t)
	repo = gitBranchRepo(t)
	wbID, err := database.CreateWorkbench("acme", repo)
	require.NoError(t, err)
	sessionID = reviewSession(t, database, wbID, repo)
	return database, wbID, sessionID, repo
}

func reviewSession(t *testing.T, database *db.DB, wbID int64, folder string) int64 {
	t.Helper()
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 's', ?, 'uuid')`, wbID, folder)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func reviewJSON(t *testing.T, wb int64, sub string, args ...string) map[string]any {
	t.Helper()
	out, _, err := runWorkbench(t, append([]string{"review", sub, "--workbench", itoa(wb), "--json"}, args...)...)
	resetSetFlags(workbenchReviewCmd.Commands()...)
	require.NoError(t, err)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	return m
}

func itoa(v int64) string { return strconv.FormatInt(v, 10) }

func TestWorkbenchReview_StartDiffSendRound(t *testing.T) {
	_, wb, s, repo := reviewFixture(t)
	require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("changed\n"), 0o644))
	start := reviewJSON(t, wb, "start", "--session", itoa(s))
	round := start["round"].(map[string]any)
	rid := int64(round["id"].(float64))
	again := reviewJSON(t, wb, "start", "--session", itoa(s))
	assert.Equal(t, rid, int64(again["round"].(map[string]any)["id"].(float64)), "start must resume the open round")
	diff := reviewJSON(t, wb, "diff", "--round", itoa(rid))
	files := diff["diff"].(map[string]any)["files"].([]any)
	require.Len(t, files, 1)
	assert.Equal(t, "README.md", files[0].(map[string]any)["path"])
	file := reviewJSON(t, wb, "file", "--round", itoa(rid), "--path", "README.md")
	assert.Contains(t, file["new"].(map[string]any)["text"].(string), "changed")
	sent := reviewJSON(t, wb, "send", "--round", itoa(rid))
	assert.Equal(t, true, sent["sent"])
	assert.True(t, strings.HasPrefix(sent["line"].(string), "Review round #"), "line = %v", sent["line"])
	twice := reviewJSON(t, wb, "send", "--round", itoa(rid))
	assert.Equal(t, false, twice["sent"])
	assert.Empty(t, twice["line"])
}

func TestWorkbenchReview_SinceLastRoundAndRefresh(t *testing.T) {
	_, wb, s, repo := reviewFixture(t)
	require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("one\n"), 0o644))
	r1 := int64(reviewJSON(t, wb, "start", "--session", itoa(s))["round"].(map[string]any)["id"].(float64))
	reviewJSON(t, wb, "send", "--round", itoa(r1))
	require.NoError(t, os.WriteFile(filepath.Join(repo, "x.txt"), []byte("new\n"), 0o644))
	r2 := reviewJSON(t, wb, "start", "--session", itoa(s))["round"].(map[string]any)
	assert.Equal(t, r1, int64(r2["prev_round_id"].(float64)))
	id2 := itoa(int64(r2["id"].(float64)))
	since := reviewJSON(t, wb, "diff", "--round", id2, "--since")["diff"].(map[string]any)["files"].([]any)
	require.Len(t, since, 1)
	assert.Equal(t, "x.txt", since[0].(map[string]any)["path"])
	require.NoError(t, os.WriteFile(filepath.Join(repo, "y.txt"), []byte("later\n"), 0o644))
	ref := reviewJSON(t, wb, "start", "--session", itoa(s), "--refresh")["round"].(map[string]any)
	assert.NotEqual(t, r2["tree_sha"], ref["tree_sha"], "refresh kept the old tree")
}

func TestWorkbenchReview_NotARepositoryIsAnEnvelope(t *testing.T) {
	database := writeActionsConfig(t)
	dir := t.TempDir()
	wb, err := database.CreateWorkbench("acme", dir)
	require.NoError(t, err)
	s := reviewSession(t, database, wb, dir)
	out := reviewJSON(t, wb, "start", "--session", itoa(s))
	assert.Equal(t, false, out["ok"])
	assert.NotEmpty(t, out["error"])
}

func TestWorkbenchReview_ContextReadsPlanTask(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	plan := "# P\n\n**Spec:** `docs/spec.md`\n\n### Task 1: One\nstep one\n\n### Task 2: Two\nstep two\n"
	require.NoError(t, os.MkdirAll(filepath.Join(repo, "docs"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(repo, "docs", "plan.md"), []byte(plan), 0o644))
	tid := db.SeedTestWorkbenchTarget(t, database, wb, sql.NullInt64{}, "Task two")
	_, err := database.Exec(`UPDATE targets SET intent = 'docs/plan.md — Task 2' WHERE id = ?`, tid)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at) VALUES (?, ?, 'x', 'x')`, s, tid)
	require.NoError(t, err)
	items := reviewJSON(t, wb, "context", "--session", itoa(s))["items"].([]any)
	require.Len(t, items, 1)
	it := items[0].(map[string]any)
	assert.Contains(t, it["plan_text"], "step two")
	assert.NotContains(t, it["plan_text"], "step one")
	assert.Equal(t, "docs/spec.md", it["spec_path"])
}

func TestWorkbenchReview_ContextPlanEscapeStaysInFolder(t *testing.T) {
	database, wb, s, _ := reviewFixture(t)
	tid := db.SeedTestWorkbenchTarget(t, database, wb, sql.NullInt64{}, "Escape")
	_, err := database.Exec(`UPDATE targets SET intent = '../../etc/passwd.md — Task 1' WHERE id = ?`, tid)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at) VALUES (?, ?, 'x', 'x')`, s, tid)
	require.NoError(t, err)
	it := reviewJSON(t, wb, "context", "--session", itoa(s))["items"].([]any)[0].(map[string]any)
	assert.Equal(t, "plan", it["missing"])
}

func linkTarget(t *testing.T, database *db.DB, wb, session int64, intent string) {
	t.Helper()
	tid := db.SeedTestWorkbenchTarget(t, database, wb, sql.NullInt64{}, "T")
	_, err := database.Exec(`UPDATE targets SET intent = ? WHERE id = ?`, intent, tid)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at) VALUES (?, ?, 'x', 'x')`, session, tid)
	require.NoError(t, err)
}

func TestWorkbenchReview_ContextRefusesAForeignSession(t *testing.T) {
	database, wb, _, _ := reviewFixture(t)
	other, err := database.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	foreign := reviewSession(t, database, other, t.TempDir())
	linkTarget(t, database, other, foreign, "secret.md — Task 1")
	out := reviewJSON(t, wb, "context", "--session", itoa(foreign))
	assert.Equal(t, false, out["ok"])
	assert.Nil(t, out["items"])
}

func TestWorkbenchReview_ContextSkipsForeignTargets(t *testing.T) {
	database, wb, s, _ := reviewFixture(t)
	other, err := database.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	linkTarget(t, database, other, s, "x.md — Task 1")
	out := reviewJSON(t, wb, "context", "--session", itoa(s))
	assert.Equal(t, true, out["ok"])
	assert.Empty(t, out["items"])
}

func TestWorkbenchReview_ContextPlanReadLimits(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	outside := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(outside, "plan.md"), []byte("### Task 1: x\nsecret\n"), 0o644))
	require.NoError(t, os.Symlink(outside, filepath.Join(repo, "docs")))
	require.NoError(t, os.WriteFile(filepath.Join(repo, "big.md"), []byte(strings.Repeat("a", 1<<20+10)), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(repo, "short.md"), []byte("### Task 1: x\nbody\n"), 0o644))
	linkTarget(t, database, wb, s, "docs/plan.md — Task 1")
	linkTarget(t, database, wb, s, "big.md — Task 1")
	linkTarget(t, database, wb, s, "short.md — Task 9")
	items := reviewJSON(t, wb, "context", "--session", itoa(s))["items"].([]any)
	require.Len(t, items, 3)
	assert.Equal(t, "plan", items[0].(map[string]any)["missing"])
	assert.Equal(t, "plan", items[1].(map[string]any)["missing"])
	assert.Equal(t, "task", items[2].(map[string]any)["missing"])
	assert.Empty(t, items[0].(map[string]any)["plan_text"])
}

func reviewRoundCount(t *testing.T, database *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM review_rounds`).Scan(&n))
	return n
}

// TestWorkbenchReview_RefreshNeverCreatesARound: --refresh with no open round
// (none yet, or the last one sent) answers an envelope and writes nothing; only
// a plain start opens the next round.
func TestWorkbenchReview_RefreshNeverCreatesARound(t *testing.T) {
	database, wb, s, _ := reviewFixture(t)
	out := reviewJSON(t, wb, "start", "--session", itoa(s), "--refresh")
	assert.Equal(t, false, out["ok"])
	assert.Equal(t, "no open review round", out["error"])
	assert.Equal(t, 0, reviewRoundCount(t, database))

	rid := int64(reviewJSON(t, wb, "start", "--session", itoa(s))["round"].(map[string]any)["id"].(float64))
	reviewJSON(t, wb, "send", "--round", itoa(rid))
	after := reviewJSON(t, wb, "start", "--session", itoa(s), "--refresh")
	assert.Equal(t, false, after["ok"])
	assert.Equal(t, 1, reviewRoundCount(t, database), "refresh after Send created a round")
}

// TestWorkbenchReview_FileOldPathReadsTheRenamedSide: a renamed file's old
// side is read at --old-path.
func TestWorkbenchReview_FileOldPathReadsTheRenamedSide(t *testing.T) {
	_, wb, s, repo := reviewFixture(t)
	require.NoError(t, os.Rename(filepath.Join(repo, "README.md"), filepath.Join(repo, "GUIDE.md")))
	rid := itoa(int64(reviewJSON(t, wb, "start", "--session", itoa(s))["round"].(map[string]any)["id"].(float64)))
	plain := reviewJSON(t, wb, "file", "--round", rid, "--path", "GUIDE.md")
	assert.Equal(t, false, plain["old"].(map[string]any)["exists"])
	renamed := reviewJSON(t, wb, "file", "--round", rid, "--path", "GUIDE.md", "--old-path", "README.md")
	assert.Equal(t, "hello\n", renamed["old"].(map[string]any)["text"])
	assert.Equal(t, "hello\n", renamed["new"].(map[string]any)["text"])
}

// TestWorkbenchReview_CancelledStartPersistsNothing: a start whose context is
// already done answers an envelope and creates no round (never a round on an
// empty-tree base).
func TestWorkbenchReview_CancelledStartPersistsNothing(t *testing.T) {
	database, wb, s, _ := reviewFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	// cobra hands the root's context only to a subcommand without one, and
	// earlier runs left one on start: set it there.
	workbenchReviewStartCmd.SetContext(ctx)
	t.Cleanup(func() { workbenchReviewStartCmd.SetContext(context.Background()) })
	m := reviewJSON(t, wb, "start", "--session", itoa(s))
	assert.Equal(t, false, m["ok"])
	assert.Equal(t, 0, reviewRoundCount(t, database))
}

func TestWorkbenchReviewContext_ReturnsLenses(t *testing.T) {
	_, wb, s, repo := reviewFixture(t)
	none := reviewJSON(t, wb, "context", "--session", itoa(s))
	assert.Len(t, none["lenses"], 5)
	assert.NotContains(t, none, "lens_notes")
	for _, l := range none["lenses"].([]any) {
		if l.(map[string]any)["id"] == "house_rules" {
			assert.Equal(t, []any{}, l.(map[string]any)["items"])
		}
	}

	require.NoError(t, os.MkdirAll(filepath.Join(repo, ".watchtower"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(repo, ".watchtower", "review.md"), []byte("## Tests\n- Extra?\nbad\n"), 0o644))
	got := reviewJSON(t, wb, "context", "--session", itoa(s))
	lenses := got["lenses"].([]any)
	require.Len(t, lenses, 5)
	var items []any
	for _, l := range lenses {
		if l.(map[string]any)["id"] == "tests" {
			items = l.(map[string]any)["items"].([]any)
		}
	}
	require.NotEmpty(t, items)
	assert.Equal(t, "Extra?", items[len(items)-1].(map[string]any)["text"])
	assert.Equal(t, []any{".watchtower/review.md: line 3: not a \"## lens\" heading or a \"- question\""}, got["lens_notes"])
}

func TestWorkbenchReviewStart_InheritsModeFromLastSentRound(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("one\n"), 0o644))
	r1 := reviewJSON(t, wb, "start", "--session", itoa(s))["round"].(map[string]any)
	assert.Equal(t, "quick", r1["mode"])
	id1 := int64(r1["id"].(float64))
	_, err := database.Exec(`UPDATE review_rounds SET mode = 'deep' WHERE id = ?`, id1)
	require.NoError(t, err)
	reviewJSON(t, wb, "send", "--round", itoa(id1))
	require.NoError(t, os.WriteFile(filepath.Join(repo, "x.txt"), []byte("new\n"), 0o644))
	r2 := reviewJSON(t, wb, "start", "--session", itoa(s))["round"].(map[string]any)
	assert.Equal(t, "deep", r2["mode"])
}

func TestWorkbenchReviewStart_ReportsDeepState(t *testing.T) {
	database, wb, s, repo := reviewFixture(t)
	require.NoError(t, os.WriteFile(filepath.Join(repo, "README.md"), []byte("one\n"), 0o644))
	r := reviewJSON(t, wb, "start", "--session", itoa(s))["round"].(map[string]any)
	_, err := database.Exec(`UPDATE review_rounds SET phase = 'chapters', chapter_key = 'dir:cmd', active_seconds = 90 WHERE id = ?`, int64(r["id"].(float64)))
	require.NoError(t, err)
	got := reviewJSON(t, wb, "start", "--session", itoa(s))["round"].(map[string]any)
	assert.Equal(t, "chapters", got["phase"])
	assert.Equal(t, "dir:cmd", got["chapter_key"])
	assert.Equal(t, float64(90), got["active_seconds"])
}
