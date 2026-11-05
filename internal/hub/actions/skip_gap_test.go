package actions

import (
	"database/sql"
	"testing"
	"time"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// loseMailbox deletes every record in the phone's mailbox, as a TTL purge or a
// lost write does: the phone read none of them, the hub still counts them as
// written.
func (w *world) loseMailbox() {
	w.t.Helper()
	names, err := w.phone.Records()
	if err != nil {
		w.t.Fatal(err)
	}
	for _, name := range names {
		rec, ok := w.stored(name)
		if !ok {
			continue
		}
		if _, err := w.fake.Delete(w.ctx, w.phone.Zone(), []transport.DeleteItem{{
			Name: name, Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: rec.RecordSeq},
		}}); err != nil {
			w.t.Fatal(err)
		}
	}
}

// A gap's ask, or the skip_to that answers it, can be lost for good (the
// relay's TTL purges a record nobody read). The hub asked once and would hold
// this phone's actions for ever: another action ahead of a gap that has
// outlived its ask asks again, and the phone's answer moves the order.
func TestAGapThatOutlivesItsAskIsAskedAgain(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		two, err := w.phone.Queue(w.phone.NewAction("test_noop"))
		if err != nil {
			t.Fatal(err)
		}
		w.phone.Forget(two) // refused for good: the phone no longer has it
		w.act("test_noop")  // 3: held, resend_from(2)
		w.pass()
		if n := w.resendFroms(); n != 1 {
			t.Fatalf("%d resend_from after the gap, want 1", n)
		}
		w.loseMailbox()

		w.advance(time.Minute)
		w.act("test_noop") // 4: held; the ask is fresh, so no second one
		w.pass()
		if n := w.resendFroms(); n != 0 {
			t.Fatalf("%d resend_from inside the window, want none", n)
		}

		w.advance(time.Hour)
		w.act("test_noop") // 5: held; the ask is old, so it is written again
		w.pass()
		if n := w.resendFroms(); n != 1 {
			t.Fatalf("%d resend_from after the window, want 1", n)
		}
		w.settle()
		w.wantCalls(noops(1, 3, 4, 5)...)
		if d := w.device(w.phone); d.LastAppliedActionSeq != 5 {
			t.Fatalf("last applied %d, want 5", d.LastAppliedActionSeq)
		}
	})
}

// A copy of a skipped action read after its skip_to (an earlier version the
// phone could not overwrite, read late) was never applied: it is answered
// expired, as a lapse's skipped action is (sim rule 16), not applied. The echo
// settles the phone's row with what really happened.
func TestALateCopyOfASkippedActionIsAnsweredExpired(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		two, err := w.phone.Queue(w.phone.NewAction("test_noop"))
		if err != nil {
			t.Fatal(err)
		}
		w.act("test_noop") // 3: held, resend_from(2) (the phone reads it later)
		w.pass()
		if err := w.phone.SkipTo(3); err != nil {
			t.Fatal(err)
		}
		w.pass()
		w.wantCalls(noops(1, 3)...)

		if err := w.phone.Send(two); err != nil { // the late copy
			t.Fatal(err)
		}
		if r := w.pass(); r.Repeats != 1 {
			t.Fatalf("the late copy: %+v", r)
		}
		w.sync(w.phone)
		w.wantEcho(two, wire.StatusExpired, reasonExpired)
		w.wantCalls(noops(1, 3)...)
	})
}

// The window is the contract: an ask just younger than it is not repeated, an
// ask exactly that old is.
func TestResendAskAgainAfterIsTheWindow(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil {
			t.Fatal(err)
		}
		w.act("test_noop")
		w.pass()
		asked := w.device(w.phone).ResendRequestedAt
		if asked.IsZero() {
			t.Fatal("the ask carries no time")
		}
		w.advance(ResendAskAgainAfter - time.Second)
		w.act("test_noop")
		w.pass()
		if at := w.device(w.phone).ResendRequestedAt; !at.Equal(asked) {
			t.Fatalf("asked again inside the window, at %v", at)
		}
		w.advance(time.Second)
		w.act("test_noop")
		w.pass()
		if at := w.device(w.phone).ResendRequestedAt; at.Equal(asked) {
			t.Fatal("not asked again at the window")
		}
	})
}

// A re-link starts the ask's time empty with the rest of the order.
func TestARelinkClearsTheAsk(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil {
			t.Fatal(err)
		}
		w.act("test_noop")
		w.pass()
		w.relink(w.phone)
		if d := w.device(w.phone); d.ResendRequestedFrom != 0 || !d.ResendRequestedAt.IsZero() {
			t.Fatalf("after a re-link: from %d at %v", d.ResendRequestedFrom, d.ResendRequestedAt)
		}
	})
}

// A skip passes only seqs still open: a held decision or a begun record keeps
// its own ledger row.
func TestASkipLeavesARecordAlreadyInTheLedger(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil {
			t.Fatal(err)
		}
		key := w.ledgerKey(2)
		if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error { return state.Begin(tx, key, w.clock()) }); err != nil {
			t.Fatal(err)
		}
		if err := w.phone.SkipTo(3); err != nil {
			t.Fatal(err)
		}
		w.pass()
		if phase, _, _, err := w.st.Phase(key); err != nil || phase != state.PhaseBegun {
			t.Fatalf("the begun record became %q (%v)", phase, err)
		}
	})
}

// Each phone has its own order: one phone's skip moves neither the other's
// last applied seq nor the answers of its actions, and its asks are its own.
func TestASkipOfOnePhoneLeavesTheOther(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		other := w.addPhone()
		w.act("test_noop")
		w.settle()
		if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil {
			t.Fatal(err)
		}
		w.act("test_noop") // 3: held
		w.pass()
		if err := w.phone.SkipTo(3); err != nil {
			t.Fatal(err)
		}
		w.pass()
		if d := w.device(w.phone); d.LastAppliedActionSeq != 3 {
			t.Fatalf("first phone last applied %d", d.LastAppliedActionSeq)
		}
		if d := w.device(other); d.LastAppliedActionSeq != 0 || d.ResendRequestedFrom != 0 {
			t.Fatalf("second phone moved: %+v", d)
		}
		for want := uint64(1); want <= 2; want++ { // 2 is its own, never skipped
			if _, err := other.Act("test_noop"); err != nil {
				t.Fatal(err)
			}
			w.pass()
			if d := w.device(other); d.LastAppliedActionSeq != want {
				t.Fatalf("second phone last applied %d, want %d", d.LastAppliedActionSeq, want)
			}
		}
		w.sync(other)
		if e, ok := other.Echoes[2]; !ok || e.Status != wire.StatusApplied {
			t.Fatalf("second phone's action 2: %+v %v", e, ok)
		}
	})
}
