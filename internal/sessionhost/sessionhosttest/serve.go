// Package sessionhosttest runs a session host inside a test process. Only
// tests import it (TestSessionhosttestIsImportedOnlyByTests).
package sessionhosttest

import (
	"context"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/sessionhost"
)

// ringSize is the `session-host` command's per-session ring (cmd).
const ringSize = 2 << 20

// reapWait bounds the cleanup's wait for the host and its sessions.
const reapWait = 10 * time.Second

// ServeInProcess serves a host on socket for the whole test. It never exits
// idle (IdleExit 0). t.Cleanup kills every hosted session's process group,
// waits for the host to see them exit, then stops Serve.
func ServeInProcess(t testing.TB, socket string) {
	t.Helper()
	l, err := sessionhost.Listen(socket)
	if err != nil {
		t.Fatalf("session host listen: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- sessionhost.NewServer(sessionhost.Options{IdleExit: 0, RingSize: ringSize}).Serve(ctx, l)
	}()
	t.Cleanup(func() {
		reapSessions(t, socket)
		cancel()
		select {
		case <-done:
		case <-time.After(reapWait):
			t.Error("the in-process session host did not stop")
		}
	})
}

// reapSessions kills each live session's group and waits until the host has
// reaped it.
func reapSessions(t testing.TB, socket string) {
	ctx, cancel := context.WithTimeout(context.Background(), reapWait)
	defer cancel()
	c, err := sessionhost.Dial(ctx, socket)
	if err != nil {
		return
	}
	defer func() { _ = c.Close() }()
	list, err := c.List(ctx)
	if err != nil {
		return
	}
	for _, info := range list {
		if info.Pid <= 0 || info.Exited {
			continue
		}
		_ = syscall.Kill(-info.Pid, syscall.SIGKILL)
		for syscall.Kill(info.Pid, 0) == nil {
			if ctx.Err() != nil {
				t.Errorf("hosted session %d still alive after SIGKILL", info.Pid)
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
}
