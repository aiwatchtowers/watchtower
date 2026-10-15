package cmd

import (
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
	out, _, err := runWorkbenchAs(t, "workbench", append([]string{"review", sub, "--workbench", itoa(wb), "--json"}, args...)...)
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
