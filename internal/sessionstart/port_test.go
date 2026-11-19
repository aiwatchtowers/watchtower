package sessionstart

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
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
	"watchtower/internal/sessionmsg"
)

const (
	pasteOpen = "\x1b[200~"
	// pasteModeOn is the stub's bracketed-paste switch (DEC mode 2004).
	pasteModeOn = "\x1b[?2004h"
	pasteClose  = "\x1b[201~"
)

// ptyMark is the marker ptyBefore types.
const ptyMark = "<mark>"

// ptyBefore types ptyMark through pane and returns what the session's PTY
// got before it: the PTY takes bytes in order, so anything the host typed
// before this call is in it — no window to wait out. The marker stays in
// the PTY.
func (w *world) ptyBefore(row int64, pane *pane) string {
	w.t.Helper()
	before := len(w.pty(row))
	pane.send(sessionhost.Input, []byte(ptyMark))
	var got string
	eventually(w.t, "the marker", func() bool {
		got = w.pty(row)
		return strings.Contains(got[min(before, len(got)):], ptyMark)
	})
	return got[:strings.LastIndex(got, ptyMark)]
}

func (w *world) port() *Port {
	w.t.Helper()
	d := w.deps()
	// One look at the launch: these sessions keep running, so a longer watch
	// would only run out its time.
	d.LaunchWatch = time.Nanosecond
	p := NewPort(d, nil)
	w.t.Cleanup(func() { _ = p.Close() })
	return p
}

// startedSession is a claude session started through the port, launched and
// idle for its run (a Stop hook after its start). The hook is written once
// the host has read the stub's bracketed-paste switch, as a real agent's
// Stop hook comes after it drew its prompt: stamped earlier, a line could
// reach the host before the switch and end cannot_type (CI, 2026-11-19).
func (w *world) startedSession(p *Port) (int64, sessionhost.SessionInfo) {
	w.t.Helper()
	res, err := p.Start(context.Background(), handlers.StartRequest{Workbench: w.wb, Brief: "go"})
	require.NoError(w.t, err)
	require.Equal(w.t, StateRunning, res.State, "the port answers after the launch was checked")
	info := w.launched(res.SessionID)
	w.waitPasteMode(info)
	_, err = w.db.Exec(`UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = ? WHERE id = ?`,
		db.AgentStateStamp(time.Now().Add(time.Second)), res.SessionID)
	require.NoError(w.t, err)
	return res.SessionID, info
}

