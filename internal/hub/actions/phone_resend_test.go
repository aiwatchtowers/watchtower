package actions

import (
	"database/sql"
	"encoding/json"
	"testing"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// The iOS phone's resends (relay client Phase 1, Task 6): a resend_from is
// answered by writing each requested action's original sealed bytes again as
// a new version of its record, over whatever holds the name (the phone's own
// earlier copy, or the hub's non-final echo, under ExpectSeq of the version it
// read). The hub must treat those bytes as the same action, never as a
// rollback, and apply each action once.

// stored is the record at wireName in the phone's mailbox.
func (w *world) stored(wireName string) (transport.Stored, bool) {
	w.t.Helper()
	var since uint64
	for {
		b, err := w.fake.Changes(w.ctx, w.phone.Zone(), since)
		if err != nil {
			w.t.Fatal(err)
		}
		for _, r := range b.Changed {
			if r.Name == wireName {
				return r, true
			}
		}
		if !b.More {
			return transport.Stored{}, false
		}
		since = b.NewSeq
	}
}

// hubEcho opens the hub's echo at action seq's name.
func (w *world) hubEcho(seq uint64) (wire.ActionRequest, transport.Stored) {
	w.t.Helper()
	name, _ := w.phone.Sealed(seq)
	rec, ok := w.stored(name)
	if !ok {
		w.t.Fatalf("no record at action %d's name", seq)
	}
	o, err := secure.NewOpener(w.keys, w.keys).OwnEcho(w.phone.Zone(), rec.Name, rec.Envelope)
	if err != nil {
		w.t.Fatalf("action %d's record is not the hub's echo: %v", seq, err)
	}
	var a wire.ActionRequest
	if err := json.Unmarshal(o.Frame.Payload, &a); err != nil {
		w.t.Fatal(err)
	}
	return a, rec
}

// resendFroms counts the hub's resend_from controls in the mailbox.
func (w *world) resendFroms() int {
	w.t.Helper()
	opener := secure.NewOpener(w.keys, w.keys)
	n := 0
	var since uint64
	for {
		b, err := w.fake.Changes(w.ctx, w.phone.Zone(), since)
		if err != nil {
			w.t.Fatal(err)
		}
		for _, r := range b.Changed {
			o, err := opener.OwnEcho(w.phone.Zone(), r.Name, r.Envelope)
			if err != nil || o.Frame.Kind != kindControl {
				continue
			}
			var c wire.Control
			if err := json.Unmarshal(o.Frame.Payload, &c); err != nil {
				w.t.Fatal(err)
			}
			if c.Kind == wire.ControlResendFrom {
				n++
			}
		}
		if !b.More {
			return n
		}
		since = b.NewSeq
	}
}

// overwrite writes action seq's original sealed bytes over the record at its
// name under ExpectSeq(at), as the phone's resend does.
func (w *world) overwrite(seq, at uint64) uint64 {
	w.t.Helper()
	name, env := w.phone.Sealed(seq)
	out, err := w.fake.Write(w.phone.Zone(), name, env, transport.Expect{Mode: transport.ExpectSeq, Seq: at})
	if err != nil || !out.Saved {
		w.t.Fatalf("overwriting action %d: saved %v conflict %v err %v", seq, out.Saved, out.Conflict != nil, err)
	}
	return out.RecordSeq
}

func (w *world) wantHubEcho(seq uint64, status string) transport.Stored {
	w.t.Helper()
	a, rec := w.hubEcho(seq)
	if a.Status != status {
		w.t.Fatalf("echo of action %d: %s, want %s", seq, a.Status, status)
	}
	return rec
}

func (w *world) wantNoHeld() {
	w.t.Helper()
	held, err := w.st.HeldActions(w.phone.ID().String())
	if err != nil {
		w.t.Fatal(err)
	}
	if len(held) != 0 {
		w.t.Fatalf("%d held actions remain", len(held))
	}
}

func TestResendOfIdenticalBytesAsANewVersionIsAppliedOnce(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		for range 2 {
			if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil {
				t.Fatal(err)
			}
		}
		if err := w.phone.Send(2); err != nil { // a2 only
			t.Fatal(err)
		}
		if r := w.pass(); r.Held != 1 || r.Applied != 0 {
			t.Fatalf("first pass %+v", r)
		}
		if n := w.resendFroms(); n != 1 {
			t.Fatalf("resend_from written %d times, want 1", n)
		}

		// The hub had opened a copy of a1 before a crash: its rollback mark is there.
		name1, env1 := w.phone.Sealed(1)
		opener := secure.NewOpener(w.keys, w.keys)
		o, err := opener.FromPhone(w.phone.Zone(), name1, env1)
		if err != nil {
			t.Fatal(err)
		}
		if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error {
			return state.RecordSeen(tx, name1, o.Sender.String(), o.Epoch, o.Seq)
		}); err != nil {
			t.Fatal(err)
		}

		// The phone writes a1, then writes the same bytes again as a new version.
		out, err := w.fake.Write(w.phone.Zone(), name1, env1, transport.Expect{Mode: transport.ExpectAbsent})
		if err != nil || !out.Saved {
			t.Fatalf("writing a1: %+v %v", out, err)
		}
		if at := w.overwrite(1, out.RecordSeq); at == out.RecordSeq {
			t.Fatalf("the overwrite kept version %d", at)
		}
		cur, ok := w.stored(name1)
		if !ok {
			t.Fatal("a1 is not in the mailbox")
		}
		o, err = opener.FromPhone(w.phone.Zone(), cur.Name, cur.Envelope)
		if err != nil {
			t.Fatalf("a1's new version does not open: %v", err)
		}
		if o.Verdict != secure.Same {
			t.Fatalf("verdict %v, want Same", o.Verdict)
		}

		if r := w.pass(); r.Applied != 2 {
			t.Fatalf("second pass %+v", r)
		}
		w.wantCalls(noops(1, 2)...)
		if d := w.device(w.phone); d.LastAppliedActionSeq != 2 {
			t.Fatalf("last applied %d", d.LastAppliedActionSeq)
		}
		w.wantHubEcho(2, wire.StatusApplied)
		rec := w.wantHubEcho(1, wire.StatusApplied)
		w.wantNoHeld()

		// A further identical overwrite is a repeat: echoed again, not applied.
		w.overwrite(1, rec.RecordSeq)
		if r := w.pass(); r.Repeats != 1 || r.Applied != 0 {
			t.Fatalf("third pass %+v", r)
		}
		w.wantHubEcho(1, wire.StatusApplied)
		w.wantCalls(noops(1, 2)...)
	})
}

