package tuning

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

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
	assert.Regexp(t, `bytes per section: commands \d+, time 14$`, err.Error())

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
