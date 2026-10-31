package handlers

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
)

// Go twins of SessionInputHandlersTests (PROJ-16). Swift's SessionLineDelivery
// queue and its follow wiring have no Go counterpart: a held line lives in the
// sidecar and is retried by DeliverHeld, which the runtime calls after each
// read of the session states. "The session is live" and "the same run" read
// SessionPort.Live (ask #807); the owner's draft is the host's
// (TestProj16_ADraftHoldsTheLineAndNothingIsPasted lives with the real host,
// in internal/sessionstart).

// lineClock is a settable clock.
type lineClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *lineClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *lineClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

// lineSealer stands in for the keyring's SealLocal: the bytes it stores never
// hold the plaintext. failOpen, when set, is returned by the next OpenLocal
// (a keyring that is not available for a moment). A value that does not open
// is identity.ErrSealedKeyUnreadable, as the keyring says.
type lineSealer struct {
	mu       sync.Mutex
	failOpen error
}

func flipBytes(b []byte) []byte {
	out := make([]byte, len(b))
	for i, c := range b {
		out[i] = c ^ 0x5a
	}
	return out
}

func (*lineSealer) SealLocal(label string, plain []byte) ([]byte, error) {
	return append([]byte("sealed:"+label+":"), flipBytes(plain)...), nil
}

func (s *lineSealer) OpenLocal(label string, sealed []byte) ([]byte, error) {
	s.mu.Lock()
	fail := s.failOpen
	s.failOpen = nil
	s.mu.Unlock()
	if fail != nil {
		return nil, fail
	}
	prefix := []byte("sealed:" + label + ":")
	if !bytes.HasPrefix(sealed, prefix) {
		return nil, identity.ErrSealedKeyUnreadable
	}
	return flipBytes(sealed[len(prefix):]), nil
}

func (s *lineSealer) failNextOpen(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.failOpen = err
}

// linePort is the fake session-host with a hook inside the next Live read
// (a try's first read), a count of the reads, and recorded starts and stops.
type linePort struct {
	*fakePort
	mu         sync.Mutex
	duringLive func()
	reads      int
	starts     []StartRequest
	startRes   StartResult
	startErr   error
	stops      []int64
}

func (p *linePort) Live(ctx context.Context, id int64) (LiveRun, bool, error) {
	p.mu.Lock()
	f := p.duringLive
	p.duringLive = nil
	p.reads++
	p.mu.Unlock()
	if f != nil {
		f()
	}
	return p.fakePort.Live(ctx, id)
}

func (p *linePort) readCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.reads
}

func (p *linePort) Start(_ context.Context, r StartRequest) (StartResult, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.starts = append(p.starts, r)
	return p.startRes, p.startErr
}

func (p *linePort) Stop(_ context.Context, id int64) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.stops = append(p.stops, id)
	return nil
}

func (p *linePort) stopCalls() []int64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return slices.Clone(p.stops)
}

func (p *linePort) startCalls() []StartRequest {
	p.mu.Lock()
	defer p.mu.Unlock()
	return slices.Clone(p.starts)
}

func (p *linePort) setResult(r DeliverResult) {
	p.fakePort.mu.Lock()
	defer p.fakePort.mu.Unlock()
	p.result = r
}

// lineEchoes is the late echoes written.
type lineEchoes struct {
	mu    sync.Mutex
	items []pendingEcho
}

func (l *lineEchoes) add(_ context.Context, r actions.Request, o actions.Outcome) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.items = append(l.items, pendingEcho{r: r, o: o})
	return nil
}

func (l *lineEchoes) of(r actions.Request) []actions.Outcome {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []actions.Outcome
	for _, e := range l.items {
		if e.r.RecordName == r.RecordName {
			out = append(out, e.o)
		}
	}
	return out
}

type lineEnv struct {
	*env
	lp     *linePort
	clock  *lineClock
	echoes *lineEchoes
	sealer *lineSealer
	// timeout is the handlers' deadline (0: DefaultTimeout).
	timeout time.Duration
	wb      int64
}

func newLineEnv(t *testing.T) *lineEnv {
	t.Helper()
	e := &env{t: t, db: db.OpenTestDB(t), port: newFakePort(), disp: actions.NewDispatcher(), device: secure.ID{0x0a, 0x0b}}
	st, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	e.store = st
	le := &lineEnv{env: e, lp: &linePort{fakePort: e.port}, clock: &lineClock{now: time.Now()}, echoes: &lineEchoes{},
		sealer: &lineSealer{}}
	e.linkDevice(true, false, false)
	e.h = le.register()
	le.wb = e.workbench()
	return le
}

// register is a hub (re)start over the same sidecar and session-host.
func (le *lineEnv) register() *Handlers { return le.registerWith(le.sealer) }

// registerWith is a (re)start with sealer (nil: a runtime built without one).
func (le *lineEnv) registerWith(sealer LocalSealer) *Handlers {
	d := Deps{
		DB: le.db, Store: le.store, Sessions: le.lp,
		DesktopHost: func() bool { return le.desktop },
		Clipboard:   func(s string) error { le.clip = append(le.clip, s); return nil },
		Clock:       le.clock.Now, LateEcho: le.echoes.add, Timeout: le.timeout,
	}
	if sealer != nil {
		d.Sealer = sealer
	}
	return Register(actions.NewDispatcher(), d)
}

// liveSession is a running claude session of the env's workbench.
func (le *lineEnv) liveSession() int64 {
	le.t.Helper()
	sid := le.agentSession("claude")
	le.lp.start(sid)
	return sid
}

