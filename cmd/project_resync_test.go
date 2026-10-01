package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/kb"
)

func runResync(t *testing.T, args ...string) (string, string, error) {
	t.Helper()
	return runProject(t, append([]string{"resync"}, args...)...)
}

func decodeResync(t *testing.T, out string) projectResyncJSON {
	t.Helper()
	var res projectResyncJSON
	require.NoError(t, json.Unmarshal([]byte(out), &res), out)
	return res
}

// resyncFolder is a git-shaped project folder holding a README and a spec;
// the watchtower path recorded in hooks is stubbed (looksLikeOurHook keys
// on the basename).
func resyncFolder(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(dir, ".git", "info"), 0o755))
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "docs", "specs"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "README.md"), []byte("# acme\n"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "docs", "specs", "a.md"), []byte("# spec a\n"), 0o600))
	prev := projectExecutable
	projectExecutable = func() (string, error) { return "/usr/local/bin/watchtower", nil }
	t.Cleanup(func() { projectExecutable = prev })
	folder, err := db.ResolveProjectFolder(dir, nil)
	require.NoError(t, err)
	return folder
}

// dumpRows renders every row the query returns, column by column, so a test
// can compare a table's project rows byte for byte.
func dumpRows(t *testing.T, d *db.DB, query string, args ...any) []string {
	t.Helper()
	rows, err := d.Query(query, args...)
	require.NoError(t, err)
	defer rows.Close()
	cols, err := rows.Columns()
	require.NoError(t, err)
	var out []string
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		require.NoError(t, rows.Scan(ptrs...))
		out = append(out, fmt.Sprintf("%q", vals))
	}
	require.NoError(t, rows.Err())
	return out
}

// projectSnapshot is every owner- or agent-authored row of the project.
func projectSnapshot(t *testing.T, d *db.DB, pid int64) map[string][]string {
	t.Helper()
	return map[string][]string{
		"project":   dumpRows(t, d, `SELECT * FROM projects WHERE id = ?`, pid),
		"targets":   dumpRows(t, d, `SELECT * FROM targets WHERE project_id = ? ORDER BY id`, pid),
		"history":   dumpRows(t, d, `SELECT h.* FROM target_status_history h JOIN targets t ON t.id = h.target_id WHERE t.project_id = ? ORDER BY h.id`, pid),
		"comments":  dumpRows(t, d, `SELECT * FROM project_comments WHERE project_id = ? ORDER BY id`, pid),
		"sources":   dumpRows(t, d, `SELECT * FROM project_sources WHERE project_id = ? ORDER BY id`, pid),
		"documents": dumpRows(t, d, `SELECT * FROM project_documents WHERE project_id = ? ORDER BY id`, pid),
		"images":    dumpRows(t, d, `SELECT * FROM project_target_images WHERE project_id = ? ORDER BY id`, pid),
	}
}

