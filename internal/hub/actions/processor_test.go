package actions

import (
	"context"
	"database/sql"
	"errors"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/wire"
)

const hubRelayID = "hubrelaytest"

// kindShared is the CloudKit memfake behind a SharedMailbox adapter: every
// phone of the hub on the one shared mailbox zone, as on CloudKit's RelayZone.
const kindShared transport.Kind = "cloudkit-shared"

var kinds = []transport.Kind{transport.KindRelay, transport.KindCloudKit, kindShared}

// sharedMailbox is the memfake as CloudKit names mailboxes: every phone's is
// transport.SharedMailboxZone (the cloudkit client's MailboxFor).
type sharedMailbox struct{ transport.Transport }

func (sharedMailbox) MailboxFor(hub, _ string) string { return transport.SharedMailboxZone(hub) }

var _ transport.SharedMailbox = sharedMailbox{}

// world is one hub (sidecar, keyring, processor) and its linked phones on
// one memfake transport, with a settable clock and a log of handler calls.
type world struct {
	t      *testing.T
	ctx    context.Context
	st     *state.Store
	keys   *identity.Keyring
	ident  identity.Identity
	fake   *memfake.Fake
	disp   *Dispatcher
	proc   *Processor
	phone  *hubtest.Phone
	sealer *secure.Sealer
	links  *link.Center
	// tr is the transport the processor started on (w.fake, or the shared
	// mailbox over it).
	tr transport.Transport
	// mailbox is every phone's zone on kindShared ("" = its own).
	mailbox string

	mu    sync.Mutex
	now   time.Time
	calls []string // "kind:action_seq"
}

func (w *world) clock() time.Time {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.now
}

func newWorld(t *testing.T, kind transport.Kind) *world {
	t.Helper()
	w := &world{t: t, ctx: context.Background(), now: time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC)}
	st, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	w.st = st
	if w.ident, err = identity.New(); err != nil {
		t.Fatal(err)
	}
	if w.keys, err = identity.NewKeyring(w.ident, st, w.clock); err != nil {
		t.Fatal(err)
	}
	var tr transport.Transport
	if kind == kindShared {
		w.fake = memfake.New(transport.KindCloudKit, w.clock)
		w.mailbox = transport.SharedMailboxZone(hubRelayID)
		tr = sharedMailbox{w.fake}
	} else {
		w.fake = memfake.New(kind, w.clock)
		tr = w.fake
	}
	w.disp = NewDispatcher()
	w.disp.Register("test_noop", w.recording(Outcome{Status: wire.StatusApplied}), KindOptions{})
	w.disp.Register("board_comment_add", w.recording(Outcome{Status: wire.StatusApplied}), KindOptions{})
	w.sealer = secure.NewSealer(w.keys)
	opener := secure.NewOpener(w.keys, w.keys)
	w.links = link.NewCenter(link.Config{Store: st, Keys: w.keys, Opener: opener, Clock: w.clock})
	w.proc = NewProcessor(Config{
		Store: st, Transport: tr, Sealer: w.sealer, Opener: opener, Keys: w.keys,
		Dispatcher: w.disp, HubRelayID: hubRelayID, Clock: w.clock, Links: w.links,
	})
	w.tr = tr
	w.phone = w.addPhone()
	return w
}

// addPhone links a new emulated phone.
func (w *world) addPhone() *hubtest.Phone {
	w.t.Helper()
	meta, err := w.keys.MetaKey()
	if err != nil {
		w.t.Fatal(err)
	}
	epoch, err := w.keys.CurrentEpoch()
	if err != nil {
		w.t.Fatal(err)
	}
	ph, err := hubtest.New(hubtest.Config{
		Hub: w.keys.HubID(), HubKX: w.ident.Agreement.PublicKey(), MetaKey: meta, Epoch: epoch,
		HubRelayID: hubRelayID, Transport: w.fake, Clock: w.clock, Mailbox: w.mailbox,
	})
	if err != nil {
		w.t.Fatal(err)
	}
	if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error { return state.LinkDevice(tx, ph.Device()) }); err != nil {
		w.t.Fatal(err)
	}
	return ph
}

