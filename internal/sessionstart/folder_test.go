package sessionstart

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/workbenchfolders"
)

// addFolder puts a new git repository on the world's bench as a second
// folder, with Watchtower's hooks installed in it when installed.
func (w *world) addFolder(installed bool) db.WorkbenchFolder {
	w.t.Helper()
	f, err := workbenchfolders.Add(context.Background(), w.db, w.wb, newRepo(w.t, true), workbenchfolders.AddedByOwner, nil)
	require.NoError(w.t, err)
	if installed {
		_, err := devpack.InstallStateHooks(f.FolderPath, "/usr/local/bin/watchtower", w.wb)
		require.NoError(w.t, err)
	}
	return f
}

// folderOf is the row's workbench_folder_id and parent_session_id.
func (w *world) folderOf(id int64) (folder, parent sql.NullInt64) {
	w.t.Helper()
	require.NoError(w.t, w.db.QueryRow(`SELECT workbench_folder_id, parent_session_id FROM terminal_sessions WHERE id = ?`, id).
		Scan(&folder, &parent))
	return folder, parent
}

func (w *world) rowCount() int {
	w.t.Helper()
	var n int
	require.NoError(w.t, w.db.QueryRow(`SELECT COUNT(*) FROM terminal_sessions`).Scan(&n))
	return n
}

// requireRefusal asserts err is a *workbenchfolders.Refusal with code.
func requireRefusal(t *testing.T, err error, code string) {
	t.Helper()
	var r *workbenchfolders.Refusal
	require.True(t, errors.As(err, &r), "want a %s refusal, got %v", code, err)
	assert.Equal(t, code, r.Code)
}

// A start in hub is placed in hub's own folder even while an agent works in
// app; a second start in hub, with an agent there now, gets a worktree of
// hub's repository.
func TestStartInAFolderPlacesInThatRepository(t *testing.T) {
	w := newWorld(t)
	hub := w.addFolder(true)
	ctx := context.Background()

	app, err := Start(ctx, w.deps(), handlers.StartRequest{Workbench: w.wb, Brief: "app"})
	require.NoError(t, err)
	w.launched(app.SessionID)

	first, err := Start(ctx, w.deps(), handlers.StartRequest{Workbench: w.wb, FolderID: hub.ID, Brief: "hub"})
	require.NoError(t, err)
	w.launched(first.SessionID)
	r := w.row(first.SessionID)
	assert.Equal(t, hub.FolderPath, r.folder, "app's agent does not occupy hub")
	assert.Empty(t, r.branch)
	assert.Equal(t, realPath(t, hub.FolderPath), w.stubFile("cwd", first.SessionID))
	folder, _ := w.folderOf(first.SessionID)
	assert.Equal(t, sql.NullInt64{Int64: hub.ID, Valid: true}, folder)

	second, err := Start(ctx, w.deps(), handlers.StartRequest{Workbench: w.wb, FolderID: hub.ID, Brief: "hub again"})
	require.NoError(t, err)
	w.launched(second.SessionID)
	r = w.row(second.SessionID)
	assert.Equal(t, "wt/session-2", r.branch, "numbered after hub's own agents")
	assert.Equal(t, filepath.Join(realPath(t, hub.FolderPath), ".claude", "worktrees", "session-2"), realPath(t, r.folder))
	assert.Equal(t, realPath(t, r.folder), w.stubFile("cwd", second.SessionID))
	assert.NoDirExists(t, filepath.Join(w.folder, ".claude", "worktrees"), "app's repository is untouched")
}

// occupied reads only the live agents of the start's own folder.
func TestOccupiedCountsOnlyTheSameFolder(t *testing.T) {
	w := newWorld(t)
	hub := w.addFolder(true)
	site := w.addFolder(true)
	ctx := context.Background()
	for _, f := range []int64{0, hub.ID} {
		res, err := Start(ctx, w.deps(), handlers.StartRequest{Workbench: w.wb, FolderID: f, Brief: "go"})
		require.NoError(t, err)
		w.launched(res.SessionID)
	}
	for _, c := range []struct {
		folder   int64
		occupied bool
		working  int
	}{{0, true, 1}, {hub.ID, true, 1}, {site.ID, false, 0}} {
		wb, err := loadWorkbench(ctx, w.db, w.wb, c.folder)
		require.NoError(t, err)
		s := &newStart{d: w.deps(), wb: wb}
		occupied, working, err := s.occupied(ctx, w.client())
		require.NoError(t, err)
		assert.Equal(t, c.occupied, occupied, "folder %d", c.folder)
		assert.Equal(t, c.working, working, "folder %d", c.folder)
	}
}

// Without a folder a start is in the home folder, as before.
func TestStartDefaultsToTheHomeFolder(t *testing.T) {
	w := newWorld(t)
	w.addFolder(true)
	home, err := w.db.HomeFolder(context.Background(), w.wb)
	require.NoError(t, err)
	id := w.begin(handlers.StartRequest{Workbench: w.wb})
	assert.Equal(t, w.folder, w.row(id).folder)
	folder, parent := w.folderOf(id)
	assert.Equal(t, sql.NullInt64{Int64: home.ID, Valid: true}, folder)
	assert.False(t, parent.Valid)
}

