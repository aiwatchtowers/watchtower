package actions

import (
	"context"
	"errors"
	"slices"
	"testing"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
)

// A claim whose done transaction failed leaves the action begun and the
// mailbox holding only the hub's own received echo. The echo's event must be
// read even when the transport takes it for the hub's own write: the action
// ends outcome_unknown and the order moves on.
func TestEventAfterAFailedDoneIsReadNotSkipped(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	ep := &eventPuller{puller: &puller{Fake: w.fake, tokens: map[string]uint64{}}}
	w.proc.cfg.Transport = ep
	calls := 0
	w.disp.Register("session_input", func(context.Context, Request) Outcome {
		calls++
		return Outcome{Status: wire.StatusApplied, Delivery: "typed"}
	}, KindOptions{})
	first := w.act("session_input")
	w.proc.fault = func(point string) error {
		if point == "done" {
			return errors.New("injected commit failure")
		}
		return nil
	}
	if _, err := w.proc.PassEvent(w.ctx, transport.Event{Zone: w.phone.Zone()}); err == nil {
		t.Fatal("the failed done was not reported")
	}
	w.proc.fault = nil
	// The received echo's event: the transport would skip it as own.
	ep.own = true
	r := w.passEvent(w.phone.Zone())
	if r.OwnEcho || r.Applied != 1 {
		t.Fatalf("event pass %+v: the begun action was not read back", r)
	}
	w.sync(w.phone)
	w.wantEcho(first, wire.StatusFailed, reasonOutcomeUnknown)
	if calls != 1 {
		t.Fatalf("handler ran %d times", calls)
	}
	// Read once without an error: own writes are skipped again.
	if r := w.passEvent(w.phone.Zone()); !r.OwnEcho {
		t.Fatalf("event pass %+v after a clean read", r)
	}
	ep.own = false
	second := w.act("test_noop")
	w.passEvent(w.phone.Zone())
	w.sync(w.phone)
	w.wantEcho(second, wire.StatusApplied, "")
	if d := w.device(w.phone); d.LastAppliedActionSeq != second {
		t.Fatalf("last applied %d: the lane is wedged", d.LastAppliedActionSeq)
	}
}

// An event that stands only for the hub's own writes reads, applies and
// writes nothing.
func TestOwnEchoEventDoesNothing(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	ep := &eventPuller{puller: &puller{Fake: w.fake, tokens: map[string]uint64{}}, own: true}
	w.proc.cfg.Transport = ep
	w.act("test_noop")
	if r := w.passEvent(w.phone.Zone()); !r.OwnEcho || r.Read != 0 || r.ControlsWritten != 0 {
		t.Fatalf("event pass %+v", r)
	}
	if len(ep.events) != 0 || len(ep.pulls) != 0 {
		t.Fatalf("reads %v %v", ep.events, ep.pulls)
	}
	w.wantCalls()
}

// partialSave writes the first k items of its next save and then fails the
// call as a whole, as a relay save cut off part-way does.
type partialSave struct {
	*memfake.Fake
	k     int
	armed bool
	saves [][]string
}

func (f *partialSave) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	names := make([]string, len(items))
	for i, it := range items {
		names[i] = it.Record.WireName()
	}
	f.saves = append(f.saves, names)
	if !f.armed {
		return f.Fake.Save(ctx, items)
	}
	f.armed = false
	if _, err := f.Fake.Save(ctx, items[:f.k]); err != nil {
		return nil, err
	}
	return nil, transport.ErrUnavailable
}

// heldThenFinal: action 3 is held (2 missing) while its held echo and the
// resend_from are written by tr, then 2 arrives: 3 is applied from the hold
// and its final echo queued behind the held one.
func heldThenFinal(t *testing.T, w *world, ps *partialSave) {
	t.Helper()
	w.act("test_noop")
	w.settle()
	if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil { // 2: not sent yet
		t.Fatal(err)
	}
	w.act("test_noop")
	ps.armed = true
	if r := w.pass(); r.ControlsWritten != 0 || w.pending() != 2 { // held 3, resend_from(2)
		t.Fatalf("pass %+v, %d rows queued after the cut-off save", r, w.pending())
	}
	if err := w.phone.Send(2); err != nil {
		t.Fatal(err)
	}
	ps.saves = nil
	w.pass()
}

