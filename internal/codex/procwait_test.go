package codex

import (
	"context"
	"errors"
	"os"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"testing/synctest"
	"time"
	"watchtower/internal/digest"
)

// The helpers below watch processes this test does not own (a stub's
// children, reparented once the stub is gone): their exit is seen only by
// polling. No deadline — a wait that never ends is go test -timeout's to
// report, its goroutine dump naming the helper.

// waitGroupGone returns once process group pgid has no process left.
func waitGroupGone(pgid int) {
	for !errors.Is(syscall.Kill(-pgid, 0), syscall.ESRCH) {
		time.Sleep(20 * time.Millisecond)
	}
}

// reapGroup kills process group pgid, if it is still there, and waits until
// it is gone. pgid <= 0 (the stub never ran) is a no-op.
func reapGroup(pgid int) {
	if pgid <= 0 {
		return
	}
	_ = syscall.Kill(-pgid, syscall.SIGKILL)
	waitGroupGone(pgid)
}

// readPID reads the pid a stub wrote to path; 0 while there is none.
func readPID(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	return n
}

// waitPID returns the pid a stub writes to path (atomically, by rename),
// once it is there.
func waitPID(path string) int {
	for {
		if pid := readPID(path); pid > 0 {
			return pid
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// generateBounded runs g behind the production call bound
// (digest.WithCallTimeout) in a synctest bubble: the bound is in the bubble's
// time, which does not move while the real child runs — the wrapper is on
// the path, its deadline never fires on a slow machine.
func generateBounded(t *testing.T, g digest.Generator, systemPrompt, userMessage string) (err error) {
	t.Helper()
	synctest.Test(t, func(*testing.T) {
		_, _, _, err = digest.WithCallTimeout(g, time.Minute).Generate(context.Background(), systemPrompt, userMessage, "")
	})
	return err
}
