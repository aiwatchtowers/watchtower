package relay

import (
	"errors"
	"slices"
	"testing"

	"watchtower/internal/hub/transport"
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
	h := &pullEventHarness{harness: newHarness(t)}
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
