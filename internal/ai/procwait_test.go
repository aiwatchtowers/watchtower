package ai

import (
	"bufio"
	"context"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// groupFIFO is a FIFO a stub's whole process group holds open: the stub's
// script starts with prefix(), which opens it as fd 3 — inherited by every
// process the stub starts — and writes the stub's pid there. The test waits
// only on process events: the pid line (the stub is running) and EOF (every
// process of the group has exited). No deadline: a wait that never ends is
// go test -timeout's to report.
type groupFIFO struct {
	path string
	r    *os.File
	pid  int
}

func newGroupFIFO(t *testing.T) *groupFIFO {
	t.Helper()
	g := &groupFIFO{path: filepath.Join(t.TempDir(), "group")}
	require.NoError(t, syscall.Mkfifo(g.path, 0o600))
	t.Cleanup(func() {
		if g.pid > 0 {
			_ = syscall.Kill(-g.pid, syscall.SIGKILL)
		}
		if g.r != nil {
			_ = g.r.Close()
			return
		}
		// The stub may still be blocked opening the FIFO: a reader that comes
		// and goes lets it on, and its first write then ends it (SIGPIPE).
		if fd, err := syscall.Open(g.path, syscall.O_RDONLY|syscall.O_NONBLOCK, 0); err == nil {
			_ = syscall.Close(fd)
		}
	})
	return g
}

// prefix is the stub script's first lines.
func (g *groupFIFO) prefix() string {
	return "exec 3>'" + g.path + "'\necho $$ >&3\n"
}

// waitPID returns the stub's pid (= its process group id) once it has
// written it.
func (g *groupFIFO) waitPID(t *testing.T) int {
	t.Helper()
	r, err := os.Open(g.path) // blocks until the stub opens its end
	require.NoError(t, err)
	g.r = r
	line, err := bufio.NewReader(r).ReadString('\n')
	require.NoError(t, err)
	g.pid, err = strconv.Atoi(strings.TrimSpace(line))
	require.NoError(t, err)
	return g.pid
}

// waitGone returns once every process holding the FIFO — the stub's whole
// group — has exited.
func (g *groupFIFO) waitGone(t *testing.T) {
	t.Helper()
	_, err := io.Copy(io.Discard, g.r)
	require.NoError(t, err)
}

// setGroupKillGrace replaces ConfigureChild's grace for one test.
func setGroupKillGrace(t *testing.T, d time.Duration) {
	t.Helper()
	prev := groupKillGrace
	groupKillGrace = d
	t.Cleanup(func() { groupKillGrace = prev })
}

// firedDeadline is a context whose deadline the test fires: Err is
// context.DeadlineExceeded from then on, as for a deadline that passed, with
// no real clock behind it.
type firedDeadline struct {
	context.Context
	once sync.Once
	done chan struct{}
}

func newFiredDeadline() *firedDeadline {
	return &firedDeadline{Context: context.Background(), done: make(chan struct{})}
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
