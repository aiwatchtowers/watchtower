package ai

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/llmusage"
)

// callSink collects the ledger calls recorded while it is installed.
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

func (s *callSink) recorded() []llmusage.Call {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]llmusage.Call(nil), s.calls...)
}

func collectCalls(t *testing.T) *callSink {
	t.Helper()
	s := &callSink{}
	llmusage.SetSink(s)
	t.Cleanup(func() { llmusage.SetSink(nil) })
	return s
}

// ledgerClient is a Client over a fake claude running script in its own
// process group; t.Cleanup kills that group, so nothing outlives the test.
func ledgerClient(t *testing.T, script string) *Client {
	t.Helper()
	pidFile := filepath.Join(t.TempDir(), "pid")
	c := NewClient("sonnet", "", "")
	c.claudeCmd = writeMockClaude(t, "echo $$ > '"+pidFile+"'\ncat >/dev/null\n"+script)
	c.SetProcessGroup(true)
	t.Cleanup(func() {
		b, err := os.ReadFile(pidFile)
		if err != nil {
			return
		}
		if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && pid > 0 {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
		}
	})
	return c
}

const ledgerResult = `{"type":"result","subtype":"success","is_error":false,"result":"answer",` +
	`"total_cost_usd":0.5,"usage":{"input_tokens":4,"cache_read_input_tokens":900,` +
	`"cache_creation_input_tokens":300,"cache_creation":{"ephemeral_5m_input_tokens":100,` +
	`"ephemeral_1h_input_tokens":200},"output_tokens":50},` +
	`"modelUsage":{"claude-sonnet-5-5":{"outputTokens":50},"claude-haiku-5-5":{"outputTokens":3}}}`

func assertLedgerResult(t *testing.T, c llmusage.Call) {
	t.Helper()
	assert.Equal(t, "claude", c.Provider)
	assert.Equal(t, "claude-sonnet-5-5", c.Model)
	assert.Equal(t, "ask", c.Purpose)
	assert.Equal(t, int64(4), c.Input)
	assert.Equal(t, int64(900), c.CacheRead)
	assert.Equal(t, int64(100), c.CacheWrite5m)
	assert.Equal(t, int64(200), c.CacheWrite1h)
	assert.Equal(t, int64(50), c.Output)
	require.NotNil(t, c.ReportedCostUSD)
	assert.InDelta(t, 0.5, *c.ReportedCostUSD, 1e-9)
	assert.True(t, c.OK)
	assert.False(t, c.Estimated)
}

func TestAIClientQuerySyncRecords(t *testing.T) {
	sink := collectCalls(t)
	c := ledgerClient(t, "echo '"+ledgerResult+"'\n")

	text, usage, err := c.QuerySync(llmusage.WithPurpose(context.Background(), "ask"), "sys", "question", "")
	require.NoError(t, err)
	assert.Equal(t, "answer", text)
	assert.Equal(t, 4, usage.InputTokens, "the caller's Usage is unchanged")
	assert.InDelta(t, 0.5, usage.CostUSD, 1e-9)

	calls := sink.recorded()
	require.Len(t, calls, 1)
	assertLedgerResult(t, calls[0])
}

func TestAIClientQuerySyncErrorEnvelopeRecordsFailed(t *testing.T) {
	sink := collectCalls(t)
	c := ledgerClient(t, `echo '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Invalid API key"}'`+"\nexit 1\n")

	_, _, err := c.QuerySync(context.Background(), "sys", "question", "")
	require.Error(t, err)

	calls := sink.recorded()
	require.Len(t, calls, 1)
	assert.False(t, calls[0].OK)
	assert.True(t, calls[0].Estimated)
	assert.Equal(t, "sonnet", calls[0].Model)
	assert.Equal(t, llmusage.EstimateTokens("sys"+"question"), calls[0].Input)
}

// drain reads a Query's channels to the end and returns the text and the
// error.
func drain(textCh <-chan StreamChunk, errCh <-chan error, sidCh <-chan string) (string, error) {
	var sb strings.Builder
	for ch := range textCh {
		sb.WriteString(ch.Text)
	}
	var err error
	for e := range errCh {
		err = e
	}
	for range sidCh { // drained to the close
		continue
	}
	return sb.String(), err
}

func TestAIClientQueryRecordsAtStreamEnd(t *testing.T) {
	sink := collectCalls(t)
	c := ledgerClient(t, `echo '{"type":"assistant","message":{"content":[{"type":"text","text":"answer"}]}}'`+
		"\necho '"+ledgerResult+"'\n")

	text, err := drain(c.Query(llmusage.WithPurpose(context.Background(), "ask"), "sys", "question", ""))
	require.NoError(t, err)
	assert.Equal(t, "answer", text)

	calls := sink.recorded()
	require.Len(t, calls, 1, "recorded once, before the channels close")
	assertLedgerResult(t, calls[0])
}

func TestAIClientQueryCancelledRecordsEstimated(t *testing.T) {
	sink := collectCalls(t)
	c := ledgerClient(t, `echo '{"type":"assistant","message":{"content":[{"type":"text","text":"partial answer"}]}}'`+
		"\nexec sleep 30\n")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	textCh, errCh, sidCh := c.Query(ctx, "sys", "question", "")
	first := <-textCh
	assert.Equal(t, "partial answer", first.Text)
	cancel()
	_, err := drain(textCh, errCh, sidCh)
	require.Error(t, err)

	calls := sink.recorded()
	require.Len(t, calls, 1)
	c0 := calls[0]
	assert.False(t, c0.OK)
	assert.True(t, c0.Estimated)
	assert.Equal(t, llmusage.EstimateTokens("sys"+"question"), c0.Input)
	assert.Equal(t, llmusage.EstimateTokens("partial answer"), c0.Output)
}
