package chat

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// feedAll runs every line through a fresh translator bound to turn id "t1".
func feedAll(t *testing.T, tr *ClaudeTranslator, lines ...string) []Event {
	t.Helper()
	var out []Event
	for _, l := range lines {
		evs, err := tr.Feed([]byte(l))
		require.NoError(t, err, l)
		out = append(out, evs...)
	}
	return out
}

func fixedTurn(id string) func() string { return func() string { return id } }

func types(evs []Event) []string {
	out := make([]string, len(evs))
	for i, e := range evs {
		out[i] = e.Type
	}
	return out
}

const (
	lnMsgStart  = `{"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-sonnet-x","content":[]}},"session_id":"s1"}`
	lnTextStart = `{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}`
	lnTextStop  = `{"type":"stream_event","event":{"type":"content_block_stop","index":0}}`
	lnMsgStop   = `{"type":"stream_event","event":{"type":"message_stop"}}`
	lnResultOK  = `{"type":"result","subtype":"success","is_error":false,"result":"Hello","session_id":"s1","usage":{"input_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":2,"output_tokens":7}}`
)

func textDelta(i int, s string) string {
	return `{"type":"stream_event","event":{"type":"content_block_delta","index":` + strconv.Itoa(i) +
		`,"delta":{"type":"text_delta","text":"` + s + `"}}}`
}

func TestClaudeTranslator_TextDeltasStreamTokenLevel(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	evs := feedAll(t, tr,
		`{"type":"system","subtype":"init","session_id":"s1","model":"claude-sonnet-x"}`,
		lnMsgStart, lnTextStart, textDelta(0, "Hel"), textDelta(0, "lo"), lnTextStop,
		`{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}}`,
		lnMsgStop,
		`{"type":"assistant","message":{"model":"claude-sonnet-x","content":[{"type":"text","text":"Hello"}]},"session_id":"s1"}`,
		lnResultOK,
	)
	require.Equal(t, []string{EventTextDelta, EventTextDelta, EventUsage, EventTurnDone}, types(evs),
		"the full assistant message must not duplicate the streamed text")
	assert.Equal(t, "Hel", evs[0].Text)
	assert.Equal(t, "t1", evs[0].TurnID)
	assert.Equal(t, 17, evs[2].TokensIn, "input + cache read + cache creation")
	assert.Equal(t, 7, evs[2].TokensOut)
	assert.Equal(t, "claude-sonnet-x", evs[2].Model)
	assert.Equal(t, StatusComplete, evs[3].Status)
	assert.Equal(t, "s1", evs[3].SessionID)
	assert.Equal(t, "s1", tr.SessionID())
}

// TestChat02_ToolCallNeverWipesText: CHAT-02 — every tool call becomes a
// visible tool_start/tool_end pair, and the text before the tool stays (there
// is no reset event in protocol v2).
// BEHAVIOR CHAT-02 — see docs/inventory/chat.md
func TestChat02_ToolCallNeverWipesText(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	evs := feedAll(t, tr,
		lnMsgStart, lnTextStart, textDelta(0, "Let me look."), lnTextStop,
		`{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"mcp__watchtower__search_knowledge","input":{}}}}`,
		`{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"queries\":"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"[\"pay\"]}"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_stop","index":1}}`,
		lnMsgStop,
		`{"type":"user","message":{"role":"user","content":[{"type":"text","text":"not a tool result, ignored"},{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"{\"hits\":[]}"}],"is_error":false}]}}`,
		lnMsgStart, lnTextStart, textDelta(0, "Found it."), lnTextStop, lnMsgStop,
		lnResultOK,
	)
	require.Equal(t, []string{EventTextDelta, EventToolStart, EventToolEnd, EventTextDelta, EventUsage, EventTurnDone}, types(evs))
	for _, e := range evs {
		assert.NotEqual(t, "reset", e.Type, "protocol v2 never wipes text")
	}
	assert.Equal(t, "Let me look.", evs[0].Text)
	assert.Equal(t, "\n\nFound it.", evs[3].Text,
		"text of a later assistant message is separated from the earlier text, never glued to it")
	start, end := evs[1], evs[2]
	assert.Equal(t, "toolu_1", start.ID)
	assert.Equal(t, "search_knowledge", start.Name, "the mcp__watchtower__ prefix is stripped")
	assert.JSONEq(t, `{"queries":["pay"]}`, string(start.Args))
	assert.Equal(t, "toolu_1", end.ID)
	require.NotNil(t, end.OK)
	assert.True(t, *end.OK)
}

func TestClaudeTranslator_ToolArgsEdgeCases(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	evs := feedAll(t, tr,
		`{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"a","name":"mcp__confluence__search"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_stop","index":0}}`,
		`{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"b","name":"mcp__watchtower__get_target"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"id\":"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_stop","index":1}}`,
	)
	require.Len(t, evs, 2)
	assert.Equal(t, "confluence:search", evs[0].Name, "external MCP tools keep server:name")
	assert.JSONEq(t, `{}`, string(evs[0].Args), "no input deltas → empty object")
	assert.JSONEq(t, `{"_raw":"{\"id\":"}`, string(evs[1].Args), "truncated JSON is wrapped, never emitted invalid")
}

