package daemon

import (
	"context"
	"os"
	"syscall"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestWatchTrigger_FiresOnSignal(t *testing.T) {
	ctx := t.Context()

	ch := WatchTrigger(ctx)
	require.NoError(t, syscall.Kill(os.Getpid(), TriggerSignal))

	_, ok := <-ch
	assert.True(t, ok, "channel should deliver a trigger, not a close")
}

// A burst of triggers must not block the signal-forwarding goroutine: the
// daemon syncs sequentially, so extra triggers collapse into the queued one
// rather than piling up into a queue of identical syncs.
func TestWatchTrigger_CoalescesBurst(t *testing.T) {
	ctx := t.Context()

	ch := WatchTrigger(ctx)
	for range 5 {
		require.NoError(t, syscall.Kill(os.Getpid(), TriggerSignal))
	}

	<-ch

	// The forwarder is still alive and serving after the burst.
	require.NoError(t, syscall.Kill(os.Getpid(), TriggerSignal))
	<-ch
}

func TestWatchTrigger_ClosesOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	ch := WatchTrigger(ctx)
	cancel()

	for {
		_, ok := <-ch
		if !ok {
			return // closed, as expected
		}
	}
}

func TestTriggerChannel_NilWhenNotWired(t *testing.T) {
	d := &Daemon{}
	assert.Nil(t, d.triggerChannel(), "trigger channel should be nil when not configured")
}
