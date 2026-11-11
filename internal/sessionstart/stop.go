package sessionstart

import (
	"context"
	"errors"
	"fmt"
	"time"

	"watchtower/internal/sessionhost"
)

// Stop's wait for the exit after the Stopping answer: the host's grace
// (SIGHUP, then SIGKILL after 3 s) with room to spare, read every
// stopExitPoll.
const (
	stopExitWait = 10 * time.Second
	stopExitPoll = 100 * time.Millisecond
)

// ErrStopNoExit means the host took the Stop request, but its run had not
// exited within stopExitWait, so it was not forgotten.
var ErrStopNoExit = errors.New("the session did not exit after the stop request")

// Stop stops a session the owner asked to stop (phone or Desktop): a host
// Stop request, never a signal of its own, so the host's Exit for it carries
// requested: true (the Desktop maps it to closedByApp: no PROJ-18 cleanup).
// Once the exit is reported the run is forgotten. A session not running in
// this workspace's scope is left as it is (nil).
func Stop(ctx context.Context, d Deps, sessionID int64) error {
	c, done, err := d.lease(ctx)
	if err != nil {
		return err
	}
	err = stopOn(ctx, c, d.scope(), sessionID)
	done(err)
	return err
}

func stopOn(ctx context.Context, c *sessionhost.Client, scope string, sessionID int64) error {
	list, err := c.List(ctx)
	if err != nil {
		return fmt.Errorf("listing the session host: %w", err)
	}
	info, ok := findRun(list, scope, sessionID)
	if !ok || info.Exited {
		return nil
	}
	if _, err := c.Stop(ctx, sessionhost.StopReq{Row: info.Row, Run: info.Run, Launch: info.Launch}); err != nil {
		return fmt.Errorf("stopping session %d: %w", sessionID, err)
	}
	deadline := time.NewTimer(stopExitWait)
	defer deadline.Stop()
	tick := time.NewTicker(stopExitPoll)
	defer tick.Stop()
	for {
		list, err := c.List(ctx)
		if err != nil {
			return fmt.Errorf("listing the session host: %w", err)
		}
		if exited(list, info) {
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err() //nolint:wrapcheck // the caller's own cancellation
		case <-deadline.C:
			return ErrStopNoExit
		case <-tick.C:
		}
	}
	// The Desktop's pane forgets the run too when it sees the exit; a run
	// it forgot first is not an error.
	var he *sessionhost.HostError
	if err := c.Forget(ctx, info.Row, info.Run); err != nil && !errors.As(err, &he) {
		return fmt.Errorf("forgetting session %d: %w", sessionID, err)
	}
	return nil
}

// exited reports whether run is gone or has exited.
func exited(list []sessionhost.SessionInfo, run sessionhost.SessionInfo) bool {
	for _, info := range list {
		if info.Row == run.Row && info.Run == run.Run {
			return info.Exited
		}
	}
	return true
}