func TestResendOverAHeldEchoIsHeldOnceThenApplied(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		for range 2 {
			if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil {
				t.Fatal(err)
			}
		}
		if err := w.phone.Send(2); err != nil {
			t.Fatal(err)
		}
		if r := w.pass(); r.Held != 1 {
			t.Fatalf("first pass %+v", r)
		}
		echo := w.wantHubEcho(2, wire.StatusHeld)
		if n := w.resendFroms(); n != 1 {
			t.Fatalf("resend_from written %d times, want 1", n)
		}

		// The phone resends a2 over the hub's held echo.
		w.overwrite(2, echo.RecordSeq)
		if r := w.pass(); r.Held != 1 || r.Applied != 0 {
			t.Fatalf("second pass %+v", r)
		}
		held, err := w.st.HeldActions(w.phone.ID().String())
		if err != nil {
			t.Fatal(err)
		}
		if len(held) != 1 || held[0].ActionSeq != 2 {
			t.Fatalf("held actions %+v", held)
		}
		if again := w.wantHubEcho(2, wire.StatusHeld); again.RecordSeq == echo.RecordSeq {
			t.Fatal("the held echo was not rewritten")
		}
		if n := w.resendFroms(); n != 1 {
			t.Fatalf("resend_from written %d times, want 1", n)
		}
		w.wantCalls()

		// Then a1 arrives: both are applied in order, once each.
		if err := w.phone.Send(1); err != nil {
			t.Fatal(err)
		}
		if r := w.pass(); r.Applied != 2 {
			t.Fatalf("third pass %+v", r)
		}
		w.wantCalls(noops(1, 2)...)
		w.wantHubEcho(1, wire.StatusApplied)
		w.wantHubEcho(2, wire.StatusApplied)
		w.wantNoHeld()
		if d := w.device(w.phone); d.LastAppliedActionSeq != 2 {
			t.Fatalf("last applied %d", d.LastAppliedActionSeq)
		}
	})
}
