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
	select {
	case line := <-ready:
		require.Equal(t, "locked\n", line)
	case <-time.After(30 * time.Second):
		kill()
		t.Fatal("the holder never took the lock")
	}
	return kill
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
		path := LockPath(t.TempDir(), 1, "/repo")
		kill := startRunLockHolder(t, path, by)
		start := time.Now()
		_, err := AcquireRun(context.Background(), path, "cli", nil)
		assert.Less(t, time.Since(start), time.Second)
		var busy *BusyError
		require.ErrorAs(t, err, &busy)
		assert.Equal(t, by, busy.Holder.By)
		assert.False(t, busy.Waited)
		assert.Equal(t, want, err.Error())
		assert.Equal(t, &RunError{Class: ClassBusy, Text: want}, busy.RunError())
		kill()
	}
}

// A waiter hears the holder at once and every Every, and takes the lock
// once the holder is killed (the kernel drops it).
func TestRunLock_WaiterTakesTheLockOfAKilledHolder(t *testing.T) {
	path := LockPath(t.TempDir(), 1, "/repo")
	kill := startRunLockHolder(t, path, "agent")
	var mu sync.Mutex
	var heard []Holder
	go func() {
		time.Sleep(300 * time.Millisecond)
		kill()
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
}

// A holder that never releases: the wait ends at its cap as busy with the
// card's sentence.
func TestRunLock_WaitCapIsBusy(t *testing.T) {
	path := LockPath(t.TempDir(), 1, "/repo")
	startRunLockHolder(t, path, "agent")
	start := time.Now()
	_, err := AcquireRun(context.Background(), path, "desktop", &LockWait{Cap: 300 * time.Millisecond, Every: time.Hour})
	assert.Less(t, time.Since(start), 5*time.Second)
	var busy *BusyError
	require.ErrorAs(t, err, &busy)
	assert.True(t, busy.Waited)
	assert.Equal(t, "Another overview of this branch is still running.", err.Error())
}

// A cancelled waiter is cancelled, not busy.
func TestRunLock_CancelledWaitIsNotBusy(t *testing.T) {
	path := LockPath(t.TempDir(), 1, "/repo")
	startRunLockHolder(t, path, "agent")
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	_, err := AcquireRun(ctx, path, "desktop", &LockWait{Cap: time.Hour})
	require.Error(t, err)
	assert.True(t, errors.Is(err, context.DeadlineExceeded), err)
	var busy *BusyError
	assert.False(t, errors.As(err, &busy))
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
}
