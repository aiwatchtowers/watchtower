package digest

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/llmusage"
	"watchtower/internal/sessions"
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

// collectCalls installs a callSink as the process's ledger sink until the
// test ends.
func collectCalls(t *testing.T) *callSink {
	t.Helper()
	s := &callSink{}
	llmusage.SetSink(s)
	t.Cleanup(func() { llmusage.SetSink(nil) })
	return s
}

// ledgerStub writes a fake claude that drains stdin, prints body and exits
// with code. It records its pid; t.Cleanup kills its process group (an
// isolated child leads its own) and the pid itself, so nothing outlives the
// test.
func ledgerStub(t *testing.T, body string, code int) string {
	t.Helper()
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "pid")
	script := filepath.Join(dir, "fake-claude")
	src := "#!/bin/sh\necho $$ > " + shellQuote(pidFile) + "\ncat >/dev/null\nprintf '%s' " + shellQuote(body) +
		"\nexit " + strconv.Itoa(code) + "\n"
	require.NoError(t, os.WriteFile(script, []byte(src), 0o755))
	t.Cleanup(func() {
		b, err := os.ReadFile(pidFile)
		if err != nil {
			return
		}
		if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && pid > 0 {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	})
	return script
}

const usageEnvelope = `{"type":"result","subtype":"success","is_error":false,"result":"the digest",` +
	`"total_cost_usd":0.0123,"usage":{"input_tokens":2,"cache_read_input_tokens":5000,` +
	`"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":1000,` +
	`"ephemeral_1h_input_tokens":0},"output_tokens":300},` +
	`"modelUsage":{"claude-haiku-5-5":{"inputTokens":2,"outputTokens":300},"claude-opus-5-5":{"outputTokens":4}}}`

func TestClaudeGeneratorRecordsUsage(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	sink := collectCalls(t)
	gen := NewClaudeGenerator("haiku", "opus", ledgerStub(t, usageEnvelope, 0))
	gen.SetIsolatedChild()

	got, usage, _, err := gen.Generate(WithSource(context.Background(), "digest.channel"), "sys", "msg", "")
	require.NoError(t, err)
	assert.Equal(t, "the digest", got)
	assert.Equal(t, 2, usage.InputTokens, "the caller's Usage is unchanged")

	calls := sink.recorded()
	require.Len(t, calls, 1)
	c := calls[0]
	assert.Equal(t, "claude", c.Provider)
	assert.Equal(t, "claude-haiku-5-5", c.Model, "the modelUsage key with the most output")
	assert.Equal(t, "digest.channel", c.Purpose)
	assert.Equal(t, int64(2), c.Input)
	assert.Equal(t, int64(5000), c.CacheRead)
	assert.Equal(t, int64(1000), c.CacheWrite5m)
	assert.Equal(t, int64(0), c.CacheWrite1h)
	assert.Equal(t, int64(300), c.Output)
	require.NotNil(t, c.ReportedCostUSD)
	assert.InDelta(t, 0.0123, *c.ReportedCostUSD, 1e-9)
	assert.True(t, c.OK)
	assert.False(t, c.Estimated)
}

func TestClaudeGeneratorErrorEnvelopeRecordsFailed(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	sink := collectCalls(t)
	envelope := `{"type":"result","subtype":"error_during_execution","is_error":true,"result":"API Error: overloaded"}`
	gen := NewClaudeGenerator("haiku", "opus", ledgerStub(t, envelope, 1))
	gen.SetIsolatedChild()

	_, _, _, err := gen.Generate(context.Background(), "a system prompt", "a user message", "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "subtype=error_during_execution", "the error is unchanged")

	calls := sink.recorded()
	require.Len(t, calls, 1)
	c := calls[0]
	assert.False(t, c.OK)
	assert.True(t, c.Estimated)
	assert.Equal(t, "opus", c.Model, "no modelUsage: the requested model")
	assert.Equal(t, llmusage.EstimateTokens("a system prompt"+"a user message"), c.Input)
	assert.Nil(t, c.ReportedCostUSD)
}

func TestClaudeGeneratorUnsplitCacheWriteIsFiveMinute(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	sink := collectCalls(t)
	envelope := `{"type":"result","subtype":"success","result":"ok","usage":{"input_tokens":1,` +
		`"cache_creation_input_tokens":700,"cache_creation":{"ephemeral_1h_input_tokens":200},"output_tokens":5}}`
	gen := NewClaudeGenerator("haiku", "opus", ledgerStub(t, envelope, 0))
	gen.SetIsolatedChild()

	_, _, _, err := gen.Generate(context.Background(), "", "msg", "")
	require.NoError(t, err)
	calls := sink.recorded()
	require.Len(t, calls, 1)
	assert.Equal(t, int64(500), calls[0].CacheWrite5m)
	assert.Equal(t, int64(200), calls[0].CacheWrite1h)
}

func TestPooledGeneratorDoesNotDoubleRecord(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	sink := collectCalls(t)
	inner := NewClaudeGenerator("haiku", "opus", ledgerStub(t, usageEnvelope, 0))
	inner.SetIsolatedChild()
	pg := NewPooledGenerator(WithCallTimeout(inner, time.Minute), sessions.NewSessionPool(1))

	_, _, _, err := pg.Generate(WithSource(context.Background(), "digest.channel"), "sys", "msg", "")
	require.NoError(t, err)
	assert.Len(t, sink.recorded(), 1)
}

func TestClaudeGenerateWithImageRecords(t *testing.T) {
	sink := collectCalls(t)
	runImageCall(t, "sys", "describe it")

	calls := sink.recorded()
	require.Len(t, calls, 1)
	c := calls[0]
	assert.Equal(t, "media.describe", c.Purpose)
	assert.Equal(t, "strong-model", c.Model)
	assert.Equal(t, int64(11), c.Input)
	assert.Equal(t, int64(2), c.CacheRead)
	assert.Equal(t, int64(7), c.Output)
	assert.True(t, c.OK)
}

func TestValidateModelRecordsProbe(t *testing.T) {
	sink := collectCalls(t)
	gen := NewClaudeGenerator("haiku", "opus", ledgerStub(t, `{"type":"result","result":"ok","usage":{"input_tokens":3,"output_tokens":1}}`, 0))

	require.NoError(t, gen.ValidateModel())
	calls := sink.recorded()
	require.Len(t, calls, 1)
	assert.Equal(t, "probe", calls[0].Purpose)
	assert.Equal(t, "opus", calls[0].Model)
	assert.Equal(t, int64(3), calls[0].Input)
	assert.True(t, calls[0].OK)
}

func TestModelFromUsage(t *testing.T) {
	assert.Equal(t, "req", ModelFromUsage(nil, "req"))
	assert.Equal(t, "req", ModelFromUsage(map[string]json.RawMessage{"x": json.RawMessage(`"bad"`)}, "req"))
	tie := map[string]json.RawMessage{
		"claude-b": json.RawMessage(`{"outputTokens":5}`),
		"claude-a": json.RawMessage(`{"outputTokens":5}`),
		"claude-c": json.RawMessage(`{"outputTokens":1}`),
	}
	assert.Equal(t, "claude-a", ModelFromUsage(tie, "req"), "a tie goes to the first name")
}
