package actions

import (
	"testing"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/wire"
)

// F31 (G1, relay client Phase 5): a device record sealed in an epoch the hub
// no longer holds is dropped with no state change; the phone's next rewrite,
// after it merged the newer keybox (the hourly touchIfStale), applies.
func TestDeviceRecordInARetiredEpochDroppedRewriteApplies(t *testing.T) {
	w := onRelay(t)
	for range 2 {
		if err := w.keys.Rotate(identity.ReasonManual); err != nil {
			t.Fatal(err)
		}
	}
	w.advance(identity.PreviousEpochGrace + 1)
	if err := w.keys.RetireOld(); err != nil {
		t.Fatal(err)
	}
	if _, err := w.keys.EraseExpired(); err != nil {
		t.Fatal(err)
	}
	w.rewrite(wire.DevicePayload{Name: "Renamed"}) // sealed in epoch 1, gone
	if d := w.device(w.phone); d.Name != "Test Phone" {
		t.Fatalf("a record in a retired epoch applied: name %q", d.Name)
	}
	kk, err := w.keys.KeyboxKeysFor(w.phone.ID())
	if err != nil {
		t.Fatal(err)
	}
	if err := w.phone.Keep(kk); err != nil {
		t.Fatal(err)
	}
	w.advance(1)
	w.rewrite(wire.DevicePayload{Name: "Renamed"})
	if d := w.device(w.phone); d.Name != "Renamed" {
		t.Fatalf("the rewrite after the merge did not apply: name %q", d.Name)
	}
}
