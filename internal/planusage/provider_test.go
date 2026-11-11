package planusage

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/codex"
	"watchtower/internal/db"
	"watchtower/internal/fsutil"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestProvider_SchedulerBackoffResetAndBusy(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	now := at(10, 0)
	poller := &CodexPoller{Store: d, Now: func() time.Time { return now }}
	failures := 0
	poller.Read = func(context.Context) (codex.UsageSnapshot, error) {
		failures++
		if failures <= 5 {
			return codex.UsageSnapshot{}, &codex.UsageError{Code: "network"}
		}
		return testCodexSnapshot(strings.Repeat("a", 64), now.Add(time.Hour), 10), nil
	}
	requested := make(chan time.Duration, 10)
	ticks := make(chan time.Time)
	p := &Provider{Name: "codex", Workspace: t.TempDir(), Poll: poller.PollOnce, After: func(d time.Duration) <-chan time.Time { requested <- d; return ticks }}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { defer close(done); _ = p.Run(ctx) }()
	require.Equal(t, 10*time.Second, <-requested)
	require.Zero(t, failures, "no call before the first timer")
	expected := []time.Duration{5 * time.Minute, 10 * time.Minute, 20 * time.Minute, 30 * time.Minute, 30 * time.Minute, 5 * time.Minute}
	for _, want := range expected {
		ticks <- now
		require.Equal(t, want, <-requested)
	}
	require.Zero(t, poller.failures)
	// A held daemon lock skips without invoking the source or changing count.
	unlock, err := fsutil.LockFile(context.Background(), p.lockPath())
	require.NoError(t, err)
	ticks <- now
	require.Equal(t, 5*time.Minute, <-requested)
	unlock()
	require.Equal(t, 6, failures)
	require.Zero(t, poller.failures)
	cancel()
	<-done
}

func TestProviders_ClocksAndFailuresAreIndependent(t *testing.T) {
	workspace := t.TempDir()
	blocked := make(chan struct{})
	started := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	makeTimer := func() (func(time.Duration) <-chan time.Time, chan time.Time, chan time.Duration) {
		ticks := make(chan time.Time)
		schedule := make(chan time.Duration, 4)
		return func(d time.Duration) <-chan time.Time { schedule <- d; return ticks }, ticks, schedule
	}
	aAfter, aTick, aSchedule := makeTimer()
	bAfter, bTick, bSchedule := makeTimer()
	a := &Provider{Name: "claude", Workspace: workspace, After: aAfter, Poll: func(ctx context.Context) (time.Duration, error) {
		close(started)
		select {
		case <-blocked:
		case <-ctx.Done():
		}
		return 30 * time.Minute, errors.New("fake failure")
	}}
	b := &Provider{Name: "codex", Workspace: workspace, After: bAfter, Poll: func(context.Context) (time.Duration, error) { return 5 * time.Minute, nil }}
	done := make(chan struct{})
	go func() { defer close(done); _ = Providers{a, b}.Run(ctx) }()
	require.Equal(t, 10*time.Second, <-aSchedule)
	require.Equal(t, 10*time.Second, <-bSchedule)
	aTick <- time.Now()
	<-started
	bTick <- time.Now()
	require.Equal(t, 5*time.Minute, <-bSchedule)
	close(blocked)
	require.Equal(t, 30*time.Minute, <-aSchedule)
	cancel()
	<-done
}

// In a synctest bubble: the lock wait and the budgets run out in the
// bubble's time, never because the machine is slow.
func TestProvider_LockBudgetsDisableAndStableInode(t *testing.T) {
	synctest.Test(t, testProviderLockBudgets)
}

func testProviderLockBudgets(t *testing.T) {
	var calls, disabled atomic.Int32
	p := &Provider{Name: "codex", Workspace: t.TempDir(), LockWait: 35 * time.Millisecond, Budget: 10 * time.Second,
		Poll:         func(context.Context) (time.Duration, error) { calls.Add(1); return pollInterval, nil },
		MarkDisabled: func(context.Context) error { disabled.Add(1); return nil }}
	unlock, err := fsutil.LockFile(context.Background(), p.lockPath())
	require.NoError(t, err)
	first, err := os.Stat(p.lockPath())
	require.NoError(t, err)
	require.Equal(t, os.FileMode(0600), first.Mode().Perm())
	require.Equal(t, "busy", ErrorCode(p.Refresh(context.Background())))
	require.Zero(t, calls.Load())
	p.Budget = 10 * time.Millisecond
	require.Equal(t, "timeout", ErrorCode(p.Refresh(context.Background())))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	require.Equal(t, "cancelled", ErrorCode(p.Refresh(ctx)))
	unlock()
	p.Budget = 10 * time.Second
	p.Enabled = func() (bool, error) { return false, nil }
	require.Equal(t, "feature_disabled", ErrorCode(p.Refresh(context.Background())))
	require.Zero(t, disabled.Load(), "manual off never writes")
	_, err = p.PollOnce(context.Background())
	require.Equal(t, "feature_disabled", ErrorCode(err))
	require.Equal(t, int32(1), disabled.Load())
	require.NoError(t, p.Disable(context.Background()))
	require.Equal(t, int32(2), disabled.Load())
	last, err := os.Stat(p.lockPath())
	require.NoError(t, err)
	require.True(t, os.SameFile(first, last), "unlock/disable do not replace the inode")
}

