package actions

import (
	"slices"
	"strconv"
	"testing"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// The relay sim's order tests (relay repo sim/README.md rules 2, 4–6), on
// real envelopes and both memfake kinds: relay (record_seq) and cloudkit
// (opaque change tags).

func noops(seqs ...uint64) []string {
	out := make([]string, len(seqs))
	for i, s := range seqs {
		out[i] = "test_noop:" + strconv.FormatUint(s, 10)
	}
	return out
}

func TestActionsAppliedInOrderOnce(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		var want []uint64
		for range 20 {
			want = append(want, w.act("test_noop"))
		}
		w.settle()
		w.wantCalls(noops(want...)...)
		if len(w.phone.Outbox()) != 0 {
			t.Fatalf("outbox %v", w.phone.Outbox())
		}
		// A stale copy of action 3 (as left on another transport) shows up again.
		if err := w.phone.WriteCopy(3); err != nil {
			t.Fatal(err)
		}
		w.settle()
		w.wantCalls(noops(want...)...)
		w.wantEcho(3, wire.StatusApplied, "")
		w.wantEmptyMailbox()
	})
}

func TestGapTriggersResendFrom(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil { // 2 never reaches the mailbox
			t.Fatal(err)
		}
		w.act("test_noop")
		if r := w.pass(); r.Held != 1 || r.Applied != 0 {
			t.Fatalf("pass %+v", r)
		}
		w.wantCalls(noops(1)...) // 3 is held back, 2 is missing
		w.settle()
		w.wantCalls(noops(1, 2, 3)...)
		var asked []uint64
		for _, c := range w.phone.Controls {
			if c.Kind == wire.ControlResendFrom {
				asked = append(asked, *c.Seq)
			}
		}
		if !slices.Equal(asked, []uint64{2}) {
			t.Fatalf("resend_from %v, want [2]", asked)
		}
		if len(w.phone.Outbox()) != 0 || len(w.phone.Undelivered) != 0 {
			t.Fatalf("outbox %v undelivered %v", w.phone.Outbox(), w.phone.Undelivered)
		}
		w.wantEmptyMailbox()
	})
}

func TestSkipToMarksUndelivered(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		for range 2 { // 2 and 3: never written, then lost by the outbox (a reinstall)
			seq, err := w.phone.Queue(w.phone.NewAction("test_noop"))
			if err != nil {
				t.Fatal(err)
			}
			w.phone.Forget(seq)
		}
		w.act("test_noop") // 4: held, resend_from(2) answered with skip_to(4)
		w.settle()
		w.wantCalls(noops(1, 4)...)
		if !slices.Equal(w.phone.Undelivered, []uint64{2, 3}) {
			t.Fatalf("undelivered %v", w.phone.Undelivered)
		}
		if d := w.device(w.phone); d.LastAppliedActionSeq != 4 {
			t.Fatalf("last applied %d", d.LastAppliedActionSeq)
		}
		// A retry goes out as a new action at the end of the queue.
		if seq := w.act("test_noop"); seq != 5 {
			t.Fatalf("retry seq %d", seq)
		}
		w.settle()
		w.wantCalls(noops(1, 4, 5)...)
		w.wantEmptyMailbox()
	})
}

// The Swift phone answers resend_from by rewriting each requeued action's
// same bytes as a new version under the last record_seq it knows at that name
// (the hub's held echo), so the hub reads an identical record again after its
// cursor moved past the first copy. It is the same action: held once, applied
// once, re-echoed once.
func TestIdenticalRecordRedeliveredAfterTheCursorMovedIsSame(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()

		// Held: 3 arrives ahead of 2, then comes back identical over its held
		// echo while 2 is still missing.
		two, err := w.phone.Queue(w.phone.NewAction("test_noop"))
		if err != nil {
			t.Fatal(err)
		}
		w.act("test_noop")
		if r := w.pass(); r.Held != 1 || r.Applied != 0 {
			t.Fatalf("first pass %+v", r)
		}
		w.sync(w.phone) // reads the held echo and resend_from(2): rewrites 2 and 3
		name2, _ := w.phone.Sealed(two)
		if _, err := w.fake.Delete(w.ctx, w.phone.Zone(), []transport.DeleteItem{{Name: name2}}); err != nil {
			t.Fatal(err) // 2 is lost again, so the gap stays open
		}
		// The copy is held again under the same row and its held echo restored;
		// the gap is not asked a second time.
		if r := w.pass(); r.Read != 1 || r.Applied != 0 || r.Held != 1 {
			t.Fatalf("identical held copy pass %+v", r)
		}
		if held, err := w.st.HeldActions(w.phone.ID().String()); err != nil || len(held) != 1 {
			t.Fatalf("held %v %v", held, err)
		}
		w.sync(w.phone)
		w.wantEcho(3, wire.StatusHeld, "")
		w.wantCalls(noops(1)...)

		// Applied: 2 comes back, 3 is applied once from the held row.
		if err := w.phone.WriteCopy(two); err != nil {
			t.Fatal(err)
		}
		w.settle()
		w.wantCalls(noops(1, 2, 3)...)
		w.wantEcho(3, wire.StatusApplied, "")
		w.wantEmptyMailbox()
		var asked []uint64
		for _, c := range w.phone.Controls {
			if c.Kind == wire.ControlResendFrom {
				asked = append(asked, *c.Seq)
			}
		}
		if !slices.Equal(asked, []uint64{2}) {
			t.Fatalf("resend_from %v, want [2]", asked)
		}

		// Re-echoed: applied 3 comes back identical once more.
		if err := w.phone.WriteCopy(3); err != nil {
			t.Fatal(err)
		}
		if r := w.pass(); r.Read != 1 || r.Applied != 0 || r.Echoed != 1 {
			t.Fatalf("re-echo pass %+v", r)
		}
		w.settle()
		w.wantCalls(noops(1, 2, 3)...)
		w.wantEcho(3, wire.StatusApplied, "")
		w.wantEmptyMailbox()
	})
}
