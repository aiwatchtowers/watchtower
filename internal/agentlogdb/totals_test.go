package agentlogdb

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTotalsSince_PeriodAndWorkbenches(t *testing.T) {
	d := openTestDB(t)
	call := func(session, key, ts string, out int64, usd float64) AgentLogEvent {
		e := apiCall(session, key, out)
		e.TS, e.CacheReadTokens, e.CacheWrite5mTokens, e.CacheWrite1hTokens, e.CostUSD = ts, 100, 20, 3, usd
		return e
	}
	tool := apiCall("s1", "tool:x", 0)
	tool.Kind, tool.TS = "tool", "2026-10-10T12:00:00.500Z"
	b := AgentLogBatch{File: AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 100}, ExpectOffset: -1,
		Sessions: []AgentLogSession{agentSession("s1", "2026-10-01T10:00:00Z", 1),
			agentSession("s2", "2026-10-01T10:00:00Z", 1), agentSession("s3", "2026-10-01T10:00:00Z", 2)},
		Events: []AgentLogEvent{
			call("s1", "m1:r1", "2026-10-10T12:00:00.000Z", 5, 0.5), // at the bound: counted
			call("s1", "m2:r2", "2026-10-10T13:00:00.123Z", 7, 0.25),
			call("s2", "m3:r3", "2026-10-10T11:59:59.999Z", 9, 1), // before the period
			call("s3", "m4:r4", "2026-10-10T14:00:00Z", 11, 2),    // workbench 2
			tool,
		}}
	ok, err := d.ApplyAgentLogBatch(b)
	require.NoError(t, err)
	require.True(t, ok)

	since := time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC)
	got, err := d.TotalsSince(since, []int64{1})
	require.NoError(t, err)
	assert.Equal(t, Totals{Sessions: 1, Calls: 2, Input: 20, CacheRead: 200, CacheWrite: 46, Output: 12, CostUSD: 0.75}, got)

	got, err = d.TotalsSince(since, []int64{1, 2})
	require.NoError(t, err)
	assert.Equal(t, int64(2), got.Sessions)
	assert.Equal(t, int64(3), got.Calls)

	got, err = d.TotalsSince(since, nil)
	require.NoError(t, err)
	assert.Equal(t, Totals{}, got)
}

func TestOpenExisting_ReadOnlyAndNeverCreates(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agentlog.db")
	_, err := OpenExisting(path, time.Second)
	require.Error(t, err, "a missing file is not created")

	d, err := Open(path)
	require.NoError(t, err)
	require.NoError(t, d.Close())
	ro, err := OpenExisting(path, time.Second)
	require.NoError(t, err)
	t.Cleanup(func() { _ = ro.Close() })
	_, err = ro.Exec(`INSERT INTO agent_log_meta (key, value) VALUES ('probe', 'x')`)
	require.Error(t, err, "query_only refuses a write")
	_, err = ro.TotalsSince(time.Time{}, []int64{1})
	require.NoError(t, err)
}