func (le *lineEnv) agentSession(kind string) int64 {
	le.t.Helper()
	var agentID any
	if kind == "claude" {
		agentID = "00000000-0000-4000-8000-0000000000" + strconv.Itoa(10+le.seq)
		le.seq++
	}
	res, err := le.db.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, ?, 'Ship it', '/tmp/acme', ?)`, le.wb, kind, agentID)
	if err != nil {
		le.t.Fatal(err)
	}
	sid, _ := res.LastInsertId()
	return sid
}

// setState writes the session's hook state for the current run: stopped,
// working, needs_approval, running (no hook this run) or marked (the run's
// mark, no turn).
func (le *lineEnv) setState(sid int64, s string) { le.setStateAt(sid, s, le.clock.Now()) }

func (le *lineEnv) setStateAt(sid int64, s string, at time.Time) {
	le.t.Helper()
	var agentState, stamp any
	switch s {
	case "stopped":
		agentState, stamp = "waiting", db.AgentStateStamp(at)
	case "working":
		agentState, stamp = "working", db.AgentStateStamp(at)
	case "needs_approval":
		agentState, stamp = "approval", db.AgentStateStamp(at)
	case "marked":
		stamp = db.AgentStateStamp(at)
	case "running":
	default:
		le.t.Fatalf("unknown state %q", s)
	}
	le.exec(`UPDATE terminal_sessions SET agent_state = ?, agent_state_at = ?, finished_at = NULL WHERE id = ?`, agentState, stamp, sid)
}

func (le *lineEnv) action(kind string, entity *string, params map[string]any, device secure.ID) actions.Request {
	le.t.Helper()
	le.seq++
	raw := map[string]json.RawMessage{}
	for k, v := range params {
		b, err := json.Marshal(v)
		if err != nil {
			le.t.Fatal(err)
		}
		raw[k] = b
	}
	seq := uint64(le.seq)
	a := wire.ActionRequest{
		ID: "act-" + strconv.Itoa(le.seq), Kind: kind, EntityID: entity, Params: raw,
		CreatedAt: wire.Time{Time: le.clock.Now()}, Status: wire.StatusPending, ActionSeq: &seq,
	}
	return actions.Request{Device: device, RecordName: "a-" + device.String() + "-" + strconv.Itoa(le.seq), Action: a, ReceivedAt: le.clock.Now()}
}

func entityStr(v int64) *string { s := strconv.FormatInt(v, 10); return &s }

func (le *lineEnv) input(sid int64, text string) actions.Request {
	return le.action("session_input", entityStr(sid), map[string]any{"text": text}, le.device)
}

func (le *lineEnv) finish(sid int64) actions.Request {
	return le.action("session_finish_request", entityStr(sid), nil, le.device)
}

func (le *lineEnv) cancel(original actions.Request) actions.Request {
	return le.action("session_input_cancel", &original.Action.ID, nil, le.device)
}

func (le *lineEnv) send(h *Handlers, r actions.Request) actions.Outcome {
	return h.sessionInput(context.Background(), r)
}

// pastes is the text of every line handed to session-host, in order.
func (le *lineEnv) pastes() []string {
	var out []string
	for _, r := range le.port.lines() {
		out = append(out, r.Text)
	}
	return out
}

func (le *lineEnv) heldRows() int { return le.heldRowsOf(le.h) }

func (le *lineEnv) heldRowsOf(h *Handlers) int {
	le.t.Helper()
	rows, err := h.heldLines()
	if err != nil {
		le.t.Fatal(err)
	}
	return len(rows)
}

func (le *lineEnv) setTyping(allowed bool) {
	le.t.Helper()
	err := le.store.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(`UPDATE devices SET typing_allowed = ?`, allowed)
		return err
	})
	if err != nil {
		le.t.Fatal(err)
	}
}

// settled waits for every late echo queued by h.
func settled(h *Handlers) { h.lines.pending.Wait() }

func wantPastes(t *testing.T, le *lineEnv, want ...string) {
	t.Helper()
	if got := le.pastes(); !slices.Equal(got, want) {
		t.Fatalf("pastes = %q, want %q", got, want)
	}
}

func wantLine(t *testing.T, got actions.Outcome, delivery string, whileBusy bool) {
	t.Helper()
	if got.Status != wire.StatusApplied || got.Delivery != delivery {
		t.Fatalf("outcome = %+v, want applied %s", got, delivery)
	}
	_, has := got.Result["while_busy"]
	if has != whileBusy || (whileBusy && got.Result["while_busy"] != true) {
		t.Fatalf("while_busy in %v, want %v", got.Result, whileBusy)
	}
}

func outcomeLabels(os []actions.Outcome) []string {
	var out []string
	for _, o := range os {
		s := o.Status
		if o.Reason != "" {
			s += ":" + o.Reason
		}
		if o.Delivery != "" {
			s += ":" + o.Delivery
		}
		out = append(out, s)
	}
	return out
}

func wantEchoes(t *testing.T, le *lineEnv, r actions.Request, want ...string) {
	t.Helper()
	if got := outcomeLabels(le.echoes.of(r)); !slices.Equal(got, want) {
		t.Fatalf("late echoes = %q, want %q", got, want)
	}
}

// MARK: - PROJ-16 guards

// Condition (1): without the owner's Allow nothing is typed — the line is
// refused, not held.
func TestProj16_AnUnallowedDeviceTypesNothing(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "stopped")
	le.setTyping(false)

	line := le.send(le.h, le.input(sid, "Rebase onto main"))
	wrapUp := le.send(le.h, le.finish(sid))

	wantOutcome(t, line, wire.StatusFailed, reasonDeviceNotAllowed)
	wantOutcome(t, wrapUp, wire.StatusFailed, reasonDeviceNotAllowed)
	le.h.DeliverHeld(context.Background())
	wantPastes(t, le)
	if n := le.heldRows(); n != 0 {
		t.Fatalf("%d held lines", n)
	}
}

// Condition (0): a device not linked never reaches the handler — nothing
// typed. E2E: a phone whose key the hub does not hold is dropped unanswered
// (D9); a linked phone's record naming another device fails
// device_not_linked.
func TestProj16_AnUnlinkedDeviceTypesNothing(t *testing.T) {
	rw := newRelayWorld(t)
	sid := rw.le.liveSession()
	rw.le.setState(sid, "stopped")
	misnamed := rw.lineAction(rw.phone, sid, "Delete the docs")
	stranger := rw.newPhone()
	other := stranger.ID().String()
	misnamed.DeviceID = &other
	mseq := rw.send(misnamed)
	rw.settle()

	// A phone never linked: its own mailbox is never read, and its record
	// put into the linked phone's mailbox does not open there.
	seq, err := stranger.Queue(rw.lineAction(stranger, sid, "Delete the tests"))
	if err != nil {
		t.Fatal(err)
	}
	if err := stranger.Send(seq); err != nil {
		t.Fatal(err)
	}
	name, env := stranger.Sealed(seq)
	if _, err := rw.fake.Write(rw.phone.Zone(), name, env, transport.Expect{Mode: transport.ExpectAbsent}); err != nil {
		t.Fatal(err)
	}
	if r, err := rw.proc.Pass(context.Background()); err != nil || r.Read != 0 || r.Echoed != 0 {
		t.Fatalf("pass %+v %v", r, err)
	}

	e := rw.phone.Echoes[mseq]
	if e.Status != wire.StatusFailed || e.Reason == nil || *e.Reason != "device_not_linked" {
		t.Fatalf("misnamed echo %+v", e)
	}
	if len(stranger.Echoes) != 0 {
		t.Fatalf("the unlinked phone got %d echoes", len(stranger.Echoes))
	}
	wantPastes(t, rw.le)
	if n := rw.le.heldRows(); n != 0 {
		t.Fatalf("%d held lines", n)
	}
}

// Condition (2), amended 2026-10-25 (ask #614): a working Claude agent takes
// the line and the echo says so (while_busy); a permission prompt still holds
// the next line, so a prompt never gets a phone line.
func TestProj16_AWorkingClaudeSessionTakesTheLineButNeverAPrompt(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "working")

	out := le.send(le.h, le.input(sid, "Also update the changelog"))

	wantLine(t, out, deliverySubmitted, true)
	wantPastes(t, le, "Also update the changelog")
	if !le.port.lines()[0].HoldIfPromptText {
		t.Fatal("a phone line must set HoldIfPromptText")
	}

	le.setStateAt(sid, "needs_approval", le.clock.Now().Add(30*time.Second))
	next := le.send(le.h, le.input(sid, "and the readme"))

	wantOutcome(t, next, wire.StatusHeld, inputReasonNeedsApproval)
	wantPastes(t, le, "Also update the changelog")
}

// Send while busy is Claude only: a Codex session is refused before any line
// check, and nothing types.
func TestProj16_AWorkingCodexSessionStillHoldsTheLine(t *testing.T) {
	le := newLineEnv(t)
	sid := le.agentSession("codex")
	le.lp.start(sid)
	le.setState(sid, "working")

	out := le.send(le.h, le.input(sid, "Also update the changelog"))

	wantOutcome(t, out, wire.StatusFailed, reasonNotFound)
	wantPastes(t, le)
}

// I-5: a session at a permission prompt never gets a phone line, not even
// the wrap-up line, however often the states are read.
func TestProj16_NeedsApprovalNeverGetsAPhoneLine(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "needs_approval")
	line := le.input(sid, "yes")

	first := le.send(le.h, line)
	wrapUp := le.send(le.h, le.finish(sid))
	for range 3 {
		le.h.DeliverHeld(context.Background())
	}

	wantOutcome(t, first, wire.StatusHeld, inputReasonNeedsApproval)
	wantOutcome(t, wrapUp, wire.StatusHeld, inputReasonNeedsApproval)
	wantPastes(t, le)
	// Answered on the Mac, the agent works on: still nothing.
	le.setState(sid, "running")
	le.h.DeliverHeld(context.Background())
	wantPastes(t, le)
	settled(le.h)
	wantEchoes(t, le, line, "held:agent_busy")
}

// A held line expires 24 h after the phone created it, even if the session is
// idle by then: nothing typed, expired.
func TestProj16_AHeldLineExpiresAfter24h(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "running")
	line := le.input(sid, "Ship it")
	wantOutcome(t, le.send(le.h, line), wire.StatusHeld, inputReasonAgentBusy)

	le.clock.advance(heldLineLifetime + time.Second)
	le.setState(sid, "stopped")
	le.h.DeliverHeld(context.Background())

	wantPastes(t, le)
	settled(le.h)
	wantEchoes(t, le, line, "expired:expired")
	if n := le.heldRows(); n != 0 {
		t.Fatalf("%d held lines", n)
	}
}

// Amended 2026-10-17 (#565, ask #305 q3): a device not allowed to type cannot
// start a session at all, even with the owner's start grant, so its brief
// never reaches one.
func TestProj16_AnEditedBriefFromAnUnallowedDeviceIsIgnored(t *testing.T) {
	le := newLineEnv(t)
	le.setTyping(false)
	le.setStartGrants(true, true)
	target := le.target(le.wb, 0, "Ship it")

	out := le.h.sessionStartStop(context.Background(), le.start(&target, startParams(le.wb, "new", false, "Delete the tests")))

	wantOutcome(t, out, wire.StatusFailed, reasonDeviceNotAllowed)
	if calls := le.lp.startCalls(); len(calls) != 0 {
		t.Fatalf("started %+v", calls)
	}
}

// Revoke on the Mac (link.Center.Allow typing off, through its OnRevoke
// seam, as Swift's MobileLinkCenter.onTypingRevoked) fails the device's held
// lines at once — echoed failed device_not_allowed with no read of the
// session states — and nothing of them is typed later.
func TestProj16_RevokeFailsHeldLines(t *testing.T) {
	rw := newRelayWorld(t)
	sid := rw.le.liveSession()
	rw.le.setState(sid, "running")
	center := link.NewCenter(link.Config{Store: rw.le.store, Keys: rw.keys, Opener: secure.NewOpener(rw.keys, rw.keys)})
	center.OnRevoke(rw.h.Revoked)
	first := rw.send(rw.lineAction(rw.phone, sid, "One"))
	second := rw.send(rw.lineAction(rw.phone, sid, "Two"))
	rw.settle()
	for _, seq := range []uint64{first, second} {
		if e := rw.phone.Echoes[seq]; e.Status != wire.StatusHeld {
			t.Fatalf("action %d: %+v, want held", seq, e)
		}
	}
	reads := rw.le.lp.readCount()

	if err := center.Allow(rw.phone.ID().String(), link.GrantTyping, false); err != nil {
		t.Fatal(err)
	}

	settled(rw.h)
	rw.settle()
	for _, seq := range []uint64{first, second} {
		e := rw.phone.Echoes[seq]
		if e.Status != wire.StatusFailed || e.Reason == nil || *e.Reason != reasonDeviceNotAllowed {
			t.Fatalf("action %d: %+v, want failed device_not_allowed", seq, e)
		}
	}
	if n := rw.le.lp.readCount(); n != reads {
		t.Fatalf("the revoke read the session %d times: it must fail the lines at once", n-reads)
	}
	if n := rw.le.heldRowsOf(rw.h); n != 0 {
		t.Fatalf("%d held lines", n)
	}
	rw.le.setState(sid, "stopped")
	rw.h.DeliverHeld(context.Background())
	wantPastes(t, rw.le)
}

// MARK: - Idle and busy

func TestProj16_AnIdleSessionEchoHasNoWhileBusy(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "stopped")

	wantLine(t, le.send(le.h, le.input(sid, "go on")), deliverySubmitted, false)
}

// A line that went while the agent worked but was left typed (its Return
// withheld) carries no while_busy.
func TestALineLeftTypedWhileWorkingHasNoWhileBusy(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "working")
	le.lp.setResult(DeliverResult{Outcome: DeliverTyped})

	wantLine(t, le.send(le.h, le.input(sid, "Also update the changelog")), deliveryTyped, false)
}

func TestAMarkedRunWithNoTurnYetIsIdle(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "marked")

	wantLine(t, le.send(le.h, le.input(sid, "Start with the tests")), deliverySubmitted, false)
	wantPastes(t, le, "Start with the tests")
}

// Without hooks this run the state is not known for the current run: Finished
// (and a hook state) from an earlier run does not count as idle.
func TestAFinishedStateFromAnEarlierRunIsNotIdle(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	earlier := db.AgentStateStamp(time.Now().Add(-time.Hour))
	le.exec(`UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = ?, finished_at = ? WHERE id = ?`, earlier, earlier, sid)

	out := le.send(le.h, le.input(sid, "Next one"))

	wantOutcome(t, out, wire.StatusHeld, inputReasonAgentBusy)
	wantPastes(t, le)
}

func TestAFailedStateReadHoldsTheLineAsStateUnknown(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "stopped")
	le.port.liveErr = errors.New("host unreachable")

	out := le.send(le.h, le.input(sid, "Go on"))

	wantOutcome(t, out, wire.StatusHeld, inputReasonStateUnknown)
	wantPastes(t, le)
}

func TestASessionNotRunningOrNotOnABoardFails(t *testing.T) {
	le := newLineEnv(t)
	sid := le.agentSession("claude") // never started in the host
	le.setState(sid, "stopped")

	wantOutcome(t, le.send(le.h, le.input(9999, "Hello")), wire.StatusFailed, reasonNotFound)
	wantOutcome(t, le.send(le.h, le.input(sid, "Hello")), wire.StatusFailed, inputReasonNotRunning)
	le.lp.start(sid)
	le.port.mu.Lock()
	run := le.port.live[sid]
	run.Exited = true
	le.port.live[sid] = run
	le.port.mu.Unlock()
	wantOutcome(t, le.send(le.h, le.input(sid, "Hello")), wire.StatusFailed, inputReasonNotRunning)
	wantPastes(t, le)
}

// MARK: - The text

func TestSanitizeInputMatchesTheKit(t *testing.T) {
	family := "\U0001F468\u200D\U0001F469\u200D\U0001F467"
	cases := []struct {
		in, want string
		ok       bool
	}{
		// SessionInputTextTests.testLineBreaksAndControlsBecomeOneSpaceEachAndCRLFOne
		{"  a\r\nb\nc\rd\x1b[2Je\u2028f  ", "a b c d [2Je f", true},
		// testFormatCharactersStay
		{"hi " + family, "hi " + family, true},
		{family, family, true},
		// testTheCapCountsCharactersAfterNormalizing
		{" \n\t ", "", false},
		{strings.Repeat("a", 4000), strings.Repeat("a", 4000), true},
		{strings.Repeat("a", 4001), strings.Repeat("a", 4001), false},
		{"  " + strings.Repeat("a", 4000) + "\r\n", strings.Repeat("a", 4000), true},
		// 4000 characters of four scalars each still fit.
		{strings.Repeat(family, 4000), strings.Repeat(family, 4000), true},
	}
	for i, c := range cases {
		got, ok := SanitizeInput(c.in)
		if got != c.want || ok != c.ok {
			t.Errorf("case %d: SanitizeInput = %q, %v; want %q, %v", i, got, ok, c.want, c.ok)
		}
	}
}

func TestEmptyOrWhitespaceTextIsInvalidParams(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "stopped")

	for _, text := range []string{"", "   ", "\n\t\r"} {
		wantOutcome(t, le.send(le.h, le.input(sid, text)), wire.StatusFailed, reasonInvalidParams)
	}
	wantPastes(t, le)
}

func TestLineBreaksAndControlCharactersBecomeOneLine(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "stopped")
	family := "\U0001F468\u200D\U0001F469\u200D\U0001F467"

	out := le.send(le.h, le.input(sid, "  first\nsecond\r\nthird\x1b[2Jfourth "+family+" "))

	wantLine(t, out, deliverySubmitted, false)
	wantPastes(t, le, "first second third [2Jfourth "+family)
}

func TestTextOver4000CharactersIsInvalidParams(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "stopped")

	wantOutcome(t, le.send(le.h, le.input(sid, strings.Repeat("a", 4001))), wire.StatusFailed, reasonInvalidParams)
	wantPastes(t, le)
	wantLine(t, le.send(le.h, le.input(sid, strings.Repeat("a", 4000))), deliverySubmitted, false)
}

func TestTheFinishRequestTypesTheFixedLine(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "stopped")

	wantLine(t, le.send(le.h, le.finish(sid)), deliverySubmitted, false)
	wantPastes(t, le, "Please wrap up: update the board, then call finish_session with a short summary.")
}

// MARK: - Host answers

// Every phone line sets HoldIfPromptText; the host's held(prompt_has_text)
// is echoed held with that reason, kept, and retried like the hook-fed holds.
func TestHostHeldPromptTextIsEchoedHeldAndRetried(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "stopped")
	le.lp.setResult(DeliverResult{Outcome: DeliverHeld, Reason: inputReasonPromptHasText})
	line := le.input(sid, "Run the tests")

	out := le.send(le.h, line)

	wantOutcome(t, out, wire.StatusHeld, inputReasonPromptHasText)
	if n := le.heldRows(); n != 1 {
		t.Fatalf("%d held lines, want 1", n)
	}
	le.lp.setResult(DeliverResult{Outcome: DeliverSubmitted})
	le.h.DeliverHeld(context.Background())

	settled(le.h)
	wantEchoes(t, le, line, "applied:submitted")
	reqs := le.port.lines()
	if len(reqs) != 2 || !reqs[0].HoldIfPromptText || !reqs[1].HoldIfPromptText {
		t.Fatalf("deliveries %+v", reqs)
	}
	if n := le.heldRows(); n != 0 {
		t.Fatalf("%d held lines", n)
	}
}

// Bracketed paste off: copied (on the clipboard) only on a desktop host,
// cannot_type otherwise.
func TestNoPasteModeLineIsCopiedOnlyOnADesktopHost(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "stopped")
	le.lp.setResult(DeliverResult{Outcome: DeliverNoPasteMode})

	cli := le.send(le.h, le.input(sid, "Hello"))
	if cli.Status != wire.StatusFailed || cli.Reason != reasonCannotType || cli.Message != CannotTypeMessage || len(le.clip) != 0 {
		t.Fatalf("CLI-only Mac: %+v, clipboard %q", cli, le.clip)
	}
	le.desktop = true
	desk := le.send(le.h, le.input(sid, "Hello"))
	if desk.Status != wire.StatusFailed || desk.Reason != reasonCannotType || desk.Message != copiedMessage ||
		!slices.Equal(le.clip, []string{"Hello"}) {
		t.Fatalf("desktop host: %+v, clipboard %q", desk, le.clip)
	}
}

// The sidecar keeps the phone's action sealed: only the sanitised line stays
// in the clear (spec §8 p. 4a).
func TestAHeldLinesActionIsSealedInTheSidecar(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "running")
	le.send(le.h, le.input(sid, "  marker-text\r\n"))

	var blob []byte
	var line string
	err := le.store.ReadTx(context.Background(), func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT action, line FROM held_session_lines`).Scan(&blob, &line)
	})
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(blob, []byte("marker-text")) {
		t.Fatal("the held action is stored in the clear")
	}
	if line != "marker-text" {
		t.Fatalf("line = %q", line)
	}
}

