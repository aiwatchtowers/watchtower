package sessionstart

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentkind"
	"watchtower/internal/devpack"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/sessionhost"
)

// Go twins of SessionStartHandlerTests' open_existing and default-agent
// tests: the port side of a phone's start, against a real session host.

const existingClaudeID = "00000000-0000-4000-8000-0000000000e1"

// existingSession is a stopped Claude session of target tid in the
// workbench folder.
func (w *world) existingSession(tid int64) int64 {
	w.t.Helper()
	res, err := w.db.Exec(`INSERT INTO terminal_sessions (project_id, target_id, kind, title, folder_path, claude_session_id)
		VALUES (?, ?, 'claude', 'T', ?, ?)`, w.wb, tid, w.folder, existingClaudeID)
	require.NoError(w.t, err)
	id, _ := res.LastInsertId()
	return id
}

func (w *world) sessionCount() int {
	w.t.Helper()
	var n int
	require.NoError(w.t, w.db.QueryRow(`SELECT COUNT(*) FROM terminal_sessions WHERE project_id = ?`, w.wb).Scan(&n))
	return n
}

// twin of SessionStartHandlerTests.testOpenExistingAnswersTheTargetsSession:
// open_existing answers the target's session, which resumes — neither the
// brief nor plan first is sent, and no row is added.
func TestOpenExistingAnswersTheTargetsSession(t *testing.T) {
	w := newWorld(t)
	tid := w.target("Ship it")
	existing := w.existingSession(tid)

	res, err := Start(context.Background(), w.deps(), handlers.StartRequest{
		Workbench: w.wb, Target: ptr(tid), OpenExisting: true, PlanFirst: true, Brief: "Edited",
	})
	require.NoError(t, err)
	assert.Equal(t, existing, res.SessionID)
	assert.Equal(t, StateRunning, res.State)
	assert.Equal(t, 1, w.sessionCount(), "no new row")
	w.launched(existing)
	assert.Equal(t, "--resume\n"+existingClaudeID, w.stubFile("argv", existing), "it resumes, with no prompt")
}

// twin of SessionStartHandlerTests.testOpenExistingNeverPicksAPendingDelete
// (PROJ-17): a session waiting in the Desktop's Undo batch is never reopened
// by the phone's open_existing — a new session starts instead.
func TestOpenExistingNeverPicksAPendingDelete(t *testing.T) {
	w := newWorld(t)
	tid := w.target("Ship it")
	deleted := w.existingSession(tid)
	d := w.deps()
	d.Hidden = func() map[int64]bool { return map[int64]bool{deleted: true} }

	res, err := Begin(context.Background(), d, handlers.StartRequest{Workbench: w.wb, Target: ptr(tid), OpenExisting: true})
	require.NoError(t, err)
	assert.NotEqual(t, deleted, res.SessionID)
	assert.Equal(t, StateStarting, res.State, "a new row, not a reopen")
	assert.Equal(t, 2, w.sessionCount(), "a new row; the hidden one waits for its window")
	_, live := findRun(w.list(), sessionhost.Scope(w.dbPath), deleted)
	assert.False(t, live, "the hidden session is not resumed")
}

// twin of SessionStartHandlerTests.testOpenExistingOnALiveSessionDoesNotWatchTheLaunch:
// a running session is answered as is — no second launch and no launch
// watch.
func TestOpenExistingOnALiveSessionDoesNotWatchTheLaunch(t *testing.T) {
	w := newWorld(t)
	tid := w.target("Ship it")
	first, err := Start(context.Background(), w.deps(), handlers.StartRequest{Workbench: w.wb, Target: ptr(tid)})
	require.NoError(t, err)
	running := w.launched(first.SessionID)

	d := w.deps()
	// A watch of the live launch would hold Start for the hour (the run never
	// ends): Start returning at all says it was not watched.
	d.LaunchWatch = time.Hour
	res, err := Start(context.Background(), d, handlers.StartRequest{Workbench: w.wb, Target: ptr(tid), OpenExisting: true})
	require.NoError(t, err)
	assert.Equal(t, first.SessionID, res.SessionID)
	assert.Equal(t, StateRunning, res.State)
	now, ok := findRun(w.list(), sessionhost.Scope(w.dbPath), first.SessionID)
	require.True(t, ok)
	assert.Equal(t, running.Launch, now.Launch, "no second launch")
	assert.Equal(t, 1, w.sessionCount())
}

