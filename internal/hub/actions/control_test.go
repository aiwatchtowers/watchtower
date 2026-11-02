package actions

import (
	"context"
	"encoding/json"
	"slices"
	"testing"
	"time"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
)

// controls is every hub control of kind the phone read.
func (w *world) controls(kind string) []wire.Control {
	var out []wire.Control
	for _, c := range w.phone.Controls {
		if c.Kind == kind {
			out = append(out, c)
		}
	}
	return out
}

func (w *world) pending() int {
	w.t.Helper()
	rows, err := w.st.PendingControls(w.queue(w.phone))
	if err != nil {
		w.t.Fatal(err)
	}
	return len(rows)
}

func (w *world) holds(wireName string) bool {
	w.t.Helper()
	names, err := w.phone.Records()
	if err != nil {
		w.t.Fatal(err)
	}
	return slices.Contains(names, wireName)
}

// Sim rule 7a twin: a resend_from that could not be written is written later,
// once.
func TestHubResendFromRetriedUntilWritten(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil { // 2 never reaches the mailbox
			t.Fatal(err)
		}
		w.act("test_noop")
		w.fake.FailNext("save", transport.ErrUnavailable)
		w.fake.FailNext("save", transport.ErrUnavailable)
		for range 2 {
			if r := w.pass(); r.ControlsWritten != 0 {
				t.Fatalf("pass %+v wrote through an outage", r)
			}
			w.sync(w.phone)
		}
		if len(w.controls(wire.ControlResendFrom)) != 0 || w.pending() != 2 {
			t.Fatalf("before the third save: controls %v, %d queued", w.phone.Controls, w.pending())
		}
		w.settle()
		w.wantCalls(noops(1, 2, 3)...)
		if got := w.controls(wire.ControlResendFrom); len(got) != 1 || *got[0].Seq != 2 {
			t.Fatalf("resend_from %v, want one for 2", got)
		}
		w.wantEmptyMailbox()
	})
}

func TestEchoOwedIsRetriedEveryPass(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		seq := w.act("test_noop")
		for i := 1; i <= 3; i++ {
			w.fake.FailNext("save", transport.ErrUnavailable)
			if r := w.pass(); r.ControlsWritten != 0 {
				t.Fatalf("pass %d %+v", i, r)
			}
			rows, err := w.st.PendingControls(w.queue(w.phone))
			if err != nil || len(rows) != 1 || rows[0].Attempts != i {
				t.Fatalf("pass %d: queue %+v, %v", i, rows, err)
			}
		}
		w.settle()
		w.wantCalls(noops(seq)...)
		w.wantEcho(seq, wire.StatusApplied, "")
		if w.pending() != 0 {
			t.Fatalf("%d rows still queued", w.pending())
		}
		w.wantEmptyMailbox()
	})
}

func TestControlRefusedForGoodIsDropped(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		first := w.act("test_noop")
		second := w.act("test_noop")
		w.fake.FailNext("save", transport.ErrRecordTooLarge)
		w.pass()
		if w.pending() != 0 {
			t.Fatalf("%d rows still queued: the queue stopped at a row refused for good", w.pending())
		}
		w.sync(w.phone)
		if _, ok := w.phone.Echoes[first]; ok {
			t.Fatal("the refused echo reached the phone")
		}
		w.wantEcho(second, wire.StatusApplied, "")
	})
}