// waitPasteMode returns once the host has read the session's bracketed-paste
// switch (DEC 2004), on a pane attached and closed again: an attach replays
// the host's tracked modes before the output, and the host tracks a chunk's
// modes before it forwards the chunk, so the switch on the pane means the
// host holds it. No clock: the pane's frames are the event.
func (w *world) waitPasteMode(info sessionhost.SessionInfo) {
	w.t.Helper()
	pane := attach(w.t, w.socket, info)
	defer func() { _ = pane.nc.Close() }()
	var seen []byte
	for !bytes.Contains(seen, []byte(pasteModeOn)) {
		ft, b, err := sessionhost.ReadFrame(pane.nc)
		require.NoError(w.t, err)
		if ft == sessionhost.Exit || ft == sessionhost.Error {
			w.t.Fatalf("session %d ended before its paste mode (%s): %q", info.Row, b, seen)
		}
		if ft == sessionhost.Output {
			seen = append(seen, b...)
		}
	}
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

	runs, err := p.Runs(context.Background())
	require.NoError(t, err)
	assert.Equal(t, map[int64]time.Time{sid: time.UnixMilli(info.StartedAtMs)}, runs,
		"Runs is this scope's running sessions only, with the run's start")
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
	assert.Equal(t, "half typed", w.ptyBefore(sid, pane))

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

// PromptState reads the run's prompt through the host and types nothing: an
// empty prompt, then the owner's draft; another launch is not running and
// never "empty".
func TestPortPromptStateReadsTheDraftAndTypesNothing(t *testing.T) {
	w := newWorld(t)
	p := w.port()
	sid, info := w.startedSession(p)
	holds, known, err := p.PromptState(context.Background(), sid, info.Launch)
	require.NoError(t, err)
	assert.True(t, known)
	assert.False(t, holds, "an empty prompt")

	pane := attach(t, w.socket, info)
	pane.send(sessionhost.Input, []byte("my draft"))
	w.waitPTY(sid, "my draft")
	holds, known, err = p.PromptState(context.Background(), sid, info.Launch)
	require.NoError(t, err)
	assert.True(t, known)
	assert.True(t, holds, "the owner's draft")
	assert.Equal(t, "my draft", w.ptyBefore(sid, pane), "not one byte from the read")

	_, known, err = p.PromptState(context.Background(), sid, info.Launch+1)
	assert.ErrorIs(t, err, ErrNotRunning)
	assert.False(t, known)
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

// finalStatuses are the echo statuses that never change again.
var finalStatuses = []string{wire.StatusApplied, wire.StatusFailed, wire.StatusExpired, wire.StatusCancelled}

// echo passes the processor and syncs the phone until seq's echo satisfies ok.
// A final echo that does not fails the test at once instead of waiting for an
// echo that cannot come.
func (r *relay) echo(seq uint64, what string, ok func(wire.ActionRequest) bool) wire.ActionRequest {
	r.t.Helper()
	var e wire.ActionRequest
	eventually(r.t, what, func() bool {
		_, err := r.proc.Pass(context.Background())
		require.NoError(r.t, err)
		_, err = r.phone.Sync()
		require.NoError(r.t, err)
		e = r.phone.Echoes[seq]
		if !ok(e) && slices.Contains(finalStatuses, e.Status) {
			reason := ""
			if e.Reason != nil {
				reason = *e.Reason
			}
			r.t.Fatalf("%s: the echo ended %s (reason %q, result %v)", what, e.Status, reason, e.Result)
		}
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
	assert.Equal(t, "my draft", w.ptyBefore(sid, pane), "not one byte from the hub beside the owner's draft")

	pane.send(sessionhost.Input, []byte("\r"))
	w.waitPTY(sid, "my draft"+ptyMark+"\r")
	r.h.DeliverHeld(context.Background())
	r.echo(seq, "the held line submitted", submitted)
	w.waitPTY(sid, "my draft"+ptyMark+"\r"+pasteOpen+"hello"+pasteClose+"\r")
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

// portWith is a port over w's host whose deps change applies. Its launch
// watch never runs out: every launch it starts ends (or never ran), and the
// watch returns at that end however long a loaded machine takes to it.
func (w *world) portWith(change func(*Deps)) *Port {
	w.t.Helper()
	d := w.deps()
	d.LaunchWatch = time.Hour
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

	unreachable := w.portWith(func(d *Deps) { d.Socket = droppingSocket(t) })
	res, err = unreachable.Start(ctx, handlers.StartRequest{Workbench: w.wb, Brief: "go"})
	require.Error(t, err)
	assert.Equal(t, StateFailed, res.State)
	assert.Equal(t, "the session host is not running", w.row(res.SessionID).agentError)
}

// A sub-session whose launch fails after the host answered stays a failed
// start, and its parent gets a failure line (spec §7 "sub-session start",
// amended); a failed start with no parent tells no one.
func TestFailedSubSessionStartTellsTheParent(t *testing.T) {
	w := newWorld(t)
	w.installHome()
	ctx := context.Background()
	parent, err := w.db.CreateTerminalSession(ctx, db.NewTerminalSession{WorkbenchID: w.wb, Kind: "codex", Title: "Lead", FolderPath: w.folder})
	require.NoError(t, err)
	refused := w.portWith(func(d *Deps) { d.Shell = filepath.Join(w.stub, "no-such-shell") })

	res, err := refused.Start(ctx, handlers.StartRequest{Workbench: w.wb, Brief: "go", ParentSessionID: parent})
	require.Error(t, err)
	assert.Equal(t, StateFailed, res.State)
	reason := w.row(res.SessionID).agentError
	require.Contains(t, reason, "launch refused: ")

	_, err = refused.Start(ctx, handlers.StartRequest{Workbench: w.wb, Brief: "go"})
	require.Error(t, err)

	msgs, err := w.db.QueuedSessionMessages(ctx)
	require.NoError(t, err)
	require.Len(t, msgs, 1, "only the sub-session's failure is told")
	assert.Equal(t, sessionmsg.KindFailure, msgs[0].Kind)
	assert.Equal(t, parent, msgs[0].ToSessionID.Int64)
	assert.Equal(t, res.SessionID, msgs[0].FromSessionID.Int64)
	assert.Equal(t, sessionmsg.FailureLine(res.SessionID, sessionmsg.StartFailureReason(reason)), msgs[0].Text)
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

// Runs only dials a host that runs: with none answering it is
// ErrHostNotRunning, and no host was started (the CLI that would start one
// leaves a mark when run).
func TestPortRunsNeverStartsAHost(t *testing.T) {
	dir, err := os.MkdirTemp("", "ss")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	mark := filepath.Join(dir, "started")
	cli := filepath.Join(dir, "watchtower")
	writeScript(t, cli, "touch '"+mark+"'\nexit 1\n")
	p := NewPort(Deps{Socket: filepath.Join(dir, "h.sock"), CLIPath: cli, DBPath: filepath.Join(dir, "watchtower.db")}, nil)
	t.Cleanup(func() { _ = p.Close() })
	for range 3 {
		runs, err := p.Runs(context.Background())
		require.ErrorIs(t, err, ErrHostNotRunning)
		assert.Empty(t, runs)
	}
	_, err = os.Stat(mark)
	assert.True(t, os.IsNotExist(err), "Runs started a session host (stat: %v)", err)
}
