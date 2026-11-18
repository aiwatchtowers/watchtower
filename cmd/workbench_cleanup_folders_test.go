package cmd

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/sessioncleanup"
	"watchtower/internal/workbenchfolders"
)

// otherFolder adds a second repository beside the fixture's (its own bare
// origin, origin/HEAD set) and puts it on the fixture's bench (#2003).
func (f *cleanupFixture) otherFolder(name string) (string, int64) {
	f.t.Helper()
	dir := filepath.Join(f.base, name)
	f.gitIn(f.base, "init", "-q", "--bare", "-b", "main", name+"-remote.git")
	f.gitIn(f.base, "init", "-q", "-b", "main", name)
	f.commit(dir, "README.md")
	f.gitIn(dir, "remote", "add", "origin", filepath.Join(f.base, name+"-remote.git"))
	f.gitIn(dir, "push", "-q", "-u", "origin", "main")
	f.gitIn(dir, "remote", "set-head", "origin", "main")
	folder, err := workbenchfolders.Add(context.Background(), f.database, f.wb, dir, "", nil)
	require.NoError(f.t, err)
	return dir, folder.ID
}

// placedSessionIn is placedSession in the bench folder dir: the worktree in
// dir's repository, the row started for folder folderID.
func (f *cleanupFixture) placedSessionIn(dir string, folderID int64, slug string) string {
	f.t.Helper()
	root := filepath.Join(dir, ".claude", "worktrees", slug)
	f.gitIn(dir, "worktree", "add", "-q", "-b", "wt/"+slug, root, "main")
	f.commit(root, slug+".txt")
	f.gitIn(root, "push", "-q", "origin", "wt/"+slug)
	_, err := f.database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, created_at, worktree_branch, worktree_base, workbench_folder_id)
		VALUES (?, 'claude', 'placed', ?, ?, ?, ?, 'abc', ?)`, f.wb, root, "p-"+slug,
		time.Now().UTC().Format(time.RFC3339), "wt/"+slug, folderID)
	require.NoError(f.t, err)
	return root
}

func stubWorkbenchInstall(t *testing.T) {
	t.Helper()
	prevRun, prevExe, prevRemove := workbenchCommandRunner, workbenchExecutable, workbenchRemoveInstall
	workbenchCommandRunner = func(context.Context, string, string, ...string) ([]byte, error) { return nil, nil }
	workbenchExecutable = func() (string, error) { return "/usr/local/bin/watchtower", nil }
	workbenchRemoveInstall = func(context.Context, *config.Config, *db.Workbench) error { return nil }
	t.Cleanup(func() {
		workbenchCommandRunner, workbenchExecutable, workbenchRemoveInstall = prevRun, prevExe, prevRemove
	})
}

// TestProj18_DeleteCleansSessionsAcrossFolders: deleting a workbench cleans
// up every placed session's worktree in its own folder's repository, and
// still keeps one with uncommitted work.
func TestProj18_DeleteCleansSessionsAcrossFolders(t *testing.T) {
	f := newCleanupFixture(t)
	stubWorkbenchInstall(t)
	hub, hubID := f.otherFolder("hub")
	home := f.placedSession("c")
	inHub := f.placedSessionIn(hub, hubID, "h")
	dirty := f.placedSessionIn(hub, hubID, "d")
	require.NoError(t, os.WriteFile(filepath.Join(dirty, "README.md"), []byte("edited\n"), 0o644))

	out, _, err := runWorkbench(t, "delete", strconv.FormatInt(f.wb, 10), "--json")
	require.NoError(t, err, out)
	var res struct {
		KeptWorktrees []string `json:"kept_worktrees"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &res), out)
	assert.NoDirExists(t, home)
	assert.NoDirExists(t, inHub)
	assert.DirExists(t, dirty)
	assert.Equal(t, []string{dirty}, res.KeptWorktrees)
	f.gitIn(hub, "rev-parse", "--verify", "-q", "refs/heads/wt/d") // a kept worktree keeps its branch
	gone := exec.Command(f.git, "rev-parse", "--verify", "-q", "refs/heads/wt/h")
	gone.Dir = hub
	assert.Error(t, gone.Run(), "the hub session's branch goes with its worktree")
}

// TestProj18_SweepCommandCoversEveryFolder: the Desktop's sweep of the
// workbench lists the work of every folder on the bench; a branch of a
// folder other than home carries its folder in its key, and applying that
// key acts in that folder's repository.
func TestProj18_SweepCommandCoversEveryFolder(t *testing.T) {
	f := newCleanupFixture(t)
	hub, _ := f.otherFolder("hub")
	root := filepath.Join(f.base, "hub-wt")
	f.gitIn(hub, "worktree", "add", "-q", "-b", "feat/h", root, "main")
	f.commit(root, "h.txt")
	f.gitIn(root, "push", "-q", "origin", "feat/h")
	wb := strconv.FormatInt(f.wb, 10)
	key := "branch:" + hub + ":feat/h"

	out, err := runCleanupCmd(t, "--workbench", wb, "--sweep", "--json", "--no-size")
	require.NoError(t, err, out)
	res := decodeCleanup(t, out)
	assert.Equal(t, sessioncleanup.ActionRemove, cleanupItem(t, res, "worktree:"+root).Action, out)
	assert.Equal(t, sessioncleanup.ActionRemove, cleanupItem(t, res, key).Action, out)

	out, err = runCleanupCmd(t, "--workbench", wb, "--sweep", "--apply", "--item", "worktree:"+root, "--item", key, "--json")
	require.NoError(t, err, out)
	res = decodeCleanup(t, out)
	assert.True(t, cleanupItem(t, res, "worktree:"+root).Done, out)
	assert.True(t, cleanupItem(t, res, key).Done, out)
	assert.NoDirExists(t, root)
}
