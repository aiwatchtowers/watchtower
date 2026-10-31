package sessionhost

import (
	"context"
	"fmt"
	"os/exec"
	"sync"
	"syscall"
	"testing"
	"time"
)

// useLauncher installs l for Ensure until the test ends.
func useLauncher(t testing.TB, l launcher) {
	t.Helper()
	old := testLauncher
	testLauncher = l
	t.Cleanup(func() { testLauncher = old })
}

// childLauncher starts `<exe> session-host --socket <socket>` as a child of
// the test in its own process group.
type childLauncher struct {
	t    testing.TB
	mu   sync.Mutex
	pids []int
}

func (c *childLauncher) launch(_ context.Context, exe, socket string) error {
	cmd := exec.Command(exe, "session-host", "--socket", socket)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start test session host: %w", err)
	}
	pid := cmd.Process.Pid
	waited := make(chan struct{})
	go func() { _ = cmd.Wait(); close(waited) }()
	c.t.Cleanup(func() {
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		select {
		case <-waited:
		case <-time.After(ioTimeout):
			c.t.Errorf("test session host %d not reaped", pid)
		}
	})
	c.mu.Lock()
	c.pids = append(c.pids, pid)
	c.mu.Unlock()
	return nil
}

// SetTestLauncher makes Ensure start the host as a child of the test (its
// own process group, killed and waited for in t.Cleanup) instead of through
// the host's service manager, until the test ends. started lists the pids.
func SetTestLauncher(t testing.TB) (started func() []int) {
	t.Helper()
	c := &childLauncher{t: t}
	useLauncher(t, c)
	return func() []int {
		c.mu.Lock()
		defer c.mu.Unlock()
		return append([]int(nil), c.pids...)
	}
}
