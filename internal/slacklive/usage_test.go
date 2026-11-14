package slacklive

import (
	"context"
	"os"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/llmusage"
)

type callSink struct {
	mu    sync.Mutex
	calls []llmusage.Call
}

func (s *callSink) Write(c llmusage.Call) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls = append(s.calls, c)
	return nil
}

func (s *callSink) all() []llmusage.Call {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]llmusage.Call(nil), s.calls...)
}

type discardSink struct{}

func (discardSink) Write(llmusage.Call) error { return nil }

func captureCalls(t *testing.T) *callSink {
	t.Helper()
	s := &callSink{}
	llmusage.SetSink(s)
	t.Cleanup(func() { llmusage.SetSink(discardSink{}) })
	return s
}

// LLMUSAGE-01: the claude probe's model turn is one ledger row with the
// result line's usage, cost and model.
func TestLiveProbe_ClaudeRecordsItsModelCall(t *testing.T) {
	sink := captureCalls(t)
	env := append(os.Environ(), "SCENARIO=ok", "API_KEY_SRC=none")
	r := ProbeClaude(context.Background(), stub(t, "fake_claude.sh"), env)
	require.Equal(t, StatusOK, r.Status)
	calls := sink.all()
	require.Len(t, calls, 1)
	c := calls[0]
	assert.Equal(t, ProbePurpose, c.Purpose)
	assert.Equal(t, "watchtower", c.Surface)
	assert.Equal(t, "claude", c.Provider)
	assert.Equal(t, "claude-haiku-5-5", c.Model)
	assert.True(t, c.OK)
	assert.False(t, c.Estimated)
	assert.Equal(t, int64(120), c.Input)
	assert.Equal(t, int64(30), c.CacheRead)
	assert.Equal(t, int64(7), c.Output)
	require.NotNil(t, c.ReportedCostUSD)
	assert.InDelta(t, 0.0012, *c.ReportedCostUSD, 1e-9)
}

// A connector that never connects asks no model turn: nothing is recorded.
func TestLiveProbe_ClaudeNoTurnNoCall(t *testing.T) {
	shortConnect(t)
	sink := captureCalls(t)
	env := append(os.Environ(), "SCENARIO=absent", "API_KEY_SRC=none")
	r := ProbeClaude(context.Background(), stub(t, "fake_claude.sh"), env)
	require.Equal(t, StatusNotConnected, r.Status)
	assert.Empty(t, sink.all())
}

// A turn with no usage on the stream is recorded as an estimate.
func TestLiveProbe_ClaudeNoUsageIsEstimated(t *testing.T) {
	sink := captureCalls(t)
	env := append(os.Environ(), "SCENARIO=unknown", "API_KEY_SRC=none")
	ProbeClaude(context.Background(), stub(t, "fake_claude.sh"), env)
	calls := sink.all()
	require.Len(t, calls, 1)
	assert.True(t, calls[0].Estimated)
	assert.Equal(t, llmusage.EstimateTokens(claudeProbePrompt), calls[0].Input)
}

// The codex probe records its turn.completed usage, cached input as cache
// reads (each exec child, the warm-up included, is a call of its own).
func TestLiveProbe_CodexRecordsItsModelCalls(t *testing.T) {
	sink := captureCalls(t)
	home := codexHomeWith(t, "chatgpt", true)
	env := append(os.Environ(), "SCENARIO=ok", "CODEX_HOME="+home)
	r := ProbeCodex(context.Background(), stub(t, "fake_codex.sh"), env)
	require.Equal(t, StatusOK, r.Status)
	calls := sink.all()
	require.Len(t, calls, 1)
	c := calls[0]
	assert.Equal(t, ProbePurpose, c.Purpose)
	assert.Equal(t, "codex", c.Provider)
	assert.True(t, c.OK)
	assert.False(t, c.Estimated)
	assert.Equal(t, int64(80), c.Input)
	assert.Equal(t, int64(20), c.CacheRead)
	assert.Equal(t, int64(5), c.Output)
}