// MARK: - Cancel

func TestCancelAfterDeliveryIsANoOpAndTheOriginalStaysApplied(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "stopped")
	line := le.input(sid, "Done already")
	wantLine(t, le.send(le.h, line), deliverySubmitted, false)

	wantOutcome(t, le.send(le.h, le.cancel(line)), wire.StatusApplied, "")

	settled(le.h)
	wantEchoes(t, le, line)
}

func TestCancelWhileHeldCancelsTheOriginal(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "running")
	line := le.input(sid, "Never mind")
	le.send(le.h, line)

	wantOutcome(t, le.send(le.h, le.cancel(line)), wire.StatusApplied, "")

	settled(le.h)
	wantEchoes(t, le, line, "cancelled:cancelled")
	le.setState(sid, "stopped")
	le.h.DeliverHeld(context.Background())
	wantPastes(t, le)
	if n := le.heldRows(); n != 0 {
		t.Fatalf("%d held lines", n)
	}
}

func TestOnlyThePhoneThatSentALineCanCancelIt(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "running")
	line := le.input(sid, "Mine")
	le.send(le.h, line)
	foreign := le.action("session_input_cancel", &line.Action.ID, nil, secure.ID{0x0c})

	wantOutcome(t, le.send(le.h, foreign), wire.StatusFailed, reasonDeviceNotAllowed)

	if n := le.heldRows(); n != 1 {
		t.Fatalf("%d held lines, want the line still held", n)
	}
	// The sender rule comes first: a line being typed is no exception.
	if ok, err := le.h.claimHeld(line.RecordName); !ok || err != nil {
		t.Fatalf("claim %v %v", ok, err)
	}
	foreign = le.action("session_input_cancel", &line.Action.ID, nil, secure.ID{0x0c})
	wantOutcome(t, le.send(le.h, foreign), wire.StatusFailed, reasonDeviceNotAllowed)
	settled(le.h)
	wantEchoes(t, le, line)
}