// twin of SessionStartHandlerTests.testPhoneStartUsesDefaultAgent (D6, board
// #399): a start that names no agent runs the Mac's default agent; Claude
// stays the default.
func TestPhoneStartUsesDefaultAgent(t *testing.T) {
	w := newWorld(t)
	claude, err := Begin(context.Background(), w.deps(), handlers.StartRequest{Workbench: w.wb, Target: ptr(w.target("Ship it"))})
	require.NoError(t, err)
	assert.Equal(t, "claude", w.row(claude.SessionID).kind)

	codexBin := filepath.Join(w.stub, "bin", "codex")
	writeScript(t, codexBin, "printf ran > '"+w.stub+"/codex.'\"$"+SessionRowEnv+"\"\n")
	d := w.deps()
	d.DefaultAgent = func() agentkind.Kind { return agentkind.Codex }
	d.CodexArgs = func(context.Context, int64) (devpack.LaunchArgs, error) {
		return devpack.LaunchArgs{Binary: codexBin}, nil
	}
	res, err := Start(context.Background(), d, handlers.StartRequest{Workbench: w.wb, Target: ptr(w.target("Ship that")), Place: "folder"})
	require.NoError(t, err)
	r := w.row(res.SessionID)
	assert.Equal(t, "codex", r.kind)
	assert.Empty(t, r.claudeID, "Codex mints its own id")
	eventually(t, "the Codex launch ran", func() bool {
		_, err := os.Stat(filepath.Join(w.stub, "codex."+strconv.FormatInt(res.SessionID, 10)))
		return err == nil
	})
}

// twin of SessionStartHandlerTests.testOpenExistingOnAnUnknownKindIsRefusedNotSupported
// (A7b, main #686): the target's latest session runs an agent kind this
// version does not know (a newer Mac wrote it). open_existing refuses it
// with that kind — the hub answers not_supported — and launches nothing: no
// shell, no Claude Code in its place, and no new session beside it.
func TestOpenExistingOnAnUnknownKindIsRefused(t *testing.T) {
	w := newWorld(t)
	tid := w.target("Ship it")
	w.existingSession(tid)
	ctx := context.Background()
	conn, err := w.db.Conn(ctx)
	require.NoError(t, err)
	_, err = conn.ExecContext(ctx, `PRAGMA ignore_check_constraints = ON`)
	require.NoError(t, err)
	res, err := conn.ExecContext(ctx, `INSERT INTO terminal_sessions (project_id, target_id, kind, title, folder_path, last_active_at)
		VALUES (?, ?, 'gemini', 'Newer', ?, '2999-01-01T00:00:00Z')`, w.wb, tid, w.folder)
	require.NoError(t, err)
	newer, _ := res.LastInsertId()
	_, err = conn.ExecContext(ctx, `PRAGMA ignore_check_constraints = OFF`)
	require.NoError(t, err)
	require.NoError(t, conn.Close())

	_, err = Start(ctx, w.deps(), handlers.StartRequest{Workbench: w.wb, Target: ptr(tid), OpenExisting: true})
	var missing *handlers.AgentNotFoundError
	require.ErrorAs(t, err, &missing)
	assert.Equal(t, "gemini", missing.Agent)
	assert.Equal(t, 2, w.sessionCount(), "no new row")
	_, live := findRun(w.list(), sessionhost.Scope(w.dbPath), newer)
	assert.False(t, live, "nothing launched for the unknown kind")

	// Asked for a named agent, the unknown row is not that agent's: the
	// target's Claude session reopens as before.
	got, err := Start(ctx, w.deps(), handlers.StartRequest{Workbench: w.wb, Target: ptr(tid), OpenExisting: true,
		Agent: string(agentkind.Claude)})
	require.NoError(t, err)
	assert.NotEqual(t, newer, got.SessionID)
}
