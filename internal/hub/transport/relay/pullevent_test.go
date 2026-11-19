package relay

import (
	"errors"
	"maps"
	"slices"
	"testing"

	"watchtower/internal/hub/relaytest"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// pullEventHarness is a zone already read up to its last seq, and a log of
// what PullEvent hands apply.
type pullEventHarness struct {
	*harness
	zone string
	got  []string
}

func newPullEventHarness(t *testing.T) *pullEventHarness {
	t.Helper()
	return newPullEventHarnessOn(t, relaytest.Start(t))
}

// newPullEventHarnessOn is newPullEventHarness over srv.
func newPullEventHarnessOn(t *testing.T, srv *relaytest.Server) *pullEventHarness {
	t.Helper()
	h := &pullEventHarness{harness: newHarnessOn(t, srv)}
	h.zone = h.data
	h.relay.Put(h.zone, "n0", []byte{0})
	if err := h.tr.Pull(t.Context(), h.zone, h.apply); err != nil {
		t.Fatal(err)
	}
	h.got = nil
	return h
}

func (h *pullEventHarness) apply(b transport.Batch) error {
	for _, s := range b.Changed {
		h.got = append(h.got, s.Name)
	}
	return nil
}

func (h *pullEventHarness) changes() int { return len(h.relay.Requests("changes")) }

func (h *pullEventHarness) token(t *testing.T) uint64 {
	t.Helper()
	tok, err := h.store.ZoneToken(h.zone)
	if err != nil {
		t.Fatal(err)
	}
	return tok
}

func (h *pullEventHarness) pullEvent(t *testing.T, ev transport.Event) {
	t.Helper()
	if err := h.tr.PullEvent(t.Context(), ev, h.apply); err != nil {
		t.Fatal(err)
	}
}

// inline is a zone event carrying the record name written at seq.
func (h *pullEventHarness) inline(seq uint64, name string) transport.Event {
	return transport.Event{Zone: h.zone, Seq: seq, Inline: &transport.Batch{
		NewSeq: seq, Changed: []transport.Stored{{Zone: h.zone, Name: name, Envelope: []byte{9}, RecordSeq: seq}},
	}}
}

// An event whose inline record is the next write after the token is applied
// as is: no changes read, the token moves to it.
func TestRelayTransport_PullEventInlineNextSeqNeedsNoRead(t *testing.T) {
	h := newPullEventHarness(t)
	seq := h.relay.Put(h.zone, "n1", []byte{1})
	before := h.changes()
	h.pullEvent(t, h.inline(seq, "n1"))
	if n := h.changes() - before; n != 0 {
		t.Fatalf("%d changes reads for an inline next record", n)
	}
	if !slices.Equal(h.got, []string{"n1"}) || h.token(t) != seq {
		t.Fatalf("applied %v, token %d (want %d)", h.got, h.token(t), seq)
	}
	// The same event again: already read, nothing applied.
	h.pullEvent(t, h.inline(seq, "n1"))
	if len(h.got) != 1 || h.changes() != before {
		t.Fatalf("a read event was applied again: %v, %d reads", h.got, h.changes()-before)
	}
	// A failed apply keeps the token.
	seq = h.relay.Put(h.zone, "n2", []byte{2})
	if err := h.tr.PullEvent(t.Context(), h.inline(seq, "n2"), func(transport.Batch) error { return errors.New("boom") }); err == nil {
		t.Fatal("apply error swallowed")
	}
	if h.token(t) != seq-1 {
		t.Fatalf("token %d moved past an unapplied record", h.token(t))
	}
}

// An event past a write nobody read (a gap) reads that zone with changes —
// that zone only — from the token; so does a record-less event.
func TestRelayTransport_PullEventGapReadsTheZoneOnly(t *testing.T) {
	h := newPullEventHarness(t)
	h.relay.Put(transport.MailboxZone(h.tr.c.DeviceID(), "phone-b"), "x", []byte{1})
	h.relay.Put(h.zone, "n1", []byte{1})
	seq := h.relay.Put(h.zone, "n2", []byte{2})
	before := h.changes()
	h.pullEvent(t, h.inline(seq, "n2"))
	reqs := h.relay.Requests("changes")[before:]
	if len(reqs) != 1 || reqs[0].GetChanges().GetZone() != h.zone || reqs[0].GetChanges().GetSinceSeq() != 1 {
		t.Fatalf("reads %v, want one of %s from 1", reqs, h.zone)
	}
	if !slices.Equal(h.got, []string{"n1", "n2"}) || h.token(t) != seq {
		t.Fatalf("applied %v, token %d", h.got, h.token(t))
	}
	// A record-less event (too large to inline, a delete, merged writes).
	seq = h.relay.Put(h.zone, "n3", []byte{3})
	h.pullEvent(t, transport.Event{Zone: h.zone, Seq: seq})
	if n := h.changes() - before; n != 2 || h.token(t) != seq {
		t.Fatalf("%d reads, token %d", n, h.token(t))
	}
	// The resync marker (seq 0) is a read even when nothing is new.
	h.pullEvent(t, transport.Event{Zone: h.zone, Resync: true})
	if n := h.changes() - before; n != 3 {
		t.Fatalf("%d reads after a resync marker", n)
	}
}

// The relay tells the writer of its own writes too: an event whose seqs
// after the token are all the hub's own saves moves the token without a read.
func TestRelayTransport_PullEventSkipsOwnWrites(t *testing.T) {
	h := newPullEventHarness(t)
	out, err := h.tr.Save(t.Context(), []transport.SaveItem{{Record: h.seal(t, "target-1", `{}`)}, {Record: h.seal(t, "target-2", `{}`)}})
	if err != nil || !out[1].Saved {
		t.Fatalf("save %+v, %v", out, err)
	}
	before := h.changes()
	// One event per own write, the second with its record inline.
	h.pullEvent(t, transport.Event{Zone: h.zone, Seq: out[0].RecordSeq})
	h.pullEvent(t, h.inline(out[1].RecordSeq, "target-2"))
	if n := h.changes() - before; n != 0 || len(h.got) != 0 || h.token(t) != out[1].RecordSeq {
		t.Fatalf("%d reads, applied %v, token %d", n, h.got, h.token(t))
	}
	// The relay's one merged event past a batch of two own writes.
	out, err = h.tr.Save(t.Context(), []transport.SaveItem{{Record: h.seal(t, "target-3", `{}`)}, {Record: h.seal(t, "target-4", `{}`)}})
	if err != nil {
		t.Fatal(err)
	}
	h.pullEvent(t, transport.Event{Zone: h.zone, Seq: out[1].RecordSeq})
	if n := h.changes() - before; n != 0 || h.token(t) != out[1].RecordSeq {
		t.Fatalf("%d reads, token %d", n, h.token(t))
	}
}

// A phone's write between the token and the hub's own write is read: the
// own write never stands for it.
func TestRelayTransport_PullEventOwnWriteAfterAForeignOneReads(t *testing.T) {
	h := newPullEventHarness(t)
	h.relay.Put(h.zone, "phone-1", []byte{1})
	out, err := h.tr.Save(t.Context(), []transport.SaveItem{{Record: h.seal(t, "target-1", `{}`)}})
	if err != nil {
		t.Fatal(err)
	}
	before := h.changes()
	h.pullEvent(t, transport.Event{Zone: h.zone, Seq: out[0].RecordSeq})
	if n := h.changes() - before; n != 1 || !slices.Contains(h.got, "phone-1") || h.token(t) != out[0].RecordSeq {
		t.Fatalf("%d reads, applied %v, token %d", n, h.got, h.token(t))
	}
	// Own, then a phone's inline write: the own one is skipped, the phone's
	// applied from the event.
	out, err = h.tr.Save(t.Context(), []transport.SaveItem{{Record: h.seal(t, "target-2", `{}`)}})
	if err != nil {
		t.Fatal(err)
	}
	seq := h.relay.Put(h.zone, "phone-2", []byte{2})
	if seq != out[0].RecordSeq+1 {
		t.Fatalf("seq %d after own %d", seq, out[0].RecordSeq)
	}
	h.got = nil
	h.pullEvent(t, h.inline(seq, "phone-2"))
	if n := h.changes() - before; n != 1 || !slices.Equal(h.got, []string{"phone-2"}) || h.token(t) != seq {
		t.Fatalf("%d reads, applied %v, token %d", n, h.got, h.token(t))
	}
}

// An own write whose event arrives before its Save returned (another
// goroutine's Save, here another transport of the same hub) is not known as
// own yet: the zone is read, never skipped. OwnWrites says the same.
func TestRelayTransport_PullEventUnnotedOwnWriteIsRead(t *testing.T) {
	h := newPullEventHarness(t)
	other := h.newTransport(t)
	out, err := other.Save(t.Context(), []transport.SaveItem{{Record: h.seal(t, "target-1", `{}`)}})
	if err != nil {
		t.Fatal(err)
	}
	ev := transport.Event{Zone: h.zone, Seq: out[0].RecordSeq}
	if h.tr.OwnWrites(ev) {
		t.Fatal("an unnoted write taken as own")
	}
	before := h.changes()
	h.pullEvent(t, ev)
	if n := h.changes() - before; n != 1 || h.token(t) != out[0].RecordSeq {
		t.Fatalf("%d reads, token %d", n, h.token(t))
	}
	// A noted one is own until the token passes it.
	out, err = h.tr.Save(t.Context(), []transport.SaveItem{{Record: h.seal(t, "target-2", `{}`)}})
	if err != nil {
		t.Fatal(err)
	}
	ev = transport.Event{Zone: h.zone, Seq: out[0].RecordSeq}
	if !h.tr.OwnWrites(ev) {
		t.Fatal("a noted own write not taken as own")
	}
	h.pullEvent(t, ev)
	if h.tr.OwnWrites(ev) || h.tr.OwnWrites(transport.Event{Zone: h.zone}) {
		t.Fatal("an event already read, or a resync marker, taken as own")
	}
}

// inlineRecords is a zone event at seq carrying the records written at the
// given seqs, named as given.
func (h *pullEventHarness) inlineRecords(seq uint64, recs map[uint64]string) transport.Event {
	b := &transport.Batch{NewSeq: seq}
	for _, s := range slices.Sorted(maps.Keys(recs)) {
		b.Changed = append(b.Changed, transport.Stored{Zone: h.zone, Name: recs[s], Envelope: []byte{9}, RecordSeq: s})
	}
	return transport.Event{Zone: h.zone, Seq: seq, Inline: b}
}

// nextSeqEvent waits for the next event of the harness's zone that names a
// seq (the initial marker and others skipped).
func (h *pullEventHarness) nextSeqEvent(t *testing.T) transport.Event {
	t.Helper()
	for {
		if ev := nextEvent(t, h.tr); ev.Zone == h.zone && ev.Err == nil && ev.Seq > 0 {
			return ev
		}
	}
}

// foreignSave saves n records into the zone as another writer would (a
// transport whose saves this one never noted as its own).
func (h *pullEventHarness) foreignSave(t *testing.T, other *Transport, names ...string) uint64 {
	t.Helper()
	var items []transport.SaveItem
	for _, n := range names {
		items = append(items, transport.SaveItem{Record: h.seal(t, n, `{}`)})
	}
	out, err := other.Save(t.Context(), items)
	if err != nil || !out[len(out)-1].Saved {
		t.Fatalf("save %+v, %v", out, err)
	}
	return out[len(out)-1].RecordSeq
}

// A save of several records comes as one event carrying all of them (relay
// records_inline): applied as is, no changes read, the token at its seq.
func TestPullEvent_MultiRecordInlineNeedsNoRead(t *testing.T) {
	h := newPullEventHarness(t)
	h.connectVouched(t)
	seq := h.foreignSave(t, h.newTransport(t), "target-1", "target-2", "target-3")
	ev := h.nextSeqEvent(t)
	if ev.Seq != seq || ev.Inline == nil || len(ev.Inline.Changed) != 3 {
		t.Fatalf("event %+v", ev)
	}
	before := h.changes()
	h.pullEvent(t, ev)
	if n := h.changes() - before; n != 0 || len(h.got) != 3 || h.token(t) != seq {
		t.Fatalf("%d reads, applied %v, token %d (want %d)", n, h.got, h.token(t), seq)
	}
}

// An event whose records span the hub's own write: the own seq is skipped,
// the others applied, no read.
func TestPullEvent_InlineWithOwnWritesBetween(t *testing.T) {
	h := newPullEventHarness(t)
	first := h.relay.Put(h.zone, "phone-1", []byte{1})
	out, err := h.tr.Save(t.Context(), []transport.SaveItem{{Record: h.seal(t, "target-1", `{}`)}})
	if err != nil || out[0].RecordSeq != first+1 {
		t.Fatalf("save %+v, %v", out, err)
	}
	last := h.relay.Put(h.zone, "phone-3", []byte{3})
	before := h.changes()
	h.pullEvent(t, h.inlineRecords(last, map[uint64]string{first: "phone-1", first + 1: "own", last: "phone-3"}))
	if n := h.changes() - before; n != 0 || !slices.Equal(h.got, []string{"phone-1", "phone-3"}) || h.token(t) != last {
		t.Fatalf("%d reads, applied %v, token %d", n, h.got, h.token(t))
	}
}

// Records that miss a seq after the token (they start past it, or skip one
// in the middle) are a changes read from the token.
func TestPullEvent_GapReads(t *testing.T) {
	h := newPullEventHarness(t)
	h.relay.Put(h.zone, "n1", []byte{1})
	s2 := h.relay.Put(h.zone, "n2", []byte{2})
	s3 := h.relay.Put(h.zone, "n3", []byte{3})
	before := h.changes()
	h.pullEvent(t, h.inlineRecords(s3, map[uint64]string{s2: "n2", s3: "n3"}))
	if n := h.changes() - before; n != 1 || !slices.Equal(h.got, []string{"n1", "n2", "n3"}) || h.token(t) != s3 {
		t.Fatalf("records after the token: %d reads, applied %v, token %d", n, h.got, h.token(t))
	}
	s4 := h.relay.Put(h.zone, "n4", []byte{4})
	h.relay.Put(h.zone, "n5", []byte{5})
	s6 := h.relay.Put(h.zone, "n6", []byte{6})
	h.got = nil
	h.pullEvent(t, h.inlineRecords(s6, map[uint64]string{s4: "n4", s6: "n6"}))
	if n := h.changes() - before; n != 2 || !slices.Equal(h.got, []string{"n4", "n5", "n6"}) || h.token(t) != s6 {
		t.Fatalf("a seq missing in the middle: %d reads, applied %v, token %d", n, h.got, h.token(t))
	}
}

// A relay before records_inline sends only the old single record: a
// one-record save is applied from the event as before, a multi-record save
// is read.
func TestPullEvent_OldRelayWithoutCapability(t *testing.T) {
	srv := relaytest.Start(t)
	srv.DisableRecordsInline()
	h := newPullEventHarnessOn(t, srv)
	h.connectVouched(t)
	other := h.newTransport(t)
	before := h.changes()
	seq := h.foreignSave(t, other, "target-1")
	ev := h.nextSeqEvent(t)
	h.pullEvent(t, ev)
	if n := h.changes() - before; n != 0 || len(h.got) != 1 || h.token(t) != seq {
		t.Fatalf("one record: %d reads, applied %v, token %d", n, h.got, h.token(t))
	}
	seq = h.foreignSave(t, other, "target-2", "target-3", "target-4")
	if ev = h.nextSeqEvent(t); ev.Inline != nil {
		t.Fatalf("an old relay's multi-record event inline: %+v", ev)
	}
	h.pullEvent(t, ev)
	if n := h.changes() - before; n != 1 || len(h.got) != 4 || h.token(t) != seq {
		t.Fatalf("three records: %d reads, applied %v, token %d", n, h.got, h.token(t))
	}
}

// The pump hands records on as one page only when they run without a gap up
// to the event's seq and none is a deletion; records win over the old single
// record, which a relay with records_inline fills only for a one-record event.
func TestRelayTransport_ZoneChangedRecordsInline(t *testing.T) {
	h := newHarness(t)
	if err := h.tr.Connect(t.Context(), []string{h.data}); err != nil {
		t.Fatal(err)
	}
	waitZoneEvent(t, h.tr, h.data)
	rec := func(name string, seq uint64) *relayv1.Record {
		return &relayv1.Record{Name: name, Envelope: []byte{1}, RecordSeq: seq}
	}
	push := func(zc *relayv1.ZoneChanged) transport.Event {
		t.Helper()
		zc.Zone = h.data
		h.relay.Push(t, &relayv1.Event{Kind: &relayv1.Event_ZoneChanged{ZoneChanged: zc}})
		return nextEvent(t, h.tr)
	}
	ev := push(&relayv1.ZoneChanged{Seq: 5, Records: []*relayv1.Record{rec("a", 3), rec("b", 4), rec("c", 5)}})
	if ev.Inline == nil || ev.Inline.NewSeq != 5 || len(ev.Inline.Changed) != 3 ||
		ev.Inline.Changed[0].Name != "a" || ev.Inline.Changed[0].RecordSeq != 3 || ev.Inline.Changed[2].Zone != h.data {
		t.Fatalf("records: %+v", ev.Inline)
	}
	for name, zc := range map[string]*relayv1.ZoneChanged{
		"a gap":              {Seq: 5, Records: []*relayv1.Record{rec("a", 3), rec("c", 5)}},
		"not up to the seq":  {Seq: 6, Records: []*relayv1.Record{rec("a", 4), rec("b", 5)}},
		"a deletion":         {Seq: 5, Records: []*relayv1.Record{rec("a", 4), {Name: "b", RecordSeq: 5, Deleted: true}}},
		"more than the seqs": {Seq: 1, Records: []*relayv1.Record{rec("a", 0), rec("b", 1)}},
	} {
		if ev = push(zc); ev.Inline != nil {
			t.Fatalf("%s: inline %+v", name, ev.Inline)
		}
	}
	ev = push(&relayv1.ZoneChanged{Seq: 7, Record: rec("x", 7), Records: []*relayv1.Record{rec("x", 7)}})
	if ev.Inline == nil || len(ev.Inline.Changed) != 1 || ev.Inline.Changed[0].Name != "x" {
		t.Fatalf("one record in both fields: %+v", ev.Inline)
	}
}
