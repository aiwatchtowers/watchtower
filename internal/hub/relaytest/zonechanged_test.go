package relaytest_test

import (
	"slices"
	"testing"

	"watchtower/internal/hub/relaytest"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// One write call is one ZoneChanged per zone, as the relay sends it: at the
// zone's last seq, with the record inline only when the call wrote exactly
// that one record there; the writer's own socket hears it too.
func TestOneZoneChangedPerWriteCall(t *testing.T) {
	srv := relaytest.Start(t)
	h := newHub(t, srv)
	p, store := newPhone(t, srv, h)
	ws := dialWS(t, srv, p.RelayDeviceID()) // the writer's own socket
	subscribeWS(t, ws, "z")
	save := func(names ...string) {
		t.Helper()
		var items []*relayv1.SaveItem
		for _, n := range names {
			items = append(items, &relayv1.SaveItem{Record: &relayv1.Record{Zone: "z", Name: n, Envelope: []byte{1}}})
		}
		if _, err := store.C.Do(t.Context(), &relayv1.Request{Op: &relayv1.Request_Save{Save: &relayv1.Save{Items: items}}}); err != nil {
			t.Fatal(err)
		}
	}
	save("a")
	zc := readFrame(t, ws).GetEvent().GetZoneChanged()
	if zc.GetSeq() != 1 || zc.GetRecord().GetName() != "a" || zc.GetRecord().GetRecordSeq() != 1 {
		t.Fatalf("single save: %v", zc)
	}
	save("b", "c")
	zc = readFrame(t, ws).GetEvent().GetZoneChanged()
	if zc.GetSeq() != 3 || zc.GetRecord() != nil {
		t.Fatalf("two-record save: %v", zc)
	}
	if _, err := store.C.Do(t.Context(), &relayv1.Request{Op: &relayv1.Request_Delete{Delete: &relayv1.Delete{
		Zone: "z", Items: []*relayv1.DeleteItem{{Name: "a"}, {Name: "b"}},
	}}}); err != nil {
		t.Fatal(err)
	}
	zc = readFrame(t, ws).GetEvent().GetZoneChanged()
	if zc.GetSeq() != 5 || zc.GetRecord() != nil {
		t.Fatalf("delete: %v", zc)
	}
	// One event per call: the relay queued them inside each call.
	if got, _ := srv.EventsQueuedFor(p.RelayDeviceID()); !slices.Equal(got, []int{3}) {
		t.Fatalf("events queued %v; want [3], one per call", got)
	}
}
