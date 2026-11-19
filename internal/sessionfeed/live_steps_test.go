package sessionfeed

import (
	"encoding/json"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const ownerLine = `{"type":"user","timestamp":"2026-11-02T12:00:00Z","message":{"content":"question"}}`
const endTurnLine = `{"type":"assistant","message":{"content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}`

func stepIDs(steps []LiveAction) []string {
	ids := []string{}
	for _, s := range steps {
		ids = append(ids, s.ID)
	}
	return ids
}

func TestLiveStepsCurrentTurnInOrderWithOpenLast(t *testing.T) {
	c := liveFile(t, false, ownerLine,
		assistantRec("a1", "m1", toolUse("t1", "Read", map[string]any{"file_path": "a.go"})), userBlocks("u1", toolResult("t1")),
		assistantRec("a2", "m2", toolUse("t2", "Grep", map[string]any{"pattern": "x"})), userBlocks("u2", toolResult("t2")),
		assistantRec("a3", "m3", toolUse("t3", "Bash", map[string]any{"command": "go test"})))
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	require.Len(t, live.Steps, 3)
	assert.Equal(t, []string{"t1", "t2", "t3"}, stepIDs(live.Steps))
	assert.False(t, live.Steps[0].CompletedAt.IsZero())
	assert.False(t, live.Steps[1].CompletedAt.IsZero())
	assert.True(t, live.Steps[2].CompletedAt.IsZero(), "the open step is last and not completed")
	assert.Equal(t, 0, live.StepsMore)
}

func TestLiveStepsResetOnNewTurn(t *testing.T) {
	c := liveFile(t, false, ownerLine,
		assistantRec("a1", "m1", toolUse("t1", "Read", map[string]any{"file_path": "a.go"})), userBlocks("u1", toolResult("t1")),
		ownerLine,
		assistantRec("a2", "m2", toolUse("t2", "Grep", map[string]any{"pattern": "x"})))
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	assert.Equal(t, []string{"t2"}, stepIDs(live.Steps))
}

func TestLiveStepsCapAt40CountsTheCut(t *testing.T) {
	lines := []string{ownerLine}
	for i := 1; i <= 45; i++ {
		id := fmt.Sprintf("t%d", i)
		lines = append(lines, assistantRec("a"+id, "m"+id, toolUse(id, "Read", map[string]any{"file_path": "a.go"})), userBlocks("u"+id, toolResult(id)))
	}
	live, err := LiveOf(liveFile(t, false, lines...), false, liveNow)
	require.NoError(t, err)
	require.Len(t, live.Steps, 40)
	assert.Equal(t, 5, live.StepsMore)
	assert.Equal(t, "t6", live.Steps[0].ID)
	assert.Equal(t, "t45", live.Steps[39].ID)
}

func TestLiveStepsEmptyWhenTurnEnded(t *testing.T) {
	c := liveFile(t, false, ownerLine,
		assistantRec("a1", "m1", toolUse("t1", "Read", map[string]any{"file_path": "a.go"})), userBlocks("u1", toolResult("t1")), endTurnLine)
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	assert.Equal(t, []LiveAction{}, live.Steps)
	assert.Equal(t, 0, live.StepsMore)
}

func TestLiveStepsCodexCallsAndOutputs(t *testing.T) {
	c := codexLiveFixture(t, liveRec("event_msg", map[string]any{"type": "task_started"}),
		liveRec("response_item", map[string]any{"type": "function_call", "name": "shell", "call_id": "c1", "arguments": `{"command":["ls"]}`}),
		liveRec("response_item", map[string]any{"type": "function_call_output", "call_id": "c1", "output": "ok"}),
		liveRec("response_item", map[string]any{"type": "custom_tool_call", "name": "functions.exec", "call_id": "c2", "input": `await tools.exec_command({cmd:"go test"})`}),
		liveRec("response_item", map[string]any{"type": "custom_tool_call_output", "call_id": "c2", "output": "ok"}),
		liveRec("response_item", map[string]any{"type": "function_call", "name": "shell", "call_id": "c3", "arguments": `{"command":["pwd"]}`}))
	live, err := LiveOf(c, true, liveNow)
	require.NoError(t, err)
	require.Equal(t, []string{"c1", "c2", "c3"}, stepIDs(live.Steps))
	assert.False(t, live.Steps[0].CompletedAt.IsZero())
	assert.False(t, live.Steps[1].CompletedAt.IsZero())
	assert.True(t, live.Steps[2].CompletedAt.IsZero())
}

func TestLiveStepsJSONNeverNull(t *testing.T) {
	c := liveFile(t, false, ownerLine, assistantRec("a1", "m1", toolUse("t1", "Read", map[string]any{"file_path": "a.go"})), userBlocks("u1", toolResult("t1")), endTurnLine)
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	b, err := json.Marshal(live)
	require.NoError(t, err)
	assert.Contains(t, string(b), `"steps":[]`)
	assert.Contains(t, string(b), `"steps_more":0`)
}

func TestLiveStepsSidechainOnlyOwnRecords(t *testing.T) {
	side := `{"type":"assistant","isSidechain":true,"timestamp":"2026-11-02T12:00:00Z","message":{"content":[{"type":"tool_use","id":"s1","name":"Read","input":{"file_path":"x.go"}}]}}`
	c := liveFile(t, false, ownerLine, side,
		assistantRec("a1", "m1", toolUse("t1", "Read", map[string]any{"file_path": "a.go"})))
	live, err := LiveOf(c, false, liveNow)
	require.NoError(t, err)
	assert.Equal(t, []string{"t1"}, stepIDs(live.Steps))
}

func TestLiveSteps_CapKeepsOpenStep(t *testing.T) {
	lines := []string{ownerLine, assistantRec("aopen", "mopen", toolUse("open", "Bash", map[string]any{"command": "sleep 99"}))}
	for i := 1; i <= 45; i++ {
		id := fmt.Sprintf("t%d", i)
		lines = append(lines, assistantRec("a"+id, "m"+id, toolUse(id, "Read", map[string]any{"file_path": "a.go"})), userBlocks("u"+id, toolResult(id)))
	}
	live, err := LiveOf(liveFile(t, false, lines...), false, liveNow)
	require.NoError(t, err)
	// Rule: the last 40 by start order (t6..t45) plus the older open step = 41;
	// the 5 cut steps (t1..t5) are finished, so StepsMore is 5.
	require.Len(t, live.Steps, 41)
	assert.Equal(t, 5, live.StepsMore)
	assert.Equal(t, "open", live.Steps[0].ID)
	assert.True(t, live.Steps[0].CompletedAt.IsZero())
	assert.Equal(t, "t6", live.Steps[1].ID)
	assert.Equal(t, "t45", live.Steps[40].ID)
}
