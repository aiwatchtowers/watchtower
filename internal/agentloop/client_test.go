package agentloop

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/ollama"
	"watchtower/internal/tools"
)

// NewClient defaults an empty base URL to the Ollama server and trims a
// trailing slash, so the request path never doubles it.
func TestNewClient_BaseURLDefaultAndTrim(t *testing.T) {
	b := tools.Binding{Surface: "main"}
	assert.Equal(t, ollama.DefaultBaseURL, NewClient("m", "", nil, b).baseURL)
	c := NewClient("m", "http://lm.example:1234///", nil, b)
	assert.Equal(t, "http://lm.example:1234", c.baseURL)
	assert.Equal(t, defaultMaxIterations, c.maxIter)
	assert.Equal(t, b, c.binding)
}

// pathCheckingServer serves responses in order and fails the test on any
// request that is not a POST to /v1/chat/completions.
func pathCheckingServer(t *testing.T, responses ...oaResponse) *httptest.Server {
	t.Helper()
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/chat/completions" {
			t.Errorf("request %s %q, want POST /v1/chat/completions", r.Method, r.URL.Path)
		}
		i := min(calls, len(responses)-1)
		calls++
		_ = json.NewEncoder(w).Encode(responses[i])
	}))
	t.Cleanup(srv.Close)
	return srv
}

// Query — the ai.Provider surface cmd/generator.go builds — streams the tool
// boundary then the answer, delivers no error, and closes all three channels.
func TestClient_QueryStreamsAndClosesChannels(t *testing.T) {
	srv := pathCheckingServer(t, toolCallResp("list_targets", `{}`), finalResp("done"))
	c := NewClient("m", srv.URL+"/", nil, tools.Binding{Surface: "main"})
	c.reg = &fakeReg{tools: map[string]*tools.Tool{"list_targets": tools.NewListTargets()}, readData: []any{}}

	textCh, errCh, sidCh := c.Query(context.Background(), "sys", "hi", "")
	var chunks []ai.StreamChunk
	for ch := range textCh {
		chunks = append(chunks, ch)
	}
	require.Equal(t, []ai.StreamChunk{{ToolBoundary: true}, {Text: "done"}}, chunks)
	for err := range errCh {
		t.Errorf("errCh delivered %v, want none", err)
	}
	for sid := range sidCh {
		t.Errorf("sidCh delivered %q, want none (runtime B has no session id)", sid)
	}
}

// A failing model endpoint reaches the caller on errCh, and the text channel
// still closes so a ranging consumer never hangs.
func TestClient_QueryDeliversErrorOnErrCh(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusBadGateway)
	}))
	t.Cleanup(srv.Close)
	c := NewClient("m", srv.URL, nil, tools.Binding{Surface: "main"})
	c.reg = &fakeReg{tools: map[string]*tools.Tool{}}

	textCh, errCh, _ := c.Query(context.Background(), "", "hi", "")
	for ch := range textCh {
		t.Errorf("text chunk %+v on a failed run, want none", ch)
	}
	err, ok := <-errCh
	require.True(t, ok, "errCh closed without delivering the error")
	assert.ErrorContains(t, err, "HTTP 502")
}

// QuerySync returns the final answer and sums usage across every round.
func TestClient_QuerySyncSumsUsageAcrossRounds(t *testing.T) {
	first := toolCallResp("list_targets", `{}`)
	first.Usage = &oaUsage{PromptTokens: 10, CompletionTokens: 2, TotalTokens: 12}
	second := finalResp("answer")
	second.Usage = &oaUsage{PromptTokens: 20, CompletionTokens: 5, TotalTokens: 25}
	srv := pathCheckingServer(t, first, second)
	c := NewClient("m", srv.URL, nil, tools.Binding{Surface: "main"})
	c.reg = &fakeReg{tools: map[string]*tools.Tool{"list_targets": tools.NewListTargets()}, readData: []any{}}

	text, usage, err := c.QuerySync(context.Background(), "", "hi", "")
	require.NoError(t, err)
	assert.Equal(t, "answer", text)
	require.NotNil(t, usage)
	assert.Equal(t, ai.Usage{InputTokens: 30, OutputTokens: 7, TotalAPITokens: 37}, *usage)
}
