package tuning

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentreport"
	"watchtower/internal/tools"
)

func rowsOf(n int, prefix string) []any {
	out := make([]any, n)
	for i := range out {
		out[i] = map[string]any{"id": fmt.Sprintf("%s%d", prefix, i)}
	}
	return out
}

func TestGetAgentReport_Sections(t *testing.T) {
	f := newFixture(t)
	f.report = map[string]any{"since": "2026-11-03", "agent": "all", "enabled": true,
		"time": map[string]any{"model_ms": 1}, "skills": map[string]any{"used": 14, "listed": 63},
		"commands": rowsOf(3, "c"), "sessions": rowsOf(2, "s")}
	got, err := f.call(t, "get_agent_report", `{"days":7,"sections":["time","skills"]}`)
	require.NoError(t, err)
	assert.Equal(t, map[string]any{"since": "2026-11-03", "agent": "all", "enabled": true,
		"time":   map[string]any{"model_ms": float64(1)},
		"skills": map[string]any{"used": float64(14), "listed": float64(63)}}, got)

	_, err = f.call(t, "get_agent_report", `{"days":7,"sections":["lanes"]}`)
	var ve *tools.ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Equal(t, `unknown section "lanes": one of commands, sessions, skills, time`, err.Error())
}

func TestGetAgentReport_LimitCutsListsAndCountsTheRest(t *testing.T) {
	f := newFixture(t)
	f.report = map[string]any{"commands": rowsOf(60, "c"), "tasks": rowsOf(10, "t"), "tasks_more": 5,
		"sessions": rowsOf(3, "s")}
	got, err := f.call(t, "get_agent_report", `{"days":7}`)
	require.NoError(t, err)
	assert.Len(t, got["commands"], 50, "default limit")
	assert.Equal(t, "c0", got["commands"].([]any)[0].(map[string]any)["id"], "the first rows stay")
	assert.Equal(t, float64(10), got["commands_more"])
	assert.Len(t, got["tasks"], 10)
	assert.Equal(t, float64(5), got["tasks_more"], "the report's own count passes")
	assert.Equal(t, []any{map[string]any{"id": "s2"}, map[string]any{"id": "s1"}, map[string]any{"id": "s0"}},
		got["sessions"], "sessions newest first")

	got, err = f.call(t, "get_agent_report", `{"days":7,"limit":4}`)
	require.NoError(t, err)
	assert.Len(t, got["tasks"], 4)
	assert.Equal(t, float64(11), got["tasks_more"], "cut rows add to the report's count")

	got, err = f.call(t, "get_agent_report", `{"days":7,"limit":1000}`)
	require.NoError(t, err)
	assert.Len(t, got["commands"], 60, "clamped to 200, which keeps all 60")
}

func TestListAgentSessions_NewestFirstWithLimit(t *testing.T) {
	f := newFixture(t)
	f.report = map[string]any{"agent": "all", "sessions": rowsOf(5, "s"), "commands": rowsOf(5, "c")}
	got, err := f.call(t, "list_agent_sessions", `{"days":7,"limit":2}`)
	require.NoError(t, err)
	assert.Equal(t, map[string]any{"agent": "all",
		"sessions":      []any{map[string]any{"id": "s4"}, map[string]any{"id": "s3"}},
		"sessions_more": float64(3)}, got)
}

func TestGetAgentReport_TooLargeNamesSectionSizes(t *testing.T) {
	f := newFixture(t)
	big := strings.Repeat("x", 300)
	rows := make([]any, 200)
	for i := range rows {
		rows[i] = map[string]any{"verb": big}
	}
	f.report = map[string]any{"commands": rows, "time": map[string]any{"model_ms": 1}}
	_, err := f.call(t, "get_agent_report", `{"days":7,"limit":200}`)
	var ve *tools.ValidationError
	require.ErrorAs(t, err, &ve)
	require.ErrorIs(t, err, tools.ErrResultTooLarge)
	assert.Contains(t, err.Error(), "ask for fewer sections")
	assert.Regexp(t, `bytes per section: commands \d+, time 23$`, err.Error(), "indented sizes, as the MCP server sends them")

	got, err := f.call(t, "get_agent_report", `{"days":7,"sections":["time"]}`)
	require.NoError(t, err, "a narrower ask fits")
	assert.NotNil(t, got["time"])
}

