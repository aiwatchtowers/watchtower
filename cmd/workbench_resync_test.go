package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/gitbin"
	"watchtower/internal/kb"
)

func runResync(t *testing.T, args ...string) (string, string, error) {
	t.Helper()
	return runWorkbench(t, append([]string{"resync"}, args...)...)
}

func decodeResync(t *testing.T, out string) workbenchResyncJSON {
	t.Helper()
	var res workbenchResyncJSON
	require.NoError(t, json.Unmarshal([]byte(out), &res), out)
	return res
}

// resyncFolder is a git repository holding a README and a spec (a bare
// .git/info when no git is installed: the text-file listing then walks the
// folder); the watchtower path recorded in hooks is stubbed
// (looksLikeOurHook keys on the basename).
func resyncFolder(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(dir, ".git", "info"), 0o755))
	if bin, ok := gitbin.Locate(); ok {
		c := exec.Command(bin, "init", "-q")
		c.Dir = dir
		out, err := c.CombinedOutput()
		require.NoError(t, err, "git init: %s", out)
	}
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "docs", "specs"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "README.md"), []byte("# acme\n"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "docs", "specs", "a.md"), []byte("# spec a\n"), 0o600))
	prev := workbenchExecutable
	workbenchExecutable = func() (string, error) { return "/usr/local/bin/watchtower", nil }
	t.Cleanup(func() { workbenchExecutable = prev })
	folder, err := db.ResolveWorkbenchFolder(dir, nil)
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

// workbenchSnapshot is every owner- or agent-authored row of the project.
func workbenchSnapshot(t *testing.T, d *db.DB, pid int64) map[string][]string {
	t.Helper()
	return map[string][]string{
		"project":  dumpRows(t, d, `SELECT * FROM projects WHERE id = ?`, pid),
		"targets":  dumpRows(t, d, `SELECT * FROM targets WHERE project_id = ? ORDER BY id`, pid),
		"history":  dumpRows(t, d, `SELECT h.* FROM target_status_history h JOIN targets t ON t.id = h.target_id WHERE t.project_id = ? ORDER BY h.id`, pid),
		"comments": dumpRows(t, d, `SELECT * FROM project_comments WHERE project_id = ? ORDER BY id`, pid),
		"sources":  dumpRows(t, d, `SELECT * FROM project_sources WHERE project_id = ? ORDER BY id`, pid),
		"images":   dumpRows(t, d, `SELECT * FROM project_target_images WHERE project_id = ? ORDER BY id`, pid),
	}
}

