package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/kb"
	"watchtower/internal/workbenchfiles"
	"watchtower/internal/workbenchfolders"
)

// mergeFixture is folderFixture (bench "acme" on app) plus bench "tools" on
// its own folder, installed for its own id, and no session host asked.
type mergeFixture struct {
	folderFixture
	tools    int64
	toolsDir string
}

func newMergeFixture(t *testing.T) mergeFixture {
	t.Helper()
	f := newFolderFixture(t)
	prev := mergeLiveSessions
	mergeLiveSessions = func(*config.Config, *db.DB) workbenchfolders.LiveBenchSessions {
		return func(context.Context, int64) (int, error) { return 0, nil }
	}
	t.Cleanup(func() { mergeLiveSessions = prev })
	toolsDir := plainDir(t, "tools")
	require.NoError(t, os.MkdirAll(filepath.Join(toolsDir, ".git", "info"), 0o755))
	tools, err := f.database.CreateWorkbench("tools", toolsDir)
	require.NoError(t, err)
	b, err := f.database.GetWorkbench(tools)
	require.NoError(t, err)
	require.NoError(t, folderInstall(context.Background(), b))
	return mergeFixture{folderFixture: f, tools: tools, toolsDir: toolsDir}
}

func (f mergeFixture) merge(t *testing.T) workbenchMergeJSON {
	t.Helper()
	out, errOut, err := runWorkbench(t, "merge", "--from", strconv.FormatInt(f.tools, 10), "--into", f.id(), "--json")
	require.NoError(t, err, errOut)
	var res workbenchMergeJSON
	require.NoError(t, json.Unmarshal([]byte(out), &res), out)
	return res
}

func installedIDs(t *testing.T, dir string) []int64 {
	t.Helper()
	ids, err := devpack.InstalledWorkbenchIDs(dir)
	require.NoError(t, err)
	return ids
}

// The moved folder is reinstalled with A's id; B's install there is
// replaced, not left beside it (spec §6.13, PROJ-04); B leaves the list.
func TestWorkbenchMergeMovesAndReinstalls(t *testing.T) {
	f := newMergeFixture(t)
	require.Equal(t, []int64{f.tools}, installedIDs(t, f.toolsDir))

	res := f.merge(t)
	require.True(t, res.OK, res.Error)
	assert.True(t, res.Reinstall.OK)
	assert.Empty(t, res.Reinstall.Failed)
	require.Len(t, res.MovedFolders, 1)
	assert.Equal(t, folderJSON{ID: res.MovedFolders[0].ID, Path: f.toolsDir, Name: "tools", Position: 1, Installed: true}, res.MovedFolders[0])
	assert.Equal(t, []int64{f.pid}, installedIDs(t, f.toolsDir), "A's install only")
	_, err := f.database.GetWorkbench(f.tools)
	assert.ErrorIs(t, err, db.ErrWorkbenchNotFound)
}

// Spec §7: a failed reinstall keeps the data where it moved; the folder is
// named in reinstall.failed (the Desktop shows the install icon + Retry).
func TestMergeReinstallFailureKeepsTheData(t *testing.T) {
	f := newMergeFixture(t)
	tid := insertMergeTarget(t, f.database, f.tools)
	prev := folderInstall
	folderInstall = func(context.Context, *db.Workbench) error { return errors.New("disk is read-only") }
	t.Cleanup(func() { folderInstall = prev })

	res := f.merge(t)
	require.True(t, res.OK, res.Error)
	assert.Equal(t, 1, res.Targets)
	assert.False(t, res.Reinstall.OK)
	assert.Equal(t, []mergeFailedJSON{{Path: f.toolsDir, Error: "disk is read-only"}}, res.Reinstall.Failed)
	var wb int64
	require.NoError(t, f.database.QueryRow(`SELECT project_id FROM targets WHERE id = ?`, tid).Scan(&wb))
	assert.Equal(t, f.pid, wb, "the data is in A")
}

// F20: B's index rows (wbdoc:<B>:…) go after the commit; nothing of B is left
// to show in search.
func TestMergeDropsTheOldBenchsDocRows(t *testing.T) {
	f := newMergeFixture(t)
	require.NoError(t, os.RemoveAll(filepath.Join(f.toolsDir, ".git"))) // listed by a walk, not git
	require.NoError(t, os.WriteFile(filepath.Join(f.toolsDir, "README.md"), []byte("# tools\nkestrel\n"), 0o644))
	ctx := context.Background()
	_, _, err := kb.IndexWorkbenchDocs(ctx, f.database, f.tools)
	require.NoError(t, err)
	count := func() int {
		var n int
		require.NoError(t, f.database.QueryRow(`SELECT COUNT(*) FROM kb_documents WHERE id LIKE ?`,
			"wbdoc:"+strconv.FormatInt(f.tools, 10)+":%").Scan(&n))
		return n
	}
	require.Equal(t, 1, count())

	require.True(t, f.merge(t).OK)
	assert.Zero(t, count())
}