// recording is a handler that logs its call and answers out.
func (w *world) recording(out Outcome) Handler {
	return func(_ context.Context, r Request) Outcome {
		w.mu.Lock()
		defer w.mu.Unlock()
		id := r.RecordName // a legacy action has no action_seq
		if r.Action.ActionSeq != nil {
			id = strconv.FormatUint(*r.Action.ActionSeq, 10)
		}
		w.calls = append(w.calls, r.Action.Kind+":"+id)
		return out
	}
}

func (w *world) callLog() []string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return slices.Clone(w.calls)
}

func (w *world) pass() PassReport {
	w.t.Helper()
	r, err := w.proc.Pass(w.ctx)
	if err != nil {
		w.t.Fatalf("pass: %v", err)
	}
	return r
}

func (w *world) sync(ph *hubtest.Phone) int {
	w.t.Helper()
	n, err := ph.Sync()
	if err != nil {
		w.t.Fatalf("phone sync: %v", err)
	}
	return n
}

// settle runs hub passes and phone syncs until neither has anything to do.
func (w *world) settle() {
	w.t.Helper()
	for range 30 {
		r := w.pass()
		n := w.sync(w.phone)
		if r.Read+r.ControlsWritten == 0 && n == 0 {
			return
		}
	}
	w.t.Fatal("the hub and the phone never settled")
}

func (w *world) act(kind string) uint64 {
	w.t.Helper()
	seq, err := w.phone.Act(kind)
	if err != nil {
		w.t.Fatal(err)
	}
	return seq
}

// send queues and writes a.
func (w *world) send(a wire.ActionRequest) uint64 {
	w.t.Helper()
	seq, err := w.phone.Queue(a)
	if err != nil {
		w.t.Fatal(err)
	}
	if err := w.phone.Send(seq); err != nil {
		w.t.Fatal(err)
	}
	return seq
}

func (w *world) device(ph *hubtest.Phone) state.Device {
	w.t.Helper()
	d, ok, err := w.st.Device(ph.ID().String())
	if err != nil || !ok {
		w.t.Fatalf("device: %v %v", ok, err)
	}
	return d
}

// ledgerKey is action seq's relay_processed key under the phone's current link.
func (w *world) ledgerKey(seq uint64) string {
	d := w.device(w.phone)
	return mailbox{linkedAt: d.LinkedAt}.ledger(actionName(w.phone.ID(), seq))
}

// wantEcho checks the phone's last echo of seq.
func (w *world) wantEcho(seq uint64, status, reason string) wire.ActionRequest {
	w.t.Helper()
	e, ok := w.phone.Echoes[seq]
	if !ok {
		w.t.Fatalf("no echo of action %d", seq)
	}
	got := ""
	if e.Reason != nil {
		got = *e.Reason
	}
	if e.Status != status || got != reason {
		w.t.Fatalf("echo of action %d: %s/%s, want %s/%s", seq, e.Status, got, status, reason)
	}
	return e
}

// use puts tr under the processor, behind the shared mailbox on kindShared.
func (w *world) use(tr transport.Transport) {
	if w.mailbox != "" {
		tr = sharedMailbox{tr}
	}
	w.proc.cfg.Transport = tr
}

// queue is ph's control_queue key: its zone, or zone@<device> in the shared
// mailbox.
func (w *world) queue(ph *hubtest.Phone) string {
	if w.mailbox != "" {
		return w.mailbox + "@" + ph.ID().String()
	}
	return ph.Zone()
}

func (w *world) wantCalls(want ...string) {
	w.t.Helper()
	if got := w.callLog(); !slices.Equal(got, want) {
		w.t.Fatalf("handler calls %v, want %v", got, want)
	}
}

func (w *world) wantEmptyMailbox() {
	w.t.Helper()
	names, err := w.phone.Records()
	if err != nil {
		w.t.Fatal(err)
	}
	if len(names) != 0 {
		w.t.Fatalf("mailbox still holds %d records", len(names))
	}
}

