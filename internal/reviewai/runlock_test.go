package reviewai

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/fsutil"
)

// Board #1025, tech spec §3.7: one overview run at a time per folder.

const (
	runLockHolderEnv = "REVIEWAI_RUNLOCK_HOLD"
	runLockByEnv     = "REVIEWAI_RUNLOCK_BY"
)

// holdRunLockForever is the holder process: it takes the run lock at path
// as by, says "locked" and blocks until it is killed.
func holdRunLockForever(path, by string) {
	if _, err := AcquireRun(context.Background(), path, by, nil); err != nil {
		fmt.Fprintln(os.Stderr, "holder:", err)
		os.Exit(3)
	}
	fmt.Println("locked")
	select {}
}

// startRunLockHolder re-execs the test binary as a holder of path; the
// returned kill ends its whole process group (also run by t.Cleanup).
func startRunLockHolder(t *testing.T, path, by string) (kill func()) {
	t.Helper()
	c := exec.Command(os.Args[0], "-test.run=^$")
	c.Env = append(os.Environ(), runLockHolderEnv+"="+path, runLockByEnv+"="+by)
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	out, err := c.StdoutPipe()
	require.NoError(t, err)
	require.NoError(t, c.Start())
	kill = sync.OnceFunc(func() {
		_ = syscall.Kill(-c.Process.Pid, syscall.SIGKILL)
		_ = c.Wait()
	})
	t.Cleanup(kill)
	ready := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(out).ReadString('\n')
		ready <- line
	}()
	require.Equal(t, "locked\n", <-ready, "the holder took the lock")
	return kill
}

// holdRunLock takes the run lock at path as by in this process, on a file
// description of its own: flock conflicts between descriptions as it does
// between processes, so the waits below run in a synctest bubble. The
// returned release frees it (also run by t.Cleanup).
func holdRunLock(t *testing.T, path, by string) (release func()) {
	t.Helper()
	r, err := AcquireRun(context.Background(), path, by, nil)
	require.NoError(t, err)
	release = sync.OnceFunc(r)
	t.Cleanup(release)
	return release
}

func TestRunLock_Path(t *testing.T) {
	p := LockPath("/ws", 7, "/repo/a")
	assert.Equal(t, "/ws/locks", filepath.Dir(p))
	assert.Regexp(t, `^review-overview-7-[0-9a-f]{16}\.lock$`, filepath.Base(p))
	assert.NotEqual(t, p, LockPath("/ws", 7, "/repo/b"), "another folder, another lock")
	assert.NotEqual(t, p, LockPath("/ws", 8, "/repo/a"), "another workbench, another lock")
}

// A free lock is taken, names its holder and is free again on release.
func TestRunLock_FreeLockNamesItsHolder(t *testing.T) {
	path := LockPath(t.TempDir(), 1, "/repo")
	release, err := AcquireRun(context.Background(), path, "agent", nil)
	require.NoError(t, err)
	h := ReadHolder(path)
	assert.Equal(t, "agent", h.By)
	assert.WithinDuration(t, time.Now(), h.StartedAt, time.Minute)
	release()
	unlock, ok, err := fsutil.TryLockFile(path)
	require.NoError(t, err)
	require.True(t, ok, "released")
	unlock()
}

// A form that never waits answers busy at once, naming the holder's kind.
func TestRunLock_HeldAnswersBusyAtOnce(t *testing.T) {
	for by, want := range map[string]string{
		"desktop": "Branch review is describing this branch now; run this again when it finishes — what it describes is kept.",
		"agent":   "Another run is describing this branch now; run this again when it finishes — what it describes is kept.",
	} {
		synctest.Test(t, func(t *testing.T) {
			path := LockPath(t.TempDir(), 1, "/repo")
			release := holdRunLock(t, path, by)
			start := time.Now()
			_, err := AcquireRun(context.Background(), path, "cli", nil)
			assert.Zero(t, time.Since(start), "no wait")
			var busy *BusyError
			require.ErrorAs(t, err, &busy)
			assert.Equal(t, by, busy.Holder.By)
			assert.False(t, busy.Waited)
			assert.Equal(t, want, err.Error())
			assert.Equal(t, &RunError{Class: ClassBusy, Text: want}, busy.RunError())
			release()
		})
	}
}

// A waiter hears the holder at once and every Every, and takes the lock
// once the holder lets it go.
func TestRunLock_WaiterTakesTheLockOnceTheHolderIsGone(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		path := LockPath(t.TempDir(), 1, "/repo")
		releaseHolder := holdRunLock(t, path, "agent")
		var mu sync.Mutex
		var heard []Holder
		go func() {
			time.Sleep(300 * time.Millisecond)
			releaseHolder()
		}()
		release, err := AcquireRun(context.Background(), path, "desktop", &LockWait{Cap: 30 * time.Second, Every: 50 * time.Millisecond,
			OnWait: func(h Holder) { mu.Lock(); heard = append(heard, h); mu.Unlock() }})
		require.NoError(t, err)
		defer release()
		mu.Lock()
		defer mu.Unlock()
		require.GreaterOrEqual(t, len(heard), 2, "at once and on the ticks")
		assert.Equal(t, "agent", heard[0].By)
		assert.Equal(t, "desktop", ReadHolder(path).By, "the new holder names itself")
	})
}

