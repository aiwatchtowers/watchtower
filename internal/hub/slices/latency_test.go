package slices

import (
	"context"
	"slices"
	"testing"
	"time"

	"watchtower/internal/hub/measure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
)

// saveStamp is one SaveLatency.Saved call.
type saveStamp struct {
	transport, kind   string
	startedAt, doneAt time.Time
}

type fakeSaveLatency struct{ stamps []saveStamp }

func (f *fakeSaveLatency) Saved(transport, kind string, startedAt, doneAt time.Time) {
	f.stamps = append(f.stamps, saveStamp{transport, kind, startedAt, doneAt})
}

// advancingSource moves the rig's clock while its kind is read, so a stamp's
// start and end differ.
type advancingSource struct {
	*fakeSource
	r *rig
	d time.Duration
}

func (s advancingSource) Items(ctx context.Context) ([]Item, error) {
	s.r.advance(s.d)
	return s.fakeSource.Items(ctx)
}

func TestSliceSaveStampsEachWrittenKind(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	lat := &fakeSaveLatency{}
	asks := &fakeSource{kind: "owner_ask"}
	asks.set(item("1", `{"q":"ship?"}`))
	board := &fakeSource{kind: "workbench"}
	p := r.publisherWith(Config{Latency: lat}, advancingSource{asks, r, 20 * time.Millisecond}, board)
	start := r.clock()
	r.cycle(p)
	want := []saveStamp{{"relay", "owner_ask", start, start.Add(20 * time.Millisecond)}}
	if !slices.Equal(lat.stamps, want) {
		t.Fatalf("stamps %+v, want %+v (a kind with nothing written gets none)", lat.stamps, want)
	}
	// Nothing changed: no write, no stamp.
	r.advance(time.Second)
	r.cycle(p)
	if len(lat.stamps) != 1 {
		t.Fatalf("an unchanged cycle stamped: %+v", lat.stamps)
	}
	// A delete is a write of its kind too.
	asks.set()
	r.advance(time.Second)
	r.cycle(p)
	if len(lat.stamps) != 2 || lat.stamps[1].kind != "owner_ask" {
		t.Fatalf("stamps after a delete %+v", lat.stamps)
	}
}

// TestSliceSaveResolvesAppliedSaved: an ask_answer applied before a cycle
// that saves owner_ask gives applied_saved and read_saved through the real
// recorder; the read_saved is read → done of the same action.
func TestSliceSaveResolvesAppliedSaved(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	rec := measure.New(r.st, r.clock)
	asks := &fakeSource{kind: "owner_ask"}
	asks.set(item("1", `{"q":"ship?","answered":true}`))
	p := r.publisherWith(Config{Latency: rec}, advancingSource{asks, r, 100 * time.Millisecond})
	read := r.clock()
	r.advance(30 * time.Millisecond)
	rec.Applied("relay", read, r.clock(), []string{"owner_ask"})
	r.advance(10 * time.Millisecond)
	r.cycle(p)
	if err := rec.Flush(); err != nil {
		t.Fatal(err)
	}
	rows, err := r.st.LatencyStats(read.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	ms := func(n int) time.Duration { return time.Duration(n) * time.Millisecond }
	want := []state.LatencyRow{
		{Step: state.StepAppliedSaved, Transport: "relay", P50: ms(110), P90: ms(110), Samples: 1},
		{Step: state.StepReadApplied, Transport: "relay", P50: ms(30), P90: ms(30), Samples: 1},
		{Step: state.StepReadSaved, Transport: "relay", P50: ms(140), P90: ms(140), Samples: 1},
	}
	if !slices.Equal(rows, want) {
		t.Fatalf("rows\n got  %+v\n want %+v", rows, want)
	}
}

func TestNoLatencyIsANoOp(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	asks := &fakeSource{kind: "owner_ask"}
	asks.set(item("1", `{}`))
	r.cycle(r.publisher(asks)) // Latency nil: nothing to call
}