func eachKind(t *testing.T, fn func(t *testing.T, w *world)) {
	t.Helper()
	for _, k := range kinds {
		t.Run(string(k), func(t *testing.T) { fn(t, newWorld(t, k)) })
	}
}

func TestCrashMidApplyEchoesOutcomeUnknownOnce(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		calls := 0
		w.disp.Register("session_finish_request", func(context.Context, Request) Outcome {
			calls++
			panic("the hub stops mid-apply")
		}, KindOptions{})
		seq := w.act("session_finish_request")
		func() {
			defer func() {
				if recover() == nil {
					t.Fatal("the handler's panic did not stop the pass")
				}
			}()
			_, _ = w.proc.Pass(w.ctx)
		}()
		if phase, _, _, err := w.st.Phase(w.ledgerKey(seq)); err != nil || phase != state.PhaseBegun {
			t.Fatalf("after the crash: phase %q, %v", phase, err)
		}
		w.settle()
		if calls != 1 {
			t.Fatalf("handler ran %d times", calls)
		}
		w.wantEcho(seq, wire.StatusFailed, reasonOutcomeUnknown)
		if _, outcome, _, _ := w.st.Phase(w.ledgerKey(seq)); outcome != "failed:outcome_unknown" {
			t.Errorf("ledger outcome %q", outcome)
		}
		if d := w.device(w.phone); d.LastAppliedActionSeq != seq {
			t.Errorf("last applied %d", d.LastAppliedActionSeq)
		}
		w.wantEmptyMailbox()
	})
}

func TestOrderAndLedgerCommitInOneTransaction(t *testing.T) {
	for _, tc := range []struct {
		kind, phase, outcome string
		calls                int
	}{
		{"board_comment_add", state.PhaseBegun, "failed:outcome_unknown", 1}, // claimed: never re-applied
		{"test_noop", "", "applied", 2},                                      // idempotent: simply re-runs
	} {
		t.Run(tc.kind, func(t *testing.T) {
			w := newWorld(t, transport.KindRelay)
			seq := w.act(tc.kind)
			w.proc.fault = func(point string) error {
				if point == "done" {
					return errors.New("injected commit failure")
				}
				return nil
			}
			if _, err := w.proc.Pass(w.ctx); err == nil {
				t.Fatal("the failed done commit did not stop the pass")
			}
			if phase, _, _, err := w.st.Phase(w.ledgerKey(seq)); err != nil || phase != tc.phase {
				t.Fatalf("ledger phase %q (%v), want %q", phase, err, tc.phase)
			}
			if d := w.device(w.phone); d.LastAppliedActionSeq != 0 {
				t.Fatalf("last applied moved to %d without the ledger", d.LastAppliedActionSeq)
			}
			if rows, _ := w.st.PendingControls(w.queue(w.phone)); len(rows) != 0 {
				t.Fatalf("%d echoes queued by a rolled back transaction", len(rows))
			}
			w.proc.fault = nil
			w.settle()
			if got := len(w.callLog()); got != tc.calls {
				t.Fatalf("handler ran %d times, want %d", got, tc.calls)
			}
			if _, outcome, _, _ := w.st.Phase(w.ledgerKey(seq)); outcome != tc.outcome {
				t.Errorf("ledger outcome %q, want %q", outcome, tc.outcome)
			}
			if d := w.device(w.phone); d.LastAppliedActionSeq != seq {
				t.Errorf("last applied %d", d.LastAppliedActionSeq)
			}
		})
	}
}

