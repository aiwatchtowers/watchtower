package agentreport

import (
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func buildDB(t *testing.T) (*db.DB, int64) {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "w.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	wb, err := d.CreateWorkbench("app", t.TempDir())
	require.NoError(t, err)
	return d, wb
}

// putSession stores one session with n events one second apart from t0; the
// file is parsed at version.
func putSession(t *testing.T, d *db.DB, wb int64, id string, n, version int) {
	t.Helper()
	putSessionWith(t, d, wb, id, n, version, nil)
}

// putSessionWith adds extra events (their SrcPath and SrcOffset are set here).
func putSessionWith(t *testing.T, d *db.DB, wb int64, id string, n, version int, extra []db.AgentLogEvent) {
	t.Helper()
	path := "/tmp/x/" + id + ".jsonl"
	start := t0.Format(tsLayout)
	end := t0.Add(time.Duration(n) * time.Second).Format(tsLayout)
	evs := make([]db.AgentLogEvent, 0, n)
	for i := 0; i < n; i++ {
		e := db.AgentLogEvent{SessionUUID: id, Key: fmt.Sprintf("%s:%d", id, i), SrcPath: path, SrcOffset: int64(i),
			TS: t0.Add(time.Duration(i) * time.Second).Format(tsLayout)}
		switch i % 4 {
		case 0:
			e.Kind, e.Trigger = "owner_turn", "owner"
		case 1:
			e.Kind, e.Name, e.OutputTokens, e.InputTokens, e.CostUSD = "api_call", "claude-opus-5-5", 5, 10, 0.01
		default:
			e.Kind, e.Name, e.Target, e.Outcome = "tool", "Bash", "go test ./...", "ok"
			e.TS = t0.Add(time.Duration(i) * time.Second).Format(tsLayout)
		}
		evs = append(evs, e)
	}
	for i, e := range extra {
		e.SessionUUID, e.Key, e.SrcPath, e.SrcOffset = id, fmt.Sprintf("%s:x%d", id, i), path, int64(1000+i)
		evs = append(evs, e)
	}
	_, err := d.ApplyAgentLogBatch(db.AgentLogBatch{
		File: db.AgentLogFile{Path: path, Agent: "claude", ReadOffset: 10, ParserVersion: version}, ExpectOffset: -1,
		Sessions: []db.AgentLogSession{{SessionUUID: id, Agent: "claude", ProjectID: &wb, FolderPath: "/w", HomeCWD: "/w",
			SourcePath: path, StartedAt: start, EndedAt: end, Model: "claude-opus-5-5"}},
		Events: evs,
	})
	require.NoError(t, err)
	if version < 2 {
		require.NoError(t, d.MarkAgentLogFileMissing(path, "2026-10-10T00:00:00Z"))
	}
}

func TestBuildOverview_OldFormatExcludedFromTime(t *testing.T) {
	d, wb := buildDB(t)
	res, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id, status) VALUES ('goal', '2026-01-01', '2026-12-31', ?, 'in_progress')`, wb)
	require.NoError(t, err)
	tid, _ := res.LastInsertId()
	_, err = d.Exec(`UPDATE target_status_history SET changed_at = ? WHERE target_id = ?`, t0.Add(-time.Hour).Format("2006-01-02T15:04:05Z"), tid)
	require.NoError(t, err)
	at := func(s int) string { return t0.Add(time.Duration(s) * time.Second).Format(tsLayout) }
	extra := []db.AgentLogEvent{
		{Kind: "tool", Name: "Agent", Target: "general", Outcome: "ok", SpawnedAgentID: "a1", TS: at(2)},
		{Kind: "tool", Name: "mcp__watchtower-workbench__update_target", Target: fmt.Sprintf("#%d", tid), Outcome: "ok", TS: at(3)},
		{Kind: "api_call", Name: "claude-opus-5-5", AgentID: "a1", TS: at(5)},
		{Kind: "api_call", Name: "claude-opus-5-5", AgentID: "a1", TS: at(9)},
	}
	putSessionWith(t, d, wb, "new", 40, 2, extra)
	putSessionWith(t, d, wb, "old", 40, 1, extra)

	ov, err := BuildOverview(d, wb, time.Time{}, t0.Add(time.Hour))
	require.NoError(t, err)
	assert.Equal(t, 1, ov.OldFormatSessions)
	assert.Equal(t, 2, ov.Totals.Sessions)
	assert.InDelta(t, 0.2, ov.Totals.CostUSD, 1e-9, "both sessions' cost counts")
	require.Len(t, ov.Sessions, 2)
	rows := map[string]SessionRow{}
	for _, r := range ov.Sessions {
		rows[r.UUID] = r
	}
	assert.True(t, rows["old"].OldFormat)
	assert.Zero(t, rows["old"].ActiveMS)
	assert.Positive(t, rows["new"].ActiveMS)
	assert.Equal(t, rows["new"].ActiveMS, ov.Time.ActiveMS, "only the new session is in the time split")
	assert.Equal(t, ov.Time.ActiveMS, ov.Totals.ActiveMS)
	assert.Equal(t, 1, ov.Subagents.Count, "the old session's subagent is not counted")
	require.Len(t, ov.Tasks, 1)
	assert.Equal(t, []string{"new"}, ov.Tasks[0].Sessions)
	for _, h := range ov.Hints {
		for _, e := range h.Evidence {
			assert.NotEqual(t, "old", e.Ref, "hint %s cites the old session", h.ID)
		}
	}
}

func TestBuildSession_UnknownIsError(t *testing.T) {
	d, wb := buildDB(t)
	putSession(t, d, wb, "s1", 8, 2)
	det, err := BuildSession(d, wb, "s1")
	require.NoError(t, err)
	assert.Equal(t, "s1", det.Session.UUID)
	_, err = BuildSession(d, wb, "nope")
	assert.Error(t, err)
	_, err = BuildSession(d, wb+1, "s1")
	assert.Error(t, err)
}

func TestBuildOverview_Performance(t *testing.T) {
	if testing.Short() || raceEnabled {
		t.Skip("wall-clock budget: skipped under -short and the race detector")
	}
	d, wb := buildDB(t)
	now := time.Now().UTC()
	tx, err := d.Begin()
	require.NoError(t, err)
	ins, err := tx.Prepare(`INSERT INTO agent_log_events (session_uuid, key, kind, ts, name, target, outcome, duration_ms,
		input_tokens, output_tokens, cost_usd, src_path, src_offset) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`)
	require.NoError(t, err)
	for day := 0; day < 30; day++ {
		for s := 0; s < 25; s++ {
			id := fmt.Sprintf("s-%d-%d", day, s)
			path := "/tmp/x/" + id + ".jsonl"
			base := now.AddDate(0, 0, -day).Add(time.Duration(s) * time.Minute)
			_, err := tx.Exec(`INSERT INTO agent_log_files (path, agent, size, mtime, read_offset, parser_version)
				VALUES (?, 'claude', 1, '', 1, 2)`, path)
			require.NoError(t, err)
			_, err = tx.Exec(`INSERT INTO agent_log_sessions (session_uuid, agent, project_id, folder_path, home_cwd, source_path, started_at, ended_at)
				VALUES (?, 'claude', ?, '/w', '/w', ?, ?, ?)`, id, wb, path, base.Format(tsLayout), base.Add(25*time.Minute).Format(tsLayout))
			require.NoError(t, err)
			for i := 0; i < 200; i++ {
				ts := base.Add(time.Duration(i) * 700 * time.Millisecond).Format(tsLayout)
				key := fmt.Sprintf("%s:%d", id, i)
				switch i % 5 {
				case 0:
					_, err = ins.Exec(id, key, "owner_turn", ts, "", "", "", nil, 0, 0, 0, path, i)
				case 1, 2:
					_, err = ins.Exec(id, key, "api_call", ts, "claude-opus-5-5", "", "", nil, 100, 50, 0.01, path, i)
				default:
					_, err = ins.Exec(id, key, "tool", ts, "Bash", "go test ./...", "ok", 300, 0, 0, 0, path, i)
				}
				require.NoError(t, err)
			}
		}
	}
	require.NoError(t, tx.Commit())

	start := time.Now()
	ov, err := BuildOverview(d, wb, time.Time{}, now)
	took := time.Since(start)
	require.NoError(t, err)
	assert.Equal(t, 750, ov.Totals.Sessions)
	t.Logf("BuildOverview over 150k events: %s", took)
	assert.Less(t, took, time.Second)
}
