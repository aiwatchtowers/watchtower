package ollama

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/providers"
)

func sseServer(t *testing.T, lines ...string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		for _, l := range lines {
			_, _ = w.Write([]byte(l + "\n\n"))
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func drainQuery(textCh <-chan ai.StreamChunk, errCh <-chan error, sidCh <-chan string) ([]ai.StreamChunk, error) {
	var chunks []ai.StreamChunk
	for c := range textCh {
		chunks = append(chunks, c)
	}
	for range sidCh {
	}
	var first error
	for err := range errCh {
		if first == nil {
			first = err
		}
	}
	return chunks, first
}

// TestOllamaQuery_EmitsUsage: with the chat events on, the stream's final
// usage (stream_options.include_usage) ends the turn as one Usage chunk
// after the text; without them a v1 consumer sees text only.
func TestOllamaQuery_EmitsUsage(t *testing.T) {
	srv := sseServer(t,
		`data: {"choices":[{"delta":{"content":"Hel"}}]}`,
		`data: {"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}`,
		`data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":5,"total_tokens":17}}`,
		`data: [DONE]`,
	)
	c := NewClient("llama", srv.URL)
	c.EmitToolEvents()
	chunks, err := drainQuery(c.Query(context.Background(), "", "hi", ""))
	require.NoError(t, err)
	require.Len(t, chunks, 3)
	assert.Equal(t, "Hel", chunks[0].Text)
	assert.Equal(t, "lo", chunks[1].Text)
	require.NotNil(t, chunks[2].Usage, "the last chunk is the turn's usage")
	assert.Equal(t, ai.TurnUsage{Model: "llama", InputTokens: 12, OutputTokens: 5}, *chunks[2].Usage)

	plain := NewClient("llama", srv.URL)
	chunks, err = drainQuery(plain.Query(context.Background(), "", "hi", ""))
	require.NoError(t, err)
	for _, ch := range chunks {
		assert.Nil(t, ch.Usage, "a v1 consumer gets no usage chunk")
	}
}

// A server that reports no usage gives no usage chunk: nothing is made up.
func TestOllamaQuery_NoUsageReportedNoChunk(t *testing.T) {
	srv := sseServer(t, `data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}`, `data: [DONE]`)
	c := NewClient("llama", srv.URL)
	c.EmitToolEvents()
	chunks, err := drainQuery(c.Query(context.Background(), "", "hi", ""))
	require.NoError(t, err)
	require.Len(t, chunks, 1)
	assert.Nil(t, chunks[0].Usage)
}

// Every failure of Query, QuerySync and the generator is a typed
// providers.Failure, its text unchanged.
func TestOllama_FailuresAreTyped(t *testing.T) {
	status := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"error":"model \"llama9\" not found, try pulling it first"}`, http.StatusNotFound)
	}))
	t.Cleanup(status.Close)
	inline := sseServer(t, `data: {"error":{"message":"input length exceeds the context length"}}`)

	requireCat := func(t *testing.T, err error, want providers.ErrorCategory) {
		t.Helper()
		var f *providers.Failure
		require.True(t, errors.As(err, &f), "untyped: %v", err)
		assert.Equal(t, want, f.Category, err.Error())
		assert.Equal(t, "ollama", f.Provider)
	}

	_, err := drainQuery(NewClient("llama9", status.URL).Query(context.Background(), "", "hi", ""))
	requireCat(t, err, providers.Model)
	assert.Contains(t, err.Error(), "HTTP 404")
	_, _, err = NewClient("llama9", status.URL).QuerySync(context.Background(), "", "hi", "")
	requireCat(t, err, providers.Model)
	_, _, _, err = NewGenerator("llama9", "llama9", status.URL).Generate(context.Background(), "", "hi", "")
	requireCat(t, err, providers.Model)

	_, err = drainQuery(NewClient("llama", inline.URL).Query(context.Background(), "", "hi", ""))
	requireCat(t, err, providers.ContextLimit)
	assert.Contains(t, err.Error(), "ollama stream error")

	_, err = drainQuery(NewClient("llama", "http://127.0.0.1:1").Query(context.Background(), "", "hi", ""))
	requireCat(t, err, providers.Transport)
}
