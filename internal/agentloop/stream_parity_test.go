package agentloop

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/llmusage"
	"watchtower/internal/providers"
	"watchtower/internal/tools"
)

func collect(t *testing.T, c *Client) ([]ai.StreamChunk, error) {
	t.Helper()
	textCh, errCh, sidCh := c.Query(context.Background(), "SYS", "what is PAY-1?", "")
	var chunks []ai.StreamChunk
	for ch := range textCh {
		chunks = append(chunks, ch)
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

func withUsage(r oaResponse, in, out int) oaResponse {
	r.Usage = &oaUsage{PromptTokens: in, CompletionTokens: out, TotalTokens: in + out}
	return r
}

// TestAgentloopQuery_EmitsUsage: with the chat events on, a turn ends with one
// Usage chunk carrying the summed usage of every model call, after the final
// answer (here one chunk: the first response has no text).
func TestAgentloopQuery_EmitsUsage(t *testing.T) {
	reg := &fakeReg{tools: map[string]*tools.Tool{"list_targets": tools.NewListTargets()}, readData: []any{}}
	srv, _ := scriptedServer(t,
		withUsage(toolCallResp("list_targets", `{}`), 100, 10),
		withUsage(finalResp("all clear"), 150, 20))
	c := clientWith(reg, srv.URL)
	c.EmitToolEvents()

	chunks, err := collect(t, c)
	require.NoError(t, err)
	last := chunks[len(chunks)-1]
	require.NotNil(t, last.Usage, "the turn ends with its usage")
	assert.Equal(t, ai.TurnUsage{Model: "m", Tokens: llmusage.Tokens{Input: 250, Output: 30}}, *last.Usage)
	var texts []string
	for _, ch := range chunks {
		if ch.Text != "" {
			texts = append(texts, ch.Text)
		}
	}
	assert.Equal(t, []string{"all clear"}, texts, "a JSON answer is sent whole")
}

// Without the chat events (a v1 consumer) no Usage chunk is sent, and a
// server that reports no usage gives none either.
func TestAgentloopQuery_NoUsageChunkWithoutEventsOrReport(t *testing.T) {
	srv, _ := scriptedServer(t, withUsage(finalResp("hi"), 5, 1))
	chunks, err := collect(t, clientWith(&fakeReg{}, srv.URL))
	require.NoError(t, err)
	for _, ch := range chunks {
		assert.Nil(t, ch.Usage)
	}

	bare, _ := scriptedServer(t, finalResp("hi"))
	c := clientWith(&fakeReg{}, bare.URL)
	c.EmitToolEvents()
	chunks, err = collect(t, c)
	require.NoError(t, err)
	for _, ch := range chunks {
		assert.Nil(t, ch.Usage, "nothing reported, nothing made up")
	}
}

// A failed model call is a typed providers.Failure (L10).
func TestAgentloop_ModelFailureIsTyped(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"error":"too many requests"}`, http.StatusTooManyRequests)
	}))
	t.Cleanup(srv.Close)
	_, err := collect(t, clientWith(&fakeReg{}, srv.URL))
	var f *providers.Failure
	require.True(t, errors.As(err, &f), "untyped: %v", err)
	assert.Equal(t, providers.RateLimit, f.Category)
	assert.Contains(t, err.Error(), "HTTP 429")

	_, err = collect(t, clientWith(&fakeReg{}, "http://127.0.0.1:1"))
	require.True(t, errors.As(err, &f), "untyped: %v", err)
	assert.Equal(t, providers.Transport, f.Category)
}
