package cmd

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/sessionagent"
	"watchtower/internal/sessionfeed"
)

// countStateWrites installs a trigger counting writes of row's agent_state
// stamp; the returned func reads the count.
func countStateWrites(t *testing.T, database *db.DB, row int64) func() int {
	t.Helper()
	_, err := database.Exec(`CREATE TABLE IF NOT EXISTS test_state_writes (n INTEGER)`)
	require.NoError(t, err)
	_, err = database.Exec(`CREATE TRIGGER IF NOT EXISTS test_count_state_writes AFTER UPDATE OF agent_state, agent_state_at, agent_failed_at
		ON terminal_sessions WHEN NEW.id = ` + jsonInt(row) + ` BEGIN INSERT INTO test_state_writes VALUES (1); END`)
	require.NoError(t, err)
	return func() int {
		var n int
		require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM test_state_writes`).Scan(&n))
		return n
	}
}

func jsonInt(n int64) string { b, _ := json.Marshal(n); return string(b) }

// The session host's watch (openCodexWatchStore + recordCodexPull) and the
// app's bridge (`workbench session-probe`) reading the same failed turn
// write it once: both go through recordAgentState over `working`, stamped
// with the rollout line's time; whichever comes second writes nothing.
func TestProj11_HostAndBridgeReportSameFailureOnce(t *testing.T) {
	for _, hostFirst := range []bool{true, false} {
		name := "bridge first"
		if hostFirst {
			name = "host first"
		}
		t.Run(name, func(t *testing.T) {
			database, pid, row := codexRowFixture(t, codexTUISession)
			home := codexHomeFixture(t)
			storeCodexState(t, database, pid, row, codexTUISession, agentStateWorking)
			at := time.Now().UTC().Truncate(time.Millisecond)
			writeCodexRollout(t, home, codexTUISession,
				codexTurnLine(at, "task_started", ""), codexTurnLine(at, "task_complete", "usage_limit_exceeded"))
			writes := countStateWrites(t, database, row)

			store, err := openCodexWatchStore(dbPathOf(t, database))
			require.NoError(t, err)
			t.Cleanup(func() { _ = store.Close() })
			host := func() {
				r, err := store.Row(row)
				require.NoError(t, err)
				path, ok := sessionfeed.LocateCodex(home, r.SessionID, r.TranscriptPath)
				require.True(t, ok)
				turn, err := sessionfeed.CodexLastTurn(path)
				require.NoError(t, err)
				require.NoError(t, store.RecordTurn(r, turn))
			}
			bridge := func() { runSessionProbe(t, pid, row) }
			if hostFirst {
				host()
				bridge()
			} else {
				bridge()
				host()
			}

			assert.Equal(t, 1, writes(), "one state write for one failed turn")
			s := codexRow(t, database, row)
			assert.Equal(t, agentStateWaiting, s.AgentState.String)
			require.NotNil(t, s.AgentFailure)
			assert.Equal(t, "usage_limit_exceeded", s.AgentFailure.Error)
			assert.Equal(t, db.AgentStateStamp(at), s.AgentFailure.At)
		})
	}
}

// dbPathOf is the file of database.
func dbPathOf(t *testing.T, database *db.DB) string {
	t.Helper()
	var seq int
	var name, file string
	require.NoError(t, database.QueryRow(`PRAGMA database_list`).Scan(&seq, &name, &file))
	return file
}

// The host's pull also ends an interrupted turn (turn_aborted) as the
// Interrupt hook does: a plain `waiting`, no error.
func TestProj11_HostPullEndsAnAbortedTurnAsWaiting(t *testing.T) {
	database, pid, row := codexRowFixture(t, codexTUISession)
	storeCodexState(t, database, pid, row, codexTUISession, agentStateWorking)
	at := time.Now().UTC().Truncate(time.Millisecond)
	pull := db.CodexWatchRow{ID: row, WorkbenchID: pid, Kind: "codex", SessionID: codexTUISession}
	require.NoError(t, recordCodexPull(database, pull, sessionfeed.CodexTurn{Aborted: true, At: at}))
	s := codexRow(t, database, row)
	assert.Equal(t, agentStateWaiting, s.AgentState.String)
	assert.Nil(t, s.AgentFailure)

	// An older abort over a newer turn writes nothing.
	_, err := database.Exec(`UPDATE terminal_sessions SET agent_state = 'working', agent_state_at = ? WHERE id = ?`,
		db.AgentStateStamp(at.Add(time.Minute)), row)
	require.NoError(t, err)
	require.NoError(t, recordCodexPull(database, pull, sessionfeed.CodexTurn{Aborted: true, At: at.Add(time.Second)}))
	assert.Equal(t, agentStateWorking, codexRow(t, database, row).AgentState.String)
}

// Any hook event of the row's session clears its watch issue, so the
// session host's watch re-arms; another session's event does not.
func TestProj11_NextHookEventClearsWatchIssue(t *testing.T) {
	database, pid, row := codexRowFixture(t, codexTUISession)
	storeCodexState(t, database, pid, row, codexTUISession, agentStateWorking)
	mark := func() {
		t.Helper()
		_, err := database.Exec(`UPDATE terminal_sessions SET agent_watch_issue = 'missing', agent_watch_issue_at = ? WHERE id = ?`,
			db.AgentStateStamp(time.Now()), row)
		require.NoError(t, err)
	}
	issue := func() string {
		t.Helper()
		var v sql.NullString
		require.NoError(t, database.QueryRow(`SELECT agent_watch_issue FROM terminal_sessions WHERE id = ?`, row).Scan(&v))
		return v.String
	}

	mark()
	_, _ = runCodexHook(t, codexPayload(t, "post_tool_use", map[string]any{"session_id": codexExecSession}),
		"session-state", "--agent", "codex")
	assert.Equal(t, "missing", issue(), "a foreign session's event")

	for _, name := range []string{"post_tool_use", "user_prompt_submit", "interrupt", "permission_request"} {
		mark()
		runCodexState(t, string(codexHookFixture(t, name)))
		assert.Empty(t, issue(), name)
	}

	mark()
	runCodexBriefHook(t, string(codexHookFixture(t, "session_start_resume")))
	assert.Empty(t, issue(), "SessionStart")

	// A compaction of the current session with nothing else to store (same
	// id, same path) is a hook event too.
	runCodexBriefHook(t, string(codexHookFixture(t, "session_start_compact")))
	mark()
	runCodexBriefHook(t, string(codexHookFixture(t, "session_start_compact")))
	assert.Empty(t, issue(), "a no-op SessionStart (compact)")
}

// The bridge marks a rollout it cannot read for good at once (spec §3.5):
// a compressed one that does not decode is `compressed`; outcome
// not_watched, one stderr line with the class and no path.
func TestSessionProbe_CodexUndecodableCompressedRolloutIsNotWatched(t *testing.T) {
	database, pid, row := codexRowFixture(t, codexTUISession)
	home := codexHomeFixture(t)
	storeCodexState(t, database, pid, row, codexTUISession, agentStateWorking)
	writeCodexRollout(t, home, codexTUISession, "x")
	p := filepath.Join(home, "sessions", "2026", "11", "05", "rollout-2026-11-05T12-00-00-"+codexTUISession+".jsonl")
	require.NoError(t, os.WriteFile(p, append([]byte{0x28, 0xb5, 0x2f, 0xfd}, []byte("not a frame")...), 0o600))

	got, logged := runSessionProbeLogged(t, pid, row)

	assert.Equal(t, probeNotWatched, got["outcome"])
	assert.Contains(t, logged, "not watched (compressed)")
	assert.NotContains(t, logged, home)
	var v sql.NullString
	require.NoError(t, database.QueryRow(`SELECT agent_watch_issue FROM terminal_sessions WHERE id = ?`, row).Scan(&v))
	assert.Equal(t, "compressed", v.String)

	// Marked: a second probe writes nothing more.
	got, _ = runSessionProbeLogged(t, pid, row)
	assert.Equal(t, probeNotStale, got["outcome"])
}

// The bridge follows the watch's give-ups without its ticks (spec §3.5):
// a rollout missing while the row has worked 30 s is `missing`, and an
// undecodable tail on a file unchanged for three watch ticks is
// `unreadable`; a younger row or a fresher file is left alone.
func TestSessionProbe_CodexBridgeGivesUpOnMissingAndUnreadable(t *testing.T) {
	issue := func(database *db.DB, row int64) string {
		var v sql.NullString
		require.NoError(t, database.QueryRow(`SELECT agent_watch_issue FROM terminal_sessions WHERE id = ?`, row).Scan(&v))
		return v.String
	}
	setStateAt := func(database *db.DB, row int64, at time.Time) {
		_, err := database.Exec(`UPDATE terminal_sessions SET agent_state_at = ? WHERE id = ?`, db.AgentStateStamp(at), row)
		require.NoError(t, err)
	}

	t.Run("missing", func(t *testing.T) {
		database, pid, row := codexRowFixture(t, codexTUISession)
		codexHomeFixture(t)
		storeCodexState(t, database, pid, row, codexTUISession, agentStateWorking)
		_, err := database.Exec(`UPDATE terminal_sessions SET agent_transcript_path = ? WHERE id = ?`,
			filepath.Join(t.TempDir(), "rollout-gone.jsonl"), row)
		require.NoError(t, err)

		setStateAt(database, row, time.Now().Add(-10*time.Second))
		assert.Equal(t, probeNotStale, runSessionProbe(t, pid, row)["outcome"])
		assert.Empty(t, issue(database, row), "missing for under 30 s")

		setStateAt(database, row, time.Now().Add(-time.Minute))
		got, logged := runSessionProbeLogged(t, pid, row)
		assert.Equal(t, probeNotWatched, got["outcome"])
		assert.Contains(t, logged, "not watched (missing)")
		assert.NotContains(t, logged, "rollout-gone")
		assert.Equal(t, db.WatchIssueMissing, issue(database, row))
	})

	t.Run("unreadable", func(t *testing.T) {
		database, pid, row := codexRowFixture(t, codexTUISession)
		home := codexHomeFixture(t)
		storeCodexState(t, database, pid, row, codexTUISession, agentStateWorking)
		writeCodexRollout(t, home, codexTUISession, codexTurnLine(time.Now(), "task_started", ""), "{not json")
		p := filepath.Join(home, "sessions", "2026", "11", "05", "rollout-2026-11-05T12-00-00-"+codexTUISession+".jsonl")

		assert.Equal(t, probeNotStale, runSessionProbe(t, pid, row)["outcome"])
		assert.Empty(t, issue(database, row), "a fresh undecodable tail waits")

		old := time.Now().Add(-time.Minute)
		require.NoError(t, os.Chtimes(p, old, old))
		got, _ := runSessionProbeLogged(t, pid, row)
		assert.Equal(t, probeNotWatched, got["outcome"])
		assert.Equal(t, db.WatchIssueUnreadable, issue(database, row))
	})
}

// S6: a codex row's stale background count is judged from its rollout's
// subagent lifecycle: busy while one still runs (the count stays), idle
// once every one finished (it ends).
func TestSessionProbe_CodexStaleCountReadsTheRollout(t *testing.T) {
	const child = "019a0000-0000-7000-8000-0000000000c1"
	spawn := func(at time.Time, status string) string {
		b, _ := json.Marshal(map[string]any{"timestamp": at.UTC().Format("2006-01-02T15:04:05.000Z"), "type": "event_msg",
			"payload": map[string]any{"type": "collab_agent_spawn_end", "new_thread_id": child, "call_id": "c1",
				"prompt": "look", "status": status}})
		return string(b)
	}
	for _, c := range []struct {
		status, want string
		ended        bool
	}{
		{"running", probeBusy, false},
		{"completed", probeIdle, true},
	} {
		t.Run(c.status, func(t *testing.T) {
			database, pid, row := codexRowFixture(t, codexTUISession)
			home := codexHomeFixture(t)
			ok, err := database.SetTerminalAgentState(row, pid, codexTUISession, agentStateWaiting, time.Now().Add(-time.Hour), "",
				nil, false, db.AgentOrder{Stop: true, Background: sql.NullInt64{Int64: 1, Valid: true}})
			require.NoError(t, err)
			require.True(t, ok)
			at := time.Now().Add(-40 * time.Minute)
			writeCodexRollout(t, home, codexTUISession, codexTurnLine(at, "task_started", ""), spawn(at, c.status))

			got := runSessionProbe(t, pid, row)

			assert.Equal(t, c.want, got["outcome"])
			assert.Equal(t, c.ended, got["ended"])
		})
	}
}

// A host binary never migrates the file it watches: a real database from
// before migration 00173 (no watch columns) is refused, and the file is
// left as it was, still without the columns and at the same goose version.
// A missing file is refused without being created.
func TestCodexWatch_PreWatchDatabaseIsRefusedAndNotMigrated(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watchtower.db")
	database, err := db.Open(path)
	require.NoError(t, err)
	for _, stmt := range []string{
		`ALTER TABLE terminal_sessions DROP COLUMN agent_watch_issue_at`,
		`ALTER TABLE terminal_sessions DROP COLUMN agent_watch_issue`,
		`DELETE FROM goose_db_version WHERE version_id >= 173`,
	} {
		_, err := database.Exec(stmt)
		require.NoError(t, err, stmt)
	}
	require.NoError(t, database.Close())
	gooseVersion := func() int64 {
		d, err := db.OpenExistingRW(path, time.Second)
		require.NoError(t, err)
		defer func() { _ = d.Close() }()
		var v int64
		require.NoError(t, d.QueryRow(`SELECT MAX(version_id) FROM goose_db_version`).Scan(&v))
		has, err := d.HasColumns("terminal_sessions", "agent_watch_issue")
		require.NoError(t, err)
		assert.False(t, has, "the watch column came back")
		return v
	}
	before := gooseVersion()
	require.Less(t, before, int64(173))

	store, err := openCodexWatchStore(path)
	require.Error(t, err)
	assert.Nil(t, store)
	assert.Contains(t, err.Error(), "no watch columns")
	assert.Equal(t, before, gooseVersion(), "the host migrated the file")

	missing := filepath.Join(t.TempDir(), "absent.db")
	_, err = openCodexWatchStore(missing)
	require.Error(t, err)
	assert.NotContains(t, err.Error(), missing, "FILES-01: the error names no path")
	_, statErr := os.Stat(missing)
	assert.ErrorIs(t, statErr, os.ErrNotExist, "the host created the missing file")
}

// The pull write resolves its reader from the row's kind: a kind whose turn
// ends are not pulled is an error, never codex's reader in disguise.
func TestProj11_PullRecordResolvesTheRowKind(t *testing.T) {
	database, pid, row := codexRowFixture(t, codexTUISession)
	storeCodexState(t, database, pid, row, codexTUISession, agentStateWorking)
	turn := sessionfeed.CodexTurn{Aborted: true, At: time.Now().UTC()}
	for _, kind := range []string{"claude", ""} {
		pull := db.CodexWatchRow{ID: row, WorkbenchID: pid, Kind: kind, SessionID: codexTUISession}
		require.Error(t, recordCodexPull(database, pull, turn), "kind %q", kind)
	}
	assert.Equal(t, agentStateWorking, codexRow(t, database, row).AgentState.String)
}

// The kinds a not-watched mark may land on are the agents whose turn ends
// are pulled, and the db tests' list is that list.
func TestProj11_WatchKindsArePulledKinds(t *testing.T) {
	for _, k := range sessionagent.RolloutWatchKinds() {
		_, pulls := sessionagent.PullerOf(k)
		assert.True(t, pulls, k)
	}
	assert.Equal(t, []string{"codex"}, sessionagent.RolloutWatchKinds(), "db's testWatchKinds")
}

// The bridge mirrors the host's watch on an interrupted turn (spec §3.5):
// a plain `waiting`, no error, no watch issue.
func TestSessionProbe_CodexBridgeAbortedTurnIsWaiting(t *testing.T) {
	database, pid, row := codexRowFixture(t, codexTUISession)
	home := codexHomeFixture(t)
	storeCodexState(t, database, pid, row, codexTUISession, agentStateWorking)
	at := time.Now().UTC().Add(time.Second).Truncate(time.Millisecond)
	writeCodexRollout(t, home, codexTUISession, codexTurnLine(at, "task_started", ""), codexTurnLine(at, "turn_aborted", ""))

	runSessionProbe(t, pid, row)
	s := codexRow(t, database, row)
	assert.Equal(t, agentStateWaiting, s.AgentState.String)
	assert.Equal(t, db.AgentStateStamp(at), db.AgentStateStamp(s.AgentStateAt))
	assert.Nil(t, s.AgentFailure)
	var issue sql.NullString
	require.NoError(t, database.QueryRow(`SELECT agent_watch_issue FROM terminal_sessions WHERE id = ?`, row).Scan(&issue))
	assert.False(t, issue.Valid)
}
