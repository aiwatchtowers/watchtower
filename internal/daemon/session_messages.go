package daemon

import (
	"context"
	"fmt"
	"path/filepath"
)

// SessionMessagesWakeCapability is the capabilities-file line of a daemon
// that delivers agent messages and serves AutomationWakeSignal for them
// (spec 2026-11-18 §6.6): send_to_session signals only such a daemon, and a
// sender that finds none relies on the deliverer's 2 s tick.
const SessionMessagesWakeCapability = "session-messages-wake"

// MessageDeliverer is the daemon's agent-message deliverer
// (*delivery.Deliverer): Start blocks until ctx is done; Wake never blocks.
type MessageDeliverer interface {
	Start(ctx context.Context) error
	Wake()
}

// SetMessageDeliverer attaches the agent-message deliverer; Run starts it
// beside the sync loop and forwards every AutomationWakeSignal to it. The
// daemon's single instance (the sync lock) is what makes it the one
// deliverer.
func (d *Daemon) SetMessageDeliverer(m MessageDeliverer) { d.messages = m }

// startSessionMessages starts the deliverer (and, when no automations wake
// forwarder runs, its own forwarder of the wake signal) as goroutines of
// their own; the returned stop cancels and waits for them.
func (d *Daemon) startSessionMessages(ctx context.Context) (stop func()) {
	if d.messages == nil {
		return func() {}
	}
	runCtx, cancel := context.WithCancel(ctx)
	done := make(chan struct{}, 2)
	n := 1
	go func() {
		defer func() { done <- struct{}{} }()
		if err := d.messages.Start(runCtx); err != nil {
			d.logger.Printf("session messages: deliverer stopped: %v", err)
		}
	}()
	if !d.automationsActive() {
		n++
		go func() {
			defer func() { done <- struct{}{} }()
			d.forwardMessageWakes(runCtx)
		}()
	}
	return func() {
		cancel()
		for range n {
			<-done
		}
	}
}

// forwardMessageWakes hands every wake to the deliverer until ctx is done or
// the wake channel closes (forwardAutomationWakes does it when automations
// run).
func (d *Daemon) forwardMessageWakes(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case _, ok := <-d.automationWakeCh:
			if !ok {
				return
			}
			d.messages.Wake()
		}
	}
}

// wakeMessages wakes the deliverer; a no-op with none wired.
func (d *Daemon) wakeMessages() {
	if d.messages != nil {
		d.messages.Wake()
	}
}

// DaemonRunning reports whether a daemon runs for the workspace: the pid in
// <workspaceDir>/daemon.pid is a live, confirmed watchtower daemon. It only
// reads the pid file (PeekProcess) and never takes sync.lock: holding that
// lock even briefly could make a starting daemon fail with "another sync is
// already running", and a one-shot `watchtower sync` holds it without
// delivering. A pid whose identity cannot be confirmed is not running.
func DaemonRunning(workspaceDir string) (bool, error) {
	_, state, err := PeekProcess(filepath.Join(workspaceDir, "daemon.pid"))
	if err != nil {
		return false, fmt.Errorf("reading the daemon's pid file: %w", err)
	}
	return state == PeekRunning, nil
}
