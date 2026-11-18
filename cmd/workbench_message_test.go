package cmd

import (
	"context"
	"database/sql"
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

	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
	"watchtower/internal/sessionhost"
	"watchtower/internal/sessionmsg"
)

func runMessage(t *testing.T, stdin string, args ...string) (string, error) {
	t.Helper()
	rootCmd.SetIn(strings.NewReader(stdin))
	out, _, err := runWorkbench(t, append([]string{"message"}, args...)...)
	rootCmd.SetIn(nil)
	resetSetFlags(workbenchMessageCmd.Commands()...)
	messageFlagTo, messageFlagID, messageFlagTextStdin, messageFlagJSON = 0, 0, false, false
	return out, err
}

func insertCodexSession(t *testing.T, database *db.DB, wb int64) int64 {
	t.Helper()
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (?, 'codex', 's', '/tmp/x')`, wb)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

// launchStub runs a sleeping process for session row in the test's host,
// under this workspace's scope: the row is live.
func launchStub(t *testing.T, socket string, row int64) {
	t.Helper()
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	c, err := sessionhost.Dial(context.Background(), socket)
	require.NoError(t, err)
	defer func() { _ = c.Close() }()
	_, err = c.Launch(context.Background(), sessionhost.LaunchReq{Row: row, Run: "r-" + strconv.FormatInt(row, 10),
		Executable: "/bin/sleep", Args: []string{"30"}, Cwd: t.TempDir(), Cols: 80, Rows: 24,
		Scope: sessionhost.Scope(cfg.DBPath()), Agent: "codex", Detach: true})
	require.NoError(t, err)
}

// startFakeDaemon writes this process's pid as the workspace's confirmed
// daemon advertising the messages wake, and counts the wake signals sent.
func startFakeDaemon(t *testing.T) *int {
	t.Helper()
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	start := time.Now().Add(-time.Hour).Truncate(time.Second)
	t.Cleanup(daemon.SetIdentityReaderForTest(func(int) (daemon.ProcessIdentity, error) {
		return daemon.ProcessIdentity{StartTime: start, Comm: "watchtower"}, nil
	}))
	pidPath := pidFilePath(cfg)
	require.NoError(t, daemon.WritePID(pidPath))
	require.NoError(t, os.WriteFile(daemon.CapsPath(pidPath),
		[]byte(strconv.Itoa(os.Getpid())+"\n"+daemon.SessionMessagesWakeCapability+"\n"), 0o600))
	sent := 0
	prev := automationWakeKill
	automationWakeKill = func(pid int, sig syscall.Signal) error {
		assert.Equal(t, os.Getpid(), pid)
		assert.Equal(t, daemon.AutomationWakeSignal, sig)
		sent++
		return nil
	}
	t.Cleanup(func() { automationWakeKill = prev })
	return &sent
}

func TestWorkbenchMessageSendQueuesAndWarns(t *testing.T) {
	database := writeActionsConfig(t)
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	from, to, stopped := insertCodexSession(t, database, wb), insertCodexSession(t, database, wb), insertCodexSession(t, database, wb)
	socket := sessionHostForTest(t)
	launchStub(t, socket, to)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(from, 10))

	// A one-shot sync holds the lock: still no daemon to deliver.
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	lock, err := os.OpenFile(filepath.Join(cfg.WorkspaceDir(), "sync.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	require.NoError(t, err)
	defer lock.Close()
	require.NoError(t, syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB))

	out, err := runMessage(t, "run the tests", "send", "--to", strconv.FormatInt(to, 10), "--text-stdin", "--json")
	require.NoError(t, err)
	var got messageSendOutput
	require.NoError(t, json.Unmarshal([]byte(out), &got))
	assert.Equal(t, "queued", got.State)
	assert.True(t, strings.HasPrefix(got.Warning, "daemon_not_running: "), "warning %q", got.Warning)
	rows, err := database.QueuedSessionMessages(context.Background())
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, got.MessageID, rows[0].ID)
	assert.True(t, strings.HasSuffix(rows[0].Text, "\nrun the tests\n(Reply with send_to_session("+strconv.FormatInt(from, 10)+", …))"))

	sent := startFakeDaemon(t)
	out, err = runMessage(t, "again", "send", "--to", strconv.FormatInt(to, 10), "--text-stdin", "--json")
	require.NoError(t, err)
	assert.NotContains(t, out, "warning")
	assert.Equal(t, 1, *sent, "the daemon is woken")

	out, err = runMessage(t, "hi", "send", "--to", strconv.FormatInt(stopped, 10), "--text-stdin", "--json")
	require.Error(t, err)
	var refusal sessionStartRefusal
	require.NoError(t, json.Unmarshal([]byte(out), &refusal))
	assert.Equal(t, sessionmsg.CodeNotRunning, refusal.ErrorCode)
	assert.True(t, strings.HasPrefix(refusal.Error, "not_running: "))
	rows, err = database.QueuedSessionMessages(context.Background())
	require.NoError(t, err)
	assert.Len(t, rows, 2, "a refused send queues nothing")
}

func TestMessageDismissClearsOnlyANullFlag(t *testing.T) {
	database := writeActionsConfig(t)
	ctx := context.Background()
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	a, b := insertCodexSession(t, database, wb), insertCodexSession(t, database, wb)
	typed := func() int64 {
		id, err := database.InsertSessionMessage(ctx, db.SessionMessage{WorkbenchID: wb, FromSessionID: sql.NullInt64{Int64: a, Valid: true},
			ToSessionID: sql.NullInt64{Int64: b, Valid: true}, Kind: sessionmsg.KindMessage, Text: "hi"})
		require.NoError(t, err)
		_, err = database.ClaimSessionMessage(ctx, id)
		require.NoError(t, err)
		require.NoError(t, database.SettleSessionMessage(ctx, id, db.SessionMessageDelivered,
			db.SessionMessageTypedNotSubmitted, time.Now()))
		return id
	}
	open, done := typed(), typed()
	const first = "2026-11-18T09:00:00Z"
	_, err = database.Exec(`UPDATE session_messages SET prompt_cleared_at = ? WHERE id = ?`, first, done)
	require.NoError(t, err)
	clearedAt := func(id int64) string {
		var s *string
		require.NoError(t, database.QueryRow(`SELECT prompt_cleared_at FROM session_messages WHERE id = ?`, id).Scan(&s))
		if s == nil {
			return ""
		}
		return *s
	}

	out, err := runMessage(t, "", "dismiss", "--id", strconv.FormatInt(open, 10), "--json")
	require.NoError(t, err)
	assert.JSONEq(t, `{"ok":true}`, out, "the Desktop's decoded shape")
	assert.NotEmpty(t, clearedAt(open))
	_, err = runMessage(t, "", "dismiss", "--id", strconv.FormatInt(done, 10), "--json")
	require.NoError(t, err)
	assert.Equal(t, first, clearedAt(done), "a flag the daemon cleared keeps its first time")

	refused := func(out, code string) {
		t.Helper()
		var got map[string]any
		require.NoError(t, json.Unmarshal([]byte(out), &got))
		assert.Equal(t, false, got["ok"])
		assert.Equal(t, code, got["error_code"])
		assert.True(t, strings.HasPrefix(got["error"].(string), code+": "), "%v", got["error"])
		assert.Len(t, got, 3, "exactly ok, error_code, error")
	}
	out, err = runMessage(t, "", "dismiss", "--id", "999999", "--json")
	require.Error(t, err)
	refused(out, "not_found")

	// Only a delivered row left typed in a prompt has a flag to dismiss.
	queued, err := database.InsertSessionMessage(ctx, db.SessionMessage{WorkbenchID: wb, FromSessionID: sql.NullInt64{Int64: a, Valid: true},
		ToSessionID: sql.NullInt64{Int64: b, Valid: true}, Kind: sessionmsg.KindMessage, Text: "hi"})
	require.NoError(t, err)
	out, err = runMessage(t, "", "dismiss", "--id", strconv.FormatInt(queued, 10), "--json")
	require.Error(t, err)
	refused(out, "not_allowed")
	assert.Empty(t, clearedAt(queued), "a queued row is never stamped")

	again := typed()
	t.Setenv(terminalSessionEnv, strconv.FormatInt(a, 10))
	out, err = runMessage(t, "", "dismiss", "--id", strconv.FormatInt(again, 10), "--json")
	require.ErrorContains(t, err, "refused inside terminal session")
	refused(out, "not_allowed")
	require.NoError(t, os.Unsetenv(terminalSessionEnv))
	t.Setenv("CLAUDECODE", "1")
	out, err = runMessage(t, "", "dismiss", "--id", strconv.FormatInt(again, 10), "--json")
	require.ErrorContains(t, err, "under an AI agent")
	refused(out, "not_allowed")
	assert.Empty(t, clearedAt(again), "an agent never dismisses the owner's notice")
}
