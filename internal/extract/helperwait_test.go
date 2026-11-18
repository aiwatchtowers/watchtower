package extract

import (
	"bufio"
	"context"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// readyFIFO makes a FIFO a helper writes one line to once it runs, and
// returns its path and the wait for that line — a process event, no clock.
func readyFIFO(t *testing.T) (path string, wait func()) {
	t.Helper()
	path = filepath.Join(t.TempDir(), "ready")
	require.NoError(t, syscall.Mkfifo(path, 0o600))
	// The wait runs on a goroutine of the test's, so it reports with
	// t.Error and returns (no FailNow): the caller's fire or cancel still runs.
	return path, func() {
		f, err := os.Open(path) // blocks until the helper opens its end
		if err != nil {
			t.Errorf("open ready FIFO: %v", err)
			return
		}
		defer f.Close()
		line, err := bufio.NewReader(f).ReadString('\n')
		if err != nil || line != "ready\n" {
			t.Errorf("ready line = %q, %v", line, err)
		}
	}
}

// manualHelperDeadline replaces helperDeadline for one test: the helper's
// deadline passes when the test calls fire, not on a real clock.
func manualHelperDeadline(t *testing.T) (fire func()) {
	t.Helper()
	d := &firedDeadline{done: make(chan struct{})}
	prev := helperDeadline
	helperDeadline = func(parent context.Context, _ time.Duration) (context.Context, context.CancelFunc) {
		d.Context = parent
		return d, func() {}
	}
	t.Cleanup(func() { helperDeadline = prev })
	return d.fire
}

// firedDeadline is a context whose deadline the test fires: Err is
// context.DeadlineExceeded from then on. The tests' parents are never
// cancelled, so only the fire ends it.
type firedDeadline struct {
	context.Context
	once sync.Once
	done chan struct{}
}

func (c *firedDeadline) fire()                       { c.once.Do(func() { close(c.done) }) }
func (c *firedDeadline) Done() <-chan struct{}       { return c.done }
func (c *firedDeadline) Deadline() (time.Time, bool) { return time.Time{}, false }
func (c *firedDeadline) Err() error {
	select {
	case <-c.done:
		return context.DeadlineExceeded
	default:
		return nil
	}
}
