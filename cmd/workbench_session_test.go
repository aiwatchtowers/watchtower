package cmd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/sessionhost"
)

// sessionHostForTest serves an in-process session-host on a short socket,
// set as WATCHTOWER_SESSION_HOST_SOCKET; hosted process groups are killed
// and reaped before it stops. The login shell is a stub that sleeps.
func sessionHostForTest(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "csh")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	socket := filepath.Join(dir, "h.sock")
	l, err := sessionhost.Listen(socket)
	require.NoError(t, err)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = sessionhost.NewServer(sessionhost.Options{}).Serve(ctx, l)
	}()
	t.Cleanup(func() { cancel(); <-done })
	t.Cleanup(func() {
		c, err := sessionhost.Dial(context.Background(), socket)
		if err != nil {
			return
		}
		defer func() { _ = c.Close() }()
		list, _ := c.List(context.Background())
		for _, info := range list {
			if info.Pid > 0 && !info.Exited {
				_ = syscall.Kill(-info.Pid, syscall.SIGKILL)
				for deadline := time.Now().Add(5 * time.Second); syscall.Kill(info.Pid, 0) == nil && time.Now().Before(deadline); {
					time.Sleep(10 * time.Millisecond)
				}
			}
		}
	})
	t.Setenv(sessionhost.SocketEnv, socket)
	// The stub records its arguments and the first prompt it was handed
	// (WATCHTOWER_FIRST_PROMPT) in args.txt beside the socket, then sleeps.
	shell := filepath.Join(dir, "loginshell")
	require.NoError(t, os.WriteFile(shell, []byte("#!/bin/sh\nprintf '%s\\n' \"$@\" \"$WATCHTOWER_FIRST_PROMPT\" > \""+
		filepath.Join(dir, "args.txt")+"\"\nexec /bin/sleep 30\n"), 0o700))
	prev, prevWatch := workbenchSessionShell, finishLaunchWatch
	workbenchSessionShell, finishLaunchWatch = shell, 300*time.Millisecond
	t.Cleanup(func() { workbenchSessionShell, finishLaunchWatch = prev, prevWatch })
	return socket
}

func runSession(t *testing.T, args ...string) (string, error) {
	t.Helper()
	out, _, err := runWorkbench(t, append([]string{"session"}, args...)...)
	resetSetFlags(workbenchSessionCmd.Commands()...)
	sessionFlagWorkbench, sessionFlagTarget, sessionFlagSession = 0, 0, 0
	sessionFlagAgent, sessionFlagPlace, sessionFlagJSON = "", "auto", false
	sessionFlagTitle, sessionFlagAutomationRun, sessionFlagBriefStdin = "", 0, false
	return out, err
}

// spawnedFinishes replaces the detached finish with a record of its
// arguments (and the brief, after a "|", when one is handed on).
func spawnedFinishes(t *testing.T) *[]string {
	t.Helper()
	var got []string
	prev := workbenchSessionFinishSpawn
	workbenchSessionFinishSpawn = func(id int64, place, brief string) error {
		line := strconv.FormatInt(id, 10) + " " + place
		if brief != "" {
			line += "|" + brief
		}
		got = append(got, line)
		return nil
	}
	t.Cleanup(func() { workbenchSessionFinishSpawn = prev })
	return &got
}

// Instant start (#942): start answers at once with the row starting in the
// workbench folder and nothing launched; the detached finish launches it
// (running in the host); stop stops and forgets it. Pinned keys.
func TestWorkbenchSessionStartJSONKeys(t *testing.T) {
	database := writeActionsConfig(t)
	folder := t.TempDir()
	wb, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	socket := sessionHostForTest(t)
	spawned := spawnedFinishes(t)

	out, err := runSession(t, "start", "--workbench", strconv.FormatInt(wb, 10), "--agent", "claude", "--json")
	require.NoError(t, err, out)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	assert.Equal(t, sorted("session_id", "state", "folder_path", "worktree_branch"), keysOf(m))
	assert.Equal(t, "starting", m["state"])
	assert.Equal(t, "", m["worktree_branch"])
	sid := int64(m["session_id"].(float64))
	assert.Equal(t, []string{strconv.FormatInt(sid, 10) + " auto"}, *spawned)

	c, err := sessionhost.Dial(context.Background(), socket)
	require.NoError(t, err)
	defer func() { _ = c.Close() }()
	list, err := c.List(context.Background())
	require.NoError(t, err)
	assert.Empty(t, list, "nothing launched before start answered")

	_, err = runSession(t, "finish", "--session", strconv.FormatInt(sid, 10), "--place", "auto")
	require.NoError(t, err)
	list, err = c.List(context.Background())
	require.NoError(t, err)
	require.Len(t, list, 1)
	assert.Equal(t, sid, list[0].Row)
	assert.False(t, list[0].Exited, "running")

	out, err = runSession(t, "stop", "--session", strconv.FormatInt(sid, 10), "--json")
	require.NoError(t, err, out)
	m = nil
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	assert.Equal(t, sorted("session_id", "stopped"), keysOf(m))
	assert.Equal(t, true, m["stopped"])
	list, err = c.List(context.Background())
	require.NoError(t, err)
	assert.Empty(t, list, "stopped and forgotten")
}

