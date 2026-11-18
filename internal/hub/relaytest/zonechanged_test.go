package relaytest_test

import (
	"fmt"
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

// zoneChangedReader is a raw socket of the writer subscribed to zone "z",
// read limit raised for events that carry large records, and its HelloOk.
func zoneChangedReader(t *testing.T, srv *relaytest.Server) (save func(sizes ...int), next func() *relayv1.ZoneChanged, hello *relayv1.HelloOk) {
	t.Helper()
	h := newHub(t, srv)
	p, store := newPhone(t, srv, h)
	ws, hello := dialWSHello(t, srv, p.RelayDeviceID())
	ws.SetReadLimit(2 << 20)
	subscribeWS(t, ws, "z")
	n := 0
	save = func(sizes ...int) {
		t.Helper()
		var items []*relayv1.SaveItem
		for _, size := range sizes {
			n++
			items = append(items, &relayv1.SaveItem{Record: &relayv1.Record{Zone: "z", Name: fmt.Sprintf("r%d", n), Envelope: make([]byte, size)}})
		}
		if _, err := store.C.Do(t.Context(), &relayv1.Request{Op: &relayv1.Request_Save{Save: &relayv1.Save{Items: items}}}); err != nil {
			t.Fatal(err)
		}
	}
	next = func() *relayv1.ZoneChanged {
		t.Helper()
		return readFrame(t, ws).GetEvent().GetZoneChanged()
	}
	return save, next, hello
}

// recordSeqs is the record_seq of each of zc's records.
func recordSeqs(zc *relayv1.ZoneChanged) []uint64 {
	var out []uint64
	for _, r := range zc.GetRecords() {
		out = append(out, r.GetRecordSeq())
	}
	return out
}

// The relay's records_inline rules (relay PR #10): HelloOk lists the
// capability; a save's records go with its event, oldest first, the last at
// the event's seq; the old single record only for a one-record event of at
// most 64 KiB; a save over the 256 KiB framed budget is split by record into
// several events, and a record over the budget alone goes without its body.
func TestZoneChanged_RecordsOfAThreeRecordSave(t *testing.T) {
	srv := relaytest.Start(t)
	save, next, hello := zoneChangedReader(t, srv)
	if !slices.Equal(hello.GetCapabilities(), []string{"records_inline"}) {
		t.Fatalf("capabilities %v", hello.GetCapabilities())
	}
	save(1, 1, 1)
	zc := next()
	if zc.GetSeq() != 3 || zc.GetRecord() != nil || !slices.Equal(recordSeqs(zc), []uint64{1, 2, 3}) ||
		zc.GetRecords()[0].GetName() != "r1" || zc.GetRecords()[2].GetZone() != "z" {
		t.Fatalf("three-record save: %v", zc)
	}
	save(1)
	if zc = next(); zc.GetSeq() != 4 || zc.GetRecord().GetRecordSeq() != 4 || !slices.Equal(recordSeqs(zc), []uint64{4}) {
		t.Fatalf("one-record save: %v", zc)
	}
	save(100 << 10) // over 64 KiB: records only
	if zc = next(); zc.GetSeq() != 5 || zc.GetRecord() != nil || !slices.Equal(recordSeqs(zc), []uint64{5}) {
		t.Fatalf("one 100 KiB record: %v", zc)
	}
	// 3 × 100 KiB: the first two fit 256 KiB, the third goes in an event of its own.
	save(100<<10, 100<<10, 100<<10)
	if zc = next(); zc.GetSeq() != 7 || !slices.Equal(recordSeqs(zc), []uint64{6, 7}) {
		t.Fatalf("first chunk: %v", zc)
	}
	if zc = next(); zc.GetSeq() != 8 || !slices.Equal(recordSeqs(zc), []uint64{8}) {
		t.Fatalf("second chunk: %v", zc)
	}
	// One record over the budget: an event without its body, then the rest.
	save(1, 300<<10, 1)
	if zc = next(); zc.GetSeq() != 9 || !slices.Equal(recordSeqs(zc), []uint64{9}) {
		t.Fatalf("before the large record: %v", zc)
	}
	if zc = next(); zc.GetSeq() != 10 || len(zc.GetRecords()) != 0 || zc.GetRecord() != nil {
		t.Fatalf("the large record: %v", zc)
	}
	if zc = next(); zc.GetSeq() != 11 || !slices.Equal(recordSeqs(zc), []uint64{11}) {
		t.Fatalf("after the large record: %v", zc)
	}
}

// A relay before records_inline (DisableRecordsInline): no capability in
// HelloOk, and an event carries only the old single record, for a one-record
// save of at most 64 KiB.
func TestZoneChanged_OldRelayWithoutCapability(t *testing.T) {
	srv := relaytest.Start(t)
	srv.DisableRecordsInline()
	save, next, hello := zoneChangedReader(t, srv)
	if len(hello.GetCapabilities()) != 0 {
		t.Fatalf("capabilities %v", hello.GetCapabilities())
	}
	save(1)
	if zc := next(); zc.GetSeq() != 1 || zc.GetRecord().GetRecordSeq() != 1 || len(zc.GetRecords()) != 0 {
		t.Fatalf("one-record save: %v", zc)
	}
	save(1, 1, 1)
	if zc := next(); zc.GetSeq() != 4 || zc.GetRecord() != nil || len(zc.GetRecords()) != 0 {
		t.Fatalf("three-record save: %v", zc)
	}
}
