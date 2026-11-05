package agentloop

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/providers"
	"watchtower/internal/tools"
)

// sseServer answers the i-th request with the i-th section (clamping to the
// last) as an SSE body, one flushed line per entry; an entry "HANG" holds
// the response open until the request is cancelled. It keeps each request
// body.
type sseServer struct {
	*httptest.Server
	mu     sync.Mutex
	bodies []string
}

func newSSEServer(t *testing.T, sections ...[]string) *sseServer {
	t.Helper()
	s := &sseServer{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		s.mu.Lock()
		i := len(s.bodies)
		s.bodies = append(s.bodies, string(b))
		s.mu.Unlock()
		w.Header().Set("Content-Type", "text/event-stream")
		for _, line := range sections[min(i, len(sections)-1)] {
			if line == "HANG" {
				<-r.Context().Done()
				return
			}
			_, _ = io.WriteString(w, line+"\n\n")
			w.(http.Flusher).Flush()
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func (s *sseServer) requests() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.bodies...)
}

func sseText(s string) string {
	b, _ := json.Marshal(map[string]any{"choices": []any{map[string]any{"index": 0, "delta": map[string]any{"content": s}}}})
	return "data: " + string(b)
}

func sseFinish(reason string) string {
	return `data: {"choices":[{"index":0,"delta":{},"finish_reason":"` + reason + `"}]}`
}

func sseUsage(in, out int) string {
	b, _ := json.Marshal(map[string]any{"choices": []any{}, "usage": map[string]int{
		"prompt_tokens": in, "completion_tokens": out, "total_tokens": in + out}})
	return "data: " + string(b)
}

const sseDone = "data: [DONE]"

func textsOf(chunks []ai.StreamChunk) []string {
	var out []string
	for _, ch := range chunks {
		if ch.Text != "" {
			out = append(out, ch.Text)
		}
	}
	return out
}

func listTargetsReg() *fakeReg {
	return &fakeReg{tools: map[string]*tools.Tool{"list_targets": tools.NewListTargets()}, readData: []any{}}
}

func textAndTool(text string) oaResponse {
	r := toolCallResp("list_targets", `{}`)
	r.Choices[0].Message.Content = text
	return r
}

// L7: with the chat events on, the text a model writes before a tool call is
// shown as it arrives, before the tool step, and the next message follows
// after a blank line — as on claude and codex. A server that answers a
// streaming request with one JSON body still has each message shown whole.
func TestAgentloopQuery_KeepsTextBeforeTool(t *testing.T) {
	srv, _ := scriptedServer(t, textAndTool("Looking it up."), finalResp("Found it."))
	c := clientWith(listTargetsReg(), srv.URL)
	c.EmitToolEvents()

	chunks, err := collect(t, c)
	require.NoError(t, err)
	assert.Equal(t, []string{"Looking it up.", "\n\nFound it."}, textsOf(chunks))
	var order []string
	for _, ch := range chunks {
		switch {
		case ch.Text != "":
			order = append(order, "text")
		case ch.Tool != nil && !ch.Tool.Done:
			order = append(order, "tool_start")
		}
	}
	assert.Equal(t, []string{"text", "tool_start", "text"}, order, "the pre-tool text comes before its tool step")
}

// A v1 consumer (no chat events) resets its text at the boundary, so the
// pre-tool text is sent before it and the answer after it has no separator
// (codex's v1 rule).
func TestAgentloopQuery_V1PreToolTextThenBoundary(t *testing.T) {
	srv, _ := scriptedServer(t, textAndTool("Looking it up."), finalResp("Found it."))
	chunks, err := collect(t, clientWith(listTargetsReg(), srv.URL))
	require.NoError(t, err)
	assert.Equal(t, []ai.StreamChunk{{Text: "Looking it up."}, {ToolBoundary: true}, {Text: "Found it."}}, chunks)
}

// A v1 consumer whose last message carries no text still gets the earlier
// text as the answer after the boundary wiped it (unchanged behaviour); a v2
// consumer already has it on screen and gets it once.
func TestAgentloopQuery_EmptyFinalMessage(t *testing.T) {
	srv, _ := scriptedServer(t, textAndTool("The answer."), finalResp(""))
	chunks, err := collect(t, clientWith(listTargetsReg(), srv.URL))
	require.NoError(t, err)
	assert.Equal(t, []string{"The answer.", "The answer."}, textsOf(chunks))

	srv2, _ := scriptedServer(t, textAndTool("The answer."), finalResp(""))
	c := clientWith(listTargetsReg(), srv2.URL)
	c.EmitToolEvents()
	chunks, err = collect(t, c)
	require.NoError(t, err)
	assert.Equal(t, []string{"The answer."}, textsOf(chunks))
}

// A streaming server's text deltas are passed on as they arrive; tool calls
// assembled from their deltas are dispatched; the usage chunk is summed.
func TestAgentloopQuery_StreamsDeltas(t *testing.T) {
	srv := newSSEServer(t,
		[]string{
			sseText("Look"), sseText("ing."),
			`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c9","type":"function","function":{"name":"list_targets","arguments":"{\"st"}}]}}]}`,
			`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"atus\":\"open\"}"}}]}}]}`,
			sseFinish("tool_calls"), sseUsage(100, 10), sseDone,
		},
		[]string{sseText("Found"), sseText(" it."), sseFinish("stop"), sseUsage(150, 20), sseDone},
	)
	reg := listTargetsReg()
	c := clientWith(reg, srv.URL)
	c.EmitToolEvents()

	chunks, err := collect(t, c)
	require.NoError(t, err)
	assert.Equal(t, []string{"Look", "ing.", "\n\nFound", " it."}, textsOf(chunks))
	assert.Equal(t, []string{"list_targets"}, reg.reads)
	var start *ai.ToolEvent
	for _, ch := range chunks {
		if ch.Tool != nil && !ch.Tool.Done {
			start = ch.Tool
		}
	}
	require.NotNil(t, start)
	assert.Equal(t, "c9", start.ID)
	assert.JSONEq(t, `{"status":"open"}`, string(start.Args))
	last := chunks[len(chunks)-1]
	require.NotNil(t, last.Usage)
	assert.Equal(t, ai.TurnUsage{Model: "m", InputTokens: 250, OutputTokens: 30}, *last.Usage)

	reqs := srv.requests()
	require.Len(t, reqs, 2)
	var req struct {
		Stream        bool `json:"stream"`
		StreamOptions struct {
			IncludeUsage bool `json:"include_usage"`
		} `json:"stream_options"`
		Messages []oaMessage `json:"messages"`
	}
	require.NoError(t, json.Unmarshal([]byte(reqs[1]), &req))
	assert.True(t, req.Stream)
	assert.True(t, req.StreamOptions.IncludeUsage)
	var assistant *oaMessage
	for i := range req.Messages {
		if req.Messages[i].Role == "assistant" {
			assistant = &req.Messages[i]
		}
	}
	require.NotNil(t, assistant, "the streamed assistant message is fed back")
	assert.Equal(t, "Looking.", assistant.Content)
	require.Len(t, assistant.ToolCalls, 1)
	assert.Equal(t, `{"status":"open"}`, assistant.ToolCalls[0].Function.Arguments)
}

// Parallel tool calls streamed by index are kept apart.
func TestAgentloopQuery_StreamsParallelToolCalls(t *testing.T) {
	srv := newSSEServer(t,
		[]string{
			`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","type":"function","function":{"name":"list_targets","arguments":"{}"}},{"index":1,"id":"b","type":"function","function":{"name":"list_targets","arguments":"{}"}}]}}]}`,
			sseFinish("tool_calls"), sseDone,
		},
		[]string{sseText("done"), sseFinish("stop"), sseDone},
	)
	reg := listTargetsReg()
	c := clientWith(reg, srv.URL)
	c.EmitToolEvents()
	_, err := collect(t, c)
	require.NoError(t, err)
	assert.Equal(t, []string{"list_targets", "list_targets"}, reg.reads)
}

// On interrupt the text already streamed stays delivered; the turn ends with
// the cancellation.
func TestAgentloopQuery_InterruptKeepsStreamedText(t *testing.T) {
	srv := newSSEServer(t, []string{sseText("First message."), "HANG"})
	c := clientWith(listTargetsReg(), srv.URL)
	c.EmitToolEvents()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	textCh, errCh, sidCh := c.Query(ctx, "", "go", "")
	var texts []string
	for ch := range textCh {
		if ch.Text != "" {
			texts = append(texts, ch.Text)
			cancel()
		}
	}
	for range sidCh {
	}
	var got error
	for err := range errCh {
		got = err
	}
	assert.Equal(t, []string{"First message."}, texts)
	require.Error(t, got)
	assert.True(t, errors.Is(got, context.Canceled), "the stop is the cause: %v", got)
}

// A stream that ends with neither [DONE] nor a finish_reason was cut short:
// a transport failure, never a finished answer.
func TestAgentloopQuery_StreamCutShortIsTransport(t *testing.T) {
	srv := newSSEServer(t, []string{sseText("partial")})
	_, err := collect(t, clientWith(listTargetsReg(), srv.URL))
	var f *providers.Failure
	require.True(t, errors.As(err, &f), "untyped: %v", err)
	assert.Equal(t, providers.Transport, f.Category)
}

// An error the server reports inside the stream is a typed failure.
func TestAgentloopQuery_StreamErrorIsTyped(t *testing.T) {
	srv := newSSEServer(t, []string{`data: {"error":{"message":"model \"x\" not found"}}`})
	_, err := collect(t, clientWith(listTargetsReg(), srv.URL))
	var f *providers.Failure
	require.True(t, errors.As(err, &f), "untyped: %v", err)
	assert.Equal(t, providers.Model, f.Category)
}

// QuerySync (an automation's agent()) has no consumer to stream to: it sends
// stream=false.
func TestAgentloopQuerySync_DoesNotStream(t *testing.T) {
	var body string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		body = string(b)
		_ = json.NewEncoder(w).Encode(finalResp("ok"))
	}))
	t.Cleanup(srv.Close)
	out, _, err := clientWith(listTargetsReg(), srv.URL).QuerySync(context.Background(), "", "hi", "")
	require.NoError(t, err)
	assert.Equal(t, "ok", out)
	assert.Contains(t, body, `"stream":false`)
	assert.NotContains(t, body, "stream_options")
}

// At the iteration cap a v2 consumer already shows the last text, so only
// the note follows it.
func TestAgentloopQuery_CapNoteAfterShownText(t *testing.T) {
	srv, _ := scriptedServer(t, textAndTool("partial progress"))
	c := clientWith(listTargetsReg(), srv.URL)
	c.maxIter = 1
	c.EmitToolEvents()
	chunks, err := collect(t, c)
	require.NoError(t, err)
	text := strings.Join(textsOf(chunks), "")
	assert.Equal(t, 1, strings.Count(text, "partial progress"), text)
	assert.True(t, strings.HasSuffix(text, "partial progress\n\n(Note: I reached the tool-call limit before finishing.)"), text)
}
