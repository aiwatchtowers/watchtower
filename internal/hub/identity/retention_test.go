package identity

import (
	"context"
	"database/sql"
	"encoding/binary"
	"slices"
	"testing"
	"time"

	"watchtower/internal/hub/state"
)

// The old-epoch retention of Go hub plan 3 Task 20 (relay sim rule 14 with
// the 7-day cap of ask #843): every retired epoch's relay-lane keys are
// accepted for PreviousEpochGrace, switch epochs included, or until every
// phone acked a newer epoch and nothing sealed in it is held.

func retained(t *testing.T, k *Keyring) []uint32 {
	t.Helper()
	got, err := k.Retained()
	if err != nil {
		t.Fatal(err)
	}
	return got
}

// Two switches within 7 days hold three epochs (phone contract point 3),
// each one accepted on the relay lane and named with why it began.
func TestRetainedHoldsEveryEpochWithin7Days(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	dev, _ := linkPhone(t, st, run(0xA0, 0xBF))
	for _, r := range []Reason{ReasonTransportSwitch, ReasonTransportSwitch} {
		c.advance(5 * time.Minute)
		if err := k.Rotate(r); err != nil {
			t.Fatal(err)
		}
	}
	if got := retained(t, k); !slices.Equal(got, []uint32{1, 2, 3}) {
		t.Fatalf("retained %v, want [1 2 3]", got)
	}
	for _, e := range []uint32{1, 2, 3} {
		if ok, err := k.AcceptsRelayEpoch(e, dev); err != nil || !ok {
			t.Fatalf("epoch %d refused: %v %v", e, ok, err)
		}
	}
	// The keybox keeps its two-epoch shape: the newest retired one.
	kk, err := k.KeyboxKeys()
	if err != nil || kk.Epoch != 3 || kk.PreviousEpoch == nil || *kk.PreviousEpoch != 2 {
		t.Fatalf("keybox keys %+v %v", kk, err)
	}
	epochs, err := st.Epochs()
	if err != nil {
		t.Fatal(err)
	}
	for i, want := range []string{"", "transport_switch", "transport_switch"} {
		if epochs[i].Reason != want {
			t.Fatalf("epoch %d reason %q, want %q", epochs[i].Epoch, epochs[i].Reason, want)
		}
	}
	if epochs[0].RetireAfter == nil || !epochs[0].RetireAfter.Equal(epochs[0].RetiredAt.Add(PreviousEpochGrace)) {
		t.Fatalf("epoch 1 retire_after %v", epochs[0].RetireAfter)
	}
}

// The cap: 6 d 23 h after its retirement an epoch is accepted, at 7 days it
// is not, whatever the reason it ended for; the older of two goes first.
func TestRetentionCapIs7Days(t *testing.T) {
	for _, r := range []Reason{ReasonTransportSwitch, ReasonManual, ReasonUnlink, ReasonAge} {
		t.Run(string(r), func(t *testing.T) {
			st := openStore(t)
			c := newClock()
			k := newKeyring(t, st, c)
			dev, _ := linkPhone(t, st, run(0xA0, 0xBF))
			if err := k.Rotate(r); err != nil {
				t.Fatal(err)
			}
			c.advance(time.Hour)
			if err := k.Rotate(ReasonManual); err != nil {
				t.Fatal(err)
			}
			c.advance(6*24*time.Hour + 22*time.Hour)
			if got := retained(t, k); !slices.Equal(got, []uint32{1, 2, 3}) {
				t.Fatalf("at 6 d 23 h retained %v", got)
			}
			c.advance(time.Hour) // epoch 1 retired 7 days ago
			if got := retained(t, k); !slices.Equal(got, []uint32{2, 3}) {
				t.Fatalf("at 7 d retained %v", got)
			}
			if ok, _ := k.AcceptsRelayEpoch(1, dev); ok {
				t.Fatal("epoch 1 accepted after 7 days")
			}
			c.advance(time.Hour)
			if got := retained(t, k); !slices.Equal(got, []uint32{3}) {
				t.Fatalf("retained %v", got)
			}
			if kk, _ := k.KeyboxKeys(); kk.PreviousEpoch != nil {
				t.Fatal("the keybox carries a retired epoch past 7 days")
			}
		})
	}
}

