package slices

import (
	"context"
	"crypto/ed25519"
	"database/sql"
	"testing"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
)

// signalCount is how many signal records (empty envelopes) the fake got.
func (r *rig) signalCount() int {
	n := 0
	for _, f := range r.tr.Frames() {
		if len(f) == 0 {
			n++
		}
	}
	return n
}

// On CloudKit an alert that first reaches the zone gets its signal
// (AskAlertSignal): a changed payload resaves the alert with no second
// signal, a rotation's reseal writes none either, and the signal leaves the
// zone with its alert.
func TestAskAlertSignalOnCloudKit(t *testing.T) {
	r := newRig(t, transport.KindCloudKit)
	src := &fakeSource{kind: KindAskAlert}
	src.set(Item{ID: "ask-7", Payload: []byte(`{"title":"acme"}`)})
	p := r.publisher(src)

	r.cycle(p, KindAskAlert)
	wire := r.wireName("ask_alert-ask-7")
	live := r.live()
	if _, ok := live[wire]; !ok {
		t.Fatal("the alert is not in the zone")
	}
	if env, ok := live[secure.SignalName(wire)]; !ok || len(env) != 0 {
		t.Fatalf("signal missing or not empty (present %v, %d bytes)", ok, len(env))
	}
	ctx := secure.Context{Zone: secure.ZoneData, WireName: wire}
	pub := r.kr.Signer().Public().(ed25519.PublicKey)
	if _, f, err := secure.OpenSymmetric(live[wire], []secure.EnvelopeClass{secure.ClassAlert}, ctx, pub,
		func(h secure.Header) ([]byte, error) { return r.kr.AlertKey(h.Epoch) }); err != nil || f.Kind != "ask_alert" {
		t.Fatalf("the alert does not open under K_alert: %v", err)
	}
	if _, _, err := secure.OpenSymmetric(live[wire], []secure.EnvelopeClass{secure.ClassAlert}, ctx, pub,
		func(h secure.Header) ([]byte, error) { return r.kr.DataKey(h.Epoch) }); err == nil {
		t.Fatal("K_data opened an alert")
	}

	r.advance(CloudKitSpacing)
	src.set(Item{ID: "ask-7", Payload: []byte(`{"title":"beta"}`)})
	if rep := r.cycle(p, KindAskAlert); rep.Saved != 1 {
		t.Fatalf("the changed alert was not resaved: %+v", rep)
	}
	if n := r.signalCount(); n != 1 {
		t.Fatalf("%d signals after a resave, want 1", n)
	}

	if err := r.kr.Rotate(identity.ReasonManual); err != nil {
		t.Fatal(err)
	}
	r.advance(CloudKitSpacing)
	if rep := r.cycle(p, KindAskAlert); rep.Saved != 1 {
		t.Fatalf("the rotation did not reseal the alert: %+v", rep)
	}
	if n := r.signalCount(); n != 1 {
		t.Fatalf("%d signals after a rotation, want 1", n)
	}

	r.advance(CloudKitSpacing)
	src.set()
	if rep := r.cycle(p, KindAskAlert); rep.Deleted != 1 {
		t.Fatalf("delete: %+v", rep)
	}
	live = r.live()
	if _, ok := live[wire]; ok {
		t.Fatal("the alert stayed")
	}
	if _, ok := live[secure.SignalName(wire)]; ok {
		t.Fatal("the signal stayed")
	}
}

// The hosted relay pushes through send_alert: no signal records there.
func TestAskAlertHasNoSignalOnTheRelay(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: KindAskAlert}
	src.set(Item{ID: "ask-7", Payload: []byte(`{}`)})
	r.cycle(r.publisher(src), KindAskAlert)
	if n := r.signalCount(); n != 0 {
		t.Fatalf("%d signals on the relay", n)
	}
	if len(r.live()) != 1 {
		t.Fatalf("zone: %d records", len(r.live()))
	}
}

// One stop of work never buzzes twice (spec §3): a signal saved by a cycle
// whose hash write then failed is not created again by the next cycle,
// which resaves the alert (the phone's subscription fires on creation only).
func TestAskAlertSignalIsNeverCreatedTwice(t *testing.T) {
	r := newRig(t, transport.KindCloudKit)
	src := &fakeSource{kind: KindAskAlert}
	src.set(Item{ID: "ask-7", Payload: []byte(`{"title":"acme"}`)})
	p := r.publisher(src)
	r.cycle(p, KindAskAlert)
	wire := r.wireName("ask_alert-ask-7")
	sig := secure.SignalName(wire)
	first, err := r.tr.Changes(context.Background(), testZone, 0)
	if err != nil {
		t.Fatal(err)
	}
	// The record write failed after the saves: the hub does not know the
	// alert reached the zone.
	if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.DeleteSliceState(tx, "ask_alert-ask-7")
	}); err != nil {
		t.Fatal(err)
	}
	r.advance(CloudKitSpacing)
	if rep := r.cycle(p, KindAskAlert); rep.Saved != 1 || len(rep.Skipped) != 0 {
		t.Fatalf("report %+v", rep)
	}
	after, err := r.tr.Changes(context.Background(), testZone, first.NewSeq)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range after.Changed {
		if c.Name == sig {
			t.Fatal("the signal was written a second time")
		}
	}
	if _, ok := r.live()[sig]; !ok {
		t.Fatal("the signal left the zone")
	}
	if known, _ := r.st.SliceHashes(string(KindAskAlert)); known["ask_alert-ask-7"].Hash == "" {
		t.Fatal("the alert's hash was not recorded after the conflict")
	}
}
