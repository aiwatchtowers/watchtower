package ollama

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

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
	if _, _, _, err := g.Generate(digest.WithSource(context.Background(), "inbox.triage"), "sys", "msg", ""); err != nil {
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
		got.WriteString(chunk)
	}
	for err := range errCh {
		t.Fatalf("stream error: %v", err)
	}
	if got.String() != "Hello" {
		t.Errorf("streamed = %q, want %q", got.String(), "Hello")
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