func TestPhoneControlsDeletedOnceRead(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		epoch, err := w.keys.CurrentEpoch()
		if err != nil {
			t.Fatal(err)
		}
		id, err := w.phone.WriteControl(wire.Control{Kind: wire.ControlEpochAck, Epoch: &epoch})
		if err != nil {
			t.Fatal(err)
		}
		w.pass()
		if w.holds(w.phone.ControlWireName(id)) {
			t.Fatal("the epoch_ack was not deleted once read")
		}
		// A second copy of the same control id (here with another body) is
		// deleted unread.
		m := uint64(5)
		if _, err := w.phone.WriteControl(wire.Control{ID: id, Kind: wire.ControlSkipTo, Seq: &m}); err != nil {
			t.Fatal(err)
		}
		w.pass()
		if w.holds(w.phone.ControlWireName(id)) {
			t.Fatal("the second copy was not deleted")
		}
		if d := w.device(w.phone); d.LastAppliedActionSeq != 0 {
			t.Fatalf("the second copy was read: last applied %d", d.LastAppliedActionSeq)
		}
		// A control the hub does not know is read and deleted too.
		other, err := w.phone.WriteControl(wire.Control{Kind: "future_control"})
		if err != nil {
			t.Fatal(err)
		}
		w.pass()
		if w.holds(w.phone.ControlWireName(other)) {
			t.Fatal("an unknown control was left behind")
		}
		w.wantEmptyMailbox()
		if w.pending() != 0 {
			t.Fatalf("%d rows queued for phone controls", w.pending())
		}
	})
}

func TestEpochAckRecorded(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		epoch, err := w.keys.CurrentEpoch()
		if err != nil {
			t.Fatal(err)
		}
		ahead := epoch + 1
		other := w.addPhone().ID().String()
		for _, c := range []wire.Control{
			{Kind: wire.ControlEpochAck, Epoch: &epoch},
			{Kind: wire.ControlEpochAck, Epoch: &ahead},                   // an epoch the hub never had
			{Kind: wire.ControlEpochAck, Epoch: &ahead, DeviceID: &other}, // naming another phone
			{Kind: wire.ControlEpochAck},                                  // no epoch
		} {
			if _, err := w.phone.WriteControl(c); err != nil {
				t.Fatal(err)
			}
		}
		w.pass()
		if d := w.device(w.phone); d.AckedEpoch != epoch {
			t.Fatalf("acked epoch %d, want %d", d.AckedEpoch, epoch)
		}
		w.wantEmptyMailbox()
	})
}

func TestTransportSwitchIsRejectedNotSupportedYet(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		target := wire.TransportCloudKit
		if w.fake.Kind() == transport.KindCloudKit {
			target = wire.TransportRelay
		}
		id, err := w.phone.WriteControl(wire.Control{Kind: wire.ControlSwitch, Target: &target})
		if err != nil {
			t.Fatal(err)
		}
		w.fake.FailNext("save", transport.ErrUnavailable) // the answer is queued and retried
		w.pass()
		if w.holds(w.phone.ControlWireName(id)) {
			t.Fatal("the transport_switch request was not deleted")
		}
		if w.pending() != 1 {
			t.Fatalf("%d rows queued, want the rejection", w.pending())
		}
		w.settle()
		got := w.controls(wire.ControlSwitchRejected)
		if len(got) != 1 || got[0].Reason == nil || *got[0].Reason != switchNotSupported ||
			got[0].DeviceID == nil || !sameID(*got[0].DeviceID, w.phone.ID()) || got[0].RetryAfterS != nil {
			t.Fatalf("rejections %+v", got)
		}
		if len(w.phone.Controls) != 1 {
			t.Fatalf("controls %+v", w.phone.Controls)
		}
		if w.proc.cfg.Transport != w.tr {
			t.Fatal("the hub's transport changed")
		}
		w.wantEmptyMailbox()
	})
}

