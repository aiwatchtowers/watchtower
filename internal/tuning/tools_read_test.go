package tuning

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/coach"
	"watchtower/internal/db"
	"watchtower/internal/llmusage"
	"watchtower/internal/prompts"
	"watchtower/internal/tools"
)

var testNow = time.Date(2026, 11, 10, 12, 0, 0, 0, time.UTC)

// reportCall is one recorded Deps.AgentReport call.
type reportCall struct {
	wb    int64
	days  int
	agent string
}

type fixture struct {
	d       *db.DB
	reg     *tools.Registry
	wb      int64
	home    string
	reports []reportCall
	report  any // what the fake AgentReport returns
	deps    Deps
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "w.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	wb, err := d.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	f := &fixture{d: d, reg: tools.New(d), wb: wb, home: t.TempDir(), report: map[string]any{"sessions": []any{}}}
	deps := Deps{
		Store: func(d *db.DB) *prompts.Store { return prompts.New(d, nil) },
		AgentReport: func(_ context.Context, wb int64, days int, agent string) (any, error) {
			f.reports = append(f.reports, reportCall{wb, days, agent})
			return f.report, nil
		},
		AgentSession: func(_ context.Context, _ int64, uuid string) (any, error) {
			if uuid != "s-1" {
				return nil, fmt.Errorf("session %s: %w", uuid, ErrNotFound)
			}
			return map[string]any{"session": map[string]any{"uuid": uuid}}, nil
		},
		LLMUsage: func(_ context.Context, period string) (any, error) {
			return map[string]any{"period": period}, nil
		},
		Now:      func() time.Time { return testNow },
		CoachEnv: func() coach.Env { return coach.Env{Home: f.home, RepoState: gitRepoState} },
	}
	for _, tl := range ReadTools(deps) {
		require.NoError(t, f.reg.Register(tl))
	}
	f.deps = deps
	return f
}

func (f *fixture) binding(contextID string) tools.Binding {
	return tools.Binding{Surface: tools.SurfaceTuning, ConversationID: 1, ContextType: ContextType, ContextID: contextID, DirectApply: true}
}

// call runs a read tool on the panel's workbench and returns its JSON.
func (f *fixture) call(t *testing.T, name, args string) (map[string]any, error) {
	t.Helper()
	res, err := f.reg.CallRead(context.Background(), name, json.RawMessage(args), f.binding(fmt.Sprint(f.wb)))
	if err != nil {
		return nil, err
	}
	raw, err := json.Marshal(res)
	require.NoError(t, err)
	var out map[string]any
	if json.Unmarshal(raw, &out) != nil {
		out = map[string]any{"list": json.RawMessage(raw)}
	}
	return out, nil
}

func TestReadTools_SurfaceAndMarks(t *testing.T) {
	ts := ReadTools(Deps{})
	var names []string
	for _, tl := range ts {
		names = append(names, tl.Name)
		assert.Equal(t, []string{tools.SurfaceTuning}, tl.Surfaces, tl.Name)
		assert.Equal(t, tools.AccessRead, tl.Access, tl.Name)
		assert.True(t, tl.CompanyData, tl.Name)
	}
	assert.Equal(t, []string{"get_agent_report", "list_agent_sessions", "get_agent_session",
		"get_llm_usage", "list_prompts", "get_prompt",
		"list_skills", "get_skill", "get_agent_instructions", "list_coach_proposals"}, names)
	assert.Nil(t, tools.UndecidedReadTools(ts))
}

func TestGetAgentReport_Args(t *testing.T) {
	cases := []struct {
		name, args string
		wantErr    string
		want       *reportCall
	}{
		{"negative days", `{"days":-1}`, "days must not be negative", nil},
		{"whole retention", `{"days":0}`, "", &reportCall{days: 0}},
		{"clamped", `{"days":400}`, "", &reportCall{days: 90}},
		{"bad agent", `{"days":7,"agent":"gpt"}`, `invalid agent "gpt"`, nil},
		{"codex", `{"days":7,"agent":"codex"}`, "", &reportCall{days: 7, agent: "codex"}},
		{"missing workbench", `{"days":7,"workbench_id":99}`, "workbench 99 not found", nil},
	}
	for _, tool := range []string{"get_agent_report", "list_agent_sessions"} {
		for _, c := range cases {
			t.Run(tool+"/"+c.name, func(t *testing.T) {
				f := newFixture(t)
				_, err := f.call(t, tool, c.args)
				if c.wantErr != "" {
					require.Error(t, err)
					var ve *tools.ValidationError
					require.ErrorAs(t, err, &ve)
					assert.Contains(t, err.Error(), c.wantErr)
					assert.Empty(t, f.reports, "the report is never read")
					return
				}
				require.NoError(t, err)
				c.want.wb = f.wb // absent workbench_id → the binding's context id
				assert.Equal(t, []reportCall{*c.want}, f.reports)
			})
		}
	}
}