func TestTokenExpiredResyncAppliesNothingTwice(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		for range 3 {
			w.act("test_noop")
		}
		w.fake.FailNext("save", transport.ErrUnavailable) // the echoes stay queued: the actions stay in the mailbox
		if r := w.pass(); r.Applied != 3 || r.ControlsWritten != 0 {
			t.Fatalf("first pass %+v", r)
		}
		token, err := w.st.ZoneToken(w.phone.Zone())
		if err != nil || token == 0 {
			t.Fatalf("token %d, %v", token, err)
		}
		w.fake.ExpireBefore(w.phone.Zone(), token+1)
		r := w.pass()
		if r.Repeats != 3 || r.Applied != 0 {
			t.Fatalf("resync pass %+v", r)
		}
		w.settle()
		w.wantCalls("test_noop:1", "test_noop:2", "test_noop:3")
		for seq := uint64(1); seq <= 3; seq++ {
			w.wantEcho(seq, wire.StatusApplied, "")
		}
		if len(w.phone.Outbox()) != 0 {
			t.Fatalf("outbox %v", w.phone.Outbox())
		}
		w.wantEmptyMailbox()
	})
}

func TestCrashBetweenOpenAndBeginRedeliveryIsApplied(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		seq := w.act("board_comment_add")
		w.proc.fault = func(point string) error {
			if point == "opened" {
				return errors.New("the hub stops after opening")
			}
			return nil
		}
		if _, err := w.proc.Pass(w.ctx); err == nil {
			t.Fatal("the fault did not stop the pass")
		}
		name, _ := w.phone.Sealed(seq)
		if _, _, ok, err := w.st.RelaySeen(name, w.phone.ID().String()); err != nil || ok {
			t.Fatalf("rollback mark written before any decision: %v %v", ok, err)
		}
		w.proc.fault = nil
		if err := w.phone.WriteCopy(seq); err != nil { // and the phone redelivers it
			t.Fatal(err)
		}
		w.settle()
		w.wantCalls("board_comment_add:1")
		w.wantEcho(seq, wire.StatusApplied, "")
		if _, _, ok, _ := w.st.RelaySeen(name, w.phone.ID().String()); !ok {
			t.Error("no rollback mark after the decision")
		}
	})
}

func TestResendFromWrittenOncePerGap(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil { // 2 never reaches the mailbox
			t.Fatal(err)
		}
		w.act("test_noop")
		w.act("test_noop")
		w.fake.FailNext("save", transport.ErrUnavailable)
		if r := w.pass(); r.Held != 2 {
			t.Fatalf("first pass %+v", r)
		}
		if err := w.phone.WriteCopy(3); err != nil { // the held action shows up again
			t.Fatal(err)
		}
		if r := w.pass(); r.Held != 1 {
			t.Fatalf("second pass %+v", r)
		}
		w.settle()
		w.wantCalls("test_noop:1", "test_noop:2", "test_noop:3", "test_noop:4")
		// A new gap gets its own request.
		if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil {
			t.Fatal(err)
		}
		w.act("test_noop")
		w.settle()
		var asked []uint64
		for _, c := range w.phone.Controls {
			if c.Kind == wire.ControlResendFrom {
				asked = append(asked, *c.Seq)
			}
		}
		if !slices.Equal(asked, []uint64{2, 5}) {
			t.Fatalf("resend_from %v, want [2 5]", asked)
		}
		w.wantCalls("test_noop:1", "test_noop:2", "test_noop:3", "test_noop:4", "test_noop:5", "test_noop:6")
		w.wantEmptyMailbox()
	})
}

