package sessionstart

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentkind"
	"watchtower/internal/aiconsent"
	"watchtower/internal/aiconsent/aiconsenttest"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/sessionfeed"
	"watchtower/internal/sessionhost"
)

// world is a real in-process session-host on its own socket, a workspace
// database with one workbench (a git repository) and stub agents: the login
// shell stub drops -l and runs the -c command under /bin/sh with a PATH whose
// first entry holds a stub `claude`. The stub records its argv and cwd,
// turns bracketed paste on and appends every byte its PTY gives it to
// pty.<row>, so that file is exactly what reached the session. Every hosted
// process group is killed and reaped before the host stops.
type world struct {
	t      *testing.T
	db     *db.DB
	socket string
	dbPath string
	stub   string
	shell  string
	wb     int64
	folder string

	mu         sync.Mutex
	integrated []string
	// watched is every database a launch asked the host to watch
	// (Options.CodexWatch), in order.
	watched []string
}

func newWorld(t *testing.T) *world {
	t.Helper()
	w := &world{t: t, db: db.OpenTestDB(t)}
	dir, err := os.MkdirTemp("", "ss")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	w.socket = filepath.Join(dir, "h.sock")
	w.stub = t.TempDir()
	w.dbPath = filepath.Join(t.TempDir(), "watchtower.db")
	bin := filepath.Join(w.stub, "bin")
	require.NoError(t, os.MkdirAll(bin, 0o700))
	w.shell = filepath.Join(w.stub, "loginshell")
	writeScript(t, w.shell, "PATH='"+bin+":/usr/bin:/bin'; export PATH\nshift\nexec /bin/sh \"$@\"\n")
	writeScript(t, filepath.Join(bin, "claude"), "out='"+w.stub+"'\nrow=\"$"+SessionRowEnv+"\"\n"+
		// Each file is written aside and renamed in, so a test that sees it
		// sees all of it (a test polling for a file read it empty in CI).
		"put() { cat > \"$out/$1.$row.tmp\" && mv \"$out/$1.$row.tmp\" \"$out/$1.$row\"; }\n"+
		"printf '%s\\n' \"$@\" | put argv\npwd -P | put cwd\n"+
		"printf '%s\\n%s' \"$"+aiconsent.EnvOrigin+"\" \"$"+aiconsent.EnvAdmitted+"\" | put origin\n"+
		"printf '%s' \"$"+AutomationRunEnv+"\" | put run\n"+
		"stty raw -echo\nprintf '\\033[?2004h'\nexec cat >> \"$out/pty.$row\"\n")

	l, err := sessionhost.Listen(w.socket)
	require.NoError(t, err)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- sessionhost.NewServer(sessionhost.Options{CodexWatch: w.codexWatch}).Serve(ctx, l) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})
	t.Cleanup(w.reapAll) // runs before the host stops

	folder := newRepo(t, true)
	w.wb, err = w.db.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	require.NoError(t, w.db.QueryRow(`SELECT folder_path FROM projects WHERE id = ?`, w.wb).Scan(&w.folder))
	return w
}

// codexWatch is the host's watch store opener: it records the database a
// launch named and opens a store whose row is gone, so the watch starts
// (the run lists Watched) and ends at its first read.
func (w *world) codexWatch(dbPath string) (sessionhost.CodexWatchStore, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.watched = append(w.watched, dbPath)
	return goneWatchStore{}, nil
}

func (w *world) watchRequests() []string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return slices.Clone(w.watched)
}

// goneWatchStore is a watch store whose row no longer exists.
type goneWatchStore struct{}

func (goneWatchStore) Row(int64) (db.CodexWatchRow, error) {
	return db.CodexWatchRow{}, db.ErrTerminalSessionNotFound
}
func (goneWatchStore) RecordTurn(db.CodexWatchRow, sessionfeed.CodexTurn) error { return nil }
func (goneWatchStore) SetIssue(db.CodexWatchRow, string, time.Time) (bool, error) {
	return false, nil
}
func (goneWatchStore) Close() error { return nil }