func TestCodexPoller_CancelAndDeadlineDoNotPublish(t *testing.T) {
	for _, deadline := range []bool{false, true} {
		t.Run(fmt.Sprint(deadline), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				d, err := db.Open(":memory:")
				require.NoError(t, err)
				defer d.Close()
				var ctx context.Context
				var cancel context.CancelFunc
				if deadline {
					ctx, cancel = context.WithTimeout(context.Background(), time.Millisecond)
				} else {
					ctx, cancel = context.WithCancel(context.Background())
				}
				defer cancel()
				p := &CodexPoller{Store: d, Now: time.Now, Read: func(ctx context.Context) (codex.UsageSnapshot, error) {
					if !deadline {
						cancel()
					}
					<-ctx.Done()
					return codex.UsageSnapshot{}, ctx.Err()
				}}
				_, err = p.PollOnce(ctx)
				require.Error(t, err)
				st, err := d.GetCodexPlanUsageStatus()
				require.NoError(t, err)
				require.Nil(t, st)
				require.Zero(t, p.failures)
			})
		})
	}
}

// noBudget leaves a cross-process lock test without a budget or lock wait:
// the processes wait only for each other, and a hang is go test -timeout's.
const noBudget = time.Duration(math.MaxInt64)

// This subprocess exercises actual flock against other daemon/CLI processes.
func runPlanLockHelper() {
	dir, name, mode := os.Getenv("WATCHTOWER_TEST_PLAN_DIR"), os.Getenv("WATCHTOWER_TEST_PLAN_NAME"), os.Getenv("WATCHTOWER_TEST_PLAN_MODE")
	p := &Provider{Name: "codex", Workspace: dir, Budget: noBudget, LockWait: noBudget, Poll: func(ctx context.Context) (time.Duration, error) {
		f, err := os.OpenFile(filepath.Join(dir, "events"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
		if err != nil {
			return 0, err
		}
		defer f.Close()
		fmt.Fprintln(f, "start "+name)
		fmt.Println("ready")
		select {
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
		fmt.Fprintln(f, "end "+name)
		return pollInterval, nil
	}}
	if mode == "hold" {
		unlock, err := fsutil.LockFile(context.Background(), p.lockPath())
		if err != nil {
			os.Exit(3)
		}
		defer unlock()
		fmt.Println("ready")
		_, _ = io.Copy(io.Discard, os.Stdin) // until killed, or the test binary is gone
	}
	var err error
	if mode == "daemon" {
		_, err = p.PollOnce(context.Background())
	} else {
		err = p.Refresh(context.Background())
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, ErrorCode(err))
		os.Exit(3)
	}
}

func planLockProcess(t *testing.T, dir, name, mode string) (*exec.Cmd, *bufio.Scanner) {
	t.Helper()
	bin, err := os.Executable()
	require.NoError(t, err)
	cmd := exec.Command(bin)
	cmd.Env = append(os.Environ(), "WATCHTOWER_TEST_PLAN_LOCK=1", "WATCHTOWER_TEST_PLAN_DIR="+dir, "WATCHTOWER_TEST_PLAN_NAME="+name, "WATCHTOWER_TEST_PLAN_MODE="+mode)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// Its stdin stays open while the test binary lives: a holder outlives
	// neither a kill nor a run go test -timeout ends.
	_, err = cmd.StdinPipe()
	require.NoError(t, err)
	stdout, err := cmd.StdoutPipe()
	require.NoError(t, err)
	require.NoError(t, cmd.Start())
	t.Cleanup(func() {
		if cmd.ProcessState == nil {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			_ = cmd.Wait()
		}
	})
	return cmd, bufio.NewScanner(stdout)
}

func TestProvider_ProcessSerializationAndCrashRelease(t *testing.T) {
	dir := t.TempDir()
	daemon, ready := planLockProcess(t, dir, "daemon", "daemon")
	require.True(t, ready.Scan())
	one, _ := planLockProcess(t, dir, "one", "manual")
	two, _ := planLockProcess(t, dir, "two", "manual")
	require.NoError(t, daemon.Wait())
	require.NoError(t, one.Wait())
	require.NoError(t, two.Wait())
	events, err := os.ReadFile(filepath.Join(dir, "events"))
	require.NoError(t, err)
	lines := strings.Fields(string(events))
	require.Len(t, lines, 12)
	for i := 0; i < len(lines); i += 4 {
		assert.Equal(t, "start", lines[i])
		assert.Equal(t, "end", lines[i+2])
		assert.Equal(t, lines[i+1], lines[i+3])
	}
	// A killed holder cannot wedge future CLI requests; the inode remains.
	holder, ready := planLockProcess(t, dir, "holder", "hold")
	require.True(t, ready.Scan())
	p := &Provider{Name: "codex", Workspace: dir, LockWait: 30 * time.Millisecond, Poll: func(context.Context) (time.Duration, error) { return pollInterval, nil }}
	before, err := os.Stat(p.lockPath())
	require.NoError(t, err)
	synctest.Test(t, func(t *testing.T) { // the lock wait runs out in the bubble's time
		require.Equal(t, "busy", ErrorCode(p.Refresh(context.Background())))
		_, err := p.PollOnce(context.Background())
		require.Equal(t, "busy", ErrorCode(err))
	})
	require.NoError(t, syscall.Kill(-holder.Process.Pid, syscall.SIGKILL))
	require.Error(t, holder.Wait())
	require.NoError(t, p.Refresh(context.Background()))
	after, err := os.Stat(p.lockPath())
	require.NoError(t, err)
	require.True(t, os.SameFile(before, after))
}
