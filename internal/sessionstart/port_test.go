package sessionstart

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
	"watchtower/internal/sessionhost"
)

const (
	pasteOpen  = "\x1b[200~"
	pasteClose = "\x1b[201~"
)

func (w *world) port() *Port {
	w.t.Helper()
	d := w.deps()
	d.LaunchWatch = 200 * time.Millisecond
	p := NewPort(d, nil)
	w.t.Cleanup(func() { _ = p.Close() })
	return p
}

// startedSession is a claude session started through the port, launched and
// idle for its run (a Stop hook after its start).
func (w *world) startedSession(p *Port) (int64, sessionhost.SessionInfo) {
	w.t.Helper()
	res, err := p.Start(context.Background(), handlers.StartRequest{Workbench: w.wb, Brief: "go"})
	require.NoError(w.t, err)
	require.Equal(w.t, StateRunning, res.State, "the port answers after the launch was checked")
	info := w.launched(res.SessionID)
	_, err = w.db.Exec(`UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = ? WHERE id = ?`,
		db.AgentStateStamp(time.Now().Add(time.Second)), res.SessionID)
	require.NoError(w.t, err)
	return res.SessionID, info
}

func TestPortLiveSeesOnlyThisScope(t *testing.T) {
	w := newWorld(t)
	p := w.port()
	c := w.client()
	other, err := c.Launch(context.Background(), sessionhost.LaunchReq{Row: 900, Run: "r", Executable: "/bin/sh",
		Args: []string{"-c", "exec sleep 30"}, Cwd: w.folder, Cols: 80, Rows: 24, Scope: "another-workspace"})
	require.NoError(t, err)
	require.Positive(t, other.Pid)
	_, ok, err := p.Live(context.Background(), 900)
	require.NoError(t, err)
	assert.False(t, ok, "another workspace's row 900 is not this one's")

	sid, info := w.startedSession(p)
	live, ok, err := p.Live(context.Background(), sid)
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, handlers.LiveRun{SessionID: sid, Run: info.Launch, Agent: "claude",
		StartedAt: time.UnixMilli(info.StartedAtMs)}, live)
	assert.False(t, live.StartedAt.IsZero(), "the port fills the run's start")
}

// The host's hold reaches the caller as is, and nothing is written.
func TestPortDeliverPassesHeldThrough(t *testing.T) {
	w := newWorld(t)
	p := w.port()
	sid, info := w.startedSession(p)
	pane := attach(t, w.socket, info)
	pane.send(sessionhost.Input, []byte("half typed"))
	w.waitPTY(sid, "half typed")
	checks := 0
	res, err := p.Deliver(context.Background(), handlers.DeliverRequest{
		SessionID: sid, Run: info.Launch, Text: "hello", HoldIfPromptText: true, Settle: 50 * time.Millisecond,
		Check: func(context.Context) handlers.CheckAnswer {
			checks++
			return handlers.CheckAnswer{Fresh: true, CanSubmit: true}
		},
	})
	require.NoError(t, err)
	assert.Equal(t, handlers.DeliverResult{Outcome: handlers.DeliverHeld, Reason: sessionhost.HeldPromptHasText}, res)
	assert.Equal(t, 1, checks, "only the pre-paste check ran")
	time.Sleep(100 * time.Millisecond)
	assert.Equal(t, "half typed", w.pty(sid))

	gone, err := p.Deliver(context.Background(), handlers.DeliverRequest{SessionID: sid, Run: info.Launch + 1, Text: "x"})
	require.NoError(t, err)
	assert.Equal(t, handlers.DeliverNoSession, gone.Outcome, "another launch is no_session")
	_, err = p.Deliver(context.Background(), handlers.DeliverRequest{SessionID: sid, Run: info.Launch, Text: "\n"})
	assert.Error(t, err, "a text that cleans to nothing is the host's error, not delivered")
}

// Interrupt is one Esc through InputTo, and it is no owner draft: a line
// still goes after it.
func TestPortInterruptIsOneEscAndNoDraft(t *testing.T) {
	w := newWorld(t)
	p := w.port()
	sid, info := w.startedSession(p)
	require.NoError(t, p.Interrupt(context.Background(), sid, info.Launch))
	w.waitPTY(sid, "\x1b")
	assert.ErrorIs(t, p.Interrupt(context.Background(), sid, info.Launch+1), ErrNotRunning)
	res, err := p.Deliver(context.Background(), handlers.DeliverRequest{
		SessionID: sid, Run: info.Launch, Text: "after", HoldIfPromptText: true, Settle: 50 * time.Millisecond,
		Check: func(context.Context) handlers.CheckAnswer { return handlers.CheckAnswer{Fresh: true, CanSubmit: true} },
	})
	require.NoError(t, err)
	assert.Equal(t, handlers.DeliverSubmitted, res.Outcome)
	w.waitPTY(sid, "\x1b"+pasteOpen+"after"+pasteClose+"\r")
}

