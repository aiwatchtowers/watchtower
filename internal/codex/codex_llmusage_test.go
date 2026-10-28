package codex

import (
	"context"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/llmusage"
)

// callSink collects the recorded calls; discardSink (installed by TestMain)
// keeps the other tests' calls out of the spool and their "call not
// recorded" lines off stderr.
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

// drain empties a channel until it closes.
func drain[T any](ch <-chan T) {
	for range ch { //nolint:revive // only waits for the close
	}
}

func TestCodexGeneratorRecords(t *testing.T) {
	calls := captureCalls(t)
	stdout := strings.Join([]string{
		`{"type":"item.completed","item":{"type":"agent_message","text":"Generated text"}}`,
		`{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":7}}`,
	}, "\n")
	bin := fakeCodexScript(t, stdout, "", 0)

	g := NewCodexGenerator("gpt-light", "gpt-strong", bin)
	out, usage, _, err := g.Generate(llmusage.WithPurpose(context.Background(), "digest.channel"), "sys", "msg", "")
	require.NoError(t, err)
	require.Equal(t, "Generated text", out)
	require.Equal(t, 100, usage.InputTokens, "the returned usage is unchanged")

	got := calls.all()
	require.Len(t, got, 1)
	c := got[0]
	require.Equal(t, "codex", c.Provider)
	require.Equal(t, "gpt-strong", c.Model)
	require.Equal(t, "digest.channel", c.Purpose)
	require.Equal(t, int64(40), c.Input, "fresh input = input minus cached")
	require.Equal(t, int64(60), c.CacheRead)
	require.Equal(t, int64(7), c.Output)
	require.False(t, c.Estimated)
	require.True(t, c.OK)
}

func TestCodexGeneratorRecordsFailure(t *testing.T) {
	calls := captureCalls(t)
	bin := fakeCodexScript(t, "", "boom", 7)

	g := NewCodexGenerator("gpt-light", "gpt-strong", bin)
	_, _, _, err := g.Generate(context.Background(), "sys", "a user message", "")
	require.Error(t, err)

	got := calls.all()
	require.Len(t, got, 1)
	require.False(t, got[0].OK)
	require.True(t, got[0].Estimated)
	require.Equal(t, llmusage.EstimateTokens("sys"+"a user message"), got[0].Input)
}

func TestCodexClientQueryRecordsEstimatedWithoutUsage(t *testing.T) {
	calls := captureCalls(t)
	bin := fakeCodexScript(t, `{"type":"item.completed","item":{"type":"agent_message","text":"an answer of some length"}}`, "", 0)

	c := NewClient("gpt-x", "", bin)
	textCh, errCh, sidCh := c.Query(context.Background(), "system prompt", "user message here", "")
	var text strings.Builder
	for ch := range textCh {
		text.WriteString(ch.Text)
	}
	for err := range errCh {
		t.Fatalf("Query error: %v", err)
	}
	drain(sidCh)
	require.Equal(t, "an answer of some length", text.String())

	got := calls.all()
	require.Len(t, got, 1)
	r := got[0]
	require.Equal(t, "codex", r.Provider)
	require.Equal(t, "gpt-x", r.Model)
	require.True(t, r.Estimated)
	require.True(t, r.OK)
	require.Equal(t, llmusage.EstimateTokens("system prompt"+"user message here"), r.Input)
	require.Equal(t, llmusage.EstimateTokens("an answer of some length"), r.Output)
}

func TestCodexClientQueryRecordsUsage(t *testing.T) {
	calls := captureCalls(t)
	stdout := strings.Join([]string{
		`{"type":"item.completed","item":{"type":"agent_message","text":"hi"}}`,
		`{"type":"turn.completed","usage":{"input_tokens":30,"cached_input_tokens":10,"output_tokens":4}}`,
	}, "\n")
	bin := fakeCodexScript(t, stdout, "", 0)

	textCh, errCh, sidCh := NewClient("gpt-x", "", bin).Query(context.Background(), "s", "u", "")
	drain(textCh)
	for err := range errCh {
		t.Fatalf("Query error: %v", err)
	}
	drain(sidCh)
	got := calls.all()
	require.Len(t, got, 1)
	require.Equal(t, int64(20), got[0].Input)
	require.Equal(t, int64(10), got[0].CacheRead)
	require.Equal(t, int64(4), got[0].Output)
	require.False(t, got[0].Estimated)
}

func TestCodexClientQuerySyncRecords(t *testing.T) {
	calls := captureCalls(t)
	stdout := strings.Join([]string{
		`{"type":"item.completed","item":{"type":"agent_message","text":"Hello"}}`,
		`{"type":"turn.completed","usage":{"input_tokens":42,"output_tokens":17}}`,
	}, "\n")
	bin := fakeCodexScript(t, stdout, "", 0)

	_, _, err := NewClient("gpt-x", "", bin).QuerySync(context.Background(), "system", "user", "")
	require.NoError(t, err)
	got := calls.all()
	require.Len(t, got, 1)
	require.Equal(t, int64(42), got[0].Input)
	require.Equal(t, int64(17), got[0].Output)
	require.True(t, got[0].OK)
}