func TestClaudeTranslator_FailedToolIsARedStepNotATurnError(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	evs := feedAll(t, tr,
		`{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"x","name":"mcp__watchtower__get_jira_issue"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_stop","index":0}}`,
		`{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"no jira issue with key ABC-1","is_error":true}]}}`,
	)
	require.Equal(t, []string{EventToolStart, EventToolEnd}, types(evs))
	require.NotNil(t, evs[1].OK)
	assert.False(t, *evs[1].OK)
	assert.Equal(t, "no jira issue with key ABC-1", evs[1].Summary)
	assert.Empty(t, evs[1].Sources)
}

func TestClaudeTranslator_ThinkingIsDropped(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	evs := feedAll(t, tr,
		lnMsgStart,
		`{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}`,
		`{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"secret reasoning"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_stop","index":0}}`,
		`{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}}`,
		textDelta(1, "391"),
	)
	require.Equal(t, []string{EventTextDelta}, types(evs))
	assert.Equal(t, "391", evs[0].Text)
}

func TestClaudeTranslator_InterruptEndsTurnInterrupted(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	tr.MarkInterrupted()
	evs := feedAll(t, tr,
		`{"type":"control_response","response":{"subtype":"success","request_id":"r1"}}`,
		`{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s1","usage":{"input_tokens":1,"output_tokens":0}}`,
	)
	require.Equal(t, []string{EventUsage, EventTurnDone}, types(evs))
	assert.Equal(t, StatusInterrupted, evs[1].Status)

	// The flag is consumed: the next failed turn is a real error again.
	evs = feedAll(t, tr, `{"type":"result","subtype":"error_during_execution","is_error":true,"result":"","session_id":"s1"}`)
	require.Equal(t, []string{EventUsage, EventError}, types(evs))
}

func TestClaudeTranslator_ErrorResultIsClassified(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t9"))
	evs := feedAll(t, tr, `{"type":"result","subtype":"success","is_error":true,"result":"API Error: 429 rate_limit_error","session_id":"s1"}`)
	require.Equal(t, []string{EventUsage, EventError}, types(evs))
	assert.Equal(t, "t9", evs[1].TurnID, "a turn error carries its turn id, so it is terminal")
	assert.Equal(t, CodeRateLimit, evs[1].Code)
	assert.True(t, evs[1].Retryable)
}

func TestClaudeTranslator_SubagentEventsIgnored(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	evs := feedAll(t, tr,
		`{"type":"stream_event","parent_tool_use_id":"toolu_parent","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"inner"}}}`)
	assert.Empty(t, evs)
}

func TestClaudeTranslator_BadLineIsAnError(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	_, err := tr.Feed([]byte(`not json`))
	assert.Error(t, err)
	evs, err := tr.Feed([]byte("   "))
	assert.NoError(t, err)
	assert.Empty(t, evs)
}

func TestClassifyClaudeError(t *testing.T) {
	cases := []struct {
		msg       string
		code      string
		retryable bool
	}{
		{"No conversation found with session ID: 0000", CodeSessionLost, false},
		{"Invalid API key · Please run /login", CodeAuth, false},
		{"API Error: 401 authentication_error", CodeAuth, false},
		{"API Error: 429 rate_limit_error", CodeRateLimit, true},
		{"Claude AI usage limit reached|1760000000", CodeRateLimit, true},
		{"API Error: 529 overloaded_error", CodeRateLimit, true},
		{`exec: "claude": executable file not found in $PATH`, CodeProviderUnavailable, true},
		{"issue PROJ-4291 is blocked", CodeInternal, true},
		{"something odd", CodeInternal, true},
	}
	for _, c := range cases {
		code, retry := ClassifyClaudeError(c.msg)
		assert.Equal(t, c.code, code, c.msg)
		assert.Equal(t, c.retryable, retry, c.msg)
	}
}

// readFixture returns the non-empty lines of a recorded fixture.
func readFixture(t *testing.T, name string) []string {
	t.Helper()
	f, err := os.Open(filepath.Join("testdata", name))
	require.NoError(t, err, "record fixtures with testdata/record_fixtures.sh")
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64<<10), 16<<20)
	var out []string
	for sc.Scan() {
		if strings.TrimSpace(sc.Text()) != "" {
			out = append(out, sc.Text())
		}
	}
	require.NoError(t, sc.Err())
	return out
}

