package tools

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/sessionmsg"
	"watchtower/internal/workbenchfiles"
)

// messageWorld is the daemon as the tools see it (daemon.DaemonRunning in
// cmd's wiring, whose pid-file read — never the sync lock — is pinned by
// TestDaemonRunningNeverTakesSyncLock): stopped until startDaemon.
type messageWorld struct {
	running bool
	wakes   int
}

func newMessageWorld(*testing.T) *messageWorld { return &messageWorld{} }

func (w *messageWorld) startDaemon(*testing.T) { w.running = true }

func (w *messageWorld) deps(live ...int64) MessageDeps {
	return MessageDeps{
		Live: func(_ context.Context, id int64) (bool, error) {
			for _, l := range live {
				if l == id {
					return true, nil
				}
			}
			return false, nil
		},
		DaemonRunning: func() (bool, error) { return w.running, nil },
		Wake:          func() { w.wakes++ },
	}
}

func messageRegistry(t *testing.T, d *db.DB, env int64, deps MessageDeps) *Registry {
	t.Helper()
	reg := New(d)
	for _, tool := range workbenchTools(workbenchfiles.New(t.TempDir()), func() string { return strconv.FormatInt(env, 10) }, nil, deps) {
		require.NoError(t, reg.Register(tool))
	}
	return reg
}

func queuedMessages(t *testing.T, d *db.DB) []db.SessionMessage {
	t.Helper()
	rows, err := d.QueuedSessionMessages(context.Background())
	require.NoError(t, err)
	return rows
}

func TestSendWithoutTheDaemonQueuesAndWarns(t *testing.T) {
	fx := newWorkbenchFixture(t)
	from, to := seedTerminalSession(t, fx.d, fx.a), seedTerminalSession(t, fx.d, fx.a)
	w := newMessageWorld(t)
	reg := messageRegistry(t, fx.d, from, w.deps(to))
	args := fmt.Sprintf(`{"session_id":%d,"text":"run the tests","reason":"r"}`, to)

	out := mustApply(t, reg, fx.a, "send_to_session", args)
	assert.Equal(t, "queued", out["state"])
	warning, _ := out["warning"].(string)
	assert.True(t, strings.HasPrefix(warning, "daemon_not_running: "), "warning %q", warning)
	assert.Equal(t, sessionmsg.DaemonNotRunningWarning, warning)
	assert.Zero(t, w.wakes)
	rows := queuedMessages(t, fx.d)
	require.Len(t, rows, 1)
	assert.EqualValues(t, rows[0].ID, out["message_id"])

	w.startDaemon(t)
	out = mustApply(t, reg, fx.a, "send_to_session", args)
	assert.NotContains(t, out, "warning")
	assert.Equal(t, 1, w.wakes, "a running daemon is woken to deliver now")
	assert.Len(t, queuedMessages(t, fx.d), 2)
}

func TestFinishWithoutTheDaemonQueuesAndWarns(t *testing.T) {
	fx := newWorkbenchFixture(t)
	parent := seedTerminalSession(t, fx.d, fx.a)
	child := seedTerminalSession(t, fx.d, fx.a)
	_, err := fx.d.Exec(`UPDATE terminal_sessions SET parent_session_id = ?, title = 'API' WHERE id = ?`, parent, child)
	require.NoError(t, err)
	w := newMessageWorld(t)
	reg := messageRegistry(t, fx.d, child, w.deps())

	out := mustApply(t, reg, fx.a, "finish_session", `{"summary":"All green.","reason":"done"}`)
	warning, _ := out["warning"].(string)
	assert.Equal(t, sessionmsg.DaemonNotRunningWarning, warning)
	rows := queuedMessages(t, fx.d)
	require.Len(t, rows, 1)
	assert.EqualValues(t, rows[0].ID, out["parent_message_id"])
	assert.Equal(t, sessionmsg.KindFinished, rows[0].Kind)
	assert.Equal(t, parent, rows[0].ToSessionID.Int64)
	assert.True(t, strings.HasPrefix(rows[0].Text, fmt.Sprintf("[Sub-session #%d “API” finished · ", child)))
	assert.True(t, strings.HasSuffix(rows[0].Text, "] All green."))

	w.startDaemon(t)
	out = mustApply(t, reg, fx.a, "finish_session", `{"summary":"Again.","reason":"done"}`)
	assert.NotContains(t, out, "warning")
	assert.Equal(t, 1, w.wakes)

	// A session with no parent tells no one and warns of nothing.
	top := messageRegistry(t, fx.d, parent, w.deps())
	out = mustApply(t, top, fx.a, "finish_session", `{"summary":"Done.","reason":"done"}`)
	assert.NotContains(t, out, "parent_message_id")
	assert.NotContains(t, out, "warning")
	assert.Len(t, queuedMessages(t, fx.d), 2)
}

func TestSendToSession_RefusalsQueueNothing(t *testing.T) {
	fx := newWorkbenchFixture(t)
	from := seedTerminalSession(t, fx.d, fx.a)
	stopped := seedTerminalSession(t, fx.d, fx.a)
	elsewhere := seedTerminalSession(t, fx.d, fx.b)
	w := newMessageWorld(t)
	reg := messageRegistry(t, fx.d, from, w.deps(from, elsewhere))

	for _, c := range []struct{ args, want string }{
		{fmt.Sprintf(`{"session_id":%d,"text":"hi","reason":"r"}`, from), "self: "},
		{fmt.Sprintf(`{"session_id":%d,"text":"hi","reason":"r"}`, stopped), "not_running: "},
		{fmt.Sprintf(`{"session_id":%d,"text":"hi","reason":"r"}`, elsewhere), "not_same_workbench: "},
		{fmt.Sprintf(`{"session_id":%d,"text":"hi","reason":"r"}`, elsewhere+100), "not_found: "},
		{fmt.Sprintf(`{"session_id":%d,"text":%q,"reason":"r"}`, stopped, strings.Repeat("x", 4001)), "too_long: "},
	} {
		_, err := proposeIn(t, reg, fx.a, "send_to_session", c.args)
		require.Error(t, err)
		assert.True(t, strings.HasPrefix(refusal(t, err), c.want), "%s → %q", c.want, refusal(t, err))
	}
	outside := messageRegistry(t, fx.d, 0, w.deps(stopped))
	_, err := proposeIn(t, outside, fx.a, "send_to_session", fmt.Sprintf(`{"session_id":%d,"text":"hi","reason":"r"}`, stopped))
	assert.Equal(t, "send_to_session needs a Watchtower terminal session", refusal(t, err))
	assert.Empty(t, queuedMessages(t, fx.d))
}
