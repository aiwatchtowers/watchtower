package agentreport

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/db"
)

// testDBs is a report's two handles: watchtower.db (embedded: workbenches,
// targets) and agentlog.db.
type testDBs struct {
	*db.DB
	al *agentlogdb.DB
}

func buildDB(t *testing.T) (testDBs, int64) {
	t.Helper()
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "w.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	al, err := agentlogdb.Open(filepath.Join(dir, "agentlog.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = al.Close() })
	_, err = agentlogdb.MoveFromMain(context.Background(), d, al, agentlogdb.MoveLockPath(filepath.Join(dir, "agentlog.db")))
	require.NoError(t, err)
	wb, err := d.CreateWorkbench("app", t.TempDir())
	require.NoError(t, err)
	return testDBs{DB: d, al: al}, wb
}

// putSession stores one session with n events one second apart from t0; the
// file is parsed at version.
func putSession(t *testing.T, d testDBs, wb int64, id string, n, version int) {
	t.Helper()
	putSessionWith(t, d, wb, id, n, version, nil)
}

// putSessionWith adds extra events (their SrcPath and SrcOffset are set here).
func putSessionWith(t *testing.T, d testDBs, wb int64, id string, n, version int, extra []agentlogdb.AgentLogEvent) {
	t.Helper()
	path := "/tmp/x/" + id + ".jsonl"
	start := t0.Format(tsLayout)
	end := t0.Add(time.Duration(n) * time.Second).Format(tsLayout)
	evs := make([]agentlogdb.AgentLogEvent, 0, n)
	for i := range n {
		e := agentlogdb.AgentLogEvent{SessionUUID: id, Key: fmt.Sprintf("%s:%d", id, i), SrcPath: path, SrcOffset: int64(i),
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
	_, err := d.al.ApplyAgentLogBatch(agentlogdb.AgentLogBatch{
		File: agentlogdb.AgentLogFile{Path: path, Agent: "claude", ReadOffset: 10, ParserVersion: version}, ExpectOffset: -1,
		Sessions: []agentlogdb.AgentLogSession{{SessionUUID: id, Agent: "claude", ProjectID: &wb, FolderPath: "/w", HomeCWD: "/w",
			SourcePath: path, StartedAt: start, EndedAt: end, Model: "claude-opus-5-5"}},
		Events: evs,
	})
	require.NoError(t, err)
	if version < 2 {
		require.NoError(t, d.al.MarkAgentLogFileMissing(path, "2026-10-10T00:00:00Z"))
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
	extra := []agentlogdb.AgentLogEvent{
		{Kind: "tool", Name: "Agent", Target: "general", Outcome: "ok", SpawnedAgentID: "a1", TS: at(2)},
		{Kind: "tool", Name: "mcp__watchtower-workbench__update_target", Target: fmt.Sprintf("#%d", tid), Outcome: "ok", TS: at(3)},
		{Kind: "api_call", Name: "claude-opus-5-5", AgentID: "a1", TS: at(5)},
		{Kind: "api_call", Name: "claude-opus-5-5", AgentID: "a1", TS: at(9)},
	}
	putSessionWith(t, d, wb, "new", 40, 2, extra)
	putSessionWith(t, d, wb, "old", 40, 1, extra)

	ov, err := BuildOverview(d.DB, d.al, wb, time.Time{}, t0.Add(time.Hour), English)
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

// #849 D6: the overview's import state follows the workbench's progress row.
func TestBuildOverview_ImportState(t *testing.T) {
	stamp := t0.Format(time.RFC3339)
	for _, tc := range []struct {
		name string
		set  func(d testDBs, wb int64) error
		want ImportState
	}{
		{"no row", func(testDBs, int64) error { return nil }, ImportState{State: "not_started"}},
		{"incomplete", func(d testDBs, wb int64) error { return d.al.SetImportProgress(wb, false, 3, t0) },
			ImportState{State: "loading", FilesStored: 3, UpdatedAt: stamp}},
		{"complete", func(d testDBs, wb int64) error { return d.al.SetImportProgress(wb, true, 7, t0) },
			ImportState{State: "done", FilesStored: 7, UpdatedAt: stamp}},
		{"complete then incomplete", func(d testDBs, wb int64) error {
			if err := d.al.SetImportProgress(wb, true, 7, t0.Add(-time.Hour)); err != nil {
				return err
			}
			return d.al.SetImportProgress(wb, false, 8, t0)
		}, ImportState{State: "loading", FilesStored: 8, UpdatedAt: stamp}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d, wb := buildDB(t)
			require.NoError(t, d.SetWorkbenchAgentAnalytics(wb, true))
			require.NoError(t, tc.set(d, wb))
			ov, err := BuildOverview(d.DB, d.al, wb, time.Time{}, t0, English)
			require.NoError(t, err)
			assert.Equal(t, tc.want, ov.Import)
		})
	}
}

// Before the one-time move no scan runs, so the overview says so instead of
// "not started" or a stale progress row.
func TestBuildOverview_ImportWaitingForMove(t *testing.T) {
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "w.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	al, err := agentlogdb.Open(filepath.Join(dir, "agentlog.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = al.Close() })
	wb, err := d.CreateWorkbench("app", t.TempDir())
	require.NoError(t, err)
	require.NoError(t, d.SetWorkbenchAgentAnalytics(wb, true))
	require.NoError(t, al.SetImportProgress(wb, false, 3, t0))

	ov, err := BuildOverview(d, al, wb, time.Time{}, t0, English)
	require.NoError(t, err)
	assert.Equal(t, ImportState{State: "waiting_for_move"}, ov.Import)

	_, err = agentlogdb.MoveFromMain(context.Background(), d, al, agentlogdb.MoveLockPath(filepath.Join(dir, "agentlog.db")))
	require.NoError(t, err)
	ov, err = BuildOverview(d, al, wb, time.Time{}, t0, English)
	require.NoError(t, err)
	assert.Equal(t, "loading", ov.Import.State)
}

func TestBuildSession_UnknownIsError(t *testing.T) {
	d, wb := buildDB(t)
	putSession(t, d, wb, "s1", 8, 2)
	det, err := BuildSession(d.DB, d.al, wb, "s1", t0, English)
	require.NoError(t, err)
	assert.Equal(t, "s1", det.Session.UUID)
	_, err = BuildSession(d.DB, d.al, wb, "nope", t0, English)
	assert.Error(t, err)
	_, err = BuildSession(d.DB, d.al, wb+1, "s1", t0, English)
	assert.Error(t, err)
}

func TestBuildSession_MainLaneFirst(t *testing.T) {
	d, wb := buildDB(t)
	at := func(s int) string { return t0.Add(time.Duration(s) * time.Second).Format(tsLayout) }
	extra := []agentlogdb.AgentLogEvent{
		{Kind: "tool", Name: "Agent", Target: "general", Outcome: "ok", SpawnedAgentID: "a1", TS: at(2)},
		{Kind: "api_call", Name: "claude-opus-5-5", AgentID: "a1", TS: at(3)},
		{Kind: "api_call", Name: "claude-opus-5-5", AgentID: "a1", TS: at(5)},
	}
	putSessionWith(t, d, wb, "new", 8, 2, extra)
	putSessionWith(t, d, wb, "old", 8, 1, extra)

	det, err := BuildSession(d.DB, d.al, wb, "new", t0, English)
	require.NoError(t, err)
	require.Len(t, det.Lanes, 2)
	assert.Empty(t, det.Lanes[0].AgentID, "the main agent's lane comes first")
	evs, err := d.al.AgentReportEvents([]string{"new"})
	require.NoError(t, err)
	_, mainSegs := SessionTime(evs)
	require.NotEmpty(t, mainSegs)
	assert.Equal(t, mainSegs, det.Lanes[0].Segments)
	assert.Equal(t, "a1", det.Lanes[1].AgentID)

	old, err := BuildSession(d.DB, d.al, wb, "old", t0, English)
	require.NoError(t, err)
	assert.Empty(t, old.Lanes, "an old-format session has no lanes")
}

// The session drill-down reads the workbench folder too, so C1 there gets
// its open_file fix.
func TestBuildSession_C1OpenFile(t *testing.T) {
	d, wb := buildDB(t)
	putSession(t, d, wb, "new", 8, 3)
	for part, n := range map[string]int{"instructions": 6000, "tools": 4000} {
		_, err := d.al.Exec(`INSERT INTO agent_log_context_parts (session_uuid, agent_id, part, bytes) VALUES ('new', '', ?, ?)`, part, n)
		require.NoError(t, err)
	}
	w, err := d.GetWorkbench(wb)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(w.FolderPath, "CLAUDE.md"), []byte("rules\n"), 0o644))

	det, err := BuildSession(d.DB, d.al, wb, "new", t0.Add(time.Hour), English)
	require.NoError(t, err)
	hs := hintsOf(det.Hints, "C1")
	require.Len(t, hs, 1)
	assert.Equal(t, &Fix{Kind: FixOpenFile, Ref: "CLAUDE.md"}, hs[0].Fix)
}

