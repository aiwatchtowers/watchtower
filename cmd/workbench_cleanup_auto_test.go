package cmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/sessionhost"
	"watchtower/internal/sessionstart"
)

// TestLiveRows: only a host with no socket file or nothing listening is no
// live run; any other failure, a host's own included, is an error (the pass
// then applies nothing); runs become rows.
func TestLiveRows(t *testing.T) {
	for name, cause := range map[string]error{
		"no socket file":    &net.OpError{Op: "dial", Err: &os.SyscallError{Syscall: "connect", Err: syscall.ENOENT}},
		"nothing listening": &net.OpError{Op: "dial", Err: &os.SyscallError{Syscall: "connect", Err: syscall.ECONNREFUSED}},
	} {
		live, err := liveRows(nil, fmt.Errorf("%w: dial session host: %w", sessionstart.ErrHostNotRunning, cause))
		if err != nil || len(live) != 0 {
			t.Fatalf("%s: %v, %v", name, live, err)
		}
	}
	for name, err := range map[string]error{
		"handshake timeout":  fmt.Errorf("%w: session host hello: %w", sessionstart.ErrHostNotRunning, context.DeadlineExceeded),
		"protocol refusal":   fmt.Errorf("%w: %w", sessionstart.ErrHostNotRunning, sessionhost.ErrHostV1),
		"list failed":        errors.New("listing the session host: broken"),
		"refusal not a dial": fmt.Errorf("listing the session host: %w", syscall.ECONNREFUSED),
	} {
		if _, got := liveRows(nil, err); got == nil {
			t.Errorf("%s: no error", name)
		}
	}
	live, err := liveRows(map[int64]time.Time{4: {}, 9: {}}, nil)
	if err != nil || !live[4] || !live[9] || len(live) != 2 {
		t.Fatalf("runs: %v, %v", live, err)
	}
}

// TestWaitCleanupLock_SaysItWaits (#2131): a free lock is taken at once and
// silently; a held one prints the notice, then waits only up to its bound.
func TestWaitCleanupLock_SaysItWaits(t *testing.T) {
	path := filepath.Join(t.TempDir(), "repo.cleanup.lock")
	var notice bytes.Buffer
	unlock, err := waitCleanupLock(context.Background(), path, &notice, time.Second)
	if err != nil || notice.Len() != 0 {
		t.Fatalf("free lock: err %v, notice %q", err, notice.String())
	}
	defer unlock()
	if _, err := waitCleanupLock(context.Background(), path, &notice, 0); err == nil {
		t.Fatal("a held lock was taken")
	}
	if !strings.Contains(notice.String(), "waiting for another cleanup") {
		t.Fatalf("notice %q", notice.String())
	}
}

// TestCleanupRequest_PruneBuildsOnlyForAnUnnamedApply (#2131): only an
// apply that names no item asks to drop kept worktrees' build output.
func TestCleanupRequest_PruneBuildsOnlyForAnUnnamedApply(t *testing.T) {
	noEnv := func(string) (string, bool) { return "", false }
	for name, tc := range map[string]struct {
		f    cleanupFlags
		want bool
	}{
		"plan":        {f: cleanupFlags{session: 5}},
		"apply":       {f: cleanupFlags{session: 5, apply: true}, want: true},
		"named apply": {f: cleanupFlags{session: 5, apply: true, items: []string{"branch:x"}}},
	} {
		req, err := cleanupRequest(tc.f, true, noEnv)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if req.PruneBuilds != tc.want {
			t.Errorf("%s: PruneBuilds = %v, want %v", name, req.PruneBuilds, tc.want)
		}
	}
}
