package agentreport

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlog"
	"watchtower/internal/agentlogdb"
)

const cxSession = "00000000-0000-0000-0000-00000000c0d1"

// cxRollout is a hand-made codex rollout ("synthetic": true on every line):
// a brief, an owner prompt, two model responses around a `go test` call that
// fails, then a second owner prompt after a long wait and a last response.
func cxRollout(t *testing.T) string {
	t.Helper()
	at := func(s int) string { return t0.Add(time.Duration(s) * time.Second).Format("2006-01-02T15:04:05.000Z") }
	var b strings.Builder
	put := func(s int, typ string, payload map[string]any) {
		raw, err := json.Marshal(map[string]any{"timestamp": at(s), "type": typ, "payload": payload, "synthetic": true})
		require.NoError(t, err)
		b.Write(raw)
		b.WriteByte('\n')
	}
	user := func(s int, id, text string) {
		put(s, "event_msg", map[string]any{"type": "item_completed",
			"item": map[string]any{"type": "UserMessage", "id": id, "content": []any{map[string]any{"type": "text", "text": text}}}})
	}
	tokens := func(s int, out, total int64) {
		u := map[string]any{"input_tokens": 1000, "cached_input_tokens": 400, "output_tokens": out, "total_tokens": 1000 + out}
		put(s, "event_msg", map[string]any{"type": "token_count",
			"info": map[string]any{"last_token_usage": u, "total_token_usage": map[string]any{"total_tokens": total}}})
	}
	put(0, "session_meta", map[string]any{"id": cxSession, "timestamp": at(0), "cwd": "/work"})
	put(0, "turn_context", map[string]any{"model": "gpt-test"})
	user(1, "u0", "Watchtower workbench #1 brief: start")
	user(2, "u1", "run the tests")
	put(10, "response_item", map[string]any{"type": "function_call", "name": "exec_command",
		"arguments": `{"cmd":"go test ./..."}`, "call_id": "c1"})
	tokens(10, 50, 1050)
	put(70, "response_item", map[string]any{"type": "function_call_output", "call_id": "c1", "output": "Process exited with code 1"})
	tokens(80, 30, 2080)
	user(400, "u2", "fix it")
	tokens(420, 20, 3100)
	return b.String()
}

// storeCodex parses the rollout and stores it as workbench wb's codex session.
func storeCodex(t *testing.T, d testDBs, wb int64) {
	t.Helper()
	path := "/work/rollout-" + cxSession + ".jsonl"
	pr, err := agentlog.ParseCodex(strings.NewReader(cxRollout(t)), 0, agentlog.ParseOptions{Path: path, Folder: "/work", SessionUUID: cxSession})
	require.NoError(t, err)
	var sessions []agentlogdb.AgentLogSession
	for _, s := range pr.Sessions {
		s.ProjectID, s.FolderPath = &wb, "/work"
		sessions = append(sessions, *s)
	}
	_, err = d.al.ApplyAgentLogBatch(agentlogdb.AgentLogBatch{
		File:     agentlogdb.AgentLogFile{Path: path, Agent: agentlog.AgentCodex, ReadOffset: pr.Consumed, ParserVersion: agentlog.ParserVersion},
		Sessions: sessions, Events: pr.Events, ToolResults: pr.ToolResults, ExpectOffset: -1,
	})
	require.NoError(t, err)
}

func TestAgentlog06_CodexTimeAddsUp(t *testing.T) {
	d, wb := buildDB(t)
	storeCodex(t, d, wb)
	evs, err := d.al.AgentReportEvents([]string{cxSession})
	require.NoError(t, err)
	ts, _ := SessionTime(evs)
	tl := ts.Tools
	sum := ts.ModelMS + tl.BuildTest + tl.Git + tl.ReadSearch + tl.Edit + tl.MCP + tl.SubagentsFG + tl.Other +
		ts.BackgroundMS + ts.OwnerMS + ts.AwayMS
	assert.Equal(t, int64(419_000), ts.WallMS, "first to last main-agent event: the brief to the last response")
	assert.Equal(t, ts.WallMS, sum, "%+v", ts)
	assert.Equal(t, ts.WallMS-ts.AwayMS, ts.ActiveMS)
	assert.Equal(t, int64(60_000), tl.BuildTest, "the go test call, from its call to its output")
	assert.Positive(t, ts.OwnerMS, "the wait before the owner's second prompt")
}

func TestReport_CodexSessionsIncludedAndUnpriced(t *testing.T) {
	d, wb := buildDB(t)
	require.NoError(t, d.SetWorkbenchAgentAnalytics(wb, true))
	putSession(t, d, wb, "claude-1", 8, 4)
	storeCodex(t, d, wb)
	ov, err := BuildOverview(d.DB, d.al, wb, time.Time{}, t0.Add(time.Hour), English, AgentAll)
	require.NoError(t, err)
	require.Len(t, ov.Sessions, 2)
	rows := map[string]SessionRow{}
	for _, r := range ov.Sessions {
		rows[r.UUID] = r
	}
	cx, cl := rows[cxSession], rows["claude-1"]
	assert.Equal(t, "codex", cx.Agent)
	assert.Equal(t, "claude", cl.Agent)
	assert.Equal(t, 3, cx.CostEstimatedCalls, "a codex model without a price shows tokens and no price")
	assert.Zero(t, cx.CostUSD)
	assert.Zero(t, cl.CostEstimatedCalls)
	assert.Positive(t, cx.ActiveMS, "codex sessions have a time model")
	assert.Equal(t, int64(2*10+3*600), ov.Totals.Tokens.Input, "both agents' tokens are in the totals")
	assert.Equal(t, 3, ov.Totals.CostEstimatedCalls)
	assert.Equal(t, 2, ov.Totals.Sessions)
	assert.Equal(t, 1, ov.Context.FactsSessions, "a rollout has no context parts: not measured for codex")
	assert.Equal(t, 1, ov.Skills.FactsSessions, "a rollout has no skill listing: not measured for codex")
	assert.Equal(t, 2, ov.Trouble.FactsSessions, "interrupts and failed calls are measured for codex too")
}
