package sessionstart

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentkind"
	"watchtower/internal/fsutil"
	"watchtower/internal/hub/actions/handlers"
)

// The Desktop's starts through Go (Go hub 3 Task 8): the lock path and the
// reasons the Desktop matches are pinned by testdata/desktop_contract.json,
// which GoSessionStartContractFixtureTests reads too.
func TestDesktopContractFixture(t *testing.T) {
	b, err := os.ReadFile("testdata/desktop_contract.json")
	require.NoError(t, err)
	var f struct {
		Lock []struct {
			DBPath    string `json:"db_path"`
			Workbench int64  `json:"workbench"`
			Want      string `json:"want"`
		} `json:"lock"`
		AgentNotFound []struct {
			Agent, Want string
		} `json:"agent_not_found"`
		MoveFailedPrefix  string `json:"move_failed_prefix"`
		SetupNotRunPrefix string `json:"setup_not_run_prefix"`
		Exit              struct {
			Code  int    `json:"code"`
			Error string `json:"error"`
		} `json:"agent_not_found_exit"`
	}
	require.NoError(t, json.Unmarshal(b, &f))
	require.NotEmpty(t, f.Lock)
	for _, c := range f.Lock {
		assert.Equal(t, c.Want, PlacementLockPath(c.DBPath, c.Workbench))
	}
	require.NotEmpty(t, f.AgentNotFound)
	for _, c := range f.AgentNotFound {
		assert.Equal(t, c.Want, AgentNotFoundReason(c.Agent))
		assert.Equal(t, c.Want, notFoundReason(agentkind.Kind(c.Agent)))
	}
	assert.Equal(t, f.MoveFailedPrefix, MoveFailedPrefix)
	assert.Equal(t, f.SetupNotRunPrefix, SetupNotRunPrefix)
	assert.Equal(t, f.Exit.Code, AgentNotFoundExit)
	assert.Equal(t, f.Exit.Error, AgentNotFoundClass)
}

func (w *world) notice(id int64) string {
	w.t.Helper()
	var n sql.NullString
	require.NoError(w.t, w.db.QueryRow(`SELECT start_notice FROM terminal_sessions WHERE id = ?`, id).Scan(&n))
	return n.String
}

func (w *world) begin(r handlers.StartRequest) int64 {
	w.t.Helper()
	res, err := Begin(context.Background(), w.deps(), r)
	require.NoError(w.t, err)
	return res.SessionID
}

// Another process holding the workbench's placement lock holds a finish
// back until it lets go: the finish then places and launches.
func TestFinishWaitsForThePlacementLock(t *testing.T) {
	w := newWorld(t)
	id := w.begin(handlers.StartRequest{Workbench: w.wb})
	unlock, err := fsutil.LockFile(context.Background(), PlacementLockPath(w.dbPath, w.wb))
	require.NoError(t, err)
	done := make(chan error, 1)
	go func() { done <- Finish(context.Background(), w.deps(), id, "auto", "", false) }()
	select {
	case err := <-done:
		t.Fatalf("finished while the lock was held: %v", err)
	case <-time.After(300 * time.Millisecond):
	}
	_, live := findRun(w.list(), w.deps().scope(), id)
	assert.False(t, live, "nothing launched under another holder's lock")
	unlock()
	require.NoError(t, <-done)
	w.launched(id)
}

// A lock held past the wait fails the row with LockTimeoutReason.
func TestFinishLockTimeoutFailsTheRow(t *testing.T) {
	prev := placementLockWait
	placementLockWait = 100 * time.Millisecond
	t.Cleanup(func() { placementLockWait = prev })
	w := newWorld(t)
	id := w.begin(handlers.StartRequest{Workbench: w.wb})
	unlock, err := fsutil.LockFile(context.Background(), PlacementLockPath(w.dbPath, w.wb))
	require.NoError(t, err)
	defer unlock()
	require.Error(t, Finish(context.Background(), w.deps(), id, "auto", "", false))
	r := w.row(id)
	assert.True(t, r.failed)
	assert.Equal(t, LockTimeoutReason, r.agentError)
}

// Two finishes of one workbench at one moment: the first runs in the
// folder, the second sees it and goes into its own worktree.
func TestTwoConcurrentFinishesSecondGoesToAWorktree(t *testing.T) {
	w := newWorld(t)
	a := w.begin(handlers.StartRequest{Workbench: w.wb})
	b := w.begin(handlers.StartRequest{Workbench: w.wb})
	var wg sync.WaitGroup
	errs := make([]error, 2)
	for i, id := range []int64{a, b} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs[i] = Finish(context.Background(), w.deps(), id, "auto", "", false)
		}()
	}
	wg.Wait()
	require.NoError(t, errs[0])
	require.NoError(t, errs[1])
	w.launched(a)
	w.launched(b)
	branches := []string{w.row(a).branch, w.row(b).branch}
	assert.ElementsMatch(t, []string{"", "wt/session-2"}, branches, "one in the folder, one in its own worktree")
}

