package chat

import (
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/llmusage"
)

// ledgerSink collects the ledger calls recorded while it is installed.
type ledgerSink struct {
	mu    sync.Mutex
	calls []llmusage.Call
}

func (s *ledgerSink) Write(c llmusage.Call) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls = append(s.calls, c)
	return nil
}

func (s *ledgerSink) recorded() []llmusage.Call {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]llmusage.Call(nil), s.calls...)
}

func collectLedger(t *testing.T) *ledgerSink {
	t.Helper()
	s := &ledgerSink{}
	llmusage.SetSink(s)
	t.Cleanup(func() { llmusage.SetSink(nil) })
	return s
}

func TestClaudeTranslatorResultRecords(t *testing.T) {
	sink := collectLedger(t)
	tr := NewClaudeTranslator(fixedTurn("t1"))
	resultLine := `{"type":"result","subtype":"success","is_error":false,"result":"Hello","session_id":"s1",` +
		`"total_cost_usd":0.25,"usage":{"input_tokens":10,"cache_read_input_tokens":5,` +
		`"cache_creation_input_tokens":40,"cache_creation":{"ephemeral_5m_input_tokens":10,` +
		`"ephemeral_1h_input_tokens":30},"output_tokens":7},` +
		`"modelUsage":{"claude-opus-5-5":{"outputTokens":7}}}`
	evs := feedAll(t, tr, lnMsgStart, lnTextStart, textDelta(0, "Hello"), lnTextStop, lnMsgStop, resultLine)

	// The protocol events are unchanged by the recording.
	require.Equal(t, []string{EventTextDelta, EventUsage, EventTurnDone}, types(evs))
	assert.Equal(t, 55, evs[1].TokensIn)

	calls := sink.recorded()
	require.Len(t, calls, 1)
	c := calls[0]
	assert.Equal(t, "claude", c.Provider)
	assert.Equal(t, "claude-opus-5-5", c.Model)
	assert.Equal(t, int64(10), c.Input)
	assert.Equal(t, int64(5), c.CacheRead)
	assert.Equal(t, int64(10), c.CacheWrite5m)
	assert.Equal(t, int64(30), c.CacheWrite1h)
	assert.Equal(t, int64(7), c.Output)
	require.NotNil(t, c.ReportedCostUSD)
	assert.InDelta(t, 0.25, *c.ReportedCostUSD, 1e-9)
	assert.True(t, c.OK)
	assert.False(t, c.Estimated)
}

func TestClaudeTranslatorRecordsOneCallPerResult(t *testing.T) {
	sink := collectLedger(t)
	tr := NewClaudeTranslator(fixedTurn("t1"))
	feedAll(t, tr, lnMsgStart, lnResultOK, lnMsgStart,
		`{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom","session_id":"s1"}`)

	calls := sink.recorded()
	require.Len(t, calls, 2)
	assert.True(t, calls[0].OK)
	assert.Equal(t, "claude-sonnet-x", calls[0].Model, "no modelUsage: the stream's model")
	assert.Equal(t, int64(10), calls[0].Input)
	assert.Equal(t, int64(2), calls[0].CacheWrite5m, "an unsplit cache write counts as 5-minute")
	assert.False(t, calls[1].OK)
	assert.True(t, calls[1].Estimated, "a result without usage is estimated")
}
