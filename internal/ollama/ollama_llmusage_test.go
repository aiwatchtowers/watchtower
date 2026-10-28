package ollama

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/llmusage"
)

// TestMain keeps the package's other tests' calls out of the spool and their
// "call not recorded" lines off stderr.
func TestMain(m *testing.M) {
	llmusage.SetSink(discardSink{})
	os.Exit(m.Run())
}

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

// jsonServer answers every chat completion with body.
func jsonServer(t *testing.T, body string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestOllamaGeneratorRecords(t *testing.T) {
	calls := captureCalls(t)
	srv := jsonServer(t, `{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":12,"completion_tokens":3,"total_tokens":15}}`)

	g := NewGenerator("light", "strong", srv.URL)
	out, _, _, err := g.Generate(llmusage.WithPurpose(context.Background(), "tracks.extract"), "sys", "msg", "")
	require.NoError(t, err)
	require.Equal(t, "ok", out)

	got := calls.all()
	require.Len(t, got, 1)
	c := got[0]
	require.Equal(t, "ollama", c.Provider)
	require.Equal(t, "strong", c.Model)
	require.Equal(t, "tracks.extract", c.Purpose)
	require.Equal(t, int64(12), c.Input)
	require.Equal(t, int64(3), c.Output)
	require.False(t, c.Estimated)
	require.True(t, c.OK)
}

func TestOllamaGeneratorNoUsageEstimates(t *testing.T) {
	calls := captureCalls(t)
	srv := jsonServer(t, `{"choices":[{"message":{"role":"assistant","content":"an answer"}}]}`)

	_, usage, _, err := NewGenerator("light", "strong", srv.URL).Generate(context.Background(), "system text", "user text", "")
	require.NoError(t, err)
	require.Nil(t, usage, "the returned usage is unchanged")

	got := calls.all()
	require.Len(t, got, 1)
	require.True(t, got[0].Estimated)
	require.Equal(t, llmusage.EstimateTokens("system text"+"user text"), got[0].Input)
	require.Equal(t, llmusage.EstimateTokens("an answer"), got[0].Output)
}

func TestOllamaGeneratorRecordsHTTPFailure(t *testing.T) {
	calls := captureCalls(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "down", http.StatusServiceUnavailable)
	}))
	t.Cleanup(srv.Close)

	_, _, _, err := NewGenerator("light", "strong", srv.URL).Generate(context.Background(), "s", "u", "")
	require.Error(t, err)
	got := calls.all()
	require.Len(t, got, 1)
	require.False(t, got[0].OK)
	require.True(t, got[0].Estimated)
}

func TestOllamaQuerySyncRecords(t *testing.T) {
	calls := captureCalls(t)
	srv := jsonServer(t, `{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":8,"completion_tokens":2,"total_tokens":10}}`)

	_, _, err := NewClient("m1", srv.URL).QuerySync(context.Background(), "s", "u", "")
	require.NoError(t, err)
	got := calls.all()
	require.Len(t, got, 1)
	require.Equal(t, "m1", got[0].Model)
	require.Equal(t, int64(8), got[0].Input)
	require.Equal(t, int64(2), got[0].Output)
}

func TestOllamaQueryAsksForStreamUsage(t *testing.T) {
	calls := captureCalls(t)
	var reqBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&reqBody)
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, `data: {"choices":[{"delta":{"content":"hel"}}]}`+"\n\n")
		fmt.Fprint(w, `data: {"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}`+"\n\n")
		fmt.Fprint(w, `data: {"choices":[],"usage":{"prompt_tokens":21,"completion_tokens":2,"total_tokens":23}}`+"\n\n")
		fmt.Fprint(w, "data: [DONE]\n\n")
	}))
	t.Cleanup(srv.Close)

	textCh, errCh, sidCh := NewClient("m1", srv.URL).Query(context.Background(), "s", "u", "")
	var text string
	for ch := range textCh {
		text += ch.Text
	}
	for err := range errCh {
		t.Fatalf("Query error: %v", err)
	}
	drain(sidCh)
	require.Equal(t, "hello", text)
	require.Equal(t, map[string]any{"include_usage": true}, reqBody["stream_options"])

	got := calls.all()
	require.Len(t, got, 1)
	require.Equal(t, int64(21), got[0].Input)
	require.Equal(t, int64(2), got[0].Output)
	require.False(t, got[0].Estimated)
	require.True(t, got[0].OK)
}

func TestOllamaQueryWithoutStreamUsageEstimates(t *testing.T) {
	calls := captureCalls(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `data: {"choices":[{"delta":{"content":"a reply"},"finish_reason":"stop"}]}`+"\n\n")
		fmt.Fprint(w, "data: [DONE]\n\n")
	}))
	t.Cleanup(srv.Close)

	textCh, errCh, sidCh := NewClient("m1", srv.URL).Query(context.Background(), "s", "u", "")
	drain(textCh)
	drain(errCh)
	drain(sidCh)
	got := calls.all()
	require.Len(t, got, 1)
	require.True(t, got[0].Estimated)
	require.Equal(t, llmusage.EstimateTokens("a reply"), got[0].Output)
}