// A cancel that lands while a held line's retry reads the states: the line is
// not typed, and nothing follows the cancelled echo.
func TestACancelDuringAnInFlightRetryTypesNothing(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "running")
	line := le.input(sid, "Never mind")
	le.send(le.h, line)
	le.setState(sid, "stopped")
	le.lp.duringLive = func() { le.send(le.h, le.cancel(line)) }

	le.h.DeliverHeld(context.Background())

	wantPastes(t, le)
	settled(le.h)
	wantEchoes(t, le, line, "cancelled:cancelled")
}

// MARK: - Hub restart

func TestAHeldLineSurvivesAHubRestartAndGoesOnIdle(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "running")
	line := le.input(sid, "After the restart")
	le.send(le.h, line)

	after := le.register()
	le.setState(sid, "stopped")
	after.DeliverHeld(context.Background())

	wantPastes(t, le, "After the restart")
	settled(after)
	wantEchoes(t, le, line, "applied:submitted")
	after.DeliverHeld(context.Background())
	wantPastes(t, le, "After the restart")
}

// A line marked as being typed when the hub stopped is never typed a second
// time: outcome_unknown.
func TestALineInterruptedMidPasteIsOutcomeUnknownAfterARestart(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "running")
	line := le.input(sid, "Half way")
	le.send(le.h, line)
	if ok, err := le.h.claimHeld(line.RecordName); !ok || err != nil {
		t.Fatalf("claim %v %v", ok, err)
	}

	after := le.register()
	le.setState(sid, "stopped")
	after.DeliverHeld(context.Background())

	wantPastes(t, le)
	settled(after)
	wantEchoes(t, le, line, "failed:outcome_unknown")
}