func TestProjectResync_IsAdditive(t *testing.T) {
	f := useFakeProjectClaude(t)
	database := writeActionsConfig(t)
	folder := resyncFolder(t)
	pid, err := database.CreateProject("acme", folder)
	require.NoError(t, err)

	// An existing project: an owner-edited description, a source, a board
	// with statuses, a comment and an attached document.
	desc := "Owner's own words."
	require.NoError(t, database.UpdateProject(pid, db.ProjectUpdate{Description: &desc}))
	_, err = database.AddProjectSource(db.ProjectSource{ProjectID: pid, Kind: "jira_project", Ref: "ACME"})
	require.NoError(t, err)
	tid := db.SeedTestProjectTarget(t, database, pid, sql.NullInt64{}, "Ship it")
	require.NoError(t, database.UpdateTargetStatus(int(tid), "in_progress"))
	require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
		_, err := db.AddProjectTargetImageTx(tx, db.ProjectTargetImage{ProjectID: pid, TargetID: tid,
			FileName: "a.png", MIME: "image/png", Size: 3, SHA256: "abc", Path: "/store/a.png"})
		return err
	}))
	_, err = database.AddProjectComment(db.ProjectComment{ProjectID: pid, TargetID: sql.NullInt64{Int64: tid, Valid: true}, Author: "owner", Body: "keep it small"})
	require.NoError(t, err)
	_, _, err = database.UpsertProjectDocument(db.ProjectDocument{ProjectID: pid, RelPath: "README.md", Kind: "doc", Title: "Edited title"})
	require.NoError(t, err)
	before := projectSnapshot(t, database, pid)

	out, _, err := runResync(t, strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	res := decodeResync(t, out)
	assert.True(t, res.DocsOK, res.DocsError)
	assert.Equal(t, []string{"docs/specs/a.md"}, res.Docs.Imported, "only the unattached spec is new")
	assert.Equal(t, []string{"README.md"}, res.Docs.AlreadyAttached)
	assert.True(t, res.IntegrationOK, res.IntegrationError)
	assert.Equal(t, string(devpack.StateInstalled), res.Skill)
	assert.True(t, res.HooksAdded)
	assert.True(t, res.MCPRegistered)
	assert.True(t, f.registered[folder])
	assert.Empty(t, res.MCPCommand)
	require.Len(t, res.Suggestions, 1)
	assert.Contains(t, res.Suggestions[0], "1 new document(s)")
	assert.True(t, res.IndexOK, res.IndexError)
	assert.Equal(t, 2, res.Indexed, "both attached documents are now searchable")
	hits, err := kb.Search(context.Background(), database, kb.Request{Queries: []string{"spec"}, ProjectID: pid})
	require.NoError(t, err)
	require.Len(t, hits.Hits, 1, "the new spec is searchable from the project's session at once")
	assert.Equal(t, kb.ProjectDocSource, hits.Hits[0].Source)

	after := projectSnapshot(t, database, pid)
	for _, table := range []string{"project", "targets", "history", "comments", "sources", "images"} {
		assert.Equal(t, before[table], after[table], "%s rows are untouched", table)
	}
	require.Len(t, after["images"], 1, "fixture: the snapshot covers an image row")
	require.Len(t, after["documents"], 2)
	assert.Equal(t, before["documents"][0], after["documents"][0], "the attached document is untouched")
	assert.Contains(t, after["documents"][1], "docs/specs/a.md")

	// A second run finds everything in place and changes nothing.
	out, _, err = runResync(t, strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	res = decodeResync(t, out)
	assert.Empty(t, res.Docs.Imported)
	assert.Equal(t, string(devpack.StateUnchanged), res.Skill)
	assert.False(t, res.HooksAdded)
	assert.Empty(t, res.Excluded)
	assert.Empty(t, res.Suggestions)
	assert.Zero(t, res.Indexed, "nothing changed: the index is not rewritten")
	assert.Equal(t, after, projectSnapshot(t, database, pid))
}

func TestProjectResync_ReinstallsMissingPiecesAndKeepsAnEditedSkill(t *testing.T) {
	useFakeProjectClaude(t)
	database := writeActionsConfig(t)
	folder := resyncFolder(t)
	pid, err := database.CreateProject("acme", folder)
	require.NoError(t, err)
	id := strconv.FormatInt(pid, 10)
	_, _, err = runResync(t, id, "--json")
	require.NoError(t, err)

	// The hooks file is gone: re-added.
	require.NoError(t, os.Remove(filepath.Join(folder, ".claude", "settings.local.json")))
	out, _, err := runResync(t, id, "--json")
	require.NoError(t, err)
	assert.True(t, decodeResync(t, out).HooksAdded)

	// The owner edited the skill: left alone and reported (PROJ-04).
	skill := filepath.Join(folder, ".claude", "skills", devpack.ProjectSkillName, "SKILL.md")
	body, err := os.ReadFile(skill)
	require.NoError(t, err)
	edited := append(body, []byte("\nMy own rule.\n")...)
	require.NoError(t, os.WriteFile(skill, edited, 0o600))
	out, _, err = runResync(t, id, "--json")
	require.NoError(t, err)
	assert.Equal(t, string(devpack.StateDrifted), decodeResync(t, out).Skill)
	got, err := os.ReadFile(skill)
	require.NoError(t, err)
	assert.Equal(t, edited, got)
}

func TestProjectResync_EmptyProjectSuggestsSetupWithoutCreatingTargets(t *testing.T) {
	useFakeProjectClaude(t)
	database := writeActionsConfig(t)
	pid, err := database.CreateProject("acme", resyncFolder(t))
	require.NoError(t, err)
	out, _, err := runResync(t, strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	res := decodeResync(t, out)
	joined := strings.Join(res.Suggestions, "\n")
	assert.Contains(t, joined, "no description yet")
	assert.Contains(t, joined, "no sources")
	assert.Contains(t, joined, "board is empty")
	board, err := database.GetProjectBoard(pid)
	require.NoError(t, err)
	assert.Empty(t, board, "resync never creates targets")
}

// A failed step does not stop the other; --json exits 0 and says which
// step failed, the text form exits non-zero.
func TestProjectResync_FailedStepIsReported(t *testing.T) {
	prev := projectCommandRunner
	projectCommandRunner = func(context.Context, string, string, ...string) ([]byte, error) {
		return nil, devpack.ErrClaudeNotFound
	}
	t.Cleanup(func() { projectCommandRunner = prev })
	database := writeActionsConfig(t)
	pid, err := database.CreateProject("acme", resyncFolder(t))
	require.NoError(t, err)
	id := strconv.FormatInt(pid, 10)

	out, _, err := runResync(t, id, "--json")
	require.NoError(t, err)
	res := decodeResync(t, out)
	assert.True(t, res.DocsOK, "documents are attached even though the integration failed")
	assert.Equal(t, []string{"README.md", "docs/specs/a.md"}, res.Docs.Imported)
	assert.False(t, res.IntegrationOK)
	assert.NotEmpty(t, res.IntegrationError)
	assert.False(t, res.MCPRegistered)
	assert.Contains(t, res.MCPCommand, "claude mcp add --scope local "+devpack.ProjectMCPServerName)
	assert.Equal(t, string(devpack.StateInstalled), res.Skill, "the skill was still installed")

	out, _, err = runResync(t, id)
	require.Error(t, err)
	assert.True(t, errors.Is(err, devpack.ErrClaudeNotFound), "%v", err)
	assert.Contains(t, out, "mcp      NOT registered — run:")
	assert.Contains(t, out, "FAILED")
}

func TestProjectResync_RequiresAProject(t *testing.T) {
	writeActionsConfig(t)
	_, _, err := runResync(t)
	require.Error(t, err)
	_, _, err = runResync(t, "99")
	require.ErrorContains(t, err, "project 99")
}

// An unreadable docs/ fails the import step; the install still runs and the
// envelope carries the failure without a docs report.
func TestProjectResync_FailedImportStillInstalls(t *testing.T) {
	f := useFakeProjectClaude(t)
	database := writeActionsConfig(t)
	folder := resyncFolder(t)
	pid, err := database.CreateProject("acme", folder)
	require.NoError(t, err)
	docs := filepath.Join(folder, "docs")
	require.NoError(t, os.Chmod(docs, 0o000))
	t.Cleanup(func() { _ = os.Chmod(docs, 0o755) })
	id := strconv.FormatInt(pid, 10)

	out, _, err := runResync(t, id, "--json")
	require.NoError(t, err)
	assert.NotContains(t, out, `"docs":`, "no report for a failed import")
	res := decodeResync(t, out)
	assert.False(t, res.DocsOK)
	assert.NotEmpty(t, res.DocsError)
	assert.True(t, res.IntegrationOK, res.IntegrationError)
	assert.True(t, f.registered[folder])

	out, _, err = runResync(t, id)
	require.Error(t, err)
	assert.Contains(t, out, "re-synced with errors")
	assert.Contains(t, out, "Documents: FAILED")
	assert.Contains(t, out, "retry: watchtower project resync "+id)
}

// A failed read behind the suggestions is reported, not an empty list
// passed off as "nothing to suggest".
func TestProjectResync_SuggestionsErrorIsReported(t *testing.T) {
	useFakeProjectClaude(t)
	database := writeActionsConfig(t)
	pid, err := database.CreateProject("acme", resyncFolder(t))
	require.NoError(t, err)
	p, err := database.GetProject(pid)
	require.NoError(t, err)
	_, err = database.Exec(`DROP TABLE project_sources`)
	require.NoError(t, err)

	res, err := resyncProject(context.Background(), database, p, true)
	require.Error(t, err)
	assert.True(t, res.DocsOK)
	assert.True(t, res.IntegrationOK)
	assert.Contains(t, res.SuggestionsError, "listing sources")
	assert.True(t, res.failed())
}

func TestProjectResync_SkipsTheIndexWhenKnowledgeSearchIsOff(t *testing.T) {
	useFakeProjectClaude(t)
	database := writeActionsConfig(t)
	pid, err := database.CreateProject("acme", resyncFolder(t))
	require.NoError(t, err)
	p, err := database.GetProject(pid)
	require.NoError(t, err)

	res, err := resyncProject(context.Background(), database, p, false)
	require.NoError(t, err)
	assert.True(t, res.IndexOK)
	assert.True(t, res.IndexSkipped)
	assert.Zero(t, res.Indexed)
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM kb_documents`).Scan(&n))
	assert.Zero(t, n, "knowledge search off: nothing indexed (FEAT-01)")
}
