package agentreport

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
	"watchtower/internal/agentlogdb"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// updateFixtures regenerates the Desktop decoding fixtures. Run with:
//
//	go test ./internal/agentreport/ -run TestDesktopReportFixtures -update
var updateFixtures = flag.Bool("update", false, "update the Desktop agent-report fixtures")

const (
	fixtureSession    = "11111111-aaaa-bbbb-cccc-000000000001"
	fixtureOldSession = "22222222-aaaa-bbbb-cccc-000000000002"
)

// seedFixtureDB stores one v2 session that exercises every time category, a
// background subagent, repeated `make test` runs inside two open board
// targets (so they share the stretch) and a PR link, plus one old-format session. Placeholders only.
func seedFixtureDB(t *testing.T) (testDBs, int64) {
	t.Helper()
	d, wb := buildDB(t)
	require.NoError(t, d.SetWorkbenchAgentAnalytics(wb, true))
	day := time.Date(2026, 10, 1, 10, 0, 0, 0, time.UTC)
	at := func(v time.Duration) string { return day.Add(v).Format(tsLayout) }

	res, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id, status)
		VALUES ('Add widget', '2026-01-01', '2026-12-31', ?, 'in_progress')`, wb)
	require.NoError(t, err)
	tid, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE target_status_history SET changed_at = ? WHERE target_id = ?`, at(-time.Hour), tid)
	require.NoError(t, err)
	res, err = d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id, status)
		VALUES ('Fix login', '2026-01-01', '2026-12-31', ?, 'in_progress')`, wb)
	require.NoError(t, err)
	tid2, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE target_status_history SET changed_at = ? WHERE target_id = ?`, at(-time.Hour), tid2)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE targets SET status = 'in_review' WHERE id = ?`, tid)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE target_status_history SET changed_at = ? WHERE target_id = ? AND to_status = 'in_review'`, at(30*time.Minute), tid)
	require.NoError(t, err)

	path := "/tmp/x/" + fixtureSession + ".jsonl"
	var evs []agentlogdb.AgentLogEvent
	var results []agentlogdb.AgentToolResult
	add := func(e agentlogdb.AgentLogEvent, v time.Duration) {
		e.SessionUUID, e.TS, e.SrcPath, e.SrcOffset = fixtureSession, at(v), path, int64(len(evs))
		if e.Key == "" {
			e.Key = fmt.Sprintf("%s:%d", e.Kind, len(evs))
		}
		evs = append(evs, e)
	}
	api := func(v time.Duration, agent string) {
		add(agentlogdb.AgentLogEvent{Kind: "api_call", Name: "claude-opus-5-5", AgentID: agent, InputTokens: 100, OutputTokens: 50,
			CacheReadTokens: 40, CostUSD: 1.5}, v)
	}
	tool := func(id string, v, dur time.Duration, name, target, outcome, agent string) {
		add(agentlogdb.AgentLogEvent{Key: "tool:" + id, Kind: "tool", Name: name, Target: target, Outcome: "pending", AgentID: agent}, v)
		results = append(results, agentlogdb.AgentToolResult{ToolUseID: id, TS: at(v + dur), Outcome: outcome})
	}
	sec, mn := time.Second, time.Minute
	add(agentlogdb.AgentLogEvent{Kind: "owner_turn", Trigger: "owner"}, 0)
	api(10*sec, "")
	tool("t1", 10*sec, 1*sec, "mcp__watchtower-workbench__update_target", fmt.Sprintf("#%d", tid), "ok", "")
	tool("t1b", 15*sec, 1*sec, "mcp__watchtower-workbench__update_target", fmt.Sprintf("#%d", tid2), "ok", "")
	api(20*sec, "")
	tool("t2", 20*sec, 2*mn, "Bash", "make test", "ok", "")
	api(2*mn+30*sec, "")
	tool("t3", 2*mn+30*sec, 2*mn, "Bash", "make test", "error", "")
	api(4*mn+40*sec, "")
	tool("t4", 4*mn+40*sec, 2*mn, "Bash", "make test", "ok", "")
	api(6*mn+50*sec, "")
	tool("t5", 6*mn+50*sec, 1*sec, "Agent", "general-purpose", "ok", "")
	results[len(results)-1].SpawnedAgentID, results[len(results)-1].Background = "agent-1", true
	api(7*mn, "")
	api(7*mn+5*sec, "agent-1")
	tool("t6", 7*mn+10*sec, 5*sec, "Read", "main.go", "ok", "agent-1")
	api(20*mn, "agent-1")
	add(agentlogdb.AgentLogEvent{Kind: "owner_turn", Trigger: "notification"}, 20*mn+5*sec)
	api(20*mn+15*sec, "")
	add(agentlogdb.AgentLogEvent{Kind: "pr_link", Target: "https://example.com/acme/app/pull/1"}, 20*mn+16*sec)
	add(agentlogdb.AgentLogEvent{Kind: "owner_turn", Trigger: "owner"}, 60*mn+15*sec)
	api(60*mn+30*sec, "")
	evs[1].CostEstimated = true

	_, err = d.al.ApplyAgentLogBatch(agentlogdb.AgentLogBatch{
		File: agentlogdb.AgentLogFile{Path: path, Agent: "claude", ReadOffset: 10, ParserVersion: 2}, ExpectOffset: -1,
		Sessions: []agentlogdb.AgentLogSession{{SessionUUID: fixtureSession, Agent: "claude", ProjectID: &wb, FolderPath: "/w", HomeCWD: "/w",
			SourcePath: path, StartedAt: at(0), EndedAt: at(60*mn + 30*sec), Model: "claude-opus-5-5", GitBranch: "feature/widget"}},
		Events: evs, ToolResults: results,
	})
	require.NoError(t, err)

	oldPath := "/tmp/x/" + fixtureOldSession + ".jsonl"
	_, err = d.al.ApplyAgentLogBatch(agentlogdb.AgentLogBatch{
		File: agentlogdb.AgentLogFile{Path: oldPath, Agent: "claude", ReadOffset: 10, ParserVersion: 1}, ExpectOffset: -1,
		Sessions: []agentlogdb.AgentLogSession{{SessionUUID: fixtureOldSession, Agent: "claude", ProjectID: &wb, FolderPath: "/w", HomeCWD: "/w",
			SourcePath: oldPath, StartedAt: at(-2 * time.Hour), EndedAt: at(-2*time.Hour + 5*mn), Model: "claude-opus-5-5"}},
		Events: []agentlogdb.AgentLogEvent{{SessionUUID: fixtureOldSession, Key: "old:0", Kind: "api_call", Name: "claude-opus-5-5",
			TS: at(-2 * time.Hour), InputTokens: 10, OutputTokens: 5, CostUSD: 0.5, SrcPath: oldPath}},
	})
	require.NoError(t, err)
	return d, wb
}