func TestClaudeTranslator_RecordedFixtures(t *testing.T) {
	t.Run("text", func(t *testing.T) {
		evs := feedAll(t, NewClaudeTranslator(fixedTurn("t1")), readFixture(t, "claude_text.jsonl")...)
		require.NotEmpty(t, evs)
		assert.Contains(t, types(evs), EventTextDelta)
		assert.NotContains(t, types(evs), EventError)
		last := evs[len(evs)-1]
		assert.Equal(t, EventTurnDone, last.Type)
		assert.Equal(t, StatusComplete, last.Status)
		assert.NotEmpty(t, last.SessionID)
	})
	t.Run("thinking", func(t *testing.T) {
		evs := feedAll(t, NewClaudeTranslator(fixedTurn("t1")), readFixture(t, "claude_thinking.jsonl")...)
		var text strings.Builder
		for _, e := range evs {
			if e.Type == EventTextDelta {
				text.WriteString(e.Text)
			}
		}
		assert.Contains(t, text.String(), "391", "the answer streams; the thinking does not")
		assert.Equal(t, EventTurnDone, evs[len(evs)-1].Type)
	})
	t.Run("tool", func(t *testing.T) {
		evs := feedAll(t, NewClaudeTranslator(fixedTurn("t1")), readFixture(t, "claude_tool.jsonl")...)
		var start, end *Event
		for i := range evs {
			switch evs[i].Type {
			case EventToolStart:
				start = &evs[i]
			case EventToolEnd:
				end = &evs[i]
			}
		}
		require.NotNil(t, start, "a tool_start was translated")
		require.NotNil(t, end, "a tool_end was translated")
		assert.Equal(t, "list_targets", start.Name)
		assert.Equal(t, start.ID, end.ID)
		require.NotNil(t, end.OK)
		assert.True(t, *end.OK)
		assert.Equal(t, StatusComplete, evs[len(evs)-1].Status)
		var text strings.Builder
		for _, e := range evs {
			if e.Type == EventTextDelta {
				text.WriteString(e.Text)
			}
		}
		assert.Contains(t, text.String(), "then call it.\n\nThe `list_targets`",
			"the recorded pre-tool and post-tool messages are separated by a paragraph break")
		assert.False(t, strings.HasPrefix(text.String(), "\n"), "the turn's first text gets no separator")
	})
	t.Run("interrupt then second turn", func(t *testing.T) {
		turn := "t1"
		tr := NewClaudeTranslator(func() string { return turn })
		var dones []Event
		for _, l := range readFixture(t, "claude_interrupt.jsonl") {
			if strings.Contains(l, `"control_response"`) {
				tr.MarkInterrupted() // the backend marks it when it sends the request
			}
			evs, err := tr.Feed([]byte(l))
			require.NoError(t, err)
			for _, e := range evs {
				if e.Type == EventTurnDone {
					dones = append(dones, e)
					turn = "t2"
				}
			}
		}
		require.Len(t, dones, 2)
		assert.Equal(t, StatusInterrupted, dones[0].Status)
		assert.Equal(t, "t1", dones[0].TurnID)
		assert.Equal(t, StatusComplete, dones[1].Status)
		assert.Equal(t, "t2", dones[1].TurnID)
	})
	t.Run("resume missing is session_lost", func(t *testing.T) {
		stderr, err := os.ReadFile(filepath.Join("testdata", "claude_resume_missing.stderr"))
		require.NoError(t, err)
		lost := false
		if code, _ := ClassifyClaudeError(string(stderr)); code == CodeSessionLost {
			lost = true
		}
		stdout, err := os.ReadFile(filepath.Join("testdata", "claude_resume_missing.jsonl"))
		require.NoError(t, err)
		tr := NewClaudeTranslator(fixedTurn("t1"))
		for _, l := range strings.Split(string(stdout), "\n") {
			evs, err := tr.Feed([]byte(l))
			if err != nil {
				continue
			}
			for _, e := range evs {
				if e.Type == EventError && e.Code == CodeSessionLost {
					lost = true
				}
			}
		}
		assert.True(t, lost, "the recorded rejection must classify as session_lost — adjust ClassifyClaudeError's phrases to the recorded text")
	})
}

// Claude's own ToolSearch (it loads deferred MCP tools) is plumbing, not a
// step: the recorded tool run yields exactly the one watchtower tool pair.
func TestClaudeTranslator_InternalToolsAreNotSteps(t *testing.T) {
	evs := feedAll(t, NewClaudeTranslator(fixedTurn("t1")), readFixture(t, "claude_tool.jsonl")...)
	var names []string
	ends := 0
	for _, e := range evs {
		switch e.Type {
		case EventToolStart:
			names = append(names, e.Name)
		case EventToolEnd:
			ends++
		}
	}
	assert.Equal(t, []string{"list_targets"}, names)
	assert.Equal(t, 1, ends, "ToolSearch's tool_result is dropped too")
}

// A rejected --resume reports its reason only in the result's "errors" array
// (recorded fixture): the turn error must say so, classified session_lost.
func TestClaudeTranslator_ResultErrorsArrayIsTheMessage(t *testing.T) {
	var got []Event
	for _, l := range readFixture(t, "claude_resume_missing.jsonl") {
		evs, err := NewClaudeTranslator(fixedTurn("t1")).Feed([]byte(l))
		require.NoError(t, err)
		got = append(got, evs...)
	}
	require.NotEmpty(t, got)
	last := got[len(got)-1]
	assert.Equal(t, EventError, last.Type)
	assert.Equal(t, CodeSessionLost, last.Code)
	assert.Contains(t, last.Message, "No conversation found")
}