// relay is the hub's handlers over the real port, behind a real processor on
// a memfake relay, with one linked phone allowed to type.
type relay struct {
	t     *testing.T
	w     *world
	h     *handlers.Handlers
	proc  *actions.Processor
	phone *hubtest.Phone
}

const relayHubID = "hubrelaysessionstart"

func newRelay(t *testing.T, w *world, p *Port) *relay {
	t.Helper()
	st, err := state.Open(t.TempDir())
	require.NoError(t, err)
	t.Cleanup(func() { _ = st.Close() })
	ident, err := identity.New()
	require.NoError(t, err)
	keys, err := identity.NewKeyring(ident, st, time.Now)
	require.NoError(t, err)
	fake := memfake.New(transport.KindRelay, time.Now)
	r := &relay{t: t, w: w}
	disp := actions.NewDispatcher()
	r.h = handlers.Register(disp, handlers.Deps{
		DB: w.db, Store: st, Sessions: p, Sealer: keys,
		LateEcho: func(ctx context.Context, req actions.Request, o actions.Outcome) error {
			return r.proc.LateEcho(ctx, req, o)
		},
	})
	r.proc = actions.NewProcessor(actions.Config{
		Store: st, Transport: fake, Sealer: secure.NewSealer(keys), Opener: secure.NewOpener(keys, keys), Keys: keys,
		Dispatcher: disp, HubRelayID: relayHubID, Clock: time.Now,
	})
	meta, err := keys.MetaKey()
	require.NoError(t, err)
	epoch, err := keys.CurrentEpoch()
	require.NoError(t, err)
	r.phone, err = hubtest.New(hubtest.Config{
		Hub: keys.HubID(), HubKX: ident.Agreement.PublicKey(), MetaKey: meta, Epoch: epoch,
		HubRelayID: relayHubID, Transport: fake, Clock: time.Now,
	})
	require.NoError(t, err)
	dev := r.phone.Device()
	dev.TypingAllowed, dev.StartSessionsAllowed, dev.StartSessionsGranted = true, true, true
	require.NoError(t, st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.LinkDevice(tx, dev) }))
	return r
}

func (r *relay) line(sid int64, text string) uint64 {
	r.t.Helper()
	a := r.phone.NewAction("session_input")
	id := strconv.FormatInt(sid, 10)
	a.EntityID = &id
	b, _ := json.Marshal(text)
	a.Params["text"] = b
	seq, err := r.phone.Queue(a)
	require.NoError(r.t, err)
	require.NoError(r.t, r.phone.Send(seq))
	return seq
}

// echo passes the processor and syncs the phone until seq's echo satisfies ok.
func (r *relay) echo(seq uint64, what string, ok func(wire.ActionRequest) bool) wire.ActionRequest {
	r.t.Helper()
	var e wire.ActionRequest
	eventually(r.t, what, func() bool {
		_, err := r.proc.Pass(context.Background())
		require.NoError(r.t, err)
		_, err = r.phone.Sync()
		require.NoError(r.t, err)
		e = r.phone.Echoes[seq]
		return ok(e)
	})
	return e
}

func submitted(e wire.ActionRequest) bool {
	return e.Status == wire.StatusApplied && string(e.Result["delivery"]) == `"submitted"`
}

// PROJ-16 with the real host: the owner's draft in the Desktop's pane holds a
// phone line (prompt_has_text) and the PTY gets no byte from the hub; after
// the owner's Return the held line goes on the next read of the session
// states (DeliverHeld).
func TestProj16_ADraftHoldsTheLineAndNothingIsPasted(t *testing.T) {
	w := newWorld(t)
	p := w.port()
	sid, info := w.startedSession(p)
	r := newRelay(t, w, p)
	pane := attach(t, w.socket, info)
	pane.send(sessionhost.Input, []byte("my draft"))
	w.waitPTY(sid, "my draft")

	seq := r.line(sid, "hello")
	r.echo(seq, "the line held", func(e wire.ActionRequest) bool {
		return e.Status == wire.StatusHeld && e.Reason != nil && *e.Reason == "prompt_has_text"
	})
	time.Sleep(200 * time.Millisecond)
	assert.Equal(t, "my draft", w.pty(sid), "not one byte from the hub beside the owner's draft")

	pane.send(sessionhost.Input, []byte("\r"))
	w.waitPTY(sid, "my draft\r")
	r.h.DeliverHeld(context.Background())
	r.echo(seq, "the held line submitted", submitted)
	w.waitPTY(sid, "my draft\r"+pasteOpen+"hello"+pasteClose+"\r")
}

// Smoke: a phone line through the hub's handlers and the real port reaches a
// stub agent as one bracketed paste, then a lone CR; the echo is applied.
func TestHubTypesAPhoneLineIntoAStubSession(t *testing.T) {
	w := newWorld(t)
	p := w.port()
	sid, _ := w.startedSession(p)
	r := newRelay(t, w, p)
	seq := r.line(sid, "hello")
	r.echo(seq, "the line submitted", submitted)
	w.waitPTY(sid, pasteOpen+"hello"+pasteClose+"\r")
}

