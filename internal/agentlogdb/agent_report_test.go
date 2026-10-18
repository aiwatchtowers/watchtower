package agentlogdb

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAgentReportSessions_OldFormat(t *testing.T) {
	d := openTestDB(t)
	pid := testWorkbenchID
	for _, f := range []struct {
		path, session string
		version       int
		missing       bool
	}{{"/x/old.jsonl", "old", 1, true}, {"/x/new.jsonl", "new", 2, true}, {"/x/live.jsonl", "live", 1, false}} {
		_, err := d.ApplyAgentLogBatch(AgentLogBatch{
			File:         AgentLogFile{Path: f.path, Agent: "claude", ReadOffset: 10, ParserVersion: f.version},
			ExpectOffset: -1,
			Sessions:     []AgentLogSession{agentSession(f.session, "2026-10-01T10:00:00.000Z", pid)},
			Events: []AgentLogEvent{{SessionUUID: f.session, Key: f.session + ":m1", Kind: "api_call",
				TS: "2026-10-01T10:00:01.000Z", Name: "claude-opus-5-5", OutputTokens: 7, CostUSD: 0.5, SrcPath: f.path, SrcOffset: 3}},
		})
		require.NoError(t, err)
		if f.missing {
			require.NoError(t, d.MarkAgentLogFileMissing(f.path, "2026-10-10T00:00:00Z"))
		}
	}
	_, err := d.ApplyAgentLogBatch(AgentLogBatch{
		File:         AgentLogFile{Path: "/x/early.jsonl", Agent: "claude", ReadOffset: 10, ParserVersion: 2},
		ExpectOffset: -1,
		Sessions:     []AgentLogSession{agentSession("early", "2026-09-01T10:00:00.000Z", pid)},
	})
	require.NoError(t, err)

	got, err := d.AgentReportSessions(pid, "2026-09-15T00:00:00.000Z")
	require.NoError(t, err)
	require.Len(t, got, 3)
	byID := map[string]AgentReportSession{}
	for _, s := range got {
		byID[s.SessionUUID] = s
	}
	assert.True(t, byID["old"].OldFormat)
	assert.False(t, byID["new"].OldFormat, "missing but parsed at the current version")
	assert.True(t, byID["live"].OldFormat, "present but not yet rescanned at the current version")

	evs, err := d.AgentReportEvents([]string{"old", "new"})
	require.NoError(t, err)
	require.Len(t, evs, 2)
	assert.Equal(t, "new", evs[0].SessionUUID)
	assert.Equal(t, "claude-opus-5-5", evs[0].Model)
	assert.Equal(t, int64(7), evs[0].OutputTokens)
	assert.InDelta(t, 0.5, evs[0].CostUSD, 1e-9)
	assert.Nil(t, evs[0].DurationMS)

	none, err := d.AgentReportEvents(nil)
	require.NoError(t, err)
	assert.Empty(t, none)
}

func applyFactsFile(t *testing.T, d *DB, path, session string, version int, extra func(*AgentLogBatch)) {
	t.Helper()
	b := AgentLogBatch{
		File:         AgentLogFile{Path: path, Agent: "claude", ReadOffset: 10, ParserVersion: version},
		ExpectOffset: -1,
		Sessions:     []AgentLogSession{agentSession(session, "2026-10-01T10:00:00.000Z", testWorkbenchID)},
	}
	if extra != nil {
		extra(&b)
	}
	_, err := d.ApplyAgentLogBatch(b)
	require.NoError(t, err)
}

func TestAgentReportEvents_V2Facts(t *testing.T) {
	d := openTestDB(t)
	size, pre, post := int64(1234), int64(9000), int64(2000)
	applyFactsFile(t, d, "/x/a.jsonl", "a", 3, func(b *AgentLogBatch) {
		b.Events = []AgentLogEvent{
			{SessionUUID: "a", Key: "tool:t1", Kind: "tool", TS: "2026-10-01T10:00:01.000Z", Name: "Bash", Outcome: "error",
				ErrorClass: "exit_code", ResultBytes: &size, SrcPath: "/x/a.jsonl", SrcOffset: 1},
			{SessionUUID: "a", Key: "a:m1", Kind: "api_call", TS: "2026-10-01T10:00:02.000Z", Name: "m",
				ThinkingTokens: 42, SrcPath: "/x/a.jsonl", SrcOffset: 2},
			{SessionUUID: "a", Key: "compact:1", Kind: "compaction", TS: "2026-10-01T10:00:03.000Z",
				PreTokens: &pre, PostTokens: &post, SrcPath: "/x/a.jsonl", SrcOffset: 3},
		}
	})
	applyFactsFile(t, d, "/x/b.jsonl", "b", 2, func(b *AgentLogBatch) {
		b.Events = []AgentLogEvent{{SessionUUID: "b", Key: "tool:t2", Kind: "tool", TS: "2026-10-01T10:00:01.000Z",
			Name: "Bash", SrcPath: "/x/b.jsonl", SrcOffset: 1}}
	})
	evs, err := d.AgentReportEvents([]string{"a", "b"})
	require.NoError(t, err)
	require.Len(t, evs, 4)
	assert.Equal(t, "exit_code", evs[0].ErrorClass)
	require.NotNil(t, evs[0].ResultBytes)
	assert.Equal(t, int64(1234), *evs[0].ResultBytes)
	assert.Equal(t, int64(42), evs[1].ThinkingTokens)
	assert.Nil(t, evs[1].ResultBytes)
	require.NotNil(t, evs[2].PreTokens)
	require.NotNil(t, evs[2].PostTokens)
	assert.Equal(t, int64(9000), *evs[2].PreTokens)
	assert.Equal(t, int64(2000), *evs[2].PostTokens)
	assert.Nil(t, evs[3].ResultBytes, "v2 row: not measured, not zero")
	assert.Nil(t, evs[3].PreTokens)
}

