package actions

import (
	"context"
	"slices"
	"testing"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
)

// failSaveN fails its n-th save (1-based) as a whole, writing nothing.
type failSaveN struct {
	*memfake.Fake
	n, calls int
}

func (f *failSaveN) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	f.calls++
	if f.calls == f.n {
		return nil, transport.ErrUnavailable
	}
	return f.Fake.Save(ctx, items)
}

// feedOrder is the order of actions 2..5's records in the phone's mailbox
// feed (by their last write).
func (w *world) feedOrder() []uint64 {
	w.t.Helper()
	feed, err := w.fake.Changes(w.ctx, w.phone.Zone(), 0)
	if err != nil {
		w.t.Fatal(err)
	}
	var order []uint64
	for _, rec := range feed.Changed {
		for s := uint64(2); s <= 5; s++ {
			if name, _ := w.phone.Sealed(s); name == rec.Name {
				order = append(order, s)
			}
		}
	}
	return order
}

// drainFromHold holds 3 and 4 (2 missing), then sends 2 and 5: the pass
// applies 2, drains 3 and 4 from the hold (their finals go over the hub's own
// held echoes) and applies 5. tr (nil = the fake) carries that pass.
func drainFromHold(w *world, tr transport.Transport) {
	w.t.Helper()
	w.act("test_noop")
	w.settle()
	if _, err := w.phone.Queue(w.phone.NewAction("test_noop")); err != nil {
		w.t.Fatal(err)
	}
	w.act("test_noop")
	w.act("test_noop")
	w.pass() // 3 and 4 held, their held echoes written
	if err := w.phone.Send(2); err != nil {
		w.t.Fatal(err)
	}
	w.act("test_noop") // 5
	if tr != nil {
		w.use(tr)
	}
	w.pass()
	w.wantCalls(noops(1, 2, 3, 4, 5)...)
}

// Finals drained from the hold are written over the hub's own held echoes;
// the phone's feed still has the echoes in queue order (2, 3, 4, then 5).
func TestDrainedFinalsKeepTheQueueOrderInTheFeed(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		drainFromHold(w, nil)
		if got := w.feedOrder(); !slices.Equal(got, []uint64{2, 3, 4, 5}) {
			t.Fatalf("feed order %v, want [2 3 4 5]", got)
		}
	})
}

// The tail save (3 and 4 over their held echoes, then 5 again) fails as a
// whole: 5 stays queued with them, so the next pass writes it after them and
// the feed keeps the queue order.
func TestFailedTailSaveKeepsTheQueueOrderNextPass(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		drainFromHold(w, &failSaveN{Fake: w.fake, n: 2})
		if w.pending() != 3 { // the finals of 3, 4 and 5
			t.Fatalf("%d rows queued after the failed tail, want 3", w.pending())
		}
		w.use(w.fake)
		w.pass()
		if w.pending() != 0 {
			t.Fatalf("%d rows still queued", w.pending())
		}
		if got := w.feedOrder(); !slices.Equal(got, []uint64{2, 3, 4, 5}) {
			t.Fatalf("feed order %v, want [2 3 4 5]", got)
		}
	})
}
