package actions

import (
	"slices"
	"testing"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// retire rotates the epoch and lets its grace run out; the phone takes the
// new keys (its keybox) and so reseals in the new epoch.
func (w *world) retire() {
	w.t.Helper()
	if err := w.keys.Rotate(identity.ReasonManual); err != nil {
		w.t.Fatal(err)
	}
	w.advance(identity.PreviousEpochGrace)
	kk, err := w.keys.KeyboxKeys()
	if err != nil {
		w.t.Fatal(err)
	}
	if err := w.phone.Keep(kk); err != nil {
		w.t.Fatal(err)
	}
}

// Sim rule 14: an action sealed in an epoch the hub no longer holds gets
// resend_from(last+1) once per record version and is left (not applied,
// marked or deleted); the phone reseals it with the same action_seq and it
// applies once.
func TestOldEpochActionGetsResendFromOncePerRecordVersion(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		seq, err := w.phone.Queue(w.phone.NewAction("test_noop")) // sealed in epoch 1
		if err != nil {
			t.Fatal(err)
		}
		w.retire()
		if err := w.phone.WriteCopy(seq); err != nil { // the old bytes
			t.Fatal(err)
		}
		w.pass()
		w.pass() // the same record version: no second answer
		w.wantCalls()
		if name, _ := w.phone.Sealed(seq); !w.holds(name) {
			t.Fatal("the old-epoch action was deleted")
		}
		w.sync(w.phone) // reads the answer and reseals
		if got := w.controls(wire.ControlResendFrom); len(got) != 1 || *got[0].Seq != seq {
			t.Fatalf("resend_from %+v, want one for %d", got, seq)
		}
		w.settle()
		if !slices.Equal(w.phone.Resealed, []uint64{seq}) {
			t.Fatalf("resealed %v", w.phone.Resealed)
		}
		w.wantCalls("test_noop:1")
		w.wantEcho(seq, wire.StatusApplied, "")
	})
}

// An old-epoch record that is no action still to apply (a stale copy of an
// applied one, a control) is dropped with no answer, as before; so is any
// old-epoch record on standby or from a lapsed phone.
func TestOldEpochRecordThatIsNoNextActionIsDropped(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		done := w.act("test_noop")
		w.settle()
		w.retire()
		if err := w.phone.WriteCopy(done); err != nil {
			t.Fatal(err)
		}
		w.pass()
		w.sync(w.phone)
		if got := w.controls(wire.ControlResendFrom); len(got) != 0 {
			t.Fatalf("a stale copy was answered: %+v", got)
		}
		w.wantCalls("test_noop:1")
	})
	for _, standby := range []bool{true, false} {
		eachKind(t, func(t *testing.T, w *world) {
			sw := &fakeSwitch{active: w.tr.Kind(), lapsed: !standby}
			if standby {
				sw.active = "elsewhere"
			}
			w.withSwitch(sw)
			seq, err := w.phone.Queue(w.phone.NewAction("test_noop"))
			if err != nil {
				t.Fatal(err)
			}
			w.retire()
			if err := w.phone.WriteCopy(seq); err != nil {
				t.Fatal(err)
			}
			w.pass()
			w.sync(w.phone)
			if got := w.controls(wire.ControlResendFrom); len(got) != 0 {
				t.Fatalf("answered resend_from (standby %v)", standby)
			}
		})
	}
}

// Sim rule 16: a lapsed phone's actions are left on the transport, never
// applied or echoed; a hub write refused ENTITLEMENT_INACTIVE is reported
// to the switcher and stays queued.
func TestLapsedPhoneIsLeftAndARefusedWriteIsReported(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		sw := &fakeSwitch{active: w.tr.Kind(), lapsed: true}
		w.withSwitch(sw)
		seq := w.act("test_noop")
		w.settle()
		w.wantCalls()
		if name, _ := w.phone.Sealed(seq); !w.holds(name) || len(w.phone.Echoes) != 0 {
			t.Fatal("a lapsed phone's action was not left alone")
		}

		sw.lapsed = false
		w.fake.RefuseWrites(w.phone.Zone(), transport.ErrEntitlementInactive)
		w.fake.RefuseWrites(w.phone.Zone(), nil)
		if err := w.phone.WriteCopy(seq); err != nil { // a new version is read
			t.Fatal(err)
		}
		w.fake.RefuseWrites(w.phone.Zone(), transport.ErrEntitlementInactive)
		w.pass() // applied; its echo is refused
		w.wantCalls("test_noop:1")
		if !slices.Contains(sw.inactive, w.phone.ID().String()) {
			t.Fatalf("not reported: %v", sw.inactive)
		}
		if w.pending() == 0 {
			t.Fatal("the refused echo left the queue")
		}
	})
}

// Sim rule 16: a lapse that commits after the record was read but before
// its decision is honoured — the action is left, neither applied nor
// echoed.
func TestALapseCommittedMidPassIsHonoured(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		sw := &fakeSwitch{active: w.tr.Kind(), lapsedAt: 2} // read: not lapsed; decision: lapsed
		w.withSwitch(sw)
		seq := w.act("test_noop")
		w.pass()
		w.sync(w.phone)
		w.wantCalls()
		if name, _ := w.phone.Sealed(seq); !w.holds(name) || len(w.phone.Echoes) != 0 {
			t.Fatal("the action was not left alone")
		}
		if sw.lapsedCalls < 2 {
			t.Fatalf("the lapse was read %d times, want it again at the decision", sw.lapsedCalls)
		}
	})
}

// Sim rule 16: an action sent before the phone's last lapse (the phone was
// told it is not delivered) gets an explicit final answer — expired — and
// is never applied; the order moves on and the next action applies.
func TestASkippedActionIsAnsweredExpired(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		sw := &fakeSwitch{active: w.tr.Kind(), skipped: true}
		w.withSwitch(sw)
		seq := w.act("test_noop")
		w.settle()
		w.wantCalls()
		w.wantEcho(seq, wire.StatusExpired, "expired")
		sw.skipped = false
		w.act("test_noop")
		w.settle()
		w.wantCalls("test_noop:2")
	})
}
