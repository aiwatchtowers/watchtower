package codex

import (
	"context"
	"slices"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
)

// SetImages adds one --image=<path> per image to the next run only, before
// the stdin marker; a path with a comma (codex splits on it) is refused.
func TestClient_SetImagesIsPerRun(t *testing.T) {
	c := NewClient("gpt-x", "", fakeCodexScript(t, plainRun, "", 0))
	c.SetImages([]string{"/work/a.png", "/work/b.jpg"})
	args := c.ArgsForTest("sys", "msg")
	assert.Equal(t, []string{"--image=/work/a.png", "--image=/work/b.jpg"}, imageArgs(args))
	assert.Equal(t, "-", args[len(args)-1])
	_, _, err := c.QuerySync(context.Background(), "sys", "msg", "")
	require.NoError(t, err)
	assert.Empty(t, imageArgs(c.ArgsForTest("sys", "msg")), "taken by the run it was set for")

	c.SetImages([]string{"/work/a,b.png"})
	_, _, err = c.QuerySync(context.Background(), "sys", "msg", "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "comma")
}

const plainRun = `{"type":"turn.started"}
{"type":"item.completed","item":{"id":"m","type":"agent_message","text":"ok"}}
{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}`

// queryTools runs one Query over jsonl and returns its tool events.
func queryTools(t *testing.T, jsonl string) []*ai.ToolEvent {
	t.Helper()
	c := NewClient("gpt-x", "", fakeCodexScript(t, jsonl, "", 0))
	c.EmitToolEvents()
	textCh, errCh, _ := c.Query(context.Background(), "sys", "msg", "")
	var tools []*ai.ToolEvent
	for ch := range textCh {
		if ch.Tool != nil {
			tools = append(tools, ch.Tool)
		}
	}
	for err := range errCh {
		require.NoError(t, err)
	}
	return tools
}

// A web_search item is a visible step named WebSearch that starts once
// its query is known (the item.started line has none), the query its
// arguments, and its results Claude's "Links:" line, so the chat lists the
// pages as sources.
func TestQuery_WebSearchItemIsAStep(t *testing.T) {
	tools := queryTools(t, strings.Join([]string{
		`{"type":"thread.started","thread_id":"th1"}`,
		`{"type":"turn.started"}`,
		`{"type":"item.started","item":{"id":"item_1","type":"web_search","id":"ws1","query":"","action":{"type":"other"}}}`,
		`{"type":"item.completed","item":{"id":"item_1","type":"web_search","id":"ws1","query":"latest go","action":{"type":"search","query":"latest go"},"results":[{"type":"text_result","domain":"example.com","title":"Releases","url":"https://example.com/dl","snippet":"x"}]}}`,
		`{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Go 1.0."}}`,
		`{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}`,
	}, "\n"))
	require.Len(t, tools, 2)
	start, end := tools[0], tools[1]
	assert.Equal(t, "WebSearch", start.Name)
	assert.Equal(t, "ws1", start.ID)
	assert.JSONEq(t, `{"query":"latest go"}`, string(start.Args))
	assert.True(t, end.Done)
	assert.True(t, end.OK)
	assert.Equal(t, `Links: [{"title":"Releases","url":"https://example.com/dl"}]`, end.Result)
}

// A web search codex reports failed is a red step with codex's reason, or
// a generic one; one with no pages is a finished step that says so.
func TestQuery_WebSearchFailureIsARedStep(t *testing.T) {
	line := func(id, extra string) string {
		return `{"type":"item.completed","item":{"id":"` + id + `","type":"web_search","query":"q"` + extra + `}}`
	}
	tools := queryTools(t, strings.Join([]string{`{"type":"turn.started"}`,
		line("a", `,"error":{"message":"search unavailable"}`),
		line("b", `,"status":"failed","results":[{"title":"T","url":"https://example.com"}]`),
		line("c", `,"results":[]`),
		`{"type":"item.completed","item":{"id":"m","type":"agent_message","text":"done"}}`,
		`{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}`}, "\n"))
	require.Len(t, tools, 6)
	assert.False(t, tools[1].OK)
	assert.Equal(t, "search unavailable", tools[1].Result)
	assert.False(t, tools[3].OK)
	assert.Equal(t, "the web search failed", tools[3].Result)
	assert.True(t, tools[5].OK)
	assert.Equal(t, "No pages found", tools[5].Result)
}

func imageArgs(args []string) []string {
	return slices.DeleteFunc(slices.Clone(args), func(a string) bool { return !strings.HasPrefix(a, "--image=") })
}

// The recorded run (codex 0.159.2, web_search="live", an image and the
// watchtower server mounted; scrubbed) shows each web search as one step
// with its pages, beside the MCP call. Codex sends a web_search item with
// two "id" keys; the later one names the search.
// A search whose completion never came (codex exited, the turn was
// stopped) is still shown, as a red step (CHAT-02).
func TestQuery_UnfinishedWebSearchIsClosedAsARedStep(t *testing.T) {
	c := NewClient("gpt-x", "", fakeCodexScript(t, strings.Join([]string{`{"type":"turn.started"}`,
		`{"type":"item.started","item":{"id":"item_1","type":"web_search","id":"ws1","query":"","action":{"type":"other"}}}`,
		`{"type":"item.completed","item":{"id":"m","type":"agent_message","text":"partial"}}`}, "\n"), "", 0))
	c.EmitToolEvents()
	textCh, errCh, _ := c.Query(context.Background(), "sys", "msg", "")
	var tools []*ai.ToolEvent
	for ch := range textCh {
		if ch.Tool != nil {
			tools = append(tools, ch.Tool)
		}
	}
	for range errCh {
	}
	require.Len(t, tools, 2)
	assert.Equal(t, "WebSearch", tools[0].Name)
	assert.Equal(t, "ws1", tools[0].ID)
	assert.True(t, tools[1].Done)
	assert.False(t, tools[1].OK)
	assert.Equal(t, "codex stopped before reporting this tool's result", tools[1].Result)
}

func TestQuery_RecordedWebSearchIsAStep(t *testing.T) {
	tools := queryTools(t, strings.Join(fixtureLines(t, "web_search_live.jsonl"), "\n"))
	var names []string
	var starts, ends []*ai.ToolEvent
	for _, tl := range tools {
		if tl.Done {
			ends = append(ends, tl)
			continue
		}
		starts = append(starts, tl)
		names = append(names, tl.Name)
	}
	assert.Equal(t, []string{"WebSearch", "mcp__watchtower__list_targets", "WebSearch"}, names)
	require.Len(t, ends, 3)
	assert.Equal(t, "exec-00000000-0000-0000-0000-000000000001", ends[0].ID)
	assert.JSONEq(t, `{"query":"example query"}`, string(starts[0].Args))
	assert.Contains(t, ends[0].Result, `"url":"https://example.com/page-1"`)
}
