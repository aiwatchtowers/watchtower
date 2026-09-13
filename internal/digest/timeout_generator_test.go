package digest

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// blockingGenerator blocks until ctx is done, then returns ctx.Err().
type blockingGenerator struct{}

func (blockingGenerator) Generate(ctx context.Context, _, _, _ string) (string, *Usage, string, error) {
	<-ctx.Done()
	return "", nil, "", ctx.Err()
}

// fastGenerator returns immediately with a fixed result, recording the
// arguments it was called with.
type fastGenerator struct {
	systemPrompt, userMessage, sessionID string
}

func (g *fastGenerator) Generate(_ context.Context, systemPrompt, userMessage, sessionID string) (string, *Usage, string, error) {
	g.systemPrompt, g.userMessage, g.sessionID = systemPrompt, userMessage, sessionID
	return "result", &Usage{OutputTokens: 7, Model: "test-model"}, "session-123", nil
}

// TestWithCallTimeout_BlockingGeneratorTimesOut pins H8: a hung claude/codex
// subprocess must not freeze the daemon's sequential cycle forever — the
// decorator must return within its own timeout with an error naming it.
func TestWithCallTimeout_BlockingGeneratorTimesOut(t *testing.T) {
	const timeout = 50 * time.Millisecond
	gen := WithCallTimeout(blockingGenerator{}, timeout)

	start := time.Now()
	result, usage, sessionID, err := gen.Generate(context.Background(), "sys", "user", "")
	elapsed := time.Since(start)

	require.Error(t, err)
	assert.Contains(t, err.Error(), "ai call exceeded")
	assert.Contains(t, err.Error(), timeout.String())
	assert.Empty(t, result)
	assert.Nil(t, usage)
	assert.Empty(t, sessionID)
	// Generous upper bound so this never flakes on a loaded CI box, but
	// tight enough to prove it didn't just fall through to the parent ctx.
	assert.Less(t, elapsed, 2*time.Second)
}

// TestWithCallTimeout_ParentCancellationPropagates ensures the decorator
// derives its timeout from the caller's ctx rather than replacing it — a
// parent cancellation (e.g. daemon shutdown) must still stop the call.
func TestWithCallTimeout_ParentCancellationPropagates(t *testing.T) {
	gen := WithCallTimeout(blockingGenerator{}, time.Minute)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, _, _, err := gen.Generate(ctx, "sys", "user", "")
		done <- err
	}()

	time.Sleep(10 * time.Millisecond)
	cancel()

	select {
	case err := <-done:
		require.Error(t, err)
		assert.ErrorIs(t, err, context.Canceled)
	case <-time.After(2 * time.Second):
		t.Fatal("Generate did not return after parent context cancellation")
	}
}

// TestWithCallTimeout_FastPathPassesThroughUnchanged pins the non-degenerate
// case: a call that finishes well within the timeout must pass through the
// inner generator's result, usage, and sessionID untouched, and the inner
// generator must see the caller's original arguments.
func TestWithCallTimeout_FastPathPassesThroughUnchanged(t *testing.T) {
	inner := &fastGenerator{}
	gen := WithCallTimeout(inner, time.Minute)

	result, usage, sessionID, err := gen.Generate(context.Background(), "sys-prompt", "user-msg", "prior-session")
	require.NoError(t, err)
	assert.Equal(t, "result", result)
	require.NotNil(t, usage)
	assert.Equal(t, 7, usage.OutputTokens)
	assert.Equal(t, "test-model", usage.Model)
	assert.Equal(t, "session-123", sessionID)

	assert.Equal(t, "sys-prompt", inner.systemPrompt)
	assert.Equal(t, "user-msg", inner.userMessage)
	assert.Equal(t, "prior-session", inner.sessionID)
}