// A line held in one launch never goes into the next one: session_not_running.
func TestAHeldLineNeverGoesIntoAnotherLaunch(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "running")
	line := le.input(sid, "For the first run")
	le.send(le.h, line)

	le.port.mu.Lock()
	run := le.port.live[sid]
	run.StartedAt = run.StartedAt.Add(time.Second)
	le.port.live[sid] = run
	le.port.mu.Unlock()
	le.setState(sid, "stopped")
	le.h.DeliverHeld(context.Background())

	wantPastes(t, le)
	settled(le.h)
	wantEchoes(t, le, line, "failed:session_not_running")
}

// Review focus 2: the session's row is deleted while a line is held:
// session_not_running, and the line is dropped.
func TestASessionDeletedWhileALineIsHeldFailsSessionNotRunning(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "running")
	line := le.input(sid, "Too late")
	le.send(le.h, line)

	le.exec(`DELETE FROM terminal_sessions WHERE id = ?`, sid)
	le.h.DeliverHeld(context.Background())

	wantPastes(t, le)
	settled(le.h)
	wantEchoes(t, le, line, "failed:session_not_running")
	if n := le.heldRows(); n != 0 {
		t.Fatalf("%d held lines", n)
	}
}

// Lines held by their gate are tried once per read of the states: their own
// tries' reads set off nothing.
func TestLinesHeldByTheirGateAreNotRetriedInALoop(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "running")

	le.send(le.h, le.input(sid, "One"))
	le.send(le.h, le.input(sid, "Two"))
	if n := le.lp.readCount(); n != 2 {
		t.Fatalf("%d reads after two first tries, want 2", n)
	}

	le.h.DeliverHeld(context.Background())

	if n := le.lp.readCount(); n != 4 {
		t.Fatalf("%d reads, want one try each per read", n)
	}
	wantPastes(t, le)
}