// A folder without Watchtower's install is refused before any row.
func TestStartRefusesNotInstalled(t *testing.T) {
	w := newWorld(t)
	hub := w.addFolder(false)
	_, err := Begin(context.Background(), w.deps(), handlers.StartRequest{Workbench: w.wb, FolderID: hub.ID})
	requireRefusal(t, err, CodeNotInstalled)
	assert.EqualError(t, err, "not_installed: Install Watchtower in "+hub.Name+" first")
	assert.Zero(t, w.rowCount())
}

// A folder moved or deleted on disk is refused folder_missing (spec §7 row
// 5), before any row.
func TestStartRefusesAMissingFolder(t *testing.T) {
	w := newWorld(t)
	hub := w.addFolder(true)
	require.NoError(t, os.Rename(hub.FolderPath, hub.FolderPath+"-moved"))
	_, err := Begin(context.Background(), w.deps(), handlers.StartRequest{Workbench: w.wb, FolderID: hub.ID})
	requireRefusal(t, err, CodeFolderMissing)
	assert.Zero(t, w.rowCount())
}

// A folder removed from the bench is refused folder_removed: when it left
// before the start, and when the remove commits between the start's
// resolution and its row (spec §7 row 4: the re-check inside the insert's
// transaction).
func TestStartRefusesARemovedFolder(t *testing.T) {
	w := newWorld(t)
	ctx := context.Background()
	hub := w.addFolder(true)
	beforeInsert = func() {
		_, err := workbenchfolders.Remove(ctx, w.db, hub.ID, nil)
		require.NoError(t, err)
	}
	t.Cleanup(func() { beforeInsert = nil })
	_, err := Begin(ctx, w.deps(), handlers.StartRequest{Workbench: w.wb, FolderID: hub.ID})
	requireRefusal(t, err, workbenchfolders.CodeFolderRemoved)
	assert.Zero(t, w.rowCount())

	beforeInsert = nil
	_, err = Begin(ctx, w.deps(), handlers.StartRequest{Workbench: w.wb, FolderID: hub.ID})
	requireRefusal(t, err, workbenchfolders.CodeFolderRemoved)
	assert.Zero(t, w.rowCount())
}

// The other order of the race (spec §7 row 4): a start's row committed
// first makes the remove's in-transaction recount refuse sessions_running.
func TestRemoveAfterAStartIsRefused(t *testing.T) {
	w := newWorld(t)
	hub := w.addFolder(true)
	w.begin(handlers.StartRequest{Workbench: w.wb, FolderID: hub.ID})
	_, err := workbenchfolders.Remove(context.Background(), w.db, hub.ID, func(context.Context, int64) (int, error) { return 0, nil })
	requireRefusal(t, err, workbenchfolders.CodeSessionsRunning)
}

// A folder of another workbench is not one of this bench's.
func TestStartRefusesAnotherBenchsFolder(t *testing.T) {
	w := newWorld(t)
	other, err := w.db.CreateWorkbench("other", newRepo(t, true))
	require.NoError(t, err)
	of, err := w.db.HomeFolder(context.Background(), other)
	require.NoError(t, err)
	_, err = Begin(context.Background(), w.deps(), handlers.StartRequest{Workbench: w.wb, FolderID: of.ID})
	requireRefusal(t, err, workbenchfolders.CodeNotFound)
	assert.Zero(t, w.rowCount())
}

// --parent is stored; a parent of another workbench, or none, is refused
// and writes nothing.
func TestStartRecordsParent(t *testing.T) {
	w := newWorld(t)
	ctx := context.Background()
	parent := w.begin(handlers.StartRequest{Workbench: w.wb})
	child := w.begin(handlers.StartRequest{Workbench: w.wb, ParentSessionID: parent})
	_, got := w.folderOf(child)
	assert.Equal(t, sql.NullInt64{Int64: parent, Valid: true}, got)

	other, err := w.db.CreateWorkbench("other", newRepo(t, true))
	require.NoError(t, err)
	foreign, err := w.db.CreateTerminalSession(ctx, db.NewTerminalSession{WorkbenchID: other, Kind: "codex", Title: "other", FolderPath: "/x"})
	require.NoError(t, err)
	before := w.rowCount()
	_, err = Begin(ctx, w.deps(), handlers.StartRequest{Workbench: w.wb, ParentSessionID: foreign})
	requireRefusal(t, err, CodeNotSameWorkbench)
	_, err = Begin(ctx, w.deps(), handlers.StartRequest{Workbench: w.wb, ParentSessionID: foreign + 100})
	requireRefusal(t, err, workbenchfolders.CodeNotFound)
	assert.Equal(t, before, w.rowCount())
}

// A sub-session's start with the host down returns the error and leaves no
// row (spec §7 "sub-session start"), on both start paths.
func TestStartFailureLeavesNoRow(t *testing.T) {
	w := newWorld(t)
	ctx := context.Background()
	parent := w.begin(handlers.StartRequest{Workbench: w.wb})
	d := w.deps()
	d.Socket = droppingSocket(t)
	_, err := Begin(ctx, d, handlers.StartRequest{Workbench: w.wb, ParentSessionID: parent, Brief: "go"})
	require.Error(t, err)
	_, err = Start(ctx, d, handlers.StartRequest{Workbench: w.wb, ParentSessionID: parent, Brief: "go"})
	require.Error(t, err)
	assert.Equal(t, 1, w.rowCount(), "only the parent")
}