func TestHandlerFailureEchoesFailedWithClass(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	w.disp.Register("ask_answer", func(context.Context, Request) Outcome {
		return Outcome{Status: wire.StatusFailed, Reason: "ask_not_open", Message: "The ask was closed"}
	}, KindOptions{})
	w.disp.Register("board_move", func(context.Context, Request) Outcome { return Outcome{} }, KindOptions{})
	w.disp.Register("session_input", func(context.Context, Request) Outcome {
		return Outcome{Status: wire.StatusApplied, Delivery: "typed", Result: map[string]any{"run": 2}}
	}, KindOptions{})
	a := w.act("ask_answer")
	b := w.act("board_move")
	c := w.act("session_input")
	w.settle()
	if e := w.wantEcho(a, wire.StatusFailed, "ask_not_open"); e.ErrorMessage == nil || *e.ErrorMessage != "The ask was closed" {
		t.Errorf("message %v", e.ErrorMessage)
	}
	w.wantEcho(b, wire.StatusFailed, reasonWriteFailed)
	if e := w.wantEcho(c, wire.StatusApplied, ""); string(e.Result["delivery"]) != `"typed"` || string(e.Result["run"]) != "2" {
		t.Errorf("result %v", e.Result)
	}
	for seq, want := range map[uint64]string{a: "failed:ask_not_open", b: "failed:write_failed", c: "applied"} {
		if _, outcome, _, _ := w.st.Phase(w.ledgerKey(seq)); outcome != want {
			t.Errorf("ledger outcome of %d: %q, want %q", seq, outcome, want)
		}
	}
	// A repeat is answered with the stored outcome, result included.
	if err := w.phone.WriteCopy(c); err != nil {
		t.Fatal(err)
	}
	if r := w.pass(); r.Repeats != 1 {
		t.Fatalf("repeat pass %+v", r)
	}
	w.sync(w.phone)
	if e := w.wantEcho(c, wire.StatusApplied, ""); string(e.Result["delivery"]) != `"typed"` {
		t.Errorf("repeat result %v", e.Result)
	}
}

func TestActionOlderThan7DaysExpires(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	w.disp.Register("session_input", w.recording(Outcome{Status: wire.StatusApplied}), KindOptions{})
	now := w.clock()
	at := func(kind string, created time.Time) uint64 {
		a := w.phone.NewAction(kind)
		a.CreatedAt = wire.Time{Time: created}
		return w.send(a)
	}
	old := at("test_noop", now.Add(-ActionMaxAge-time.Second))
	fresh := at("test_noop", now.Add(-ActionMaxAge+time.Minute))
	staleSession := at("session_input", now.Add(-SessionRequestMaxAge-time.Second))
	w.settle()
	w.wantEcho(old, wire.StatusExpired, reasonExpired)
	w.wantEcho(fresh, wire.StatusApplied, "")
	w.wantEcho(staleSession, wire.StatusExpired, reasonExpired)
	w.wantCalls("test_noop:2")
	if d := w.device(w.phone); d.LastAppliedActionSeq != staleSession {
		t.Errorf("last applied %d", d.LastAppliedActionSeq)
	}
}

func TestClockSkewOver300sExpired(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	now := w.clock()
	ahead := w.phone.NewAction("test_noop")
	ahead.CreatedAt = wire.Time{Time: now.Add(MaxClockSkew + time.Second)}
	within := w.phone.NewAction("test_noop")
	within.CreatedAt = wire.Time{Time: now.Add(MaxClockSkew - time.Second)}
	a, b := w.send(ahead), w.send(within)
	w.settle()
	if e := w.wantEcho(a, wire.StatusExpired, reasonExpired); e.ErrorMessage == nil || !strings.Contains(*e.ErrorMessage, "clocks differ") {
		t.Errorf("message %v", e.ErrorMessage)
	}
	w.wantEcho(b, wire.StatusApplied, "")
	w.wantCalls("test_noop:2")
}

func TestRefusedKindsFailWithoutHandler(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	for _, k := range RefusedKinds {
		w.disp.Register(k, w.recording(Outcome{Status: wire.StatusApplied}), KindOptions{})
	}
	var seqs []uint64
	for _, k := range append(slices.Clone(RefusedKinds), "never_registered") {
		seqs = append(seqs, w.act(k))
	}
	w.settle()
	for _, seq := range seqs {
		w.wantEcho(seq, wire.StatusFailed, reasonUnsupported)
	}
	w.wantCalls()
	if d := w.device(w.phone); d.LastAppliedActionSeq != seqs[len(seqs)-1] {
		t.Errorf("last applied %d", d.LastAppliedActionSeq)
	}
}