func TestProjectResync_IsAdditive(t *testing.T) {
	f := useFakeWorkbenchClaude(t)
	database := writeActionsConfig(t)
	folder := resyncFolder(t)
	pid, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)

	// An existing project: an owner-edited description, a source, a board
	// with statuses, an image and a comment.
	require.NoError(t, database.UpdateWorkbenchDescription(pid, "Owner's own words."))
	_, err = database.AddWorkbenchSource(db.WorkbenchSource{WorkbenchID: pid, Kind: "jira_project", Ref: "ACME"})
	require.NoError(t, err)
	tid := db.SeedTestWorkbenchTarget(t, database, pid, sql.NullInt64{}, "Ship it")
	require.NoError(t, database.UpdateTargetStatus(int(tid), "in_progress"))
	require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
		_, err := db.AddWorkbenchTargetImageTx(tx, db.WorkbenchTargetImage{WorkbenchID: pid, TargetID: tid,
			FileName: "a.png", MIME: "image/png", Size: 3, SHA256: "abc", Path: "/store/a.png"})
		return err
	}))
	_, err = database.AddWorkbenchComment(db.WorkbenchComment{WorkbenchID: pid, TargetID: sql.NullInt64{Int64: tid, Valid: true}, Author: "owner", Body: "keep it small"})
	require.NoError(t, err)
	before := workbenchSnapshot(t, database, pid)

	out, _, err := runResync(t, strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	res := decodeResync(t, out)
	assert.True(t, res.IntegrationOK, res.IntegrationError)
	assert.Equal(t, string(devpack.StateInstalled), res.Skill)
	assert.True(t, res.HooksAdded)
	assert.True(t, res.MCPRegistered)
	assert.True(t, f.registered[fakeRegistration(folder, devpack.WorkbenchMCPServerName)])
	assert.Empty(t, res.MCPCommand)
	assert.Empty(t, res.Suggestions, "set up, with a source and a board: nothing to suggest")
	assert.True(t, res.IndexOK, res.IndexError)
	assert.Empty(t, res.IndexError)
	assert.Equal(t, 2, res.Indexed, "both text files of the folder are now searchable")
	hits, err := kb.Search(context.Background(), database, kb.Request{Queries: []string{"spec"}, WorkbenchID: pid})
	require.NoError(t, err)
	require.Len(t, hits.Hits, 1, "the spec is searchable from the project's session at once")
	assert.Equal(t, kb.WorkbenchDocSource, hits.Hits[0].Source)

	after := workbenchSnapshot(t, database, pid)
	for _, table := range []string{"project", "targets", "history", "comments", "sources", "images"} {
		assert.Equal(t, before[table], after[table], "%s rows are untouched", table)
	}
	require.Len(t, after["images"], 1, "fixture: the snapshot covers an image row")
	require.Len(t, after["comments"], 1, "fixture: the snapshot covers a comment row")

	// A second run finds everything in place and changes nothing.
	out, _, err = runResync(t, strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	res = decodeResync(t, out)
	assert.True(t, res.IndexOK, res.IndexError)
	assert.Equal(t, string(devpack.StateUnchanged), res.Skill)
	assert.False(t, res.HooksAdded)
	assert.Empty(t, res.Excluded)
	assert.Empty(t, res.Suggestions)
	assert.Zero(t, res.Indexed, "nothing changed: the index is not rewritten")
	assert.Equal(t, after, workbenchSnapshot(t, database, pid))
}

// A folder set up before the session state hooks existed (SessionStart and
// Stop only) gets them on its next resync, reported as hooks_added; a second
// resync adds nothing.
func TestWorkbenchResync_AddsTheStateHooksToAnOlderInstall(t *testing.T) {
	useFakeWorkbenchClaude(t)
	database := writeActionsConfig(t)
	folder := resyncFolder(t)
	pid, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	id := strconv.FormatInt(pid, 10)
	_, _, err = runResync(t, id, "--json")
	require.NoError(t, err)
	changed, err := devpack.RemoveStateHooks(folder, pid)
	require.NoError(t, err)
	require.True(t, changed, "fixture: the state hooks were installed")
	has, err := devpack.HasStateHooks(folder, pid)
	require.NoError(t, err)
	require.False(t, has)

	out, _, err := runResync(t, id, "--json")
	require.NoError(t, err)
	assert.True(t, decodeResync(t, out).HooksAdded)
	has, err = devpack.HasStateHooks(folder, pid)
	require.NoError(t, err)
	assert.True(t, has)

	out, _, err = runResync(t, id, "--json")
	require.NoError(t, err)
	assert.False(t, decodeResync(t, out).HooksAdded)
}

func TestProjectResync_ReinstallsMissingPiecesAndKeepsAnEditedSkill(t *testing.T) {
	useFakeWorkbenchClaude(t)
	database := writeActionsConfig(t)
	folder := resyncFolder(t)
	pid, err := database.CreateWorkbench("acme", folder)
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
	skill := filepath.Join(folder, ".claude", "skills", devpack.WorkbenchSkillName, "SKILL.md")
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
	useFakeWorkbenchClaude(t)
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", resyncFolder(t))
	require.NoError(t, err)
	out, _, err := runResync(t, strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	res := decodeResync(t, out)
	joined := strings.Join(res.Suggestions, "\n")
	assert.Contains(t, joined, "no description yet")
	assert.Contains(t, joined, "no sources")
	assert.Contains(t, joined, "board is empty")
	board, err := database.GetWorkbenchBoard(pid)
	require.NoError(t, err)
	assert.Empty(t, board, "resync never creates targets")
}

// A failed step does not stop the other; --json exits 0 and says which
// step failed, the text form exits non-zero.
func TestProjectResync_FailedStepIsReported(t *testing.T) {
	prev := workbenchCommandRunner
	workbenchCommandRunner = func(context.Context, string, string, ...string) ([]byte, error) {
		return nil, devpack.ErrClaudeNotFound
	}
	t.Cleanup(func() { workbenchCommandRunner = prev })
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", resyncFolder(t))
	require.NoError(t, err)
	id := strconv.FormatInt(pid, 10)

	out, _, err := runResync(t, id, "--json")
	require.NoError(t, err)
	res := decodeResync(t, out)
	assert.True(t, res.IndexOK, "the folder is indexed even though the integration failed: %s", res.IndexError)
	assert.Equal(t, 2, res.Indexed)
	assert.False(t, res.IntegrationOK)
	assert.NotEmpty(t, res.IntegrationError)
	assert.False(t, res.MCPRegistered)
	assert.Contains(t, res.MCPCommand, "claude mcp add --scope local "+devpack.WorkbenchMCPServerName)
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
	require.ErrorContains(t, err, "workbench 99")
}

// A git failure fails the index step — reported in index_error, never an
// empty listing that would drop the folder's entries; the install still
// runs and the resync is not failed by it in --json.
func TestProjectResync_FailedIndexStillInstalls(t *testing.T) {
	if _, ok := gitbin.Locate(); !ok {
		t.Skip("no git installed: the listing walks the folder and cannot fail this way")
	}
	f := useFakeWorkbenchClaude(t)
	database := writeActionsConfig(t)
	folder := resyncFolder(t)
	pid, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	id := strconv.FormatInt(pid, 10)
	out, _, err := runResync(t, id, "--json")
	require.NoError(t, err)
	require.Equal(t, 2, decodeResync(t, out).Indexed, "fixture: the folder is indexed")

	// A broken repository: git refuses every command in it.
	require.NoError(t, os.WriteFile(filepath.Join(folder, ".git", "HEAD"), []byte("garbage\n"), 0o600))
	out, _, err = runResync(t, id, "--json")
	require.NoError(t, err)
	res := decodeResync(t, out)
	assert.False(t, res.IndexOK)
	assert.NotEmpty(t, res.IndexError)
	assert.True(t, res.IntegrationOK, res.IntegrationError)
	assert.True(t, f.registered[fakeRegistration(folder, devpack.WorkbenchMCPServerName)])
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM kb_documents WHERE source = ?`, kb.WorkbenchDocSource).Scan(&n))
	assert.Equal(t, 2, n, "a failed listing keeps the folder's index entries")

	out, _, err = runResync(t, id)
	require.Error(t, err)
	assert.Contains(t, out, "re-synced with errors")
	assert.Contains(t, out, "Search index: FAILED")
	assert.Contains(t, out, "retry: watchtower workbench resync "+id)
}

// A failed read behind the suggestions is reported, not an empty list
// passed off as "nothing to suggest".
func TestProjectResync_SuggestionsErrorIsReported(t *testing.T) {
	useFakeWorkbenchClaude(t)
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", resyncFolder(t))
	require.NoError(t, err)
	p, err := database.GetWorkbench(pid)
	require.NoError(t, err)
	_, err = database.Exec(`DROP TABLE project_sources`)
	require.NoError(t, err)

	res, err := resyncWorkbench(context.Background(), database, p, true)
	require.Error(t, err)
	assert.True(t, res.IndexOK, res.IndexError)
	assert.True(t, res.IntegrationOK)
	assert.Contains(t, res.SuggestionsError, "listing sources")
	assert.True(t, res.failed())
}

func TestProjectResync_SkipsTheIndexWhenKnowledgeSearchIsOff(t *testing.T) {
	useFakeWorkbenchClaude(t)
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", resyncFolder(t))
	require.NoError(t, err)
	p, err := database.GetWorkbench(pid)
	require.NoError(t, err)

	res, err := resyncWorkbench(context.Background(), database, p, false)
	require.NoError(t, err)
	assert.True(t, res.IndexOK)
	assert.True(t, res.IndexSkipped)
	assert.Zero(t, res.Indexed)
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM kb_documents`).Scan(&n))
	assert.Zero(t, n, "knowledge search off: nothing indexed (FEAT-01)")
}
