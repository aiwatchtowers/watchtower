package cmd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
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
	shell := filepath.Join(dir, "loginshell")
	require.NoError(t, os.WriteFile(shell, []byte("#!/bin/sh\nexec /bin/sleep 30\n"), 0o700))
	prev := workbenchSessionShell
	workbenchSessionShell = shell
	t.Cleanup(func() { workbenchSessionShell = prev })
	return socket
}

func runSession(t *testing.T, args ...string) (string, error) {
	t.Helper()
	out, _, err := runWorkbench(t, append([]string{"session"}, args...)...)
	resetSetFlags(workbenchSessionCmd.Commands()...)
	sessionFlagWorkbench, sessionFlagTarget, sessionFlagSession = 0, 0, 0
	sessionFlagAgent, sessionFlagPlace, sessionFlagJSON = "", "auto", false
	return out, err
}

func TestWorkbenchSessionStartJSONKeys(t *testing.T) {
	database := writeActionsConfig(t)
	folder := t.TempDir()
	wb, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	socket := sessionHostForTest(t)

	out, err := runSession(t, "start", "--workbench", strconv.FormatInt(wb, 10), "--agent", "claude", "--json")
	require.NoError(t, err, out)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	assert.Equal(t, sorted("session_id", "state", "folder_path", "worktree_branch"), keysOf(m))
	assert.Equal(t, "running", m["state"])
	assert.Equal(t, "", m["worktree_branch"])
	sid := int64(m["session_id"].(float64))

	c, err := sessionhost.Dial(context.Background(), socket)
	require.NoError(t, err)
	defer func() { _ = c.Close() }()
	list, err := c.List(context.Background())
	require.NoError(t, err)
	require.Len(t, list, 1)
	assert.Equal(t, sid, list[0].Row)

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