// A switch epoch's keys go as soon as every phone acked a newer one and no
// held action is sealed in it, never while one of them is not so.
func TestSwitchEpochRetiredWhenEveryPhoneAcked(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	if err := k.Rotate(ReasonTransportSwitch); err != nil {
		t.Fatal(err)
	}
	c.advance(time.Hour)
	for _, step := range []struct {
		acked  map[string]uint32
		heldIn map[uint32]bool
	}{
		{map[string]uint32{"A": 2, "B": 1}, nil},                      // B has not acked
		{map[string]uint32{"A": 2, "B": 2}, map[uint32]bool{1: true}}, // a held action is sealed in 1
		{map[string]uint32{"A": 2, "B": 2}, map[uint32]bool{3: true}}, // held in no retired epoch: done
		{map[string]uint32{"A": 2, "B": 2}, map[uint32]bool{}},        // already gone: nothing changes
	} {
		if err := k.RetireIfDone(step.acked, step.heldIn); err != nil {
			t.Fatal(err)
		}
	}
	if got := retained(t, k); !slices.Equal(got, []uint32{2}) {
		t.Fatalf("retained %v, want [2]", got)
	}
	epochs, _ := st.Epochs()
	if epochs[0].RetireAfter == nil || !epochs[0].RetireAfter.Equal(c.now()) {
		t.Fatalf("epoch 1 retire_after %v, want now", epochs[0].RetireAfter)
	}
	// The current epoch never retires early, acked or not.
	if err := k.RetireIfDone(map[string]uint32{"A": 9}, nil); err != nil {
		t.Fatal(err)
	}
	if got := retained(t, k); !slices.Equal(got, []uint32{2}) {
		t.Fatalf("retained %v after acking the current epoch", got)
	}
}

// RetireOld reads the acks off the device rows, and the retiring
// transaction checks what is held or queued (F3/F7): an epoch a held action
// or a queued write is sealed in keeps its keys; a phone that never acked
// keeps them for the full 7 days.
func TestRetireOldReadsAcksHeldActionsAndQueuedWrites(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	dev, _ := linkPhone(t, st, run(0xA0, 0xBF))
	if err := k.Rotate(ReasonTransportSwitch); err != nil {
		t.Fatal(err)
	}
	if err := k.RetireOld(); err != nil {
		t.Fatal(err)
	}
	if got := retained(t, k); !slices.Equal(got, []uint32{1, 2}) {
		t.Fatalf("retained %v before the ack", got)
	}
	ctx := context.Background()
	if err := st.WithTx(ctx, func(tx *sql.Tx) error { return state.AckEpoch(tx, dev.String(), 2) }); err != nil {
		t.Fatal(err)
	}
	sealedIn := func(epoch uint32) []byte {
		env := make([]byte, 80)
		binary.BigEndian.PutUint32(env[38:42], epoch)
		return env
	}
	for _, step := range []struct {
		name string
		add  func(tx *sql.Tx) error
		drop string
	}{
		{"held action", func(tx *sql.Tx) error { return state.Hold(tx, dev.String(), 5, "w5", sealedIn(1)) }, `DELETE FROM held_actions`},
		{"queued write", func(tx *sql.Tx) error {
			return state.Enqueue(tx, state.Control{Mailbox: "m", RecordName: "w6", Kind: "hub_on_relay", Envelope: sealedIn(1), Expect: state.ExpectAbsent})
		}, `DELETE FROM control_queue`},
	} {
		if err := st.WithTx(ctx, step.add); err != nil {
			t.Fatal(err)
		}
		if err := k.RetireOld(); err != nil {
			t.Fatal(err)
		}
		if got := retained(t, k); !slices.Equal(got, []uint32{1, 2}) {
			t.Fatalf("retained %v with a %s sealed in epoch 1", got, step.name)
		}
		if err := st.WithTx(ctx, func(tx *sql.Tx) error { _, err := tx.Exec(step.drop); return err }); err != nil {
			t.Fatal(err)
		}
	}
	// A row sealed in another epoch does not hold epoch 1.
	if err := st.WithTx(ctx, func(tx *sql.Tx) error { return state.Hold(tx, dev.String(), 7, "w7", sealedIn(2)) }); err != nil {
		t.Fatal(err)
	}
	if err := k.RetireOld(); err != nil {
		t.Fatal(err)
	}
	if got := retained(t, k); !slices.Equal(got, []uint32{2}) {
		t.Fatalf("retained %v after every phone acked and nothing is sealed in 1", got)
	}
}

// A row retired before sidecar migration 00010 has no retire_after: its
// retention runs from retired_at, as the two-epoch window did.
func TestRetentionOfARowWithoutRetireAfter(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	if err := k.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(`UPDATE hub_epochs SET retire_after = NULL, reason = NULL`)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	c.advance(PreviousEpochGrace - time.Second)
	if got := retained(t, k); !slices.Equal(got, []uint32{1, 2}) {
		t.Fatalf("retained %v inside the grace", got)
	}
	c.advance(time.Second)
	if got := retained(t, k); !slices.Equal(got, []uint32{2}) {
		t.Fatalf("retained %v after the grace", got)
	}
}