func TestGetAgentReport_WorkbenchFromContext(t *testing.T) {
	f := newFixture(t)
	other, err := f.d.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	_, err = f.reg.CallRead(context.Background(), "get_agent_report", json.RawMessage(`{"days":7}`), f.binding(fmt.Sprint(other)))
	require.NoError(t, err)
	_, err = f.call(t, "get_agent_report", fmt.Sprintf(`{"days":7,"workbench_id":%d}`, f.wb))
	require.NoError(t, err)
	assert.Equal(t, []int64{other, f.wb}, []int64{f.reports[0].wb, f.reports[1].wb})

	_, err = f.reg.CallRead(context.Background(), "get_agent_report", json.RawMessage(`{"days":7}`),
		tools.Binding{Surface: tools.SurfaceTuning, ConversationID: 1})
	require.ErrorContains(t, err, "workbench_id is required")

	_, err = f.reg.CallRead(context.Background(), "get_agent_report", json.RawMessage(`{"days":7}`), f.binding("x"))
	var ve *tools.ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, err.Error(), `"x" is not a workbench id`)
	assert.Len(t, f.reports, 2, "the report is never read")
}

func TestGetAgentReport_EmptyPeriodAndOneAgent(t *testing.T) {
	f := newFixture(t)
	f.report = map[string]any{"agent": "claude", "agents": []string{}, "sessions": []any{}, "totals": map[string]any{"sessions": 0}}
	got, err := f.call(t, "get_agent_report", `{"days":1,"agent":"claude"}`)
	require.NoError(t, err)
	assert.Equal(t, map[string]any{"agent": "claude", "agents": []any{}, "sessions": []any{},
		"totals": map[string]any{"sessions": float64(0)}}, got)
}

func TestGetAgentReport_CodexWithNoData(t *testing.T) {
	f := newFixture(t)
	f.report = map[string]any{"agent": "codex", "sessions": []any{}, "models": []any{}, "hints": []any{}}
	_, err := f.call(t, "get_agent_report", `{"days":30,"agent":"codex"}`)
	require.NoError(t, err)
}

func TestListAgentSessions_KeepsTheSessionList(t *testing.T) {
	f := newFixture(t)
	f.report = map[string]any{"since": "2026-11-03", "agent": "all", "sessions": []any{map[string]any{"uuid": "s-1"}},
		"hints": []any{"h"}, "totals": map[string]any{}, "enabled": true, "import": map[string]any{"state": "done"}}
	got, err := f.call(t, "list_agent_sessions", `{"days":7}`)
	require.NoError(t, err)
	assert.Equal(t, map[string]any{"since": "2026-11-03", "agent": "all",
		"sessions": []any{map[string]any{"uuid": "s-1"}}, "enabled": true, "import": map[string]any{"state": "done"}}, got)

	// Analytics off: the empty list says why.
	f.report = map[string]any{"sessions": []any{}, "enabled": false}
	got, err = f.call(t, "list_agent_sessions", `{"days":7}`)
	require.NoError(t, err)
	assert.Equal(t, false, got["enabled"])
}

func TestGetAgentSession(t *testing.T) {
	f := newFixture(t)
	got, err := f.call(t, "get_agent_session", `{"session":"s-1"}`)
	require.NoError(t, err)
	assert.Equal(t, map[string]any{"uuid": "s-1"}, got["session"])

	_, err = f.call(t, "get_agent_session", `{"session":"nope"}`)
	var ve *tools.ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Equal(t, "session nope not found", err.Error())

	_, err = f.call(t, "get_agent_session", `{"session":"s-1","workbench_id":99}`)
	require.ErrorContains(t, err, "workbench 99 not found")
}