func writeScript(t *testing.T, path, body string) {
	t.Helper()
	require.NoError(t, os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o700))
}

func (w *world) deps() Deps {
	return Deps{
		DB: w.db, Socket: w.socket, CLIPath: "/usr/bin/false", DBPath: w.dbPath, Shell: w.shell,
		Integrate: func(_ context.Context, _ int64, folder string, _ agentkind.Kind) error {
			w.mu.Lock()
			defer w.mu.Unlock()
			w.integrated = append(w.integrated, folder)
			return nil
		},
	}
}

func (w *world) client() *sessionhost.Client {
	w.t.Helper()
	c, err := sessionhost.Dial(context.Background(), w.socket)
	require.NoError(w.t, err)
	w.t.Cleanup(func() { _ = c.Close() })
	return c
}

func (w *world) list() []sessionhost.SessionInfo {
	w.t.Helper()
	c, err := sessionhost.Dial(context.Background(), w.socket)
	require.NoError(w.t, err)
	defer func() { _ = c.Close() }()
	l, err := c.List(context.Background())
	require.NoError(w.t, err)
	return l
}

// reapAll kills every hosted process group and waits until each is gone.
// droppingSocket is a host that cannot be reached: it hangs up on every
// connection before Hello, so Ensure gives up without starting a host (an
// absent socket would start one, on Linux through the real systemd-run).
func droppingSocket(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "ss")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	path := filepath.Join(dir, "drop.sock")
	l, err := net.Listen("unix", path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = l.Close() })
	go func() {
		for {
			nc, err := l.Accept()
			if err != nil {
				return
			}
			_ = nc.Close()
		}
	}()
	return path
}

func (w *world) reapAll() {
	c, err := sessionhost.Dial(context.Background(), w.socket)
	if err != nil {
		return
	}
	defer func() { _ = c.Close() }()
	list, err := c.List(context.Background())
	if err != nil {
		return
	}
	for _, info := range list {
		if info.Pid <= 0 || info.Exited {
			continue
		}
		_ = syscall.Kill(-info.Pid, syscall.SIGKILL)
		for syscall.Kill(info.Pid, 0) == nil { // until the host reaped it
			time.Sleep(10 * time.Millisecond)
		}
	}
}

// launched waits until the host runs row and its stub is up (paste mode on).
func (w *world) launched(row int64) sessionhost.SessionInfo {
	w.t.Helper()
	var got sessionhost.SessionInfo
	eventually(w.t, "session "+strconv.FormatInt(row, 10)+" launched", func() bool {
		info, ok := findRun(w.list(), sessionhost.Scope(w.dbPath), row)
		got = info
		// The stub renames cwd.N in whole: once it exists, it is written.
		_, err := os.Stat(filepath.Join(w.stub, "cwd."+strconv.FormatInt(row, 10)))
		return ok && !info.Exited && err == nil
	})
	return got
}

func (w *world) pty(row int64) string {
	b, _ := os.ReadFile(filepath.Join(w.stub, "pty."+strconv.FormatInt(row, 10)))
	return string(b)
}

func (w *world) waitPTY(row int64, want string) {
	w.t.Helper()
	eventually(w.t, "pty "+strconv.Quote(want), func() bool { return w.pty(row) == want })
}

func (w *world) stubFile(name string, row int64) string {
	w.t.Helper()
	b, err := os.ReadFile(filepath.Join(w.stub, name+"."+strconv.FormatInt(row, 10)))
	require.NoError(w.t, err)
	return strings.TrimSpace(string(b))
}

func (w *world) target(text string) int64 {
	w.t.Helper()
	res, err := w.db.Exec(`INSERT INTO targets (text, period_start, period_end, project_id) VALUES (?, '2026-01-01', '2026-12-31', ?)`, text, w.wb)
	require.NoError(w.t, err)
	id, _ := res.LastInsertId()
	return id
}

