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

// Web search is the owner's own codex setting unless the caller sets it
// (ask #323): unset, no web_search flag; set, live or disabled. A
// read-folder run never searches.
func TestClient_WebSearchUnsetOrExplicit(t *testing.T) {
	unset := NewClient("gpt-x", "", "codex").ArgsForTest("sys", "msg")
	assert.NotContains(t, strings.Join(unset, " "), "web_search", "the owner's setting is left alone")

	c := NewClient("gpt-x", "", "codex")
	c.SetWebSearch(true)
	on := c.ArgsForTest("sys", "msg")
	assert.True(t, hasPair(on, "-c", `web_search="live"`), "%v", on)
	assert.False(t, hasPair(on, "-c", `web_search="disabled"`), "%v", on)

	c.SetWebSearch(false)
	off := c.ArgsForTest("sys", "msg")
	assert.True(t, hasPair(off, "-c", `web_search="disabled"`), "%v", off)
	assert.False(t, hasPair(off, "-c", `web_search="live"`), "%v", off)

	c.SetWebSearch(true)
	c.SetReadFolder(t.TempDir())
	rf := c.ArgsForTest("sys", "msg")
	assert.True(t, hasPair(rf, "-c", `web_search="disabled"`), "%v", rf)
	assert.False(t, hasPair(rf, "-c", `web_search="live"`), "%v", rf)
}

// SetImages adds one --image=<path> per image to the next run only, before
// the stdin marker; a path with a comma (codex splits on it) is refused.
func TestClient_SetImagesIsPerRun(t *testing.T) {
	c := NewClient("gpt-x", "", "codex")
	c.SetImages([]string{"/work/a.png", "/work/b.jpg"})
	args := c.ArgsForTest("sys", "msg")
	assert.Equal(t, []string{"--image=/work/a.png", "--image=/work/b.jpg"}, imageArgs(args))
	assert.Equal(t, "-", args[len(args)-1])
	assert.Empty(t, imageArgs(c.ArgsForTest("sys", "msg")), "taken by the run it was set for")

	c.SetImages([]string{"/work/a,b.png"})
	_, _, err := c.QuerySync(context.Background(), "sys", "msg", "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "comma")
}

// A web_search item is a visible step named WebSearch, its query the
// arguments and its results Claude's "Links:" line, so the chat lists the
// pages as sources.
func TestQuery_WebSearchItemIsAStep(t *testing.T) {
	jsonl := strings.Join([]string{
		`{"type":"thread.started","thread_id":"th1"}`,
		`{"type":"turn.started"}`,
		`{"type":"item.started","item":{"id":"item_1","type":"web_search","id":"ws1","query":"","action":{"type":"other"}}}`,
		`{"type":"item.completed","item":{"id":"item_1","type":"web_search","id":"ws1","query":"latest go","action":{"type":"search","query":"latest go"},"results":[{"type":"text_result","domain":"example.com","title":"Releases","url":"https://example.com/dl","snippet":"x"}]}}`,
		`{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Go 1.0."}}`,
		`{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}`,
	}, "\n")
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
	require.Len(t, tools, 2)
	assert.Equal(t, "WebSearch", tools[0].Name)
	assert.Equal(t, "ws1", tools[0].ID)
	end := tools[1]
	assert.True(t, end.Done)
	assert.True(t, end.OK)
	assert.JSONEq(t, `{"query":"latest go"}`, string(end.Args))
	assert.Equal(t, `Links: [{"title":"Releases","url":"https://example.com/dl"}]`, end.Result)
}

func hasPair(args []string, flag, value string) bool {
	for i := 0; i+1 < len(args); i++ {
		if args[i] == flag && args[i+1] == value {
			return true
		}
	}
	return false
}

func imageArgs(args []string) []string {
	return slices.DeleteFunc(slices.Clone(args), func(a string) bool { return !strings.HasPrefix(a, "--image=") })
}

// The recorded run (codex 0.159.2, web_search="live", an image and the
// watchtower server mounted; scrubbed) shows each web search as one step
// with its pages, beside the MCP call. Codex sends a web_search item with
// two "id" keys; the later one names the search.
func TestQuery_RecordedWebSearchIsAStep(t *testing.T) {
	jsonl := strings.Join(fixtureLines(t, "web_search_live.jsonl"), "\n")
	c := NewClient("gpt-x", "", fakeCodexScript(t, jsonl, "", 0))
	c.EmitToolEvents()
	textCh, errCh, _ := c.Query(context.Background(), "sys", "msg", "")
	var names []string
	var ends []*ai.ToolEvent
	for ch := range textCh {
		if ch.Tool != nil && !ch.Tool.Done {
			names = append(names, ch.Tool.Name)
		}
		if ch.Tool != nil && ch.Tool.Done {
			ends = append(ends, ch.Tool)
		}
	}
	for err := range errCh {
		require.NoError(t, err)
	}
	assert.Equal(t, []string{"WebSearch", "mcp__watchtower__list_targets", "WebSearch"}, names)
	require.Len(t, ends, 3)
	assert.Equal(t, "exec-00000000-0000-0000-0000-000000000001", ends[0].ID)
	assert.Contains(t, ends[0].Result, `"url":"https://example.com/page-1"`)
	assert.JSONEq(t, `{"query":"example query"}`, string(ends[0].Args))
}
