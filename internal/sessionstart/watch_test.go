package sessionstart

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentkind"
	"watchtower/internal/devpack"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/sessionhost"
)

// codexDeps is w.deps() with a stub codex as the default agent.
func (w *world) codexDeps() Deps {
	w.t.Helper()
	codexBin := filepath.Join(w.stub, "bin", "codex")
	writeScript(w.t, codexBin, "printf ran > '"+w.stub+"/codex.'\"$"+SessionRowEnv+"\"\nexec cat > /dev/null\n")
	d := w.deps()
	d.DefaultAgent = func() agentkind.Kind { return agentkind.Codex }
	d.CodexArgs = func(context.Context, int64) (devpack.LaunchArgs, error) {
		return devpack.LaunchArgs{Binary: codexBin}, nil
	}
	return d
}

func (w *world) codexRan(row int64) {
	w.t.Helper()
	eventually(w.t, "the Codex launch ran", func() bool {
		_, err := os.Stat(filepath.Join(w.stub, "codex."+strconv.FormatInt(row, 10)))
		return err == nil
	})
}

// Main's G5 (spec 2026-11-05 §3.5), TerminalCenter.watchSpec's Go twin: a
// session Go starts for an agent whose turn ends are read from its rollout
// (Codex) asks the host to watch it in the workspace database, so the host
// lists the run Watched and the Desktop adopts it as host-watched; Claude
// Code asks nothing.
func TestCodexStartAsksTheHostToWatchItsRollout(t *testing.T) {
	w := newWorld(t)
	claude, err := Start(context.Background(), w.deps(), handlers.StartRequest{Workbench: w.wb, Brief: "claude", Place: "folder"})
	require.NoError(t, err)
	info := w.launched(claude.SessionID)
	assert.False(t, info.Watched, "Claude Code is not rollout-watched")
	assert.Empty(t, w.watchRequests())

	codex, err := Start(context.Background(), w.codexDeps(), handlers.StartRequest{Workbench: w.wb, Brief: "codex", Place: "folder"})
	require.NoError(t, err)
	w.codexRan(codex.SessionID)
	info, ok := findRun(w.list(), sessionhost.Scope(w.dbPath), codex.SessionID)
	require.True(t, ok)
	assert.True(t, info.Watched, "the host watches the Codex run")
	assert.Equal(t, []string{w.dbPath}, w.watchRequests())
}

// The same on reopen: a target's stopped Codex session that the phone's
// open_existing relaunches is watched too.
func TestCodexReopenAsksTheHostToWatchItsRollout(t *testing.T) {
	w := newWorld(t)
	tid := w.target("Ship it")
	res, err := w.db.Exec(`INSERT INTO terminal_sessions (project_id, target_id, kind, title, folder_path)
		VALUES (?, ?, 'codex', 'T', ?)`, w.wb, tid, w.folder)
	require.NoError(t, err)
	existing, _ := res.LastInsertId()

	got, err := Start(context.Background(), w.codexDeps(), handlers.StartRequest{Workbench: w.wb, Target: ptr(tid), OpenExisting: true})
	require.NoError(t, err)
	assert.Equal(t, existing, got.SessionID)
	w.codexRan(existing)
	info, ok := findRun(w.list(), sessionhost.Scope(w.dbPath), existing)
	require.True(t, ok)
	assert.True(t, info.Watched)
	assert.Equal(t, []string{w.dbPath}, w.watchRequests())
}

// A7b, placement half (main #686, TerminalCenter.liveAgentIDs'
// mayRunAgent): a live run of a kind this version does not know (a newer
// version's, adopted from the host) may be an agent in the folder, so an
// auto start goes into its own worktree.
func TestALiveRunOfAnUnknownKindOccupiesTheFolder(t *testing.T) {
	w := newWorld(t)
	first, err := Start(context.Background(), w.deps(), handlers.StartRequest{Workbench: w.wb, Brief: "first"})
	require.NoError(t, err)
	w.launched(first.SessionID)
	ctx := context.Background()
	conn, err := w.db.Conn(ctx)
	require.NoError(t, err)
	_, err = conn.ExecContext(ctx, `PRAGMA ignore_check_constraints = ON`)
	require.NoError(t, err)
	_, err = conn.ExecContext(ctx, `UPDATE terminal_sessions SET kind = 'gemini' WHERE id = ?`, first.SessionID)
	require.NoError(t, err)
	_, err = conn.ExecContext(ctx, `PRAGMA ignore_check_constraints = OFF`)
	require.NoError(t, err)
	require.NoError(t, conn.Close())

	second, err := Start(ctx, w.deps(), handlers.StartRequest{Workbench: w.wb, Brief: "second"})
	require.NoError(t, err)
	w.launched(second.SessionID)
	assert.Equal(t, "wt/session-2", w.row(second.SessionID).branch, "the unknown kind's live run occupies the folder")
}