type sessionRow struct {
	kind, title, folder, branch, claudeID, agentState, agentError string
	failed, failedAtState                                         bool
	target                                                        sql.NullInt64
}

func (w *world) row(id int64) sessionRow {
	w.t.Helper()
	var r sessionRow
	var claude, state, stateAt, failedAt sql.NullString
	require.NoError(w.t, w.db.QueryRow(`SELECT kind, title, folder_path, COALESCE(worktree_branch, ''), claude_session_id,
		agent_state, agent_state_at, agent_failed_at, agent_error, target_id FROM terminal_sessions WHERE id = ?`, id).
		Scan(&r.kind, &r.title, &r.folder, &r.branch, &claude, &state, &stateAt, &failedAt, &r.agentError, &r.target))
	r.claudeID, r.agentState = claude.String, state.String
	r.failed = failedAt.Valid
	r.failedAtState = failedAt.Valid && failedAt.String == stateAt.String
	return r
}

// eventually checks ok until it holds — for what a stub process or the
// session host writes on its own. No deadline: go test -timeout bounds a
// broken run.
func eventually(t *testing.T, _ string, ok func() bool) {
	t.Helper()
	for !ok() {
		time.Sleep(20 * time.Millisecond)
	}
}

func ptr(v int64) *int64 { return &v }

// realPath is path with its symlinks resolved (the stub records `pwd -P`).
func realPath(t *testing.T, path string) string {
	t.Helper()
	r, err := filepath.EvalSymlinks(path)
	require.NoError(t, err)
	return r
}

// Instant start (#942): Begin writes the row in the workbench folder and
// answers starting before anything is placed or launched; Finish, rebuilt
// from the row, launches it.
func TestSessionStartReturnsTheRowAtOnceInStarting(t *testing.T) {
	w := newWorld(t)
	tid := w.target("Ship the thing")
	res, err := Begin(context.Background(), w.deps(), handlers.StartRequest{Workbench: w.wb, Target: ptr(tid)})
	require.NoError(t, err)
	assert.Equal(t, StateStarting, res.State)
	r := w.row(res.SessionID)
	assert.Equal(t, sessionRow{kind: "claude", title: "Ship the thing", folder: w.folder, claudeID: r.claudeID,
		target: sql.NullInt64{Int64: tid, Valid: true}}, r)
	assert.True(t, IsValidSessionID(r.claudeID))
	_, live := findRun(w.list(), sessionhost.Scope(w.dbPath), res.SessionID)
	assert.False(t, live, "nothing launched before the return")

	require.True(t, beginTarget(tid))
	_, err = Start(context.Background(), w.deps(), handlers.StartRequest{Workbench: w.wb, Target: ptr(tid)})
	assert.ErrorIs(t, err, handlers.ErrStartInProgress, "a second start of a target still starting is refused")
	endTarget(tid)

	require.NoError(t, Finish(context.Background(), w.deps(), res.SessionID, "auto", "", false))
	w.launched(res.SessionID)
	assert.Error(t, Finish(context.Background(), w.deps(), res.SessionID, "auto", "", false), "a launched row is not launched twice")
	argv := w.stubFile("argv", res.SessionID)
	assert.Equal(t, "--session-id\n"+r.claudeID+"\n"+WorkOnPrompt(tid, false, true), argv)
	assert.Equal(t, realPath(t, w.folder), w.stubFile("cwd", res.SessionID))
}

