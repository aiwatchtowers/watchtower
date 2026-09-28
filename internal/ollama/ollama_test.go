package ollama

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"watchtower/internal/ai"
	"watchtower/internal/digest"
)

// newChatServer returns a server that answers /v1/chat/completions with the
// given content and records the model of each request.
func newChatServer(t *testing.T, content string, models *[]string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req chatRequest
		if err := json.Unmarshal(body, &req); err != nil {
			t.Errorf("bad request body: %v", err)
		}
		*models = append(*models, req.Model)
		resp := map[string]any{
			"choices": []map[string]any{{"message": map[string]string{"role": "assistant", "content": content}}},
			"usage":   map[string]int{"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10},
		}
		_ = json.NewEncoder(w).Encode(resp)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func TestGenerator_TierRouting(t *testing.T) {
	var models []string
	srv := newChatServer(t, "hello", &models)
	g := NewGenerator("light-model", "strong-model", srv.URL)

	// Untagged call → strong.
	out, usage, sid, err := g.Generate(context.Background(), "sys", "msg", "")
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if out != "hello" || sid != "" {
		t.Errorf("out=%q sid=%q", out, sid)
	}
	if usage == nil || usage.Model != "strong-model" || usage.InputTokens != 7 || usage.OutputTokens != 3 {
		t.Errorf("usage = %+v", usage)
	}

	// Light-tier source → light model.
	if _, _, _, err := g.Generate(digest.WithSource(context.Background(), "digest.period"), "sys", "msg", ""); err != nil {
		t.Fatalf("Generate light: %v", err)
	}
	// Strong-tier source → strong model.
	if _, _, _, err := g.Generate(digest.WithSource(context.Background(), "digest.channel"), "sys", "msg", ""); err != nil {
		t.Fatalf("Generate strong: %v", err)
	}

	want := []string{"strong-model", "light-model", "strong-model"}
	if len(models) != len(want) {
		t.Fatalf("models = %v, want %v", models, want)
	}
	for i := range want {
		if models[i] != want[i] {
			t.Errorf("request %d model = %q, want %q", i, models[i], want[i])
		}
	}
}

func TestGenerator_ErrorPaths(t *testing.T) {
	// HTTP 500 → error.
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	g := NewGenerator("l", "s", srv.URL)
	if _, _, _, err := g.Generate(context.Background(), "", "msg", ""); err == nil || !strings.Contains(err.Error(), "HTTP 500") {
		t.Errorf("want HTTP 500 error, got %v", err)
	}

	// Valid response with no choices → error (degenerate clean exit).
	mux2 := http.NewServeMux()
	mux2.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"choices":[]}`))
	})
	srv2 := httptest.NewServer(mux2)
	defer srv2.Close()
	g2 := NewGenerator("l", "s", srv2.URL)
	if _, _, _, err := g2.Generate(context.Background(), "", "msg", ""); err == nil || !strings.Contains(err.Error(), "no choices") {
		t.Errorf("want no-choices error, got %v", err)
	}

	// 200 response carrying an inline error object → that error, not the
	// generic no-choices message.
	mux3 := http.NewServeMux()
	mux3.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"error":{"message":"context length exceeded","type":"invalid_request_error"}}`))
	})
	srv3 := httptest.NewServer(mux3)
	defer srv3.Close()
	g3 := NewGenerator("l", "s", srv3.URL)
	_, _, _, err := g3.Generate(context.Background(), "", "msg", "")
	if err == nil || !strings.Contains(err.Error(), "context length exceeded") {
		t.Errorf("want the inline error's message, got %v", err)
	}
	if err != nil && strings.Contains(err.Error(), "no choices") {
		t.Errorf("err = %v, must not fall back to the generic no-choices message", err)
	}
}

func TestClient_QuerySync(t *testing.T) {
	var models []string
	srv := newChatServer(t, "pong\n", &models)
	c := NewClient("chat-model", srv.URL)

	text, usage, err := c.QuerySync(context.Background(), "sys", "ping", "")
	if err != nil {
		t.Fatalf("QuerySync: %v", err)
	}
	if text != "pong" {
		t.Errorf("text = %q, want trailing newline trimmed", text)
	}
	if usage == nil || usage.InputTokens != 7 || usage.OutputTokens != 3 || usage.TotalAPITokens != 10 {
		t.Errorf("usage = %+v", usage)
	}
	if len(models) != 1 || models[0] != "chat-model" {
		t.Errorf("models = %v", models)
	}
}

func TestClient_QueryStreaming(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		chunks := []string{
			`data: {"choices":[{"delta":{"content":"Hel"}}]}`,
			`data: {"choices":[{"delta":{"content":"lo"}}]}`,
			`data: [DONE]`,
		}
		for _, c := range chunks {
			_, _ = w.Write([]byte(c + "\n\n"))
		}
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	c := NewClient("m", srv.URL)
	textCh, errCh, _ := c.Query(context.Background(), "", "hi", "")

	var got strings.Builder
	for chunk := range textCh {
		got.WriteString(chunk.Text)
	}
	for err := range errCh {
		t.Fatalf("stream error: %v", err)
	}
	if got.String() != "Hello" {
		t.Errorf("streamed = %q, want %q", got.String(), "Hello")
	}
}

