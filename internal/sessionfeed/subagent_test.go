package sessionfeed

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func agentCall(id, typ, desc string) map[string]any {
	in := map[string]any{"description": desc, "prompt": "do it"}
	if typ != "" {
		in["subagent_type"] = typ
	}
	return map[string]any{"type": "tool_use", "id": id, "name": "Agent", "input": in}
}

func sideRec(rec string) string {
	// mark a fabricated record as a sidechain one
	return rec[:len(rec)-2] + `,"isSidechain":true,"agentId":"ag1"}` + "\n"
}

func TestSubagent_MarkerFromAgentCall(t *testing.T) {
	res := parseStr(t, join(
		assistantRec("a1", "m1", agentCall("toolu_1", "Explore", "look around"), agentCall("toolu_2", "", "second")),
	), 0)
	require.Len(t, res.Entries, 2)
	e := res.Entries[0]
	assert.Equal(t, KindSubagent, e.Kind)
	assert.Equal(t, "toolu_1", e.ID)
	require.NotNil(t, e.Subagent)
	assert.Equal(t, "Explore", e.Subagent.Type)
	assert.Equal(t, "look around", e.Subagent.Description)
	assert.Equal(t, "toolu_1", e.Subagent.ToolUseID)
	assert.Equal(t, "general-purpose", res.Entries[1].Subagent.Type)
}

func writeSub(t *testing.T, dir, agent, meta, body string) {
	t.Helper()
	sub := filepath.Join(dir, "subagents")
	require.NoError(t, os.MkdirAll(sub, 0o755))
	if meta != "" {
		require.NoError(t, os.WriteFile(filepath.Join(sub, "agent-"+agent+".meta.json"), []byte(meta), 0o644))
	}
	if body != "" {
		require.NoError(t, os.WriteFile(filepath.Join(sub, "agent-"+agent+".jsonl"), []byte(body), 0o644))
	}
}

func TestSubagent_StatusFromMeta(t *testing.T) {
	dir := t.TempDir()
	writeSub(t, dir, "aa", `{"agentType":"Explore","toolUseId":"toolu_1","finished":true}`, "")
	writeSub(t, dir, "bb", `{"agentType":"Explore","toolUseId":"toolu_2","finished":false}`, "")
	require.NoError(t, os.Symlink(filepath.Join(dir, "subagents", "agent-aa.meta.json"), filepath.Join(dir, "subagents", "agent-cc.meta.json")))
	mk := func(id string) Entry {
		return Entry{ID: id, Kind: KindSubagent, Subagent: &SubagentRef{ToolUseID: id}}
	}
	out := ResolveSubagents(dir, []Entry{mk("toolu_1"), mk("toolu_2"), mk("toolu_3"), {Kind: KindOwner}})
	assert.Equal(t, "finished", out[0].Subagent.Status)
	assert.Equal(t, "aa", out[0].Subagent.AgentID)
	assert.Equal(t, "running", out[1].Subagent.Status)
	assert.Equal(t, "bb", out[1].Subagent.AgentID)
	assert.Equal(t, "unknown", out[2].Subagent.Status)
	assert.Empty(t, out[2].Subagent.AgentID)
	assert.Equal(t, "unknown", ResolveSubagents(filepath.Join(dir, "nope"), []Entry{mk("x")})[0].Subagent.Status)
}

func writeFeed(t *testing.T, body string) string {
	p := filepath.Join(t.TempDir(), "agent-ag1.jsonl")
	require.NoError(t, os.WriteFile(p, []byte(body), 0o644))
	return p
}

func TestSubagent_FeedTaskRepliesReport(t *testing.T) {
	p := writeFeed(t, join(
		sideRec(userStr("u1", "the task")),
		sideRec(assistantRec("a1", "m1", textB("working"))),
		sideRec(assistantRec("a2", "m2", map[string]any{"type": "tool_use", "id": "t9", "name": "SubagentHandback",
			"input": map[string]any{"message": "R"}})),
	))
	res, err := ParseSubagent(p, "ignored")
	require.NoError(t, err)
	require.Len(t, res.Entries, 3)
	assert.Equal(t, KindOwner, res.Entries[0].Kind)
	assert.Equal(t, "the task", res.Entries[0].Text)
	assert.Equal(t, KindAgent, res.Entries[1].Kind)
	assert.Equal(t, "working", res.Entries[1].Text)
	assert.Equal(t, KindAgent, res.Entries[2].Kind)
	assert.Equal(t, "R", res.Entries[2].Text)
}

func TestSubagent_ForegroundReportFromParent(t *testing.T) {
	p := writeFeed(t, join(
		sideRec(userStr("u1", "the task")),
		sideRec(assistantRec("a1", "m1", textB("done"), agentCall("toolu_n", "Plan", "nested"))),
	))
	res, err := ParseSubagent(p, "P")
	require.NoError(t, err)
	require.Len(t, res.Entries, 4)
	assert.Equal(t, KindSubagent, res.Entries[2].Kind) // nested marker
	assert.Equal(t, KindAgent, res.Entries[3].Kind)
	assert.Equal(t, "P", res.Entries[3].Text)
}

func TestSubagent_ParentReportRecordedOnMarker(t *testing.T) {
	res := parseStr(t, join(
		assistantRec("a1", "m1", agentCall("toolu_1", "Explore", "d")),
		userBlocks("u2", map[string]any{"type": "tool_result", "tool_use_id": "toolu_1",
			"content": []map[string]any{{"type": "text", "text": "P"}}}),
	), 0)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, "P", res.Entries[0].Subagent.ParentReport)
}