// The hub stops while a held line's retry reads the states: the stopped hub
// types nothing and echoes nothing, and the next start types it once.
func TestAStopDuringAnInFlightRetryTypesNothingAndTheNextStartTypesItOnce(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "running")
	line := le.input(sid, "Later")
	le.send(le.h, line)
	le.setState(sid, "stopped")
	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	le.lp.duringLive = stop

	le.h.DeliverHeld(ctx)

	wantPastes(t, le)
	rows, err := le.h.heldLines()
	if err != nil || len(rows) != 1 || rows[0].typing {
		t.Fatalf("held rows %+v %v: want the line left held, not half-typed", rows, err)
	}
	after := le.register()
	after.DeliverHeld(context.Background())
	wantPastes(t, le, "Later")
	settled(le.h)
	settled(after)
	wantEchoes(t, le, line, "applied:submitted")
}

// A quick stop and start while a retry is in flight types the line once.
func TestAQuickStopAndStartTypesTheLineOnce(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "running")
	line := le.input(sid, "Once")
	le.send(le.h, line)
	le.setState(sid, "stopped")
	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	var after *Handlers
	le.lp.duringLive = func() {
		stop()
		after = le.register()
	}

	le.h.DeliverHeld(ctx)
	after.DeliverHeld(context.Background())
	after.DeliverHeld(context.Background())

	wantPastes(t, le, "Once")
	settled(le.h)
	settled(after)
	wantEchoes(t, le, line, "applied:submitted")
}

