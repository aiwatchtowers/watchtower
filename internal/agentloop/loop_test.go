package agentloop

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/tools"
)

// scriptedServer replies with responses[i] for the i-th request (clamping to
// the last), and counts how many requests it saw.
func scriptedServer(t *testing.T, responses ...oaResponse) (*httptest.Server, *int) {
	t.Helper()
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		i := calls
		calls++
		if i >= len(responses) {
			i = len(responses) - 1
		}
		_ = json.NewEncoder(w).Encode(responses[i])
	}))
	t.Cleanup(srv.Close)
	return srv, &calls
}

func toolCallResp(name, args string) oaResponse {
	return oaResponse{Choices: []oaChoice{{Message: oaMessage{
		Role:      "assistant",
		ToolCalls: []oaToolCall{{ID: "c1", Type: "function", Function: oaFunction{Name: name, Arguments: args}}},
	}}}}
}

func finalResp(text string) oaResponse {
	return oaResponse{Choices: []oaChoice{{Message: oaMessage{Role: "assistant", Content: text}}}}
}

// fakeReg is an in-memory registry for loop-logic tests (no DB).
type fakeReg struct {
	tools    map[string]*tools.Tool
	proposed []string
	reads    []string
	readData any
}

func (f *fakeReg) List(string) []*tools.Tool {
	out := make([]*tools.Tool, 0, len(f.tools))
	for _, t := range f.tools {
		out = append(out, t)
	}
	return out
}
func (f *fakeReg) Get(name string) (*tools.Tool, bool) { t, ok := f.tools[name]; return t, ok }
func (f *fakeReg) Propose(_ context.Context, name string, _ json.RawMessage, _ tools.Binding) (tools.Receipt, error) {
	f.proposed = append(f.proposed, name)
	return tools.Receipt{ActionID: 7, Status: "pending", Tool: name, Message: "awaits approval"}, nil
}
func (f *fakeReg) CallRead(_ context.Context, name string, _ json.RawMessage) (any, error) {
	f.reads = append(f.reads, name)
	return f.readData, nil
}

func clientWith(reg registry, url string) *Client {
	return &Client{model: "m", baseURL: url, httpc: http.DefaultClient, reg: reg, binding: tools.Binding{Surface: "main"}, maxIter: 6}
}

// A read tool call is dispatched, its result fed back, and the next (no-tool)
// turn's content is the answer.
func TestLoop_ToolCallThenFinalAnswer(t *testing.T) {
	reg := &fakeReg{tools: map[string]*tools.Tool{"list_situations": tools.NewListSituations()}, readData: []any{}}
	srv, calls := scriptedServer(t, toolCallResp("list_situations", `{}`), finalResp("here is what is going on"))

	text, _, err := clientWith(reg, srv.URL).run(context.Background(), "sys", "what is going on")
	require.NoError(t, err)
	assert.Equal(t, "here is what is going on", text)
	assert.Equal(t, []string{"list_situations"}, reg.reads)
	assert.Equal(t, 2, *calls, "one tool round then the answer")
}

// A write tool call goes through Propose, never Execute; the loop then finishes.
func TestLoop_WriteToolGoesThroughPropose(t *testing.T) {
	reg := &fakeReg{tools: map[string]*tools.Tool{"create_target": tools.NewCreateTarget()}}
	srv, _ := scriptedServer(t, toolCallResp("create_target", `{"text":"do it","reason":"because"}`), finalResp("proposed"))

	text, _, err := clientWith(reg, srv.URL).run(context.Background(), "", "remember to do it")
	require.NoError(t, err)
	assert.Equal(t, "proposed", text)
	assert.Equal(t, []string{"create_target"}, reg.proposed)
}

// An unknown-tool call comes back as an error tool-result and the turn still
// completes — one bad call must not kill the loop.
func TestLoop_ToolErrorFedBackNotFatal(t *testing.T) {
	reg := &fakeReg{tools: map[string]*tools.Tool{}}
	srv, calls := scriptedServer(t, toolCallResp("nope", `{}`), finalResp("recovered"))

	text, _, err := clientWith(reg, srv.URL).run(context.Background(), "", "go")
	require.NoError(t, err)
	assert.Equal(t, "recovered", text)
	assert.Equal(t, 2, *calls)
}

// A model that always calls a tool terminates at the iteration cap instead of
// looping forever; the loop never hangs.
func TestLoop_MaxIterationsCap(t *testing.T) {
	reg := &fakeReg{tools: map[string]*tools.Tool{"list_situations": tools.NewListSituations()}, readData: []any{}}
	srv, calls := scriptedServer(t, toolCallResp("list_situations", `{}`)) // always a tool call
	c := clientWith(reg, srv.URL)
	c.maxIter = 3

	text, _, err := c.run(context.Background(), "", "loop")
	require.NoError(t, err)
	assert.NotEmpty(t, text, "cap must still return some text, never hang")
	assert.Equal(t, 3, *calls, "the loop stops exactly at the cap")
}

// A non-200 from the model endpoint fails the run (a transport error, unlike a
// tool error which is fed back).
func TestLoop_ModelEndpointErrorFailsRun(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)

	_, _, err := clientWith(&fakeReg{tools: map[string]*tools.Tool{}}, srv.URL).run(context.Background(), "", "hi")
	require.Error(t, err)
	assert.True(t, strings.Contains(err.Error(), "500") || strings.Contains(err.Error(), "boom"))
}