// TestDesktopReportFixtures pins the Desktop decoding fixtures to what the
// builders produce: a renamed or reshaped key on the Go side fails here, and
// AgentReportDecodingTests fails on the Swift side.
func TestDesktopReportFixtures(t *testing.T) {
	d, wb := seedFixtureDB(t)
	now := time.Date(2026, 10, 8, 0, 0, 0, 0, time.UTC)
	ov, err := BuildOverview(d.DB, d.al, wb, time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC), now)
	require.NoError(t, err)
	det, err := BuildSession(d.DB, d.al, wb, fixtureSession, now)
	require.NoError(t, err)

	dir := filepath.Join("..", "..", "WatchtowerDesktop", "Tests", "Core", "Fixtures")
	for name, v := range map[string]any{"agent-report-overview.json": ov, "agent-report-session.json": det} {
		got, err := json.MarshalIndent(v, "", "  ")
		require.NoError(t, err)
		got = append(got, '\n')
		file := filepath.Join(dir, name)
		if *updateFixtures {
			require.NoError(t, os.WriteFile(file, got, 0o644))
			t.Logf("wrote %s (%d bytes)", file, len(got))
			continue
		}
		want, err := os.ReadFile(file)
		require.NoError(t, err, "missing fixture — run with -update to create it")
		assert.JSONEq(t, string(want), string(got), "%s is stale — run with -update", name)
	}
}
