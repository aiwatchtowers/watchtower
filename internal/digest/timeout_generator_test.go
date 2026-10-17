package digest

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os/exec"
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

type errGenerator struct{ err error }

func (g errGenerator) Generate(context.Context, string, string, string) (string, *Usage, string, error) {
	return "", nil, "", g.err
}

// #580: a transport-level failure (the process could not start or was
// killed, the network, a timeout) matches ErrAICall so the history backfill
// retries it; a reply the call did get back does not. The message and the
// inner error stay as they were.
func TestWithCallTimeout_TransportFailureIsAnAICallError(t *testing.T) {
	gen := func(err error) error {
		_, _, _, got := WithCallTimeout(errGenerator{err}, time.Minute).Generate(context.Background(), "s", "u", "")
		require.Error(t, got)
		assert.Equal(t, err.Error(), got.Error(), "message unchanged")
		assert.ErrorIs(t, got, err)
		return got
	}
	killed := exec.Command("sh", "-c", "kill -9 $$").Run()
	var exitErr *exec.ExitError
	require.ErrorAs(t, killed, &exitErr)
	exited := exec.Command("sh", "-c", "exit 1").Run()
	require.ErrorAs(t, exited, &exitErr)

	transport := map[string]error{
		"not found": WithCause(errors.New("claude CLI not found at \"claude\""), exec.ErrNotFound),
		"start":     fmt.Errorf("claude CLI error: %w", &exec.Error{Name: "claude", Err: errors.New("permission denied")}),
		"killed":    WithCause(errors.New("claude CLI failed (exit -1): signal: killed"), killed),
		"network":   fmt.Errorf("ollama request failed: %w", &net.OpError{Op: "dial", Err: errors.New("refused")}),
		"deadline":  fmt.Errorf("x: %w", context.DeadlineExceeded),
	}
	for name, err := range transport {
		assert.ErrorIs(t, gen(err), ErrAICall, name)
	}
	// A provider outage reported in the envelope or on stderr is transport
	// too: the request was fine, the provider was not.
	outage := map[string]error{
		"connection error": WithCause(errors.New("claude CLI failed (exit 1, subtype=success, stop_reason=): API Error: Connection error."), exited),
		"overloaded":       errors.New(`claude returned error (subtype=success): API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}`),
		"500":              errors.New("claude returned error (subtype=success): API Error: 500 Internal server error"),
		"503":              WithCause(errors.New("claude CLI failed (exit 1): API Error: 503 Service Unavailable"), exited),
		"429":              errors.New(`claude returned error (subtype=success): API Error: 429 {"type":"error","error":{"type":"rate_limit_error"}}`),
		"rate limit":       errors.New("codex error: rate_limit_error: slow down"),
		"timed out":        errors.New("claude returned error (subtype=success): Request timed out."),
		"codex 502":        WithCause(errors.New("codex CLI failed (exit 1): unexpected status code 502 Bad Gateway"), exited),
	}
	for name, err := range outage {
		assert.ErrorIs(t, gen(err), ErrAICall, name)
	}
	reply := map[string]error{
		"max turns": errors.New("claude returned error (subtype=error_max_turns): too many turns"),
		"empty":     errors.New("claude returned empty result (turns=1, tokens=1+0)"),
		"format":    errors.New("unexpected claude CLI output format: 12 bytes"),
		"exit 1":    WithCause(errors.New("claude CLI failed (exit 1): API Error: 400 prompt is too long"), exited),
		"bad cert": fmt.Errorf("ollama request failed: %w", &url.Error{Op: "Post", URL: "https://ollama.example.com",
			Err: errors.New("x509: certificate signed by unknown authority")}),
		"auth": errors.New("claude returned error (subtype=success): Invalid API key"),
	}
	for name, err := range reply {
		assert.NotErrorIs(t, gen(err), ErrAICall, name)
	}

	_, _, _, err := WithCallTimeout(blockingGenerator{}, 10*time.Millisecond).Generate(context.Background(), "s", "u", "")
	assert.ErrorIs(t, err, ErrAICall, "the call's own timeout is a transport failure")

	_, _, _, err = WithCallTimeout(&fastGenerator{}, time.Minute).Generate(context.Background(), "s", "u", "")
	assert.NoError(t, err)
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
	// The error must be recognisable as a deadline at every caller, not just
	// readable: callers distinguish "the AI call timed out" from a genuine
	// generator failure with errors.Is.
	assert.ErrorIs(t, err, context.DeadlineExceeded)
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

// TestWithCallTimeout_ParentDeadlineIsNotReportedAsTheCap: when the CALLER's
// context expires first, the failure belongs to the caller, not to the
// daemon's 10-minute cap — reporting "ai call exceeded 10m0s" on a call that
// ran for milliseconds would send whoever reads the log hunting a hang that
// never happened.
func TestWithCallTimeout_ParentDeadlineIsNotReportedAsTheCap(t *testing.T) {
	gen := WithCallTimeout(blockingGenerator{}, time.Minute)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()

	_, _, _, err := gen.Generate(ctx, "sys", "user", "")
	require.Error(t, err)
	assert.ErrorIs(t, err, context.DeadlineExceeded)
	assert.NotContains(t, err.Error(), "ai call exceeded",
		"the caller's own deadline must not be reported as the daemon AI cap")
}

// TestCallTimeout_ReportsTheBound: the wiring tests that pin an unattended AI
// path as bounded (H8) need boundedness to be observable from outside.
func TestCallTimeout_ReportsTheBound(t *testing.T) {
	d, ok := CallTimeout(WithCallTimeout(&fastGenerator{}, 3*time.Minute))
	assert.True(t, ok)
	assert.Equal(t, 3*time.Minute, d)

	_, ok = CallTimeout(&fastGenerator{})
	assert.False(t, ok, "an unwrapped generator carries no bound")
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
