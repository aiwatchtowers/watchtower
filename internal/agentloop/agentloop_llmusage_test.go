package agentloop

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/llmusage"
	"watchtower/internal/tools"
)

// callSink collects the recorded calls; discardSink (installed by TestMain)
// keeps the other tests' calls out of the spool and off stderr.
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

func TestAgentloopRecordsEachModelCall(t *testing.T) {
	calls := captureCalls(t)
	first := toolCallResp("list_targets", `{}`)
	first.Usage = &oaUsage{PromptTokens: 50, CompletionTokens: 5, TotalTokens: 55}
	srv := pathCheckingServer(t, first, finalResp("the final answer"))
	c := NewClient("local-model", srv.URL, nil, tools.Binding{Surface: "main"})
	c.reg = &fakeReg{tools: map[string]*tools.Tool{"list_targets": tools.NewListTargets()}, readData: []any{}}

	out, _, err := c.QuerySync(context.Background(), "sys", "hi", "")
	require.NoError(t, err)
	require.Equal(t, "the final answer", out)

	got := calls.all()
	require.Len(t, got, 2, "one row per model call")
	require.Equal(t, "http", got[0].Provider)
	require.Equal(t, "local-model", got[0].Model)
	require.Equal(t, int64(50), got[0].Input)
	require.Equal(t, int64(5), got[0].Output)
	require.False(t, got[0].Estimated)
	require.True(t, got[0].OK)

	require.True(t, got[1].Estimated, "no usage on the second response")
	require.True(t, got[1].OK)
	require.Positive(t, got[1].Input)
	require.Equal(t, llmusage.EstimateTokens("the final answer"), got[1].Output)
}

func TestAgentloopRecordsFailedModelCall(t *testing.T) {
	calls := captureCalls(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusBadGateway)
	}))
	t.Cleanup(srv.Close)
	c := NewClient("local-model", srv.URL, nil, tools.Binding{Surface: "main"})
	c.reg = &fakeReg{tools: map[string]*tools.Tool{}}

	_, _, err := c.QuerySync(context.Background(), "", "hi", "")
	require.Error(t, err)
	got := calls.all()
	require.Len(t, got, 1)
	require.False(t, got[0].OK)
	require.True(t, got[0].Estimated)
}
