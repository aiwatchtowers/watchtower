package identity

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"math"
	"testing"
	"time"

	"watchtower/internal/hub/state"
)

// A keyring rebuilt over the sidecar after a committed rotation (the hub
// killed and started again) resumes on the same epoch: it neither repeats
// the rotation nor forks a new epoch, and the epoch's keys are the ones the
// rotation wrote.
// twin of HubKeyringTests.testAKilledRotationResumesOnTheSameEpoch
func TestKeyring_AKilledRotationResumesOnTheSameEpoch(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	c.advance(RotationAge)
	if rotated, err := k.RotateIfDue(); err != nil || !rotated {
		t.Fatalf("RotateIfDue at 90 days = %v, %v", rotated, err)
	}
	data2, err := k.DataKey(2)
	if err != nil {
		t.Fatal(err)
	}

	restarted := newKeyring(t, st, c)
	if rotated, err := restarted.RotateIfDue(); err != nil || rotated {
		t.Fatalf("the committed rotation was repeated: %v, %v", rotated, err)
	}
	c.advance(24 * time.Hour)
	if rotated, err := restarted.RotateIfDue(); err != nil || rotated {
		t.Fatalf("a day later: %v, %v", rotated, err)
	}
	if cur, err := restarted.CurrentEpoch(); err != nil || cur != 2 {
		t.Fatalf("epoch %d, %v; want 2", cur, err)
	}
	if got, err := restarted.DataKey(2); err != nil || !bytes.Equal(got, data2) {
		t.Fatalf("epoch 2's keys changed across the restart: %v", err)
	}
	if epochs, err := st.Epochs(); err != nil || len(epochs) != 2 {
		t.Fatalf("%d epochs, %v; want 2", len(epochs), err)
	}
}

// Rotating past the last epoch (MaxUint32) is ErrEpochOverflow and writes
// nothing: the current epoch stays the last one.
// twin of HubKeyringTests.testRotatingPastTheLastEpochIsAnOverflow
func TestKeyring_RotatingPastTheLastEpochIsAnOverflow(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	epochs, err := st.Epochs()
	if err != nil || len(epochs) != 1 {
		t.Fatalf("epochs %d, %v", len(epochs), err)
	}
	last := epochs[0]
	last.Epoch = math.MaxUint32
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.InsertEpoch(tx, last) }); err != nil {
		t.Fatal(err)
	}

	if err := k.Rotate(ReasonManual); !errors.Is(err, ErrEpochOverflow) {
		t.Fatalf("Rotate past the last epoch = %v, want ErrEpochOverflow", err)
	}
	if cur, err := k.CurrentEpoch(); err != nil || cur != math.MaxUint32 {
		t.Fatalf("epoch %d, %v; want the last one", cur, err)
	}
	if after, err := st.Epochs(); err != nil || len(after) != 2 || after[0].RetiredAt != nil {
		t.Fatalf("the refused rotation wrote: %+v, %v", after, err)
	}
}