// A live agent already works in the folder: the next start goes into its
// own worktree (wt/session-2), integrated, and the row is moved there.
func TestSessionStartOwnWorktreeWhenAnAgentWorksInTheFolder(t *testing.T) {
	w := newWorld(t)
	first, err := Start(context.Background(), w.deps(), handlers.StartRequest{Workbench: w.wb, Brief: "first"})
	require.NoError(t, err)
	assert.Equal(t, StateRunning, first.State)
	w.launched(first.SessionID)
	assert.Equal(t, w.folder, w.row(first.SessionID).folder)

	second, err := Start(context.Background(), w.deps(), handlers.StartRequest{Workbench: w.wb, Brief: "second", PlanFirst: true})
	require.NoError(t, err)
	w.launched(second.SessionID)
	r := w.row(second.SessionID)
	assert.Equal(t, "wt/session-2", r.branch)
	assert.Equal(t, filepath.Join(realPath(t, w.folder), ".claude", "worktrees", "session-2"), realPath(t, r.folder))
	assert.Equal(t, []string{r.folder}, w.integrated, "the new worktree gets the integration")
	assert.Equal(t, realPath(t, r.folder), w.stubFile("cwd", second.SessionID))
	assert.Contains(t, w.stubFile("argv", second.SessionID), "second "+PlanFirstSuffix)

	folder, err := Start(context.Background(), w.deps(), handlers.StartRequest{Workbench: w.wb, Brief: "third", Place: "folder"})
	require.NoError(t, err)
	assert.Equal(t, w.folder, w.row(folder.SessionID).folder, "folder is honoured even with an agent there")
}

// Review Focus 5: a launch the host refuses leaves Starting… as a failed
// waiting with the reason in agent_error; nothing is removed.
func TestSessionStartLaunchFailureMarksTheRow(t *testing.T) {
	w := newWorld(t)
	d := w.deps()
	d.Shell = filepath.Join(w.stub, "no-such-shell")
	res, err := Start(context.Background(), d, handlers.StartRequest{Workbench: w.wb, Brief: "go"})
	require.Error(t, err)
	assert.Equal(t, StateFailed, res.State)
	r := w.row(res.SessionID)
	assert.Equal(t, "waiting", r.agentState)
	assert.True(t, r.failedAtState, "agent_failed_at = agent_state_at: a failure")
	assert.True(t, strings.HasPrefix(r.agentError, "launch refused: "), r.agentError)
	assert.Equal(t, w.folder, r.folder)
	assert.DirExists(t, w.folder)
}

// The worktree made before a refused launch stays on disk and the row still
// holds it by record, so `workbench cleanup` lists it (PlacedSessions is its
// listing).
func TestFailedStartKeepsItsWorktree(t *testing.T) {
	w := newWorld(t)
	d := w.deps()
	d.Shell = filepath.Join(w.stub, "no-such-shell")
	tid := w.target("Fix the bug")
	res, err := Start(context.Background(), d, handlers.StartRequest{Workbench: w.wb, Target: ptr(tid), Place: "worktree"})
	require.Error(t, err)
	r := w.row(res.SessionID)
	want := "wt/" + strconv.FormatInt(tid, 10) + "-fix-the-bug"
	assert.Equal(t, want, r.branch)
	assert.DirExists(t, r.folder)
	placed, err := w.db.PlacedSessions(w.wb)
	require.NoError(t, err)
	assert.Equal(t, []db.PlacedSession{{ID: res.SessionID, FolderPath: r.folder, Branch: want}}, placed)
}

// With WATCHTOWER_SESSION_HOST_SOCKET set and no socket given, the start
// reaches that host, never the default path.
func TestSessionStartUsesTheOverrideSocket(t *testing.T) {
	w := newWorld(t)
	t.Setenv(sessionhost.SocketEnv, w.socket)
	d := w.deps()
	d.Socket = ""
	socket, err := d.socket()
	require.NoError(t, err)
	assert.Equal(t, w.socket, socket)
	assert.NotEqual(t, sessionhost.SocketPath(sessionhost.BundleID, os.TempDir()), socket)
	res, err := Start(context.Background(), d, handlers.StartRequest{Workbench: w.wb, Brief: "go"})
	require.NoError(t, err)
	w.launched(res.SessionID)
}

