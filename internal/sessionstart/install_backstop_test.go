package sessionstart

import (
	"context"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentkind"
	"watchtower/internal/devpack"
	"watchtower/internal/hub/actions/handlers"
)

// reinstallCall is one Deps.Reinstall the backstop made.
type reinstallCall struct {
	wb    int64
	dir   string
	stale []int64
}

// reinstallRecorder is a Deps.Reinstall that records its calls and installs
// the state hooks for the workbench, as the real one does.
type reinstallRecorder struct {
	mu    sync.Mutex
	calls []reinstallCall
}

func (r *reinstallRecorder) reinstall(_ context.Context, wb int64, dir string, _ agentkind.Kind, stale []int64) error {
	r.mu.Lock()
	r.calls = append(r.calls, reinstallCall{wb: wb, dir: dir, stale: stale})
	r.mu.Unlock()
	_, err := devpack.InstallStateHooks(dir, "watchtower", wb)
	return err
}

func (r *reinstallRecorder) all() []reinstallCall {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]reinstallCall(nil), r.calls...)
}

// mergedFolder makes w's folder look like a merged bench's: installed for
// workbench gone, a bench that no longer exists.
func (w *world) mergedFolder(gone int64) {
	w.t.Helper()
	_, err := devpack.InstallStateHooks(w.folder, "watchtower", gone)
	require.NoError(w.t, err)
}

// D37 (spec §6.13): every launch — a new session and a resume — compares
// the workbench id installed in its cwd with the row's and reinstalls on a
// mismatch before the agent starts.
func TestLaunchReinstallsOnAnInstallMismatch(t *testing.T) {
	gone := int64(9999)
	t.Run("new", func(t *testing.T) {
		w := newWorld(t)
		w.mergedFolder(gone)
		rec := &reinstallRecorder{}
		d := w.deps()
		d.Reinstall = rec.reinstall
		tid := w.target("Ship it")
		res, err := Begin(context.Background(), d, handlers.StartRequest{Workbench: w.wb, Target: ptr(tid)})
		require.NoError(t, err)
		require.NoError(t, Finish(context.Background(), d, res.SessionID, "auto", "", false))
		w.launched(res.SessionID)
		assert.Equal(t, []reinstallCall{{wb: w.wb, dir: w.folder, stale: []int64{gone}}}, rec.all())
		ok, err := devpack.HasCoreStateHooks(w.folder, w.wb)
		require.NoError(t, err)
		assert.True(t, ok, "the row's workbench is installed before the launch")
	})
	t.Run("resume", func(t *testing.T) {
		w := newWorld(t)
		w.mergedFolder(gone)
		rec := &reinstallRecorder{}
		d := w.deps()
		d.Reinstall = rec.reinstall
		tid := w.target("Ship it")
		existing := w.existingSession(tid)
		res, err := Start(context.Background(), d, handlers.StartRequest{Workbench: w.wb, Target: ptr(tid), OpenExisting: true})
		require.NoError(t, err)
		assert.Equal(t, existing, res.SessionID)
		w.launched(existing)
		assert.Equal(t, []reinstallCall{{wb: w.wb, dir: w.folder, stale: []int64{gone}}}, rec.all())
	})
}

// A place installed for the row's own workbench, or not installed at all,
// is left alone: the start behaves as it always did.
func TestEnsureInstallLeavesAMatchingOrBareFolderAlone(t *testing.T) {
	w := newWorld(t)
	rec := &reinstallRecorder{}
	d := w.deps()
	d.Reinstall = rec.reinstall
	done, err := EnsureInstall(context.Background(), d, 1, w.wb, w.folder, agentkind.Claude)
	require.NoError(t, err)
	assert.False(t, done, "no install at all")
	_, err = devpack.InstallStateHooks(w.folder, "watchtower", w.wb)
	require.NoError(t, err)
	done, err = EnsureInstall(context.Background(), d, 1, w.wb, w.folder, agentkind.Claude)
	require.NoError(t, err)
	assert.False(t, done, "installed for the row's workbench")
	assert.Empty(t, rec.all())
}

// The row's own install beside a gone bench's still repairs: the gone id's
// install goes, the row's stays.
func TestEnsureInstallRepairsAGoneIDBesideTheRowsOwn(t *testing.T) {
	w := newWorld(t)
	gone := int64(9999)
	_, err := devpack.InstallStateHooks(w.folder, "watchtower", w.wb)
	require.NoError(t, err)
	w.mergedFolder(gone)
	rec := &reinstallRecorder{}
	d := w.deps()
	d.Reinstall = rec.reinstall
	done, err := EnsureInstall(context.Background(), d, 1, w.wb, w.folder, agentkind.Claude)
	require.NoError(t, err)
	assert.True(t, done)
	assert.Equal(t, []reinstallCall{{wb: w.wb, dir: w.folder, stale: []int64{gone}}}, rec.all())
}

// A partial install of the row's own workbench is no mismatch (the
// Desktop's WorkbenchInstallCheck agrees): Repair's business, not the merge's.
func TestEnsureInstallLeavesAPartialOwnInstallAlone(t *testing.T) {
	w := newWorld(t)
	rec := &reinstallRecorder{}
	d := w.deps()
	d.Reinstall = rec.reinstall
	cmd := devpack.WorkbenchSessionStateHookCommand("watchtower", w.wb)
	settings := `{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"` + cmd + `"}]}]}}`
	require.NoError(t, os.MkdirAll(filepath.Join(w.folder, ".claude"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(w.folder, ".claude", "settings.local.json"), []byte(settings), 0o644))
	done, err := EnsureInstall(context.Background(), d, 1, w.wb, w.folder, agentkind.Claude)
	require.NoError(t, err)
	assert.False(t, done)
	assert.Empty(t, rec.all())
}
