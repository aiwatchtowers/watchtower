package chat

import (
	"strconv"
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
	assert.Equal(t, "claude-sonnet-x", c.Model, "the turn's own model from message_start")
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
	assert.Equal(t, "claude-sonnet-x", calls[0].Model, "the stream's model")
	assert.Equal(t, int64(10), calls[0].Input)
	assert.Equal(t, int64(2), calls[0].CacheWrite5m, "an unsplit cache write counts as 5-minute")
	assert.False(t, calls[1].OK)
	assert.True(t, calls[1].Estimated, "a result without usage is estimated")
}

// resultWithTotals is a success result line with the child's cumulative
// total_cost_usd and haiku output, and the turn's own output tokens.
func resultWithTotals(cost string, turnOut, totalOut int) string {
	return `{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"s1",` +
		`"total_cost_usd":` + cost + `,"usage":{"input_tokens":3,"output_tokens":` + strconv.Itoa(turnOut) + `},` +
		`"modelUsage":{"claude-haiku-5-5":{"outputTokens":` + strconv.Itoa(totalOut) + `}}}`
}

const lnInit = `{"type":"system","subtype":"init","session_id":"s1","apiKeySource":"none"}`

func TestClaudeTranslatorRecordsPerTurnCost(t *testing.T) {
	sink := collectLedger(t)
	tr := NewClaudeTranslator(fixedTurn("t1"))
	// The real CLI's numbers for two turns of one warm child: usage is per
	// turn, total_cost_usd and modelUsage add up over the child's life.
	feedAll(t, tr, lnInit, resultWithTotals("0.000967", 183, 183), resultWithTotals("0.001068", 16, 199))

	calls := sink.recorded()
	require.Len(t, calls, 2)
	require.NotNil(t, calls[0].ReportedCostUSD)
	require.NotNil(t, calls[1].ReportedCostUSD)
	assert.InDelta(t, 0.000967, *calls[0].ReportedCostUSD, 1e-12)
	assert.InDelta(t, 0.000101, *calls[1].ReportedCostUSD, 1e-12)
	assert.Equal(t, int64(183), calls[0].Output)
	assert.Equal(t, int64(16), calls[1].Output)
	assert.Equal(t, "claude-haiku-5-5", calls[1].Model, "no message_start: the model whose output grew")
}

// resultIn is resultWithTotals for the session sid.
func resultIn(sid, cost string, turnOut, totalOut int) string {
	return `{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"` + sid + `",` +
		`"total_cost_usd":` + cost + `,"usage":{"input_tokens":3,"output_tokens":` + strconv.Itoa(turnOut) + `},` +
		`"modelUsage":{"claude-haiku-5-5":{"outputTokens":` + strconv.Itoa(totalOut) + `}}}`
}

func initIn(sid string) string {
	return `{"type":"system","subtype":"init","session_id":"` + sid + `","apiKeySource":"none"}`
}

func TestClaudeTranslatorSameSessionInitKeepsBaseline(t *testing.T) {
	sink := collectLedger(t)
	tr := NewClaudeTranslator(fixedTurn("t1"))
	// The real warm child prints system/init before every turn with the
	// same session id; its totals keep adding up.
	feedAll(t, tr, initIn("s1"), resultIn("s1", "0.000939", 20, 20),
		initIn("s1"), resultIn("s1", "0.001028", 5, 25))

	calls := sink.recorded()
	require.Len(t, calls, 2)
	require.NotNil(t, calls[1].ReportedCostUSD)
	assert.InDelta(t, 0.000089, *calls[1].ReportedCostUSD, 1e-12, "only the growth of the running total")
	assert.Equal(t, "claude-haiku-5-5", calls[1].Model)
	var sum float64
	for _, c := range calls {
		sum += *c.ReportedCostUSD
	}
	assert.InDelta(t, 0.001028, sum, 1e-12, "the turns add up to the child's total")
}

func TestClaudeTranslatorRespawnResetsCost(t *testing.T) {
	sink := collectLedger(t)
	tr := NewClaudeTranslator(fixedTurn("t1"))
	feedAll(t, tr, initIn("s1"), resultIn("s1", "0.002", 10, 10),
		initIn("s2"), resultIn("s2", "0.0025", 5, 5), // a respawned child: new session, totals start over
		resultIn("s2", "0.003", 5, 10))

	calls := sink.recorded()
	require.Len(t, calls, 3)
	require.NotNil(t, calls[1].ReportedCostUSD)
	assert.InDelta(t, 0.0025, *calls[1].ReportedCostUSD, 1e-12, "a new session's whole total")
	require.NotNil(t, calls[2].ReportedCostUSD)
	assert.InDelta(t, 0.0005, *calls[2].ReportedCostUSD, 1e-12)
}

func TestClaudeTranslatorShrinkingTotalIsANewChild(t *testing.T) {
	sink := collectLedger(t)
	tr := NewClaudeTranslator(fixedTurn("t1"))
	// No init between: a total smaller than the baseline is a new child's.
	feedAll(t, tr, initIn("s1"), resultIn("s1", "0.002", 10, 10), resultIn("s1", "0.0005", 4, 4))

	calls := sink.recorded()
	require.Len(t, calls, 2)
	require.NotNil(t, calls[1].ReportedCostUSD)
	assert.InDelta(t, 0.0005, *calls[1].ReportedCostUSD, 1e-12, "the new child's whole total, not nothing")
	assert.Equal(t, "claude-haiku-5-5", calls[1].Model, "the shrunk model's output counts as grown")
}

func TestClaudeTranslatorInterruptFixtureCost(t *testing.T) {
	sink := collectLedger(t)
	tr := NewClaudeTranslator(fixedTurn("t1"))
	for _, l := range readFixture(t, "claude_interrupt.jsonl") {
		_, err := tr.Feed([]byte(l))
		require.NoError(t, err)
	}
	calls := sink.recorded()
	require.Len(t, calls, 2)
	assert.False(t, calls[0].OK)
	assert.False(t, calls[0].Estimated, "a zero usage object is reported as zero, not estimated")
	assert.Nil(t, calls[0].ReportedCostUSD)
	require.NotNil(t, calls[1].ReportedCostUSD)
	assert.InDelta(t, 0.011648, *calls[1].ReportedCostUSD, 1e-9, "the same session's init keeps the baseline")
	assert.Equal(t, int64(56), calls[1].Output)
}