// A Linux host start that systemd-run refused keeps its class in the row's
// reason (and so in the phone's echo); any other failure keeps the plain one.
func TestHostDownReasonKeepsTheUserManagerClass(t *testing.T) {
	um := fmt.Errorf("the session host is not running: %w", &sessionhost.UserManagerError{Class: "no_user_bus"})
	assert.Equal(t, "the session host is not running: no systemd user manager (no_user_bus)", hostDownReason(um))
	assert.Equal(t, "the session host is not running", hostDownReason(errors.New("dial: connection reset")))
}

// A stop is the host's Stop request: the attached pane sees an Exit with
// requested: true, and the run is forgotten after it.
func TestSessionStopIsAHostStopRequest(t *testing.T) {
	w := newWorld(t)
	res, err := Start(context.Background(), w.deps(), handlers.StartRequest{Workbench: w.wb, Brief: "go"})
	require.NoError(t, err)
	info := w.launched(res.SessionID)
	pane := attach(t, w.socket, info)

	p := NewPort(w.deps(), nil)
	t.Cleanup(func() { _ = p.Close() })
	require.NoError(t, p.Stop(context.Background(), res.SessionID))
	exit := pane.until(sessionhost.Exit)
	var m sessionhost.ExitMsg
	require.NoError(t, json.Unmarshal(exit, &m))
	assert.True(t, m.Requested, "the exit of an owner's stop carries requested")
	_, still := findRun(w.list(), sessionhost.Scope(w.dbPath), res.SessionID)
	assert.False(t, still, "forgotten after the exit")
	require.NoError(t, Stop(context.Background(), w.deps(), res.SessionID), "a stopped session stops again as a no-op")
}

func TestSlugAndWorktreeTopMatchTheSwiftHelpers(t *testing.T) {
	assert.Equal(t, "session-3", Slug(nil, "ignored", 3))
	assert.Equal(t, "12-cafe-deja-vu-2", Slug(ptr(12), "Café: déjà vu #2!", 1))
	assert.Equal(t, "7-short-another", Slug(ptr(7), "short "+strings.Repeat("x", 40)+" another", 1),
		"a word that does not fit is skipped, later ones still added")
	assert.LessOrEqual(t, len(Slug(ptr(123), strings.Repeat("word ", 30), 1)), 40)
	assert.Equal(t, "/r/.claude/worktrees/a", WorktreeTop("/r/.claude/worktrees/a/sub/dir"))
	assert.Equal(t, "r/.claude/worktrees/a", WorktreeTop("r/.claude/worktrees/a"))
	assert.Empty(t, WorktreeTop("/r/.claude/worktrees"))
	assert.Empty(t, WorktreeTop("/r/src"))
}

// pane is a raw attached client (the Desktop's pane).
type pane struct {
	t  *testing.T
	nc net.Conn
}

func attach(t *testing.T, socket string, info sessionhost.SessionInfo) *pane {
	t.Helper()
	nc, err := net.Dial("unix", socket)
	require.NoError(t, err)
	t.Cleanup(func() { _ = nc.Close() })
	p := &pane{t: t, nc: nc}
	p.send(sessionhost.Hello, mustJSON(t, sessionhost.HelloMsg{Version: sessionhost.ProtocolVersion}))
	p.until(sessionhost.HelloOK)
	p.send(sessionhost.Attach, mustJSON(t, sessionhost.AttachReq{Row: info.Row, Run: info.Run}))
	p.until(sessionhost.Attached)
	return p
}

func (p *pane) send(ft sessionhost.FrameType, b []byte) {
	p.t.Helper()
	require.NoError(p.t, sessionhost.WriteFrame(p.nc, ft, b))
}