// A finish whose launch is refused leaves the row failed with its reason.
func TestWorkbenchSessionFinishRecordsAFailedLaunch(t *testing.T) {
	database := writeActionsConfig(t)
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	sessionHostForTest(t)
	spawnedFinishes(t)
	workbenchSessionShell = "/nonexistent/shell" // restored by sessionHostForTest's cleanup
	out, err := runSession(t, "start", "--workbench", strconv.FormatInt(wb, 10), "--agent", "claude", "--json")
	require.NoError(t, err, out)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	sid := strconv.FormatInt(int64(m["session_id"].(float64)), 10)
	_, err = runSession(t, "finish", "--session", sid)
	require.Error(t, err)
	var state, failure string
	require.NoError(t, database.QueryRow(`SELECT agent_state, agent_error FROM terminal_sessions WHERE id = ?`, sid).Scan(&state, &failure))
	assert.Equal(t, "waiting", state)
	assert.Contains(t, failure, "launch refused: ")
}

// Under an agent marker only the caller's own workbench: another
// workbench's session is refused, start and stop alike, and a marker with
// no terminal session is refused outright.
func TestWorkbenchSessionRefusesAnotherWorkbenchUnderAnAgent(t *testing.T) {
	database := writeActionsConfig(t)
	own, err := database.CreateWorkbench("own", t.TempDir())
	require.NoError(t, err)
	other, err := database.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	insert := func(wb int64) int64 {
		res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (?, 'codex', 's', '/tmp/x')`, wb)
		require.NoError(t, err)
		id, _ := res.LastInsertId()
		return id
	}
	caller, foreign := insert(own), insert(other)
	sessionHostForTest(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(caller, 10))

	_, err = runSession(t, "start", "--workbench", strconv.FormatInt(other, 10), "--json")
	require.ErrorContains(t, err, "only its own workbench")
	_, err = runSession(t, "stop", "--session", strconv.FormatInt(foreign, 10), "--json")
	require.ErrorContains(t, err, "only its own workbench")
	out, err := runSession(t, "stop", "--session", strconv.FormatInt(caller, 10), "--json")
	require.NoError(t, err, "its own workbench's session (not running: a no-op)")
	assert.Contains(t, out, `"stopped"`)

	require.NoError(t, os.Unsetenv(terminalSessionEnv))
	t.Setenv("CLAUDECODE", "1")
	_, err = runSession(t, "start", "--workbench", strconv.FormatInt(own, 10), "--json")
	require.ErrorContains(t, err, "under an AI agent")
}

// The Desktop's starts (Go hub 3 Task 8): --title and --automation-run land
// on the row, the brief comes on stdin (never argv) and is handed to the
// detached finish, which launches with it.
func TestWorkbenchSessionStartTitleRunAndBriefFromStdin(t *testing.T) {
	database := writeActionsConfig(t)
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	res, err := database.Exec(`INSERT INTO automations (slug, scope, path) VALUES ('a', 'personal', '/p/a.md')`)
	require.NoError(t, err)
	aid, _ := res.LastInsertId()
	res, err = database.Exec(`INSERT INTO automation_runs (automation_id, trigger, status) VALUES (?, 'manual', 'running')`, aid)
	require.NoError(t, err)
	run, _ := res.LastInsertId()
	sessionHostForTest(t)
	spawned := spawnedFinishes(t)

	rootCmd.SetIn(strings.NewReader("sweep the board\n"))
	t.Cleanup(func() { rootCmd.SetIn(nil) })
	out, err := runSession(t, "start", "--workbench", strconv.FormatInt(wb, 10), "--agent", "claude", "--place", "folder",
		"--title", "Nightly sweep", "--automation-run", strconv.FormatInt(run, 10), "--brief-stdin", "--json")
	require.NoError(t, err, out)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	sid := int64(m["session_id"].(float64))
	assert.Equal(t, []string{strconv.FormatInt(sid, 10) + " folder|sweep the board\n"}, *spawned)
	var title string
	var stored int64
	require.NoError(t, database.QueryRow(`SELECT title, automation_run_id FROM terminal_sessions WHERE id = ?`, sid).
		Scan(&title, &stored))
	assert.Equal(t, "Nightly sweep", title)
	assert.Equal(t, run, stored)
}

// A finish reads its brief from stdin with --brief-stdin.
func TestWorkbenchSessionFinishReadsTheBriefFromStdin(t *testing.T) {
	database := writeActionsConfig(t)
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	socket := sessionHostForTest(t)
	spawnedFinishes(t)
	out, err := runSession(t, "start", "--workbench", strconv.FormatInt(wb, 10), "--agent", "claude", "--json")
	require.NoError(t, err, out)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	sid := int64(m["session_id"].(float64))

	rootCmd.SetIn(strings.NewReader("sweep the board"))
	t.Cleanup(func() { rootCmd.SetIn(nil) })
	_, err = runSession(t, "finish", "--session", strconv.FormatInt(sid, 10), "--brief-stdin")
	require.NoError(t, err)
	c, err := sessionhost.Dial(context.Background(), socket)
	require.NoError(t, err)
	defer func() { _ = c.Close() }()
	list, err := c.List(context.Background())
	require.NoError(t, err)
	require.Len(t, list, 1)
	assert.Equal(t, sid, list[0].Row)
	args := filepath.Join(filepath.Dir(socket), "args.txt")
	require.Eventually(t, func() bool { _, err := os.Stat(args); return err == nil }, 5*time.Second, 20*time.Millisecond)
	b, err := os.ReadFile(args)
	require.NoError(t, err)
	assert.Contains(t, string(b), "sweep the board", "the brief reached the launch")
}

// A missing agent before any row: the pinned class on stdout and exit 3
// (sessionstart.AgentNotFoundExit), nothing written.
func TestWorkbenchSessionStartAnswersAgentNotFound(t *testing.T) {
	database := writeActionsConfig(t)
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	sessionHostForTest(t)
	spawned := spawnedFinishes(t)
	out, err := runSession(t, "start", "--workbench", strconv.FormatInt(wb, 10), "--agent", "codex", "--json")
	var exit *exitCodeError
	require.ErrorAs(t, err, &exit)
	assert.Equal(t, 3, exit.code)
	assert.JSONEq(t, `{"error":"agent_not_found","agent":"codex"}`, out)
	assert.Empty(t, *spawned)
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM terminal_sessions`).Scan(&n))
	assert.Zero(t, n)
}

// An agent that exits 127 at once: the finish's launch watch records
// "<agent> was not found" on the row.
func TestWorkbenchSessionFinishRecordsAMissingAgent(t *testing.T) {
	database := writeActionsConfig(t)
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	socket := sessionHostForTest(t)
	spawnedFinishes(t)
	missing := filepath.Join(filepath.Dir(socket), "exit127")
	require.NoError(t, os.WriteFile(missing, []byte("#!/bin/sh\nexit 127\n"), 0o700))
	workbenchSessionShell = missing // restored by sessionHostForTest's cleanup
	finishLaunchWatch = 3 * time.Second
	out, err := runSession(t, "start", "--workbench", strconv.FormatInt(wb, 10), "--agent", "claude", "--json")
	require.NoError(t, err, out)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	sid := strconv.FormatInt(int64(m["session_id"].(float64)), 10)
	_, err = runSession(t, "finish", "--session", sid)
	require.Error(t, err)
	var failure string
	require.NoError(t, database.QueryRow(`SELECT agent_error FROM terminal_sessions WHERE id = ?`, sid).Scan(&failure))
	assert.Equal(t, "claude was not found", failure)
}