func TestWorkbenchMergeRefusedWhileSessionsRun(t *testing.T) {
	f := newMergeFixture(t)
	home, err := f.database.HomeFolder(context.Background(), f.tools)
	require.NoError(t, err)
	for range 2 {
		_, err = f.database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, workbench_folder_id)
			VALUES (?, 'claude', 'work', ?, 'sid', ?)`, f.tools, home.FolderPath, home.ID)
		require.NoError(t, err)
	}

	res := f.merge(t)
	assert.False(t, res.OK)
	assert.Equal(t, workbenchfolders.CodeSessionsRunning, res.ErrorCode)
	assert.Equal(t, 2, res.Running)
	assert.Equal(t, "sessions_running: 2 sessions are running in tools. Finish them first.", res.Error)
	assert.NotNil(t, res.MovedFolders)
	_, err = f.database.GetWorkbench(f.tools)
	require.NoError(t, err, "nothing moved")
}

func TestWorkbenchMergeRefusedUnderAnAgent(t *testing.T) {
	f := newMergeFixture(t)
	t.Setenv(agentEnvMarkers[0], "1")
	_, _, err := runWorkbench(t, "merge", "--from", strconv.FormatInt(f.tools, 10), "--into", f.id(), "--json")
	require.Error(t, err)
}

// The merged bench's target images move to A's store, their rows follow,
// and B's store directory goes (PROJ-02 for A's later delete).
func TestWorkbenchMergeMovesTheTargetImages(t *testing.T) {
	f := newMergeFixture(t)
	tid := insertMergeTarget(t, f.database, f.tools)
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	store := workbenchfiles.New(cfg.WorkspaceDir())
	require.NoError(t, os.MkdirAll(store.Dir(f.tools), 0o700))
	src := filepath.Join(store.Dir(f.tools), "abc.png")
	require.NoError(t, os.WriteFile(src, []byte("png"), 0o600))
	res, err := f.database.Exec(`INSERT INTO project_target_images (project_id, target_id, file_name, mime, size, sha256, path)
		VALUES (?, ?, 'shot.png', 'image/png', 3, 'abc', ?)`, f.tools, tid, src)
	require.NoError(t, err)
	img, err := res.LastInsertId()
	require.NoError(t, err)

	require.True(t, f.merge(t).OK)
	var path string
	require.NoError(t, f.database.QueryRow(`SELECT path FROM project_target_images WHERE id = ?`, img).Scan(&path))
	assert.Equal(t, filepath.Join(store.Dir(f.pid), "abc.png"), path)
	assert.FileExists(t, path)
	assert.NoDirExists(t, store.Dir(f.tools))
}

func insertMergeTarget(t *testing.T, database *db.DB, wb int64) int64 {
	t.Helper()
	res, err := database.Exec(`INSERT INTO targets (text, period_start, period_end, status, project_id)
		VALUES ('ship it', '2026-11-01', '2026-11-30', 'todo', ?)`, wb)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

// The Desktop's launch backstop (resume, Start fresh): a session whose
// folder still carries the merged bench's install is reinstalled for its
// row's bench.
func TestWorkbenchSessionEnsureInstallReinstallsAMergedFolder(t *testing.T) {
	f := newMergeFixture(t)
	gone := f.tools
	res := f.merge(t)
	require.True(t, res.OK)
	// A worktree of the merged bench the merge did not know about.
	wt := plainDir(t, "wt")
	require.NoError(t, os.MkdirAll(filepath.Join(wt, ".git", "info"), 0o755))
	_, err := devpack.InstallStateHooks(wt, folderTestBin, gone)
	require.NoError(t, err)
	r, err := f.database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 'work', ?, 'sid')`, f.pid, wt)
	require.NoError(t, err)
	sid, err := r.LastInsertId()
	require.NoError(t, err)

	out, errOut, err := runWorkbench(t, "session", "ensure-install", "--session", strconv.FormatInt(sid, 10), "--json")
	resetSetFlags(workbenchSessionCmd.Commands()...)
	require.NoError(t, err, errOut)
	var got sessionEnsureInstallJSON
	require.NoError(t, json.Unmarshal([]byte(out), &got), out)
	assert.Equal(t, sessionEnsureInstallJSON{OK: true, Reinstalled: true}, got)
	assert.Equal(t, []int64{f.pid}, installedIDs(t, wt), "the gone bench's hooks are replaced")
}