func TestGetAgentSession_LanesFoldIntoTotals(t *testing.T) {
	f := newFixture(t)
	seg := func(start, end, cat, class string) map[string]any {
		return map[string]any{"start": start, "end": end, "category": cat, "tool_class": class, "verb": "go test"}
	}
	f.deps.AgentSession = func(context.Context, int64, string) (any, error) {
		return map[string]any{
			"session": map[string]any{"uuid": "s-1"},
			"time":    map[string]any{"model_ms": 3000},
			"lanes": []any{
				map[string]any{"agent_id": "", "subagent_type": "", "background": false, "segments": []any{
					seg("2026-11-16T07:00:00.000Z", "2026-11-16T07:00:02.000Z", "model", ""),
					seg("2026-11-16T07:00:02.000Z", "2026-11-16T07:00:07.500Z", "tool", "build_test"),
					seg("2026-11-16T07:00:07.500Z", "2026-11-16T07:00:08.500Z", "model", ""),
					seg("bad", "2026-11-16T07:00:09.000Z", "tool", "git"),
				}},
				map[string]any{"agent_id": "a1", "subagent_type": "Explore", "background": true, "segments": []any{}},
			},
			"commands": rowsOf(2, "c"),
		}, nil
	}
	reg := tools.New(f.d)
	for _, tl := range ReadTools(f.deps) {
		require.NoError(t, reg.Register(tl))
	}
	res, err := reg.CallRead(context.Background(), "get_agent_session", json.RawMessage(`{"session":"s-1"}`), f.binding(fmt.Sprint(f.wb)))
	require.NoError(t, err)
	raw, err := json.Marshal(res)
	require.NoError(t, err)
	var got map[string]any
	require.NoError(t, json.Unmarshal(raw, &got))
	assert.Equal(t, []any{
		map[string]any{"agent_id": "", "background": false, "segments": float64(4),
			"start": "2026-11-16T07:00:00.000Z", "end": "2026-11-16T07:00:09.000Z",
			"ms_by_category":   map[string]any{"model": float64(3000), "tool": float64(5500)},
			"ms_by_tool_class": map[string]any{"build_test": float64(5500), "git": float64(0)}},
		map[string]any{"agent_id": "a1", "subagent_type": "Explore", "background": true, "segments": float64(0),
			"ms_by_category": map[string]any{}},
	}, got["lanes"])
	assert.Len(t, got["commands"], 2)

	res, err = reg.CallRead(context.Background(), "get_agent_session", json.RawMessage(`{"session":"s-1","sections":["time"]}`), f.binding(fmt.Sprint(f.wb)))
	require.NoError(t, err)
	raw, err = json.Marshal(res)
	require.NoError(t, err)
	assert.JSONEq(t, `{"session":{"uuid":"s-1"},"time":{"model_ms":3000}}`, string(raw))
}

func TestGetAgentReport_LimitCutsListsInsideObjectSections(t *testing.T) {
	f := newFixture(t)
	f.report = map[string]any{"skills": map[string]any{"used": 14, "rows": rowsOf(3, "r"), "never_used": rowsOf(60, "n")}}
	got, err := f.call(t, "get_agent_report", `{"days":7,"sections":["skills"],"limit":2}`)
	require.NoError(t, err)
	assert.Equal(t, map[string]any{"used": float64(14),
		"rows": []any{map[string]any{"id": "r0"}, map[string]any{"id": "r1"}}, "rows_more": float64(1),
		"never_used": []any{map[string]any{"id": "n0"}, map[string]any{"id": "n1"}}, "never_used_more": float64(58)},
		got["skills"])
	assert.NotContains(t, got, "skills_more")
}

