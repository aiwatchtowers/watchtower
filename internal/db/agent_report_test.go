package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAgentReportSessions_OldFormat(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
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

func TestAgentReportTargets(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	res, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id) VALUES ('parent', '2026-01-01', '2026-12-31', ?)`, pid)
	require.NoError(t, err)
	parent, _ := res.LastInsertId()
	_, err = d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id, parent_id) VALUES ('child', '2026-01-01', '2026-12-31', ?, ?)`, pid, parent)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE targets SET status = 'in_progress' WHERE id = ?`, parent+1)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO targets (text, period_start, period_end) VALUES ('personal', '2026-01-01', '2026-12-31')`)
	require.NoError(t, err)

	got, err := d.AgentReportTargets(pid)
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Nil(t, got[0].ParentID)
	require.NotNil(t, got[1].ParentID)
	assert.Equal(t, parent, *got[1].ParentID)
	assert.Equal(t, "in_progress", got[1].Status)
	require.Len(t, got[1].History, 2)
	assert.Equal(t, "todo", got[1].History[0].To)
	assert.Equal(t, "in_progress", got[1].History[1].To)
}