// A killed holder process's lock is dropped by the kernel: a waiter takes
// it. Real processes, so only process events are waited on.
func TestRunLock_WaiterTakesTheLockOfAKilledHolder(t *testing.T) {
	path := LockPath(t.TempDir(), 1, "/repo")
	kill := startRunLockHolder(t, path, "agent")
	_, err := AcquireRun(context.Background(), path, "desktop", nil)
	var busy *BusyError
	require.ErrorAs(t, err, &busy, "held by the other process")
	assert.Equal(t, "agent", busy.Holder.By)
	kill() // returns once the holder has exited
	release, err := AcquireRun(context.Background(), path, "desktop", &LockWait{Cap: time.Hour})
	require.NoError(t, err)
	defer release()
	assert.Equal(t, "desktop", ReadHolder(path).By, "the new holder names itself")
}

// A holder that never releases: the wait ends at its cap as busy with the
// card's sentence.
func TestRunLock_WaitCapIsBusy(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		path := LockPath(t.TempDir(), 1, "/repo")
		holdRunLock(t, path, "agent")
		start := time.Now()
		_, err := AcquireRun(context.Background(), path, "desktop", &LockWait{Cap: 300 * time.Millisecond, Every: time.Hour})
		assert.Equal(t, 300*time.Millisecond, time.Since(start), "the wait ends at its cap")
		var busy *BusyError
		require.ErrorAs(t, err, &busy)
		assert.True(t, busy.Waited)
		assert.Equal(t, "Another overview of this branch is still running.", err.Error())
	})
}

// A cancelled waiter is cancelled, not busy.
func TestRunLock_CancelledWaitIsNotBusy(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		path := LockPath(t.TempDir(), 1, "/repo")
		holdRunLock(t, path, "agent")
		ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
		defer cancel()
		_, err := AcquireRun(ctx, path, "desktop", &LockWait{Cap: time.Hour})
		require.Error(t, err)
		assert.True(t, errors.Is(err, context.DeadlineExceeded), err)
		var busy *BusyError
		assert.False(t, errors.As(err, &busy))
	})
}

// A reader in the instant between the holder's flock and its line still
// hears the holder; a released lock names no one.
func TestRunLock_HolderWrittenJustAfterTheLock(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		path := LockPath(t.TempDir(), 1, "/repo")
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o700))
		unlock, ok, err := fsutil.TryLockFile(path)
		require.NoError(t, err)
		require.True(t, ok)
		written := make(chan struct{})
		go func() {
			defer close(written)
			time.Sleep(holderSettle / 5) // inside the reader's settle
			_ = os.WriteFile(path, []byte(`{"by":"desktop"}`), 0o600)
		}()
		_, err = AcquireRun(context.Background(), path, "cli", nil)
		<-written
		unlock()
		var busy *BusyError
		require.ErrorAs(t, err, &busy)
		assert.Equal(t, "desktop", busy.Holder.By)

		release, err := AcquireRun(context.Background(), path, "agent", nil)
		require.NoError(t, err)
		assert.Equal(t, "agent", ReadHolder(path).By)
		release()
		assert.Equal(t, Holder{}, ReadHolder(path), "a released lock names no one")
	})
}

// An unreadable lock file is the zero holder: "Another run".
func TestRunLock_UnreadableHolder(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.lock")
	require.NoError(t, os.WriteFile(path, []byte("{not json"), 0o600))
	assert.Equal(t, Holder{}, ReadHolder(path))
	assert.True(t, strings.HasPrefix((&BusyError{}).Error(), "Another run"))
}

// CachedChapters is what a run would reuse: the parts a finished run left.
func TestRunLock_CachedChaptersAreTheRunsParts(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		d := dirsDiff(12)
		m := dirsMap(d)
		store := newMemStore()
		p := fastPipeline(&keyGen{skip: map[string]bool{"dir:d00": true}})
		got, err := p.CachedChapters(store, 1, m, d, nil)
		require.NoError(t, err)
		assert.Empty(t, got)
		_, err = p.Run(context.Background(), store, m, d, nil, nil, RunOptions{ProjectID: 1})
		require.NoError(t, err)
		got, err = p.CachedChapters(store, 1, m, d, nil)
		require.NoError(t, err)
		assert.Len(t, got, 11)
		assert.NotContains(t, got, "dir:d00")
		assert.Equal(t, "about dir:d01", got["dir:d01"].What)
	})
}