// A batch cut off after its first row: the held echo landed, the call
// failed. The final echo queued behind it is written over the held one; the
// phone never keeps "held" for an applied action. One batch never writes two
// echoes of one record.
func TestPartlyWrittenHeldEchoThenFinalIsWritten(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		ps := &partialSave{Fake: w.fake, k: 1}
		w.use(ps)
		heldThenFinal(t, w, ps)
		if w.pending() != 0 {
			t.Fatalf("%d rows still queued", w.pending())
		}
		for _, names := range ps.saves {
			if len(slices.Compact(slices.Sorted(slices.Values(names)))) != len(names) {
				t.Fatalf("one save wrote a record twice: %v", names)
			}
		}
		w.sync(w.phone)
		w.wantEcho(3, wire.StatusApplied, "")
		w.settle()
		w.wantCalls(noops(1, 2, 3)...)
		w.wantEmptyMailbox()
	})
}

// A held echo that never landed and the final one behind it go out as the
// final one alone, in one save with the rest of the queue.
func TestHeldAndFinalEchoOfOneActionFoldIntoOne(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		ps := &partialSave{Fake: w.fake, k: 0}
		w.use(ps)
		heldThenFinal(t, w, ps)
		if len(ps.saves) != 1 || len(ps.saves[0]) != 3 { // resend_from, final 2, final 3
			t.Fatalf("saves %v, want one of three rows", ps.saves)
		}
		if w.pending() != 0 {
			t.Fatalf("%d rows still queued", w.pending())
		}
		w.sync(w.phone)
		w.wantEcho(2, wire.StatusApplied, "")
		w.wantEcho(3, wire.StatusApplied, "")
	})
}

// A row refused for now, then a later echo of the same record: the later one
// is never written alone over a newer state — both are one row, which waits.
func TestRefusedEchoAndALaterOneOfTheSameRecordWaitTogether(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	w.act("test_noop")
	w.settle()
	if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil {
		t.Fatal(err)
	}
	w.act("test_noop")
	w.fake.FailNext("save", transport.ErrRateLimited) // held 3 and resend_from stay queued
	w.pass()
	if err := w.phone.Send(2); err != nil {
		t.Fatal(err)
	}
	w.fake.FailNext("save", transport.ErrRateLimited) // the folded batch waits too
	w.pass()
	rows, err := w.st.PendingControls(w.queue(w.phone))
	if err != nil || len(rows) != 4 { // held 3, resend_from, final 2, final 3
		t.Fatalf("queue %+v, %v", rows, err)
	}
	w.settle()
	w.wantCalls(noops(1, 2, 3)...)
	w.wantEcho(3, wire.StatusApplied, "")
	w.wantEmptyMailbox()
}

// Finals drained from the hold are written over the hub's own held echoes;
// the phone's feed still has the echoes in queue order (2, 3, 4, then 5).
func TestDrainedFinalsKeepTheQueueOrderInTheFeed(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		w.act("test_noop")
		w.settle()
		if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil {
			t.Fatal(err)
		}
		w.act("test_noop")
		w.act("test_noop")
		w.pass() // 3 and 4 held, their held echoes written
		if err := w.phone.Send(2); err != nil {
			t.Fatal(err)
		}
		w.act("test_noop") // 5
		w.pass()           // 2 applied, 3 and 4 drained, 5 applied
		w.wantCalls(noops(1, 2, 3, 4, 5)...)
		feed, err := w.fake.Changes(w.ctx, w.phone.Zone(), 0)
		if err != nil {
			t.Fatal(err)
		}
		var order []uint64
		for _, rec := range feed.Changed {
			for s := uint64(2); s <= 5; s++ {
				if name, _ := w.phone.Sealed(s); name == rec.Name {
					order = append(order, s)
				}
			}
		}
		if !slices.Equal(order, []uint64{2, 3, 4, 5}) {
			t.Fatalf("feed order %v, want [2 3 4 5]", order)
		}
	})
}