// until reads frames until one of type want (an Error fails the test).
func (p *pane) until(want sessionhost.FrameType) []byte {
	p.t.Helper()
	for {
		ft, b, err := sessionhost.ReadFrame(p.nc)
		require.NoError(p.t, err)
		if ft == want {
			return b
		}
		if ft == sessionhost.Error {
			p.t.Fatalf("host error: %s", b)
		}
	}
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	require.NoError(t, err)
	return b
}

// The Desktop's starts through the CLI (Go hub 3 Task 8): a title and an
// automation run given to Begin land on the row, and Finish, rebuilt from
// the row, launches with the run marker and the brief it is handed.
func TestSessionStartTitleAndAutomationRunReachTheRowAndTheLaunch(t *testing.T) {
	w := newWorld(t)
	res, err := w.db.Exec(`INSERT INTO automations (slug, scope, path) VALUES ('a', 'personal', '/p/a.md')`)
	require.NoError(t, err)
	aid, _ := res.LastInsertId()
	res, err = w.db.Exec(`INSERT INTO automation_runs (automation_id, trigger, status) VALUES (?, 'manual', 'running')`, aid)
	require.NoError(t, err)
	run, _ := res.LastInsertId()

	begun, err := Begin(context.Background(), w.deps(), handlers.StartRequest{
		Workbench: w.wb, Title: "Nightly sweep", AutomationRunID: run,
	})
	require.NoError(t, err)
	assert.Equal(t, "Nightly sweep", w.row(begun.SessionID).title)
	var stored sql.NullInt64
	require.NoError(t, w.db.QueryRow(`SELECT automation_run_id FROM terminal_sessions WHERE id = ?`, begun.SessionID).Scan(&stored))
	assert.Equal(t, run, stored.Int64)

	require.NoError(t, Finish(context.Background(), w.deps(), begun.SessionID, "folder", "sweep the board", false))
	w.launched(begun.SessionID)
	eventually(t, "the stub ran", func() bool {
		_, err := os.Stat(filepath.Join(w.stub, "run."+strconv.FormatInt(begun.SessionID, 10)))
		return err == nil
	})
	assert.Equal(t, strconv.FormatInt(run, 10), w.stubFile("run", begun.SessionID))
	assert.Contains(t, w.stubFile("argv", begun.SessionID), "sweep the board")
	assert.Empty(t, w.stubFile("origin", begun.SessionID), "an owner-triggered run's session carries no origin")
}

// BGAI-01 (#1886 §4.3): a session a background run started carries the
// run's admission, so the agent's own `watchtower` calls in it run while
// background AI is paused, as the run they belong to does (D12).
func TestSessionOfABackgroundRunIsAdmittedAsItsRun(t *testing.T) {
	w := newWorld(t)
	res, err := w.db.Exec(`INSERT INTO automations (slug, scope, path) VALUES ('a', 'personal', '/p/a.md')`)
	require.NoError(t, err)
	aid, _ := res.LastInsertId()
	res, err = w.db.Exec(`INSERT INTO automation_runs (automation_id, trigger, status, started_at) VALUES (?, 'schedule', 'running', '2026-11-18T09:00:00Z')`, aid)
	require.NoError(t, err)
	run, _ := res.LastInsertId()

	begun, err := Begin(context.Background(), w.deps(), handlers.StartRequest{Workbench: w.wb, AutomationRunID: run})
	require.NoError(t, err)
	require.NoError(t, Finish(context.Background(), w.deps(), begun.SessionID, "folder", "sweep", false))
	w.launched(begun.SessionID)
	eventually(t, "the stub recorded its origin", func() bool {
		_, err := os.Stat(filepath.Join(w.stub, "origin."+strconv.FormatInt(begun.SessionID, 10)))
		return err == nil
	})
	unit := "run:" + strconv.FormatInt(run, 10)
	assert.Equal(t, "background\n"+unit, w.stubFile("origin", begun.SessionID))

	// A `watchtower` child started with that env, background AI paused.
	aiconsenttest.Use(t, "", map[string]string{
		aiconsent.EnvOrigin: "background", aiconsent.EnvAdmitted: unit,
		AutomationRunEnv: strconv.FormatInt(run, 10),
	}, false)
	require.NoError(t, aiconsent.Check(context.Background()), "the run's session child is admitted while paused")

	// A run never claimed (cancelled by the paused hold): its session's
	// child is background, not admitted, and refused while paused.
	aiconsenttest.Use(t, "", map[string]string{aiconsent.EnvOrigin: "background"}, false)
	require.ErrorIs(t, aiconsent.Check(context.Background()), aiconsent.ErrPaused)
}