// Back to back: right after a line was submitted, the session counts as busy
// until a hook reports after the submit.
func TestASecondLineWaitsForAHookAfterTheFirstWasSubmitted(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "stopped")

	first := le.send(le.h, le.input(sid, "First"))
	second := le.send(le.h, le.input(sid, "Second"))
	le.h.DeliverHeld(context.Background())

	wantLine(t, first, deliverySubmitted, false)
	wantOutcome(t, second, wire.StatusHeld, inputReasonAgentBusy)
	wantPastes(t, le, "First")
	le.setStateAt(sid, "stopped", le.clock.Now().Add(time.Second))
	le.h.DeliverHeld(context.Background())
	wantPastes(t, le, "First", "Second")
}

// No hook after the submit: the session counts as busy for 30 s only.
func TestWithoutAHookTheSecondLineGoesAfterTheSettleCap(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "stopped")
	le.send(le.h, le.input(sid, "First"))
	le.send(le.h, le.input(sid, "Second"))

	le.clock.advance(busyAfterSubmit - time.Second)
	le.h.DeliverHeld(context.Background())
	wantPastes(t, le, "First")
	le.clock.advance(2 * time.Second)
	le.h.DeliverHeld(context.Background())

	wantPastes(t, le, "First", "Second")
}

// MARK: - Through the relay

// relayWorld is the env's handlers behind a real processor on a memfake
// relay, with one linked phone allowed to type.
type relayWorld struct {
	t     *testing.T
	le    *lineEnv
	keys  *identity.Keyring
	ident identity.Identity
	fake  *memfake.Fake
	proc  *actions.Processor
	phone *hubtest.Phone
	h     *Handlers
}

const testHubRelayID = "hubrelayhandlers"

func newRelayWorld(t *testing.T) *relayWorld {
	t.Helper()
	le := newLineEnv(t)
	rw := &relayWorld{t: t, le: le}
	var err error
	if rw.ident, err = identity.New(); err != nil {
		t.Fatal(err)
	}
	if rw.keys, err = identity.NewKeyring(rw.ident, le.store, le.clock.Now); err != nil {
		t.Fatal(err)
	}
	rw.fake = memfake.New(transport.KindRelay, le.clock.Now)
	disp := actions.NewDispatcher()
	rw.h = Register(disp, Deps{
		DB: le.db, Store: le.store, Sessions: le.lp, Clock: le.clock.Now, Sealer: rw.keys,
		LateEcho: func(ctx context.Context, r actions.Request, o actions.Outcome) error {
			return rw.proc.LateEcho(ctx, r, o)
		},
	})
	sealer := secure.NewSealer(rw.keys)
	rw.proc = actions.NewProcessor(actions.Config{
		Store: le.store, Transport: rw.fake, Sealer: sealer, Opener: secure.NewOpener(rw.keys, rw.keys), Keys: rw.keys,
		Dispatcher: disp, HubRelayID: testHubRelayID, Clock: le.clock.Now,
	})
	rw.phone = rw.newPhone()
	dev := rw.phone.Device()
	dev.TypingAllowed = true
	if err := le.store.WithTx(context.Background(), func(tx *sql.Tx) error { return state.LinkDevice(tx, dev) }); err != nil {
		t.Fatal(err)
	}
	return rw
}

func (rw *relayWorld) newPhone() *hubtest.Phone {
	rw.t.Helper()
	meta, err := rw.keys.MetaKey()
	if err != nil {
		rw.t.Fatal(err)
	}
	epoch, err := rw.keys.CurrentEpoch()
	if err != nil {
		rw.t.Fatal(err)
	}
	ph, err := hubtest.New(hubtest.Config{
		Hub: rw.keys.HubID(), HubKX: rw.ident.Agreement.PublicKey(), MetaKey: meta, Epoch: epoch,
		HubRelayID: testHubRelayID, Transport: rw.fake, Clock: rw.le.clock.Now,
	})
	if err != nil {
		rw.t.Fatal(err)
	}
	return ph
}

func (rw *relayWorld) lineAction(ph *hubtest.Phone, sid int64, text string) wire.ActionRequest {
	a := ph.NewAction("session_input")
	a.EntityID = entityStr(sid)
	b, _ := json.Marshal(text)
	a.Params["text"] = b
	return a
}

func (rw *relayWorld) send(a wire.ActionRequest) uint64 {
	rw.t.Helper()
	seq, err := rw.phone.Queue(a)
	if err != nil {
		rw.t.Fatal(err)
	}
	if err := rw.phone.Send(seq); err != nil {
		rw.t.Fatal(err)
	}
	return seq
}

func (rw *relayWorld) settle() {
	rw.t.Helper()
	for range 30 {
		r, err := rw.proc.Pass(context.Background())
		if err != nil {
			rw.t.Fatalf("pass: %v", err)
		}
		n, err := rw.phone.Sync()
		if err != nil {
			rw.t.Fatalf("sync: %v", err)
		}
		if r.Read+r.ControlsWritten == 0 && n == 0 {
			return
		}
	}
	rw.t.Fatal("never settled")
}