func TestProbeApplied(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		RegisterProbe(w.disp)
		a := w.phone.NewAction("probe")
		a.Params["nonce"] = json.RawMessage(`"n-1"`)
		withNonce := w.send(a)
		bare := w.act("probe")
		w.settle()
		hub, _ := json.Marshal(w.keys.HubID().String())
		e := w.wantEcho(withNonce, wire.StatusApplied, "")
		if string(e.Result["nonce"]) != `"n-1"` || string(e.Result["hub_id"]) != string(hub) {
			t.Fatalf("probe result %s", mustJSON(t, e.Result))
		}
		e = w.wantEcho(bare, wire.StatusApplied, "")
		if _, ok := e.Result["nonce"]; ok || string(e.Result["hub_id"]) != string(hub) {
			t.Fatalf("bare probe result %s", mustJSON(t, e.Result))
		}
		w.wantEmptyMailbox()
	})
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestUnknownRecordKindIgnored(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		name, err := w.phone.WriteFrame("future_kind", "future-1", []byte(`{"id":"1"}`))
		if err != nil {
			t.Fatal(err)
		}
		r := w.pass()
		if r.Read != 0 || r.ControlsWritten != 0 || w.pending() != 0 {
			t.Fatalf("pass %+v, %d queued", r, w.pending())
		}
		if !w.holds(name) {
			t.Fatal("a record of another lane was deleted")
		}
		w.wantCalls()
	})
}

func TestHygieneSweepsStaleRecordsOnCloudKitOnly(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		first := w.act("test_noop")
		w.pass() // the applied echo waits for a phone that went quiet
		second := w.act("test_noop")
		undecided, _ := w.phone.Sealed(second)
		future, err := w.phone.WriteFrame("future_kind", "future-1", []byte(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.fake.Write(w.phone.Zone(), "junk", []byte("not an envelope"), transport.Expect{Mode: transport.ExpectAbsent}); err != nil {
			t.Fatal(err)
		}
		key := w.ledgerKey(first)
		w.mu.Lock()
		w.now = w.now.Add(ActionMaxAge + 2*24*time.Hour)
		w.mu.Unlock()

		rep, err := w.proc.Hygiene(w.ctx)
		if err != nil || !rep.Ran || rep.Pruned != 1 {
			t.Fatalf("hygiene %+v, %v", rep, err)
		}
		names, err := w.phone.Records()
		if err != nil {
			t.Fatal(err)
		}
		if w.fake.Kind() == transport.KindCloudKit {
			// The echo and the junk go; the undecided action and the other
			// lane's record stay.
			if rep.Deleted != 2 || len(names) != 2 || !w.holds(undecided) || !w.holds(future) {
				t.Fatalf("deleted %d, left %d records", rep.Deleted, len(names))
			}
		} else if rep.Deleted != 0 || len(names) != 4 { // the hosted relay's TTL does it
			t.Fatalf("deleted %d on the hosted relay, left %d records", rep.Deleted, len(names))
		}
		if phase, _, _, err := w.st.Phase(key); err != nil || phase != "" {
			t.Fatalf("ledger row of action %d: %q, %v", first, phase, err)
		}
		if rep, err := w.proc.Hygiene(w.ctx); err != nil || rep.Ran {
			t.Fatalf("second run the same day %+v, %v", rep, err)
		}
	})
}

// failSave refuses the save call number n (1-based) with err.
type failSave struct {
	*memfake.Fake
	calls, n int
	err      error
}

func (f *failSave) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	f.calls++
	if f.calls == f.n {
		return nil, f.err
	}
	return f.Fake.Save(ctx, items)
}

func TestResendFromRefusedForGoodAsksTheGapAgain(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil { // 2 never reaches the mailbox
			t.Fatal(err)
		}
		w.act("test_noop")
		// The pass saves the held echo of 3, then resend_from(2): refuse that one for good.
		w.use(&failSave{Fake: w.fake, n: 2, err: transport.ErrForbidden})
		w.pass()
		if w.pending() != 0 {
			t.Fatalf("%d rows still queued", w.pending())
		}
		if d := w.device(w.phone); d.ResendRequestedFrom != 0 {
			t.Fatalf("resend_requested_from %d: the gap stays marked asked", d.ResendRequestedFrom)
		}
		w.sync(w.phone)
		w.act("test_noop") // 4: held, and the gap is asked again
		w.settle()
		w.wantCalls(noops(1, 2, 3, 4)...)
		if got := w.controls(wire.ControlResendFrom); len(got) != 1 || *got[0].Seq != 2 {
			t.Fatalf("resend_from %v, want one for 2", got)
		}
		w.wantEmptyMailbox()
	})
}