func TestOriginEnvFollowsTheRun(t *testing.T) {
	d := db.OpenTestDB(t)
	res, err := d.Exec(`INSERT INTO automations (slug, scope, path) VALUES ('a', 'personal', '/p/a.md')`)
	require.NoError(t, err)
	aid, _ := res.LastInsertId()
	runOf := func(trigger string) int64 {
		res, err := d.Exec(`INSERT INTO automation_runs (automation_id, trigger, status, started_at) VALUES (?, ?, 'running', '2026-11-18T09:00:00Z')`, aid, trigger)
		require.NoError(t, err)
		id, _ := res.LastInsertId()
		return id
	}
	ctx := context.Background()
	for _, trigger := range []string{"schedule", "catch_up", "event", "sync"} {
		id := runOf(trigger)
		assert.Equal(t, []string{aiconsent.EnvOrigin + "=background", aiconsent.EnvAdmitted + "=run:" + strconv.FormatInt(id, 10)},
			originEnv(ctx, d, id), trigger)
	}
	for _, trigger := range []string{"manual", "button", "dry_run", "reply"} {
		assert.Nil(t, originEnv(ctx, d, runOf(trigger)), trigger)
	}
	assert.Nil(t, originEnv(aiconsent.WithOwnerStarted(ctx), d, 0), "the owner's own session")
	// Every row of the shared fixture (the Desktop reads it too): admitted
	// only once claimed under consent; queued or cancelled before its start
	// (the paused hold included) is background, not admitted.
	data, err := os.ReadFile(filepath.Join("..", "aiconsent", "testdata", "run_session_origin.json"))
	require.NoError(t, err)
	var cases []struct {
		Name, Trigger, Status, Error, Want string
		Started                            bool
	}
	require.NoError(t, json.Unmarshal(data, &cases))
	require.NotEmpty(t, cases)
	for i, c := range cases {
		res, err := d.Exec(`INSERT INTO automations (slug, scope, path) VALUES (?, 'personal', ?)`,
			fmt.Sprintf("case-%d", i), fmt.Sprintf("/p/case-%d.md", i))
		require.NoError(t, err)
		caseAuto, _ := res.LastInsertId()
		var started any
		if c.Started {
			started = "2026-11-18T09:00:00Z"
		}
		res, err = d.Exec(`INSERT INTO automation_runs (automation_id, trigger, status, started_at, error) VALUES (?, ?, ?, ?, ?)`,
			caseAuto, c.Trigger, c.Status, started, c.Error)
		require.NoError(t, err, c.Name)
		id, _ := res.LastInsertId()
		want := map[string][]string{
			"admitted":   {aiconsent.EnvOrigin + "=background", aiconsent.EnvAdmitted + "=run:" + strconv.FormatInt(id, 10)},
			"background": {aiconsent.EnvOrigin + "=background"},
			"owner":      nil,
		}[c.Want]
		assert.Equal(t, want, originEnv(ctx, d, id), c.Name)
	}

	// A run that cannot be read: the starting process's own origin.
	assert.Nil(t, originEnv(aiconsent.WithOwnerStarted(ctx), d, 999999))
	assert.Equal(t, []string{aiconsent.EnvOrigin + "=background", aiconsent.EnvAdmitted + "=phase:x"},
		originEnv(aiconsent.WithAdmitted(ctx, "phase:x"), d, 999999))
}