// The size check measures the indented JSON the MCP server sends: a result
// that fits only when compact is refused.
func TestGetAgentReport_SizeIsTheIndentedEncoding(t *testing.T) {
	rows := make([]any, 200)
	for i := range rows {
		rows[i] = map[string]any{"a": 1, "b": 2, "c": 3, "d": 4, "e": 5, "f": 6, "g": 7, "h": 8, "i": 9, "j": 10, "k": 11, "l": 12, "m": 13, "n": 14, "o": 15, "p": 16, "q": 17}
	}
	compact, err := json.Marshal(map[string]any{"commands": rows})
	require.NoError(t, err)
	indented, err := json.MarshalIndent(map[string]any{"commands": rows}, "", "  ")
	require.NoError(t, err)
	require.Less(t, len(compact), maxReportBytes)
	require.Greater(t, len(indented), maxReportBytes)

	f := newFixture(t)
	f.report = map[string]any{"commands": rows}
	_, err = f.call(t, "get_agent_report", `{"days":7,"limit":200}`)
	require.ErrorIs(t, err, tools.ErrResultTooLarge)
}

// The shaping keys on the real agents report JSON (sessions, tasks_more,
// lanes, segments, the meta keys): a rename in internal/agentreport breaks
// this test, not the chat silently. A long session's timeline fits once
// folded.
func TestReportShaping_RealReportTypes(t *testing.T) {
	f := newFixture(t)
	ov := &agentreport.Overview{WorkbenchID: f.wb, Since: "2026-11-03", Until: "2026-11-10", Agent: "all",
		Enabled: true, Tasks: make([]agentreport.TaskRow, 60), TasksMore: 7}
	for i := range 3 {
		ov.Sessions = append(ov.Sessions, agentreport.SessionRow{UUID: fmt.Sprintf("s-%d", i)})
	}
	f.report = ov
	got, err := f.call(t, "get_agent_report", `{"days":7,"sections":["sessions","tasks"]}`)
	require.NoError(t, err)
	assert.Equal(t, "2026-11-03", got["since"])
	assert.Equal(t, true, got["enabled"])
	assert.Equal(t, "s-2", got["sessions"].([]any)[0].(map[string]any)["session_uuid"], "newest first")
	assert.Len(t, got["tasks"], 50)
	assert.Equal(t, float64(17), got["tasks_more"])

	segs := make([]agentreport.Segment, 3000)
	for i := range segs {
		segs[i] = agentreport.Segment{Start: "2026-11-16T07:00:00.000Z", End: "2026-11-16T07:00:01.000Z",
			Category: "tool", ToolClass: "build_test", Verb: "go test ./internal/some/long/package/path"}
	}
	det := &agentreport.SessionDetail{Session: agentreport.SessionRow{UUID: "s-1"},
		Lanes: []agentreport.Lane{{Segments: segs}}}
	f.deps.AgentSession = func(context.Context, int64, string) (any, error) { return det, nil }
	reg := tools.New(f.d)
	for _, tl := range ReadTools(f.deps) {
		require.NoError(t, reg.Register(tl))
	}
	res, err := reg.CallRead(context.Background(), "get_agent_session", json.RawMessage(`{"session":"s-1"}`), f.binding(fmt.Sprint(f.wb)))
	require.NoError(t, err, "3000 segments fold into one lane's totals")
	raw, err := json.Marshal(res)
	require.NoError(t, err)
	var out map[string]any
	require.NoError(t, json.Unmarshal(raw, &out))
	lane := out["lanes"].([]any)[0].(map[string]any)
	assert.Equal(t, float64(3000), lane["segments"])
	assert.Equal(t, map[string]any{"tool": float64(3_000_000)}, lane["ms_by_category"])
}
