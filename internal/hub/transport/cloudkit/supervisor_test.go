package cloudkit_test

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/hub/transport/cloudkit"
)

// stubs starts stub bridge processes, each in its own process group, and
// reaps every group at the test's end.
type stubs struct {
	t    *testing.T
	mu   sync.Mutex
	pids []int
}

func newStubs(t *testing.T) *stubs {
	s := &stubs{t: t}
	t.Cleanup(func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		for _, pid := range s.pids {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
			if p, err := os.FindProcess(pid); err == nil {
				_, _ = p.Wait()
			}
		}
	})
	return s
}

func (s *stubs) start(script string) (*os.Process, error) {
	cmd := exec.Command("/bin/sh", "-c", script)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	s.pids = append(s.pids, cmd.Process.Pid)
	s.mu.Unlock()
	return cmd.Process, nil
}

// fakeClock moves only when advanced.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

func TestSupervisorRestartsWithBackoff(t *testing.T) {
	st := newStubs(t)
	clock := &fakeClock{now: time.Unix(1_800_000_000, 0)}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	launches := 0
	failLaunch := 3 // the third launch fails to start at all
	healthy := 10   // the tenth run lasts past the healthy mark
	var mu sync.Mutex
	s := cloudkit.NewSupervisor(cloudkit.Config{Clock: clock.Now, Launch: func(context.Context) (*os.Process, error) {
		mu.Lock()
		launches++
		n := launches
		mu.Unlock()
		if n == failLaunch {
			return nil, os.ErrNotExist
		}
		if n == healthy {
			clock.advance(61 * time.Second)
		}
		return st.start("exit 1")
	}})
	var waits []time.Duration
	cloudkit.SetSleep(s, func(_ context.Context, d time.Duration) error {
		waits = append(waits, d)
		if len(waits) == 12 {
			cancel()
			return context.Canceled
		}
		return nil
	})
	if err := s.Run(ctx); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	sec := time.Second
	want := []time.Duration{sec, 2 * sec, 4 * sec, 8 * sec, 16 * sec, 32 * sec, 60 * sec, 60 * sec, 60 * sec, sec, 2 * sec, 4 * sec}
	if !slices.Equal(waits, want) {
		t.Fatalf("backoff %v, want %v", waits, want)
	}
}

func TestSupervisorStopsTheBridgeWithItsContext(t *testing.T) {
	st := newStubs(t)
	ctx, cancel := context.WithCancel(context.Background())
	started := make(chan *os.Process, 1)
	s := cloudkit.NewSupervisor(cloudkit.Config{Launch: func(context.Context) (*os.Process, error) {
		p, err := st.start("exec sleep 30")
		if err == nil {
			started <- p
		}
		return p, err
	}})
	done := make(chan error, 1)
	go func() { done <- s.Run(ctx) }()
	var p *os.Process
	select {
	case p = <-started:
	case <-time.After(10 * time.Second):
		t.Fatal("the bridge was not launched")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Run did not return after its context ended")
	}
	if err := p.Signal(syscall.Signal(0)); !errors.Is(err, os.ErrProcessDone) {
		t.Fatalf("the bridge still runs: %v", err)
	}
}

func TestSupervisorWithoutLauncher(t *testing.T) {
	if err := cloudkit.NewSupervisor(cloudkit.Config{}).Run(context.Background()); err == nil {
		t.Fatal("ran without a launcher")
	}
}

// TestSupervisorStopsTheWholeProcessGroup: stopping signals the bridge's
// process group, so a helper the bridge started goes with it.
func TestSupervisorStopsTheWholeProcessGroup(t *testing.T) {
	st := newStubs(t)
	pidFile := filepath.Join(t.TempDir(), "child.pid")
	ctx, cancel := context.WithCancel(context.Background())
	s := cloudkit.NewSupervisor(cloudkit.Config{Launch: func(context.Context) (*os.Process, error) {
		return st.start("sleep 30 & echo $! > '" + pidFile + "'; wait")
	}})
	done := make(chan error, 1)
	go func() { done <- s.Run(ctx) }()
	var child int
	deadline := time.Now().Add(10 * time.Second)
	for child == 0 {
		if b, err := os.ReadFile(pidFile); err == nil {
			child, _ = strconv.Atoi(strings.TrimSpace(string(b)))
		}
		if time.Now().After(deadline) {
			t.Fatal("the bridge's helper did not start")
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Cleanup(func() { _ = syscall.Kill(child, syscall.SIGKILL) })
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	for syscall.Kill(child, 0) == nil {
		if time.Now().After(deadline) {
			t.Fatal("the bridge's helper outlived the stop")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