// The budget covers the v2 blocks: every session carries parser-v3 facts
// (result sizes, error classes, context parts per lane, a skill listing,
// subagents), so Context, Skills and Trouble do their full work.
func TestBuildOverview_Performance(t *testing.T) {
	if testing.Short() || raceEnabled || testing.CoverMode() != "" {
		t.Skip("wall-clock budget: skipped under -short, the race detector and coverage instrumentation")
	}
	d, wb := buildDB(t)
	now := time.Now().UTC()
	tx, err := d.al.Begin()
	require.NoError(t, err)
	ins, err := tx.Prepare(`INSERT INTO agent_log_events (session_uuid, key, kind, ts, name, target, outcome, duration_ms,
		input_tokens, output_tokens, cost_usd, src_path, src_offset, agent_id, error_class, result_bytes, skill, thinking_tokens)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
	require.NoError(t, err)
	part, err := tx.Prepare(`INSERT INTO agent_log_context_parts (session_uuid, agent_id, part, bytes) VALUES (?,?,?,?)`)
	require.NoError(t, err)
	listed, err := tx.Prepare(`INSERT INTO agent_log_skill_listing (session_uuid, skill, bytes) VALUES (?,?,?)`)
	require.NoError(t, err)
	sub, err := tx.Prepare(`INSERT INTO agent_log_subagents (session_uuid, agent_id, agent_type, depth, finished) VALUES (?,?,?,?,?)`)
	require.NoError(t, err)
	errClasses := []string{"exit_code", "too_large", "not_found", "edit_no_match", "automode-blocked"}
	for day := range 30 {
		for s := range 25 {
			id := fmt.Sprintf("s-%d-%d", day, s)
			path := "/tmp/x/" + id + ".jsonl"
			base := now.AddDate(0, 0, -day).Add(time.Duration(s) * time.Minute)
			_, err := tx.Exec(`INSERT INTO agent_log_files (path, agent, size, mtime, read_offset, parser_version)
				VALUES (?, 'claude', 1, '', 1, 4)`, path)
			require.NoError(t, err)
			_, err = tx.Exec(`INSERT INTO agent_log_sessions (session_uuid, agent, project_id, folder_path, home_cwd, source_path, started_at, ended_at)
				VALUES (?, 'claude', ?, '/w', '/w', ?, ?, ?)`, id, wb, path, base.Format(tsLayout), base.Add(25*time.Minute).Format(tsLayout))
			require.NoError(t, err)
			for _, lane := range []string{"", "a1", "a2"} {
				for j, p := range []string{"system", "tools", "instructions", "skills", "agents", "mcp", "deferred_tools", "hooks"} {
					_, err = part.Exec(id, lane, p, 1000*(j+1))
					require.NoError(t, err)
				}
			}
			for k := range 40 {
				_, err = listed.Exec(id, fmt.Sprintf("skill-%d", k), 120)
				require.NoError(t, err)
			}
			_, err = sub.Exec(id, "a1", "general-purpose", 1, 1)
			require.NoError(t, err)
			_, err = sub.Exec(id, "a2", "Explore", 1, 0)
			require.NoError(t, err)
			for i := range 200 {
				ts := base.Add(time.Duration(i) * 700 * time.Millisecond).Format(tsLayout)
				key := fmt.Sprintf("%s:%d", id, i)
				lane := ""
				if i >= 160 {
					lane = []string{"a1", "a2"}[i%2]
				}
				skill := ""
				if i%20 == 1 {
					skill = fmt.Sprintf("skill-%d", i%7)
				}
				switch i % 5 {
				case 0:
					_, err = ins.Exec(id, key, "owner_turn", ts, "", "", "", nil, 0, 0, 0, path, i, lane, "", nil, "", 0)
				case 1, 2:
					_, err = ins.Exec(id, key, "api_call", ts, "claude-opus-5-5", "", "", nil, 100+i*10, 50, 0.01, path, i, lane, "", nil, skill, 20)
				case 3:
					_, err = ins.Exec(id, key, "tool", ts, "Read", fmt.Sprintf("/w/f%d.go", i%9), "ok", 300, 0, 0, 0, path, i, lane, "", 4000+i, skill, 0)
				default:
					outcome, class := "ok", ""
					if i%15 == 4 {
						outcome, class = "error", errClasses[(i/15)%len(errClasses)]
					}
					_, err = ins.Exec(id, key, "tool", ts, "Bash", "go test ./...", outcome, 300, 0, 0, 0, path, i, lane, class, 2000, skill, 0)
				}
				require.NoError(t, err)
			}
		}
	}
	require.NoError(t, tx.Commit())

	// The fastest of three runs: one slow run on a loaded machine is noise.
	var ov *Overview
	var runs []time.Duration
	for range 3 {
		start := time.Now()
		ov, err = BuildOverview(d.DB, d.al, wb, time.Time{}, now, English)
		runs = append(runs, time.Since(start))
		require.NoError(t, err)
	}
	took := slices.Min(runs)
	assert.Equal(t, 750, ov.Totals.Sessions)
	assert.Equal(t, 750, ov.Context.FactsSessions, "every session has the v3 facts")
	assert.Equal(t, 750, ov.Skills.FactsSessions)
	assert.Equal(t, 750, ov.Trouble.FactsSessions)
	assert.NotEmpty(t, ov.Trouble.Classes, "the trouble block did its work")
	t.Logf("BuildOverview over 150k v3 events: %v (fastest %s)", runs, took)
	assert.Less(t, took, time.Second)
}

// The overview measures the trouble of the v3 sessions only, with their
// subagents, and feeds it to the hints.
func TestBuildOverview_Trouble(t *testing.T) {
	d, wb := buildDB(t)
	at := func(s int) string { return t0.Add(time.Duration(s) * time.Second).Format(tsLayout) }
	extra := []agentlogdb.AgentLogEvent{
		{Kind: "owner_turn", Trigger: "interrupt", TS: at(41)},
		{Kind: "owner_turn", Trigger: "interrupt", TS: at(50)},
		{Kind: "owner_turn", Trigger: "interrupt", TS: at(60)},
		{Kind: "api_error", ErrorClass: "429", TS: at(61)},
	}
	putSessionWith(t, d, wb, "new", 40, 3, extra)
	putSessionWith(t, d, wb, "v2", 40, 2, extra)
	no := false
	for _, sid := range []string{"new", "v2"} {
		_, err := d.al.UpsertAgentSubagent(agentlogdb.AgentSubagent{SessionUUID: sid, AgentID: "a1", Finished: &no})
		require.NoError(t, err)
	}

	ov, err := BuildOverview(d.DB, d.al, wb, time.Time{}, t0.Add(2*time.Hour), English)
	require.NoError(t, err)
	assert.Equal(t, 1, ov.Trouble.FactsSessions)
	assert.Equal(t, 3, ov.Trouble.Interrupts)
	assert.Equal(t, 1, ov.Trouble.RateLimited)
	assert.Equal(t, 1, ov.Trouble.UnfinishedSubagents)
	assert.Equal(t, []SessionCount{{"new", 3}}, ov.Trouble.InterruptSessions)
	require.Len(t, hintsOf(ov.Hints, "T3"), 1)

	det, err := BuildSession(d.DB, d.al, wb, "new", t0.Add(time.Hour), English)
	require.NoError(t, err)
	assert.Len(t, hintsOf(det.Hints, "T3"), 1, "the session's drill-down has the trouble hints too")
}
