package cloudkit

import (
	"context"
	"errors"
	"log"
	"os"
	"syscall"
	"time"
)

// The Supervisor's restart backoff: 1 s, doubling to 60 s; a bridge that ran
// at least healthyRun before it exited starts the backoff over.
const (
	minBackoff = time.Second
	maxBackoff = 60 * time.Second
	healthyRun = 60 * time.Second
	// stopGrace is how long a stopped bridge gets after SIGTERM before
	// SIGKILL.
	stopGrace = 5 * time.Second
)

// Supervisor keeps the bridge process running while the hub runs on a
// desktop host: it launches it with Config.Launch, restarts it with backoff
// when it exits or fails to start, and stops it when its context ends.
type Supervisor struct {
	c     Config
	sleep func(ctx context.Context, d time.Duration) error
}

// NewSupervisor returns a supervisor for c.Launch.
func NewSupervisor(c Config) *Supervisor {
	if c.Clock == nil {
		c.Clock = time.Now
	}
	return &Supervisor{c: c, sleep: sleepCtx}
}

// Run supervises until ctx ends, then stops the bridge and returns ctx's
// error.
func (s *Supervisor) Run(ctx context.Context) error {
	if s.c.Launch == nil {
		return errors.New("cloudkit: no bridge launcher")
	}
	backoff := minBackoff
	for ctx.Err() == nil {
		start := s.c.Clock()
		s.runOnce(ctx)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if s.c.Clock().Sub(start) >= healthyRun {
			backoff = minBackoff
		}
		log.Printf("hub: cloudkit bridge exited: restart in %s", backoff)
		if err := s.sleep(ctx, backoff); err != nil {
			return err
		}
		backoff = min(2*backoff, maxBackoff)
	}
	return ctx.Err()
}

// runOnce launches the bridge and waits for it to exit (or ctx to end).
func (s *Supervisor) runOnce(ctx context.Context) {
	p, err := s.c.Launch(ctx)
	if err != nil {
		log.Printf("hub: cloudkit bridge did not start (%s)", launchClass(err))
		return
	}
	s.wait(ctx, p)
}

// wait returns when p exits; when ctx ends first it stops p's process group
// (SIGTERM, then SIGKILL after stopGrace — Config.Launch starts the bridge
// as its own group's leader) and reaps it.
func (s *Supervisor) wait(ctx context.Context, p *os.Process) {
	done := make(chan struct{})
	go func() {
		_, _ = p.Wait()
		close(done)
	}()
	select {
	case <-done:
		return
	case <-ctx.Done():
	}
	stopGroup(p, syscall.SIGTERM)
	t := time.NewTimer(stopGrace)
	defer t.Stop()
	select {
	case <-done:
	case <-t.C:
		stopGroup(p, syscall.SIGKILL)
		<-done
	}
}

// stopGroup signals p's process group, or p alone when it leads none.
func stopGroup(p *os.Process, sig syscall.Signal) {
	if err := syscall.Kill(-p.Pid, sig); err != nil {
		_ = p.Signal(sig)
	}
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// launchClass is a launch error's class, never its text (FILES-01).
func launchClass(err error) string {
	switch {
	case errors.Is(err, os.ErrNotExist):
		return "not_found"
	case errors.Is(err, os.ErrPermission):
		return "permission"
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return "canceled"
	}
	return "failed"
}