func TestGetLLMUsage_Period(t *testing.T) {
	f := newFixture(t)
	got, err := f.call(t, "get_llm_usage", `{"period":"7d"}`)
	require.NoError(t, err)
	assert.Equal(t, "7d", got["period"])

	_, err = f.call(t, "get_llm_usage", `{"period":"week"}`)
	var ve *tools.ValidationError
	require.ErrorAs(t, err, &ve)
}

func TestListPrompts_Shape(t *testing.T) {
	f := newFixture(t)
	_, err := f.d.AddPromptAddition(prompts.DigestChannel, "x", 0, testNow)
	require.NoError(t, err)
	_, err = f.d.AddPromptAddition(prompts.BriefingDaily, "never reaches it", 0, testNow)
	require.NoError(t, err)
	store := prompts.New(f.d, nil)
	require.NoError(t, store.Seed())
	require.NoError(t, store.Update(prompts.DigestDaily, "tuned", "manual edit"))
	cost := 0.25
	require.NoError(t, f.d.InsertLLMCalls([]llmusage.Call{{
		CallID: "c1", At: testNow.Add(-24 * time.Hour).Format(time.RFC3339), Surface: "watchtower",
		Purpose: prompts.DigestChannel, Process: "daemon", Provider: "claude", Model: "m", OK: true,
		Tokens: llmusage.Tokens{Input: 10, Output: 5, ReportedCostUSD: &cost},
	}}))

	res, err := f.reg.CallRead(context.Background(), "list_prompts", nil, f.binding(fmt.Sprint(f.wb)))
	require.NoError(t, err)
	rows, ok := res.([]promptRow)
	require.True(t, ok)
	require.Len(t, rows, len(prompts.AllIDs))
	by := map[string]promptRow{}
	for _, r := range rows {
		by[r.ID] = r
	}
	dc := by[prompts.DigestChannel]
	assert.Equal(t, []string{"x"}, dc.Additions)
	assert.InDelta(t, 0.25, dc.Spend30dUSD, 1e-9)
	assert.True(t, dc.TakesAdditions)
	assert.Equal(t, prompts.Descriptions[prompts.DigestChannel], dc.Description)
	assert.False(t, by[prompts.BriefingDaily].TakesAdditions)
	assert.Equal(t, []string{}, by[prompts.BriefingDaily].Additions, "a prompt that takes no additions shows none")
	assert.Equal(t, prompts.DefaultVersions[prompts.DigestChannel], dc.Version)
	assert.Equal(t, prompts.DefaultVersions[prompts.DigestDaily]+1, by[prompts.DigestDaily].Version)
}

func TestGetPrompt(t *testing.T) {
	f := newFixture(t)
	_, err := f.d.AddPromptAddition(prompts.DigestChannel, "x", 0, testNow)
	require.NoError(t, err)
	got, err := f.call(t, "get_prompt", `{"prompt_id":"`+prompts.DigestChannel+`"}`)
	require.NoError(t, err)
	assert.Equal(t, prompts.Defaults[prompts.DigestChannel], got["template"], "the template comes without additions")
	assert.Equal(t, []any{"x"}, got["additions"])
	assert.Equal(t, []any{}, got["history"])
	assert.Equal(t, float64(0), got["version"])

	store := prompts.New(f.d, nil)
	require.NoError(t, store.Seed())
	require.NoError(t, store.Update(prompts.DigestChannel, "tuned text", "manual edit"))
	got, err = f.call(t, "get_prompt", `{"prompt_id":"`+prompts.DigestChannel+`"}`)
	require.NoError(t, err)
	assert.Equal(t, "tuned text", got["template"])
	assert.Equal(t, float64(prompts.DefaultVersions[prompts.DigestChannel]+1), got["version"])
	hist, ok := got["history"].([]any)
	require.True(t, ok)
	require.NotEmpty(t, hist)
	assert.Contains(t, fmt.Sprint(hist), "manual edit")
}

func TestGetPrompt_NotFound(t *testing.T) {
	f := newFixture(t)
	_, err := f.call(t, "get_prompt", `{"prompt_id":"nope"}`)
	var ve *tools.ValidationError
	require.True(t, errors.As(err, &ve))
	assert.Equal(t, "prompt nope not found", err.Error())
}
