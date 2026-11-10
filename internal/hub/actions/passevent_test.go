package actions

import (
	"context"
	"slices"
	"testing"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/wire"
)

// The hosted relay transport reads zone events itself: PassEvent narrows to it.
var _ EventPuller = (*relay.Transport)(nil)

// eventPuller is the puller that also reads events (as the hosted relay
// does), logging the zones each read was for; own is what OwnWrites says.
type eventPuller struct {
	*puller
	events, pulls []string
	own           bool
}

func (e *eventPuller) OwnWrites(transport.Event) bool { return e.own }

func (e *eventPuller) PullEvent(ctx context.Context, ev transport.Event, apply func(transport.Batch) error) error {
	e.events = append(e.events, ev.Zone)
	return e.puller.Pull(ctx, ev.Zone, apply)
}

func (e *eventPuller) Pull(ctx context.Context, zone string, apply func(transport.Batch) error) error {
	e.pulls = append(e.pulls, zone)
	return e.puller.Pull(ctx, zone, apply)
}

func (w *world) passEvent(zone string) PassReport {
	w.t.Helper()
	r, err := w.proc.PassEvent(w.ctx, transport.Event{Zone: zone})
	if err != nil {
		w.t.Fatalf("event pass: %v", err)
	}
	return r
}

// An event for one phone's mailbox reads that mailbox only; the backstop
// Pass reads the others.
func TestPassEventReadsOnlyTheEventsMailbox(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	ep := &eventPuller{puller: &puller{Fake: w.fake, tokens: map[string]uint64{}}}
	w.proc.cfg.Transport = ep
	other := w.addPhone()
	if _, err := other.Act("board_comment_add"); err != nil {
		t.Fatal(err)
	}
	w.act("test_noop")
	if r := w.passEvent(w.phone.Zone()); r.Applied != 1 || r.ControlsWritten != 1 {
		t.Fatalf("event pass %+v", r)
	}
	w.wantCalls("test_noop:1")
	if !slices.Equal(ep.events, []string{w.phone.Zone()}) || len(ep.pulls) != 0 {
		t.Fatalf("event reads %v, pulls %v", ep.events, ep.pulls)
	}
	w.pass()
	w.wantCalls("test_noop:1", "board_comment_add:1")
	if !slices.Contains(ep.pulls, other.Zone()) {
		t.Fatalf("the backstop pass did not read the other mailbox: %v", ep.pulls)
	}
}

// An event that names no linked phone's own mailbox, or one on a transport
// that does not read events, is a full pass.
func TestPassEventFallsBackToAFullPass(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	ep := &eventPuller{puller: &puller{Fake: w.fake, tokens: map[string]uint64{}}}
	w.proc.cfg.Transport = ep
	w.act("test_noop")
	if r := w.passEvent(transport.MailboxZone(hubRelayID, "unknown-phone")); r.Applied != 1 {
		t.Fatalf("event pass %+v", r)
	}
	if len(ep.events) != 0 || !slices.Equal(ep.pulls, []string{w.phone.Zone()}) {
		t.Fatalf("event reads %v, pulls %v", ep.events, ep.pulls)
	}
	w.proc.cfg.Transport = w.fake
	w.act("test_noop")
	if w.proc.ReadsEvents() {
		t.Fatal("memfake reads events")
	}
	if r := w.passEvent(w.phone.Zone()); r.Applied != 1 {
		t.Fatalf("event pass on memfake %+v", r)
	}
	w.wantCalls(noops(1, 2)...)
}

// countSaves logs each Save's wire names; before (when set) runs ahead of
// the n-th save (1-based).
type countSaves struct {
	*memfake.Fake
	saves  [][]string
	before func(n int)
}

func (c *countSaves) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	names := make([]string, len(items))
	for i, it := range items {
		names[i] = it.Record.WireName()
	}
	c.saves = append(c.saves, names)
	if c.before != nil {
		c.before(len(c.saves))
	}
	return c.Fake.Save(ctx, items)
}

// One mailbox's queued echoes go out in one Save, in queue order.
func TestQueuedEchoesOfAMailboxGoInOneSave(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		cs := &countSaves{Fake: w.fake}
		w.use(cs)
		seqs := []uint64{w.act("test_noop"), w.act("test_noop"), w.act("test_noop")}
		if r := w.pass(); r.Applied != 3 || r.ControlsWritten != 3 {
			t.Fatalf("pass %+v", r)
		}
		var want []string
		for _, s := range seqs {
			name, _ := w.phone.Sealed(s)
			want = append(want, name)
		}
		if len(cs.saves) != 1 || !slices.Equal(cs.saves[0], want) {
			t.Fatalf("saves %v, want one of %v", cs.saves, want)
		}
		w.sync(w.phone)
		for _, s := range seqs {
			w.wantEcho(s, wire.StatusApplied, "")
		}
		if w.pending() != 0 {
			t.Fatalf("%d rows still queued", w.pending())
		}
	})
}

// A conflict in the middle of a batch settles that row alone: the rows
// around it are written, the conflicting one (the phone wrote its action
// again meanwhile) leaves the queue and its new copy is answered as a repeat
// when read. Nothing is applied twice.
func TestBatchConflictInTheMiddleMapsPerRow(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		cs := &countSaves{Fake: w.fake}
		w.use(cs)
		seqs := []uint64{w.act("test_noop"), w.act("test_noop"), w.act("test_noop")}
		cs.before = func(n int) {
			if n == 1 {
				if err := w.phone.WriteCopy(seqs[1]); err != nil {
					t.Fatal(err)
				}
			}
		}
		if r := w.pass(); r.Applied != 3 || r.ControlsWritten != 3 {
			t.Fatalf("pass %+v", r)
		}
		if len(cs.saves) != 1 || len(cs.saves[0]) != 3 {
			t.Fatalf("saves %v, want one of three", cs.saves)
		}
		if w.pending() != 0 {
			t.Fatalf("%d rows still queued", w.pending())
		}
		cs.before = nil
		w.settle()
		w.wantCalls(noops(seqs...)...)
		for _, s := range seqs {
			w.wantEcho(s, wire.StatusApplied, "")
		}
		w.wantEmptyMailbox()
	})
}

// A batch the transport refuses as a whole may be partly written: the first
// row is marked failed, the rest wait, and the next pass writes them all
// (a row that did land meets its own echo and is written over it).
func TestBatchRefusedWholeIsRetriedNextPass(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		seqs := []uint64{w.act("test_noop"), w.act("test_noop")}
		w.fake.FailNext("save", transport.ErrRateLimited)
		if r := w.pass(); r.ControlsWritten != 0 {
			t.Fatalf("pass %+v", r)
		}
		rows, err := w.st.PendingControls(w.queue(w.phone))
		if err != nil || len(rows) != 2 || rows[0].Attempts != 1 || rows[1].Attempts != 0 {
			t.Fatalf("queue %+v, %v", rows, err)
		}
		w.settle()
		w.wantCalls(noops(seqs...)...)
		for _, s := range seqs {
			w.wantEcho(s, wire.StatusApplied, "")
		}
		w.wantEmptyMailbox()
	})
}