func TestPayloadNamingAnotherDeviceFailsNotLinked(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	other := w.addPhone()
	a := w.phone.NewAction("test_noop")
	id := other.ID().String()
	a.DeviceID = &id
	seq := w.send(a)
	hub := "AAAAAAAA-0000-4000-8000-000000000001"
	b := w.phone.NewAction("test_noop")
	b.HubID = &hub
	wrongHub := w.send(b)
	w.settle()
	w.wantEcho(seq, wire.StatusFailed, reasonDeviceNotLinked)
	w.wantEcho(wrongHub, wire.StatusFailed, reasonWrongHub)
	w.wantCalls()
}

func TestRecordInAnotherPhonesMailboxDropped(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	other := w.addPhone()
	seq, err := other.Queue(other.NewAction("test_noop"))
	if err != nil {
		t.Fatal(err)
	}
	name, env := other.Sealed(seq)
	if _, err := w.fake.Write(w.phone.Zone(), name, env, transport.Expect{Mode: transport.ExpectAbsent}); err != nil {
		t.Fatal(err)
	}
	if r := w.pass(); r.Read != 0 || r.Echoed != 0 {
		t.Fatalf("pass %+v", r)
	}
	w.wantCalls()
	if rows, _ := w.st.PendingControls(w.queue(w.phone)); len(rows) != 0 {
		t.Fatalf("%d answers to a misplaced record", len(rows))
	}
	if _, _, ok, _ := w.st.RelaySeen(name, other.ID().String()); ok {
		t.Error("rollback mark for a dropped record")
	}
}

func TestReceivedEchoBeforeHandler(t *testing.T) {
	w := newWorld(t, transport.KindCloudKit)
	var seenBefore string
	w.disp.Register("board_target_create", func(_ context.Context, r Request) Outcome {
		w.sync(w.phone)
		seenBefore = w.phone.Echoes[*r.Action.ActionSeq].Status
		return Outcome{Status: wire.StatusApplied}
	}, KindOptions{})
	seq := w.act("board_target_create")
	w.settle()
	if seenBefore != wire.StatusReceived {
		t.Fatalf("the phone saw %q before the handler ran", seenBefore)
	}
	w.wantEcho(seq, wire.StatusApplied, "")
	w.wantEmptyMailbox()
}

func TestNudgeAfterApplied(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	var got [][]string
	w.proc.cfg.Nudge = func(k []string) { got = append(got, k) }
	w.disp.Register("board_move", w.recording(Outcome{Status: wire.StatusApplied}), KindOptions{Nudges: []string{"workbench", "board"}})
	w.disp.Register("ask_answer", w.recording(Outcome{Status: wire.StatusFailed, Reason: "ask_not_open"}), KindOptions{Nudges: []string{"asks"}})
	w.act("board_move")
	w.act("board_move")
	w.act("ask_answer")
	w.pass()
	if len(got) != 1 || !slices.Equal(got[0], []string{"board", "workbench"}) {
		t.Fatalf("nudges %v", got)
	}
}

func TestDispatcherRegister(t *testing.T) {
	d := NewDispatcher()
	noop := func(context.Context, Request) Outcome { return Outcome{} }
	d.Register("session_input", noop, KindOptions{MaxAge: 30 * 24 * time.Hour})
	d.Register("custom", noop, KindOptions{})
	r, _ := d.lookup("session_input")
	if !r.opts.NonIdempotent || !r.opts.ReceivedEcho || r.opts.MaxAge != SessionRequestMaxAge {
		t.Errorf("canonical lists did not win: %+v", r.opts)
	}
	if r, _ := d.lookup("custom"); r.opts.NonIdempotent || r.opts.MaxAge != ActionMaxAge {
		t.Errorf("custom kind: %+v", r.opts)
	}
	defer func() {
		if recover() == nil {
			t.Error("a duplicate kind did not panic")
		}
	}()
	d.Register("custom", noop, KindOptions{})
}

