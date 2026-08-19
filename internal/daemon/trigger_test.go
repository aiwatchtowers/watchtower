package daemon

import (
	"context"
	"os"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestWatchTrigger_FiresOnSignal(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ch := WatchTrigger(ctx)
	require.NoError(t, syscall.Kill(os.Getpid(), TriggerSignal))

	select {
	case _, ok := <-ch:
		assert.True(t, ok, "channel should deliver a trigger, not a close")
	case <-time.After(2 * time.Second):
		t.Fatal("trigger signal did not reach the channel")
	}
}

// A burst of triggers must not block the signal-forwarding goroutine: the
// daemon syncs sequentially, so extra triggers collapse into the queued one
// rather than piling up into a queue of identical syncs.
func TestWatchTrigger_CoalescesBurst(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ch := WatchTrigger(ctx)
	for i := 0; i < 5; i++ {
		require.NoError(t, syscall.Kill(os.Getpid(), TriggerSignal))
	}

	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal("trigger signal did not reach the channel")
	}

	// The forwarder is still alive and serving after the burst.
	require.NoError(t, syscall.Kill(os.Getpid(), TriggerSignal))
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal("forwarder stopped serving after a burst")
	}
}

func TestWatchTrigger_ClosesOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	ch := WatchTrigger(ctx)
	cancel()

	deadline := time.After(2 * time.Second)
	for {
		select {
		case _, ok := <-ch:
			if !ok {
				return // closed, as expected
			}
		case <-deadline:
			t.Fatal("trigger channel was not closed after context cancellation")
		}
	}
}

func TestTriggerChannel_NilWhenNotWired(t *testing.T) {
	d := &Daemon{}
	assert.Nil(t, d.triggerChannel(), "trigger channel should be nil when not configured")
}