// The relay echoes held; the line's later outcome is echoed into the same
// record, sealed to the phone, and replaces the ledger's stored echo.
func TestTheRelayEchoesHeldThenTheLaterOutcomeAndKeepsIt(t *testing.T) {
	rw := newRelayWorld(t)
	sid := rw.le.liveSession()
	rw.le.setState(sid, "running")
	seq := rw.send(rw.lineAction(rw.phone, sid, "Through the relay"))

	rw.settle()
	if e := rw.phone.Echoes[seq]; e.Status != wire.StatusHeld || e.Reason == nil || *e.Reason != inputReasonAgentBusy {
		t.Fatalf("first echo %+v", e)
	}
	rw.le.setState(sid, "stopped")
	rw.h.DeliverHeld(context.Background())
	settled(rw.h)
	rw.settle()

	e := rw.phone.Echoes[seq]
	if e.Status != wire.StatusApplied || string(e.Result["delivery"]) != `"submitted"` {
		t.Fatalf("late echo %+v", e)
	}
	wantPastes(t, rw.le, "Through the relay")
	d, _, err := rw.le.store.Device(rw.phone.ID().String())
	if err != nil {
		t.Fatal(err)
	}
	key := "a-" + rw.phone.ID().String() + "-" + strconv.FormatUint(seq, 10) + "@" + strconv.FormatInt(d.LinkedAt.UnixMilli(), 10)
	phase, outcome, _, err := rw.le.store.Phase(key)
	if err != nil || phase != state.PhaseDone || outcome != wire.StatusApplied {
		t.Fatalf("ledger %s/%s %v", phase, outcome, err)
	}
}

// MARK: - Deadline and sidecar failures

// A first try that is still running at the dispatch's deadline (here a
// Deliver blocked on a hung host that finally answers held) holds nothing:
// the phone was answered outcome_unknown, so the line is never typed later
// and that echo is never replaced. The phone's own re-send is typed once.
func TestASlowFirstTryHeldAfterItsDeadlineIsNeverTyped(t *testing.T) {
	le := newLineEnv(t)
	le.timeout = 50 * time.Millisecond
	h := le.register()
	sid := le.liveSession()
	le.setState(sid, "stopped")
	release := make(chan struct{})
	le.port.onDeliver = func(DeliverRequest) { <-release }
	le.lp.setResult(DeliverResult{Outcome: DeliverHeld, Reason: inputReasonPromptHasText})
	first := le.input(sid, "Ship it")

	out := le.send(h, first)

	wantOutcome(t, out, wire.StatusFailed, reasonOutcomeUnknown)
	close(release)
	h.lines.tries.Wait()
	if n := le.heldRowsOf(h); n != 0 {
		t.Fatalf("%d held lines after the deadline", n)
	}

	le.port.onDeliver = nil
	le.lp.setResult(DeliverResult{Outcome: DeliverSubmitted})
	again := le.send(h, le.input(sid, "Ship it"))
	le.clock.advance(busyAfterSubmit)
	le.setState(sid, "stopped")
	h.DeliverHeld(context.Background())
	le.register().DeliverHeld(context.Background())

	wantLine(t, again, deliverySubmitted, false)
	if n := len(le.port.lines()); n != 2 {
		t.Fatalf("%d deliveries, want the timed-out try and the re-send only", n)
	}
	settled(h)
	wantEchoes(t, le, first)
}

// A sealer that cannot open for a moment (a locked keyring) keeps every
// held row: the round is skipped, nothing is echoed, and the line goes on the
// next read.
func TestATransientSealerFailureKeepsTheHeldLine(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "running")
	line := le.input(sid, "Later")
	le.send(le.h, line)
	le.setState(sid, "stopped")

	le.sealer.failNextOpen(errors.New("keyring not available"))
	le.h.DeliverHeld(context.Background())

	wantPastes(t, le)
	settled(le.h)
	wantEchoes(t, le, line)
	le.h.DeliverHeld(context.Background())
	wantPastes(t, le, "Later")
	settled(le.h)
	wantEchoes(t, le, line, "applied:submitted")
}

// A hub built without a sealer keeps the held rows too (at start and on each
// read); a later hub with one types them.
func TestAHubWithoutASealerKeepsTheHeldLines(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "running")
	line := le.input(sid, "Later")
	le.send(le.h, line)
	le.setState(sid, "stopped")

	bare := le.registerWith(nil)
	bare.DeliverHeld(context.Background())

	wantPastes(t, le)
	settled(bare)
	wantEchoes(t, le, line)
	after := le.register()
	after.DeliverHeld(context.Background())
	wantPastes(t, le, "Later")
}

// A held row whose sealed text genuinely does not open (the hub's identity
// was recreated) is removed and echoed failed: it can never be typed.
func TestAHeldLineThatDoesNotOpenIsDroppedWithAFailedEcho(t *testing.T) {
	le := newLineEnv(t)
	sid := le.liveSession()
	le.setState(sid, "running")
	line := le.input(sid, "Lost")
	le.send(le.h, line)
	err := le.store.WithTx(context.Background(), func(tx *sql.Tx) error {
		var blob []byte
		if err := tx.QueryRow(`SELECT action FROM held_session_lines`).Scan(&blob); err != nil {
			return err
		}
		var env heldEnvelope
		if err := json.Unmarshal(blob, &env); err != nil {
			return err
		}
		env.Params = []byte("sealed under another identity")
		b, err := json.Marshal(env)
		if err != nil {
			return err
		}
		_, err = tx.Exec(`UPDATE held_session_lines SET action = ?`, b)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	le.setState(sid, "stopped")

	le.h.DeliverHeld(context.Background())

	wantPastes(t, le)
	settled(le.h)
	wantEchoes(t, le, line, "failed:write_failed")
	if n := le.heldRows(); n != 0 {
		t.Fatalf("%d held lines", n)
	}
}