// A worktree asked for where none can be made: the row starts in the folder
// and its notice says why.
func TestStartNoticeNamesTheFolderFallback(t *testing.T) {
	w := newWorld(t)
	plain, err := w.db.CreateWorkbench("plain", t.TempDir())
	require.NoError(t, err)
	id := w.begin(handlers.StartRequest{Workbench: plain})
	require.NoError(t, Finish(context.Background(), w.deps(), id, "worktree", "", false))
	w.launched(id)
	assert.True(t, strings.HasPrefix(w.notice(id), "Started in the folder: "), w.notice(id))
	assert.Empty(t, w.row(id).branch)
}

// The integration of a new worktree failed: the session runs, the notice
// names it.
func TestStartNoticeNamesAFailedIntegration(t *testing.T) {
	w := newWorld(t)
	d := w.deps()
	d.Integrate = func(context.Context, int64, string, agentkind.Kind) error { return errors.New("mcp add refused") }
	id := w.begin(handlers.StartRequest{Workbench: w.wb})
	require.NoError(t, Finish(context.Background(), d, id, "worktree", "", false))
	w.launched(id)
	assert.Contains(t, w.notice(id), "Worktree: mcp add refused")
}

// A placed row whose first launch did not run: its setup command never ran,
// and the notice gives it to run by hand — written before the failure, so a
// reader that sees the failure sees the notice.
func TestStartNoticeNamesTheSetupCommandThatDidNotRun(t *testing.T) {
	w := newWorld(t)
	_, err := w.db.Exec(`UPDATE projects SET worktree_setup = 'make deps' WHERE id = ?`, w.wb)
	require.NoError(t, err)
	d := w.deps()
	d.Shell = w.stub + "/no-such-shell"
	id := w.begin(handlers.StartRequest{Workbench: w.wb})
	require.Error(t, Finish(context.Background(), d, id, "worktree", "", false))
	assert.True(t, w.row(id).failed)
	assert.Contains(t, w.notice(id), SetupNotRunPrefix+"make deps")
}

// A row that could not be moved into its new worktree is failed (not
// deleted) with MoveFailedPrefix; the whole sentence, naming the kept
// worktree, is its notice.
func TestMoveFailureFailsTheRowAndNamesTheWorktree(t *testing.T) {
	w := newWorld(t)
	_, err := w.db.Exec(`CREATE TRIGGER fail_place BEFORE UPDATE OF worktree_branch ON terminal_sessions
		BEGIN SELECT RAISE(ABORT, 'boom'); END`)
	require.NoError(t, err)
	id := w.begin(handlers.StartRequest{Workbench: w.wb})
	require.Error(t, Finish(context.Background(), w.deps(), id, "worktree", "", false))
	r := w.row(id)
	assert.True(t, r.failed)
	assert.True(t, strings.HasPrefix(r.agentError, MoveFailedPrefix), r.agentError)
	n := w.notice(id)
	assert.True(t, strings.HasPrefix(n, MoveFailedPrefix), n)
	assert.Contains(t, n, " on wt/session-1 was kept.")
	_, live := findRun(w.list(), w.deps().scope(), id)
	assert.False(t, live)
}

// The caller giving up while the worktree is made: the row is still moved
// into it, and the launch that cannot run any more fails the row.
func TestFinishCancelledBeforeTheLaunchFailsTheRow(t *testing.T) {
	w := newWorld(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d := w.deps()
	d.Integrate = func(context.Context, int64, string, agentkind.Kind) error {
		cancel()
		return nil
	}
	id := w.begin(handlers.StartRequest{Workbench: w.wb})
	require.Error(t, Finish(ctx, d, id, "worktree", "", false))
	r := w.row(id)
	assert.True(t, r.failed, "a cancelled launch is recorded on the row")
	assert.Equal(t, "wt/session-1", r.branch, "moved into the worktree it got")
}

// The owner's delete lands between the finish's row check and its launch:
// the run that started for the gone row is stopped at once.
func TestADeleteBetweenTheCheckAndTheLaunchStopsTheRun(t *testing.T) {
	w := newWorld(t)
	id := w.begin(handlers.StartRequest{Workbench: w.wb})
	beforeLaunch = func(sid int64) {
		_, err := w.db.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, sid)
		require.NoError(t, err)
	}
	t.Cleanup(func() { beforeLaunch = nil })
	err := Finish(context.Background(), w.deps(), id, "auto", "", false)
	require.ErrorContains(t, err, "was deleted before it started")
	eventually(t, "the run is stopped", func() bool {
		info, ok := findRun(w.list(), w.deps().scope(), id)
		return !ok || info.Exited
	})
}
