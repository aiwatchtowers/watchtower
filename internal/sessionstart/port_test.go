package sessionstart

import (
	"context"
	"database/sql"
	"encoding/json"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

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
	p := NewPort(w.deps(), nil)
	w.t.Cleanup(func() { _ = p.Close() })
	return p
}

// startedSession is a claude session started through the port, launched and
// idle for its run (a Stop hook after its start).
func (w *world) startedSession(p *Port) (int64, sessionhost.SessionInfo) {
	w.t.Helper()
	res, err := p.Start(context.Background(), handlers.StartRequest{Workbench: w.wb, Brief: "go"})
	require.NoError(w.t, err)
	require.Equal(w.t, StateStarting, res.State)
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
	dev.TypingAllowed = true
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