func TestAgentReportSessions_FactsFlag(t *testing.T) {
	d := openTestDB(t)
	applyFactsFile(t, d, "/x/v2.jsonl", "v2", 2, nil)
	applyFactsFile(t, d, "/x/v3.jsonl", "v3", 3, nil)
	applyFactsFile(t, d, "/x/mix2.jsonl", "other", 2, nil)
	applyFactsFile(t, d, "/x/mix3.jsonl", "mix", 3, func(b *AgentLogBatch) {
		b.Events = []AgentLogEvent{{SessionUUID: "mix", Key: "mix:m1", Kind: "api_call", TS: "2026-10-01T10:00:01.000Z",
			Name: "m", SrcPath: "/x/mix2.jsonl", SrcOffset: 1}}
	})
	applyFactsFile(t, d, "/x/nofile.jsonl", "nofile", 3, nil)
	_, err := d.Exec(`DELETE FROM agent_log_files WHERE path = '/x/nofile.jsonl'`)
	require.NoError(t, err)
	got, err := d.AgentReportSessions(testWorkbenchID, "2026-09-01T00:00:00.000Z")
	require.NoError(t, err)
	byID := map[string]AgentReportSession{}
	for _, s := range got {
		byID[s.SessionUUID] = s
	}
	assert.False(t, byID["v2"].Facts)
	assert.True(t, byID["v3"].Facts)
	assert.False(t, byID["v2"].OldFormat)
	assert.False(t, byID["mix"].Facts, "an event source file below v3 clears Facts")
	assert.False(t, byID["nofile"].Facts, "no file row: not measured")
}

func TestAgentReportContextParts_ChunkedIDs(t *testing.T) {
	d := openTestDB(t)
	applyFactsFile(t, d, "/x/a.jsonl", "a", 3, func(b *AgentLogBatch) {
		b.ContextParts = []AgentContextPart{{SessionUUID: "a", Part: "system", Bytes: 5}}
	})
	applyFactsFile(t, d, "/x/z.jsonl", "z", 3, func(b *AgentLogBatch) {
		b.ContextParts = []AgentContextPart{{SessionUUID: "z", Part: "system", Bytes: 6}}
	})
	ids := []string{"z"}
	for i := 0; i < agentReportChunk+10; i++ {
		ids = append(ids, fmt.Sprintf("filler-%04d", i))
	}
	ids = append(ids, "a")
	got, err := d.AgentReportContextParts(ids)
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Equal(t, "a", got[0].SessionUUID)
	assert.Equal(t, "z", got[1].SessionUUID)
}

func TestAgentReportContextParts(t *testing.T) {
	d := openTestDB(t)
	applyFactsFile(t, d, "/x/a.jsonl", "a", 3, func(b *AgentLogBatch) {
		b.ContextParts = []AgentContextPart{
			{SessionUUID: "a", AgentID: "z1", Part: "system", Bytes: 5},
			{SessionUUID: "a", AgentID: "", Part: "tools", Bytes: 7},
			{SessionUUID: "a", AgentID: "", Part: "claude_md", Bytes: 9},
		}
	})
	applyFactsFile(t, d, "/x/c.jsonl", "c", 3, func(b *AgentLogBatch) {
		b.ContextParts = []AgentContextPart{{SessionUUID: "c", Part: "system", Bytes: 1}}
	})
	got, err := d.AgentReportContextParts([]string{"c", "a"})
	require.NoError(t, err)
	assert.Equal(t, []AgentContextPart{
		{SessionUUID: "a", AgentID: "", Part: "claude_md", Bytes: 9},
		{SessionUUID: "a", AgentID: "", Part: "tools", Bytes: 7},
		{SessionUUID: "a", AgentID: "z1", Part: "system", Bytes: 5},
		{SessionUUID: "c", Part: "system", Bytes: 1},
	}, got)
	none, err := d.AgentReportContextParts(nil)
	require.NoError(t, err)
	assert.Empty(t, none)
}

func TestAgentReportSkillListing(t *testing.T) {
	d := openTestDB(t)
	applyFactsFile(t, d, "/x/a.jsonl", "a", 3, func(b *AgentLogBatch) {
		b.SkillListing = []AgentSkillListed{{SessionUUID: "a", Skill: "zeta", Bytes: 3}, {SessionUUID: "a", Skill: "alpha", Bytes: 4}}
	})
	got, err := d.AgentReportSkillListing([]string{"a"})
	require.NoError(t, err)
	assert.Equal(t, []AgentSkillListed{{SessionUUID: "a", Skill: "alpha", Bytes: 4}, {SessionUUID: "a", Skill: "zeta", Bytes: 3}}, got)
}

func TestAgentReportSubagents(t *testing.T) {
	d := openTestDB(t)
	yes := true
	applyFactsFile(t, d, "/x/a.jsonl", "a", 3, func(b *AgentLogBatch) {
		b.Subagents = []AgentSubagent{
			{SessionUUID: "a", AgentID: "s2", AgentType: "Explore", Depth: 0},
			{SessionUUID: "a", AgentID: "s1", AgentType: "general", Depth: 2, Finished: &yes},
		}
	})
	got, err := d.AgentReportSubagents([]string{"a"})
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Equal(t, "s1", got[0].AgentID)
	assert.Equal(t, 2, got[0].Depth)
	require.NotNil(t, got[0].Finished)
	assert.True(t, *got[0].Finished)
	assert.Equal(t, "s2", got[1].AgentID)
	assert.Equal(t, 0, got[1].Depth, "unknown depth stays 0")
	assert.Nil(t, got[1].Finished)
}