// TestStreamSSE_InlineErrorObjectSurfacesAsError pins that an OpenAI-compatible
// mid-stream failure (model OOM / context overflow while generating), sent as
// a "data: {"error":{...}}" line after a 200 status, reaches errCh instead of
// silently unmarshaling to zero choices and ending the stream cleanly.
func TestStreamSSE_InlineErrorObjectSurfacesAsError(t *testing.T) {
	body := strings.NewReader(
		`data: {"choices":[{"delta":{"content":"partial "}}]}` + "\n\n" +
			`data: {"error":{"message":"model ran out of memory","type":"server_error"}}` + "\n\n",
	)
	textCh := make(chan ai.StreamChunk, 8)
	errCh := make(chan error, 1)

	streamSSE(context.Background(), body, textCh, errCh)
	close(textCh)
	close(errCh)

	var got strings.Builder
	for chunk := range textCh {
		got.WriteString(chunk.Text)
	}
	if got.String() != "partial " {
		t.Errorf("streamed text = %q, want the text delivered before the error", got.String())
	}

	err := <-errCh
	if err == nil {
		t.Fatal("want an error for the inline error object, got nil")
	}
	if !strings.Contains(err.Error(), "model ran out of memory") || !strings.Contains(err.Error(), "server_error") {
		t.Errorf("err = %v, want it to carry the server's message and type", err)
	}
}

// TestStreamSSE_ConnectionClosedBeforeDoneIsAnError pins the other silent-
// failure shape: the connection ends (clean EOF, scanner.Err() == nil) after
// ordinary deltas but before "[DONE]" or any finish_reason — a server
// crash/restart mid-generation must not look like a short, complete answer.
func TestStreamSSE_ConnectionClosedBeforeDoneIsAnError(t *testing.T) {
	body := strings.NewReader(
		`data: {"choices":[{"delta":{"content":"Hel"}}]}` + "\n\n" +
			`data: {"choices":[{"delta":{"content":"lo"}}]}` + "\n\n",
		// no [DONE], no finish_reason, then EOF
	)
	textCh := make(chan ai.StreamChunk, 8)
	errCh := make(chan error, 1)

	streamSSE(context.Background(), body, textCh, errCh)
	close(textCh)
	close(errCh)

	var got strings.Builder
	for chunk := range textCh {
		got.WriteString(chunk.Text)
	}
	if got.String() != "Hello" {
		t.Errorf("streamed text = %q, want %q", got.String(), "Hello")
	}

	err := <-errCh
	if err == nil {
		t.Fatal("want an error for a stream truncated before [DONE]/finish_reason, got nil")
	}
	if !strings.Contains(err.Error(), "closed early") {
		t.Errorf("err = %v, want it to describe the early close", err)
	}
}

// TestStreamSSE_FinishReasonWithoutLiteralDoneIsNotAnError is the degenerate
// clean-exit counterpart: some OpenAI-compatible servers end the stream right
// after a chunk carrying finish_reason, without ever sending a literal
// "[DONE]" line — that must NOT be misclassified as a truncated stream.
func TestStreamSSE_FinishReasonWithoutLiteralDoneIsNotAnError(t *testing.T) {
	body := strings.NewReader(
		`data: {"choices":[{"delta":{"content":"ok"}}]}` + "\n\n" +
			`data: {"choices":[{"delta":{},"finish_reason":"stop"}]}` + "\n\n",
	)
	textCh := make(chan ai.StreamChunk, 8)
	errCh := make(chan error, 1)

	streamSSE(context.Background(), body, textCh, errCh)
	close(textCh)
	close(errCh)

	var got strings.Builder
	for chunk := range textCh {
		got.WriteString(chunk.Text)
	}
	if got.String() != "ok" {
		t.Errorf("streamed text = %q, want %q", got.String(), "ok")
	}
	if err := <-errCh; err != nil {
		t.Errorf("want no error when a finish_reason chunk closes the stream, got %v", err)
	}
}

// TestQuerySync_InlineErrorObjectSurfacesAsError is QuerySync's non-streaming
// counterpart: a 200 response with an inline "error" object and no choices
// must report that error, not the generic "no choices" message.
func TestQuerySync_InlineErrorObjectSurfacesAsError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"error":{"message":"context length exceeded","type":"invalid_request_error"}}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	c := NewClient("m", srv.URL)
	_, _, err := c.QuerySync(context.Background(), "", "hi", "")
	if err == nil {
		t.Fatal("want an error for the inline error object, got nil")
	}
	if !strings.Contains(err.Error(), "context length exceeded") {
		t.Errorf("err = %v, want it to carry the server's message", err)
	}
	if strings.Contains(err.Error(), "no choices") {
		t.Errorf("err = %v, must not fall back to the generic no-choices message", err)
	}
}

func TestListModels(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/models", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"data":[{"id":"llama4:8b"},{"id":"qwen3:14b"},{"id":""}]}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	models, err := ListModels(context.Background(), srv.URL+"/")
	if err != nil {
		t.Fatalf("ListModels: %v", err)
	}
	want := []string{"llama4:8b", "qwen3:14b"}
	if len(models) != 2 || models[0] != want[0] || models[1] != want[1] {
		t.Errorf("models = %v, want %v (empty ids dropped)", models, want)
	}
}

func TestListModels_ServerDown(t *testing.T) {
	srv := httptest.NewServer(http.NewServeMux())
	url := srv.URL
	srv.Close()
	if _, err := ListModels(context.Background(), url); err == nil {
		t.Fatal("want error for unreachable server")
	}
}
