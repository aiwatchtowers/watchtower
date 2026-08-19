package daemon

import (
	"context"
	"os"
	"os/signal"
	"syscall"
)

// TriggerSignal asks a running daemon to start a sync immediately instead of
// waiting for the next poll tick. SIGUSR1 is the whole IPC surface: the daemon
// already owns an exclusive flock on sync.lock (cmd/sync.go), so a second
// process cannot simply run a sync of its own — it has to ask the one holding
// the lock.
const TriggerSignal = syscall.SIGUSR1

// WatchTrigger returns a channel that fires once per TriggerSignal received.
// Sends are non-blocking, so triggers arriving while a sync is already running
// collapse into the single one already queued — the WatchWake contract, for the
// same reason: the daemon runs syncs sequentially, and a backlog of queued
// triggers would just replay the same sync back to back.
func WatchTrigger(ctx context.Context) <-chan struct{} {
	ch := make(chan struct{}, 1)
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, TriggerSignal)
	go func() {
		defer signal.Stop(sigCh)
		defer close(ch)
		for {
			select {
			case <-ctx.Done():
				return
			case <-sigCh:
				select {
				case ch <- struct{}{}:
				default:
				}
			}
		}
	}()
	return ch
}