// relink writes the phone's new link as hub/link does: the device row
// replaced (order reset), its held actions and rollback marks deleted.
func (w *world) relink(ph *hubtest.Phone) {
	w.t.Helper()
	w.mu.Lock()
	w.now = w.now.Add(time.Minute)
	w.mu.Unlock()
	if err := ph.Relink(); err != nil {
		w.t.Fatal(err)
	}
	if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error {
		if err := state.LinkDevice(tx, ph.Device()); err != nil {
			return err
		}
		for _, q := range []string{
			`DELETE FROM relay_seen WHERE sender_id = ? COLLATE NOCASE`,
			`DELETE FROM held_actions WHERE device_id = ? COLLATE NOCASE`,
		} {
			if _, err := tx.Exec(q, ph.ID().String()); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		w.t.Fatal(err)
	}
}

func TestRelinkRestartsTheOrder(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("board_comment_add")
		w.act("board_comment_add")
		w.settle()
		w.relink(w.phone)
		if seq := w.act("board_comment_add"); seq != 1 {
			t.Fatalf("new link's first seq %d", seq)
		}
		w.settle()
		w.wantCalls("board_comment_add:1", "board_comment_add:2", "board_comment_add:1")
		w.wantEcho(1, wire.StatusApplied, "")
		if d := w.device(w.phone); d.LastAppliedActionSeq != 1 {
			t.Errorf("last applied %d", d.LastAppliedActionSeq)
		}
		w.wantEmptyMailbox()
	})
}

func TestRelinkDuringApplyCommitsNothing(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	relinked := false
	w.disp.Register("ask_answer", func(context.Context, Request) Outcome {
		if !relinked {
			relinked = true
			w.relink(w.phone)
		}
		return Outcome{Status: wire.StatusApplied}
	}, KindOptions{})
	w.act("ask_answer")
	if r := w.pass(); r.Applied != 0 || r.Echoed != 0 {
		t.Fatalf("pass %+v", r)
	}
	if d := w.device(w.phone); d.LastAppliedActionSeq != 0 {
		t.Errorf("the old link's apply moved the new link's order to %d", d.LastAppliedActionSeq)
	}
	if rows, _ := w.st.PendingControls(w.queue(w.phone)); len(rows) != 0 {
		t.Errorf("%d echoes queued for the old link", len(rows))
	}
	if tok, _ := w.st.ZoneToken(w.phone.Zone()); tok != 0 {
		t.Fatalf("the page read under the old link stored its token: %d", tok)
	}
	// The new link's first action is read and applied.
	if seq := w.act("ask_answer"); seq != 1 {
		t.Fatalf("new link's first seq %d", seq)
	}
	w.settle()
	w.wantEcho(1, wire.StatusApplied, "")
	if d := w.device(w.phone); d.LastAppliedActionSeq != 1 {
		t.Errorf("last applied %d", d.LastAppliedActionSeq)
	}
}

// A received-echo kind whose apply never finished leaves only the hub's own
// received echo in the phone's record: a later pass must settle it
// outcome_unknown (never re-run) and the phone's lane must go on.
func TestStoppedApplyAfterReceivedEchoLetsTheLaneContinue(t *testing.T) {
	for _, stop := range []string{"crash", "done_commit"} {
		t.Run(stop, func(t *testing.T) {
			eachKind(t, func(t *testing.T, w *world) {
				calls := 0
				w.disp.Register("session_input", func(context.Context, Request) Outcome {
					calls++
					if stop == "crash" {
						panic("the hub stops mid-apply")
					}
					return Outcome{Status: wire.StatusApplied, Delivery: "typed"}
				}, KindOptions{})
				first := w.act("session_input")
				second := w.act("test_noop")
				if stop == "done_commit" {
					w.proc.fault = func(point string) error {
						if point == "done" {
							return errors.New("injected commit failure")
						}
						return nil
					}
				}
				func() {
					defer func() { _ = recover() }()
					_, _ = w.proc.Pass(w.ctx)
				}()
				w.proc.fault = nil
				w.sync(w.phone)
				w.wantEcho(first, wire.StatusReceived, "") // the record now holds the hub's own echo
				w.settle()
				if calls != 1 {
					t.Fatalf("handler ran %d times", calls)
				}
				w.wantEcho(first, wire.StatusFailed, reasonOutcomeUnknown)
				w.wantEcho(second, wire.StatusApplied, "")
				w.wantCalls("test_noop:2")
				if d := w.device(w.phone); d.LastAppliedActionSeq != second {
					t.Fatalf("last applied %d: the lane is wedged", d.LastAppliedActionSeq)
				}
				w.wantEmptyMailbox()
			})
		})
	}
}