// portWith is a port over w's host whose deps change applies (a short
// launch watch).
func (w *world) portWith(change func(*Deps)) *Port {
	w.t.Helper()
	d := w.deps()
	d.LaunchWatch = time.Second
	change(&d)
	p := NewPort(d, nil)
	w.t.Cleanup(func() { _ = p.Close() })
	return p
}

// The phone's start is answered only after the launch was checked (Swift's
// launchCheck): a refused launch, a failed placement and an unreachable host
// are errors, never a started session, and each row says why.
func TestPortStartFailuresAreNeverStarted(t *testing.T) {
	w := newWorld(t)
	ctx := context.Background()

	refused := w.portWith(func(d *Deps) { d.Shell = filepath.Join(w.stub, "no-such-shell") })
	res, err := refused.Start(ctx, handlers.StartRequest{Workbench: w.wb, Brief: "go"})
	require.Error(t, err)
	assert.Equal(t, StateFailed, res.State)
	assert.Contains(t, w.row(res.SessionID).agentError, "launch refused: ")

	unplaced := w.portWith(func(d *Deps) {
		d.Integrate = func(ctx context.Context, _ int64, _ string, _ agentkind.Kind) error {
			_, err := w.db.ExecContext(ctx, `DELETE FROM terminal_sessions WHERE folder_path = ?`, w.folder)
			return err
		}
	})
	_, err = unplaced.Start(ctx, handlers.StartRequest{Workbench: w.wb, Brief: "go", Place: "worktree"})
	require.ErrorContains(t, err, "into its worktree")

	unreachable := w.portWith(func(d *Deps) { d.Socket = filepath.Join(t.TempDir(), "none.sock") })
	res, err = unreachable.Start(ctx, handlers.StartRequest{Workbench: w.wb, Brief: "go"})
	require.Error(t, err)
	assert.Equal(t, StateFailed, res.State)
	assert.Equal(t, "the session host is not running", w.row(res.SessionID).agentError)
}

// Swift's launch watch: a launch that exits 127 at once (no claude on the
// login PATH) is claude_not_found, not a started session.
func TestPortStartAnExit127IsClaudeNotFound(t *testing.T) {
	w := newWorld(t)
	shell := filepath.Join(w.stub, "exit127")
	writeScript(t, shell, "exit 127\n")
	p := w.portWith(func(d *Deps) { d.Shell = shell })
	res, err := p.Start(context.Background(), handlers.StartRequest{Workbench: w.wb, Brief: "go"})
	var missing *handlers.AgentNotFoundError
	require.True(t, errors.As(err, &missing), "%v", err)
	assert.Equal(t, "claude", missing.Agent)
	assert.Equal(t, StateFailed, res.State)
	assert.Equal(t, "claude was not found", w.row(res.SessionID).agentError)

	other := filepath.Join(w.stub, "exit3")
	writeScript(t, other, "exit 3\n")
	res, err = w.portWith(func(d *Deps) { d.Shell = other }).Start(context.Background(), handlers.StartRequest{Workbench: w.wb, Brief: "go"})
	require.NoError(t, err, "any other exit is the session's own end")
	assert.Equal(t, StateRunning, res.State)
}

func (r *relay) start(brief string) uint64 {
	r.t.Helper()
	a := r.phone.NewAction("session_start")
	for k, v := range map[string]any{"workbench_id": r.w.wb, "mode": "new", "plan_first": false, "bring_forward": false, "brief": brief} {
		b, _ := json.Marshal(v)
		a.Params[k] = b
	}
	seq, err := r.phone.Queue(a)
	require.NoError(r.t, err)
	require.NoError(r.t, r.phone.Send(seq))
	return seq
}

func failedWith(reason string) func(wire.ActionRequest) bool {
	return func(e wire.ActionRequest) bool {
		return e.Status == wire.StatusFailed && e.Reason != nil && *e.Reason == reason
	}
}

// Through the hub's handlers: the phone's session_start echoes failed
// write_failed for a refused launch and claude_not_found for an exit 127,
// and applied {stage: starting} only for a launch that ran.
func TestThePhonesStartEchoesTheLaunchCheck(t *testing.T) {
	w := newWorld(t)
	refused := newRelay(t, w, w.portWith(func(d *Deps) { d.Shell = filepath.Join(w.stub, "no-such-shell") }))
	refused.echo(refused.start("go"), "a refused launch failed write_failed", failedWith("write_failed"))

	shell := filepath.Join(w.stub, "exit127")
	writeScript(t, shell, "exit 127\n")
	missing := newRelay(t, w, w.portWith(func(d *Deps) { d.Shell = shell }))
	missing.echo(missing.start("go"), "an exit 127 failed claude_not_found", failedWith("claude_not_found"))

	ok := newRelay(t, w, w.port())
	e := ok.echo(ok.start("go"), "a launch that ran applied", func(e wire.ActionRequest) bool { return e.Status == wire.StatusApplied })
	assert.JSONEq(t, `"starting"`, string(e.Result["stage"]))
}
