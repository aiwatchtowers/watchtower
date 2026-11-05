package actions

import (
	"context"
	"database/sql"
	"slices"
	"testing"
	"time"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
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

// A skip_to read from a lapsed phone leaves its held action held: the lapse
// check comes first, as for its actions (sim rule 16).
func TestASkipFromALapsedPhoneLeavesItsHeldActionAndEnds(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil {
			t.Fatal(err)
		}
		w.act("test_noop") // 3: held
		w.pass()
		sw := &fakeSwitch{active: w.tr.Kind(), lapsed: true, spinLimit: 1000}
		w.withSwitch(sw)
		if err := w.phone.SkipTo(3); err != nil {
			t.Fatal(err)
		}
		w.pass()
		w.wantCalls(noops(1)...)
		sw.lapsed = false
		w.pass()
		w.wantCalls(noops(1, 3)...)
	})
}

// A lapse that commits mid-drain reaches the same loop through an action: the
// drain ends when apply did not move the order.
func TestALapseCommittedMidDrainEndsTheDrain(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		two, err := w.phone.Queue(w.phone.NewAction("test_noop"))
		if err != nil {
			t.Fatal(err)
		}
		w.act("test_noop") // 3: held
		w.pass()
		// The pass's start, 2's read and 2's decision: not lapsed; 3's decision: lapsed.
		sw := &fakeSwitch{active: w.tr.Kind(), lapsedAt: 4, spinLimit: 1000}
		w.withSwitch(sw)
		if err := w.phone.Send(two); err != nil {
			t.Fatal(err)
		}
		w.pass()
		w.wantCalls(noops(1, 2)...)
		if d := w.device(w.phone); d.LastAppliedActionSeq != 2 {
			t.Fatalf("last applied %d", d.LastAppliedActionSeq)
		}
	})
}

// A resend_requested_at in the future (the Mac's clock ran fast) is no reason
// to wait for the clock to catch up: the ask counts as old.
func TestAnAskDatedInTheFutureCountsAsOld(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil {
			t.Fatal(err)
		}
		w.act("test_noop") // 3: held, asked
		w.pass()
		w.loseMailbox()
		future := w.clock().Add(24 * time.Hour)
		if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error {
			return state.SetResendRequested(tx, w.phone.ID().String(), 2, future)
		}); err != nil {
			t.Fatal(err)
		}
		w.act("test_noop") // 4: held, asked again
		w.pass()
		if n := w.resendFroms(); n != 1 {
			t.Fatalf("%d resend_from, want 1", n)
		}
	})
}

// A skip that moves the order to a new gap (skip_to(3), 3 refused for good in
// the same pass, 4 written): the hub holds 4 with 3 missing and must ask for
// it, not wait for the next action (a held Interrupt waits on this). The ask
// keeps the once-per-window rule.
func TestASkipThatLeavesHeldRowsBehindAGapAsks(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		for range 2 { // 2 and 3 never reach the mailbox
			if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil {
				t.Fatal(err)
			}
		}
		w.act("test_noop") // 4: held, resend_from(2)
		w.pass()
		w.loseMailbox()
		if err := w.phone.SkipTo(3); err != nil {
			t.Fatal(err)
		}
		w.pass()
		if d := w.device(w.phone); d.LastAppliedActionSeq != 2 || d.ResendRequestedFrom != 3 {
			t.Fatalf("after the skip: last %d, asked %d", d.LastAppliedActionSeq, d.ResendRequestedFrom)
		}
		if n := w.resendFroms(); n != 1 {
			t.Fatalf("%d resend_from for the new gap, want 1", n)
		}
		// The same skip again moves nothing and does not ask again.
		if err := w.phone.SkipTo(3); err != nil {
			t.Fatal(err)
		}
		w.pass()
		if n := w.resendFroms(); n != 1 {
			t.Fatalf("%d resend_from after a second skip, want 1", n)
		}
		// A pass with nothing to read does not ask, however old the ask is: a
		// phone away for a week must not find a mailbox full of them.
		w.advance(time.Hour)
		w.pass()
		if n := w.resendFroms(); n != 1 {
			t.Fatalf("%d resend_from after an idle pass, want 1", n)
		}
	})
}

// The Swift phone's real order on a resend: the rows first, a refused one
// listed, then the skip past it. The hub reads the rewritten row as held again,
// then the skip, and the order moves on.
func TestARowRefusedOnAResendIsSkippedAfterTheRows(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		two, err := w.phone.Queue(w.phone.NewAction("test_noop"))
		if err != nil {
			t.Fatal(err)
		}
		w.phone.RefusedForGood = map[uint64]bool{two: true}
		w.act("test_noop") // 3: held, resend_from(2)
		w.settle()
		w.wantCalls(noops(1, 3)...)
		if !slices.Equal(w.phone.Undelivered, []uint64{two}) {
			t.Fatalf("undelivered %v", w.phone.Undelivered)
		}
		w.act("test_noop")
		w.settle()
		w.wantCalls(noops(1, 3, 4)...)
		w.wantEmptyMailbox()
	})
}

// A copy of a record the hub began and then skipped past: nobody knows whether
// it ran, so it is answered outcome_unknown (a final answer, never applied).
func TestALateCopyOfABegunRecordIsAnsweredOutcomeUnknown(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		two, err := w.phone.Queue(w.phone.NewAction("test_noop"))
		if err != nil {
			t.Fatal(err)
		}
		key := w.ledgerKey(two)
		if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error { return state.Begin(tx, key, w.clock()) }); err != nil {
			t.Fatal(err)
		}
		if err := w.phone.SkipTo(3); err != nil {
			t.Fatal(err)
		}
		w.pass()
		if err := w.phone.Send(two); err != nil {
			t.Fatal(err)
		}
		w.pass()
		w.sync(w.phone)
		w.wantEcho(two, wire.StatusFailed, reasonOutcomeUnknown)
		w.wantCalls(noops(1)...)
	})
}

// countWrites counts the records the hub tries to write.
type countWrites struct {
	*memfake.Fake
	n int
}

func (f *countWrites) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	f.n += len(items)
	return f.Fake.Save(ctx, items)
}

// An ask refused for good is forgotten so the gap can be asked again, but its
// time stays: a drain asks at most once per ResendAskAgainAfter, not once per
// pass, until the refusal ends. The order then recovers.
func TestAnAskRefusedForGoodIsNotRepeatedEveryPass(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil { // 2 never sent
			t.Fatal(err)
		}
		w.act("test_noop") // 3: held
		saves := &countWrites{Fake: w.fake}
		w.use(saves)
		w.fake.RefuseWrites(w.phone.Zone(), transport.ErrForbidden)
		w.pass() // the held echo and the ask, both refused and dropped
		if d := w.device(w.phone); d.ResendRequestedFrom != 0 {
			t.Fatalf("resend_requested_from %d: the gap stays marked asked", d.ResendRequestedFrom)
		}
		saves.n = 0

		const step = 30 * time.Second
		passes := int(2 * ResendAskAgainAfter / step) // two windows of clock
		for range passes {
			w.advance(step)
			w.pass()
		}
		if saves.n < 1 || saves.n > 2 {
			t.Fatalf("%d refused writes over %d passes and two windows, want one per window at most, and some", saves.n, passes)
		}

		w.fake.RefuseWrites(w.phone.Zone(), nil)
		w.advance(ResendAskAgainAfter)
		w.settle()
		w.wantCalls(noops(1, 2, 3)...)
	})
}