func TestOnePhonesFailureDoesNotHoldBackTheOthers(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	other := w.addPhone()
	w.act("test_noop")
	if _, err := other.Act("test_noop"); err != nil {
		t.Fatal(err)
	}
	w.fake.FailNext("changes", transport.ErrUnavailable) // the first mailbox read fails
	r, err := w.proc.Pass(w.ctx)
	if err == nil {
		t.Fatal("the failed read was not reported")
	}
	if r.Applied != 1 {
		t.Fatalf("pass %+v: the other phone was held back", r)
	}
	if r := w.pass(); r.Applied != 1 {
		t.Fatalf("retry pass %+v", r)
	}
}

func TestHeldDrainHonoursTheBatchLimit(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil { // 1 never reaches the mailbox
		t.Fatal(err)
	}
	total := BatchLimit + 10
	for range total - 1 {
		w.act("test_noop")
	}
	if r := w.pass(); r.Held != BatchLimit || r.Remaining == 0 {
		t.Fatalf("first pass %+v", r)
	}
	sawRemaining := false
	for range 30 {
		r := w.pass()
		sawRemaining = sawRemaining || (r.Applied > 0 && r.Remaining > 0)
		if r.Applied > BatchLimit {
			t.Fatalf("a pass applied %d", r.Applied)
		}
		n := w.sync(w.phone)
		if r.Read+r.ControlsWritten+r.Applied == 0 && n == 0 {
			break
		}
	}
	if got := len(w.callLog()); got != total {
		t.Fatalf("%d applied, want %d", got, total)
	}
	if !sawRemaining {
		t.Error("no pass stopped at the batch limit")
	}
	if d := w.device(w.phone); d.LastAppliedActionSeq != uint64(total) {
		t.Errorf("last applied %d", d.LastAppliedActionSeq)
	}
}

func TestSkipToOutsideTheWindowIgnored(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	w.act("test_noop")
	w.settle()
	if err := w.phone.SkipTo(1 << 40); err != nil {
		t.Fatal(err)
	}
	w.pass()
	if d := w.device(w.phone); d.LastAppliedActionSeq != 1 {
		t.Fatalf("skip_to jumped the order to %d", d.LastAppliedActionSeq)
	}
	w.act("test_noop")
	w.settle()
	w.wantCalls("test_noop:1", "test_noop:2")
}

// The hosted relay transport owns its zone cursors: the processor must use its Pull.
var _ Puller = (*relay.Transport)(nil)

// puller keeps its own zone cursors, as the hosted relay transport does.
type puller struct {
	*memfake.Fake
	tokens map[string]uint64
	pulls  int
}

func (p *puller) Pull(ctx context.Context, zone string, apply func(transport.Batch) error) error {
	p.pulls++
	for {
		b, err := p.Changes(ctx, zone, p.tokens[zone])
		if err != nil {
			return err
		}
		if err := apply(b); err != nil {
			return err
		}
		p.tokens[zone] = b.NewSeq
		if !b.More {
			return nil
		}
	}
}

func TestPullerTransportOwnsTheCursor(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	pl := &puller{Fake: w.fake, tokens: map[string]uint64{}}
	w.proc.cfg.Transport = pl
	w.act("test_noop")
	w.settle()
	w.wantCalls("test_noop:1")
	if pl.pulls == 0 || pl.tokens[w.phone.Zone()] == 0 {
		t.Fatalf("pulls %d, token %d", pl.pulls, pl.tokens[w.phone.Zone()])
	}
	if tok, _ := w.st.ZoneToken(w.phone.Zone()); tok != 0 {
		t.Errorf("the processor kept a cursor of its own: %d", tok)
	}
}
