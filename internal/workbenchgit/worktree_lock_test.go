package workbenchgit

import (
	"context"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/fsutil"
)

// lockWatch records, for every `git worktree …` call, whether the
// repository's worktree lock was held while it ran (#2394).
type lockWatch struct {
	mu    sync.Mutex
	lock  string
	calls map[string]bool // "worktree <verb>" -> held on every call
}

func newLockWatch(commonDir string) *lockWatch {
	return &lockWatch{lock: filepath.Join(commonDir, worktreeLockName), calls: map[string]bool{}}
}

func (w *lockWatch) before(args []string) {
	if len(args) < 2 || args[0] != "worktree" {
		return
	}
	unlock, free, err := fsutil.TryLockFile(w.lock)
	if free {
		unlock()
	}
	key := strings.Join(args[:2], " ")
	w.mu.Lock()
	defer w.mu.Unlock()
	held, seen := w.calls[key]
	w.calls[key] = (!seen || held) && err == nil && !free
}

func (w *lockWatch) assertHeld(t *testing.T, keys ...string) {
	t.Helper()
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, k := range keys {
		held, seen := w.calls[k]
		require.True(t, seen, "%s never ran (calls: %v)", k, w.calls)
		assert.True(t, held, "%s ran without the worktree lock", k)
	}
}

func TestWorktreeLock_PublishHoldsItForAddAndRemove(t *testing.T) {
	f := newPublishFixture(t)
	w := newLockWatch(filepath.Join(f.dir, ".git"))
	_, err := Publish(context.Background(), f.options(&recorder{before: w.before}), f.request(31))
	require.NoError(t, err)
	w.assertHeld(t, "worktree add", "worktree remove")
}

func TestWorktreeLock_CreateAndEnsureHoldIt(t *testing.T) {
	dir := newRepo(t)
	w := newLockWatch(filepath.Join(dir, ".git"))
	wt := CreateWorktree(context.Background(), options(dir, &recorder{before: w.before}), WorktreeRequest{Slug: "r"})
	require.True(t, wt.Created, "%+v", wt)
	dropWorktree(t, dir, wt)
	res := EnsureWorktree(context.Background(), options(dir, &recorder{before: w.before}), wt.Path, wt.Branch)
	require.True(t, res.Created, "%+v", res)
	w.assertHeld(t, "worktree add", "worktree prune")
}

// A held lock and a done context: the add is refused, never run unserialized.
func TestWorktreeLock_WaitEndsWithTheContext(t *testing.T) {
	dir := newRepo(t)
	unlock, err := LockWorktrees(context.Background(), filepath.Join(dir, ".git"))
	require.NoError(t, err)
	defer unlock()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = LockWorktrees(ctx, filepath.Join(dir, ".git"))
	require.Error(t, err)
}

// No lock file can be made (the common dir is missing): git runs as before.
func TestWorktreeLock_UnopenableLockIsNoFailure(t *testing.T) {
	unlock, err := LockWorktrees(context.Background(), filepath.Join(t.TempDir(), "missing"))
	require.NoError(t, err)
	unlock()
}
