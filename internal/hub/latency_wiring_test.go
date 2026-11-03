package hub

import (
	"context"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/measure"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// bumpSource is a "target" slice whose one item changes each time n moves.
type bumpSource struct{ n *atomic.Int64 }

func (bumpSource) Kind() hubslices.Kind { return "target" }
func (s bumpSource) Items(context.Context) ([]hubslices.Item, error) {
	return []hubslices.Item{{ID: "T1", Payload: []byte(`{"id":"T1","v":` + strconv.FormatInt(s.n.Load(), 10) + `}`)}}, nil
}

// TestRuntimeRecordsLatencySamples: a running hub stamps a phone action read
// → applied (the processor's recorder), resolves it at the slice save that
// shows it (the publisher's recorder) and writes the samples to the sidecar
// (the measure loop). Removing either Latency wiring or the loop fails it.
func TestRuntimeRecordsLatencySamples(t *testing.T) {
	var n atomic.Int64
	e := runEndToEnd(t, "", func(o *Options) {
		o.Register = func(d *actions.Dispatcher) {
			d.Register("latency_test", func(context.Context, actions.Request) actions.Outcome {
				n.Add(1)
				return actions.Outcome{Status: wire.StatusApplied}
			}, actions.KindOptions{Nudges: []string{"target"}})
		}
		o.Sources = func(*state.Store) []hubslices.Source { return []hubslices.Source{bumpSource{&n}} }
	})
	seq, err := e.phone.Act("latency_test")
	if err != nil {
		t.Fatal(err)
	}
	eventually(t, 15*time.Second, "the latency_test action applied", func() bool {
		if _, err := e.phone.Sync(); err != nil {
			t.Fatal(err)
		}
		return e.phone.Echoes[seq].Status == wire.StatusApplied
	})
	steps := func() map[string]int {
		st, err := state.OpenReadOnly(e.dir)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = st.Close() }()
		rows, err := st.LatencyStats(time.Now().Add(-time.Hour))
		if err != nil {
			t.Fatal(err)
		}
		out := map[string]int{}
		for _, r := range rows {
			if r.Transport == "relay" {
				out[r.Step] = r.Samples
			}
		}
		return out
	}
	eventually(t, 15*time.Second, "read_applied, applied_saved and read_saved samples", func() bool {
		s := steps()
		// The two probes and latency_test are timed read → applied; only
		// latency_test nudges a slice.
		return s[state.StepReadApplied] >= 3 && s[state.StepAppliedSaved] == 1 && s[state.StepReadSaved] == 1
	})
}

// TestMeasureLoopFlushesOnStop: what the recorder holds when the hub stops is
// written by the loop's last flush.
func TestMeasureLoopFlushesOnStop(t *testing.T) {
	st, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	h := &hubRuntime{st: st}
	h.lat = measure.New(st, nil)
	now := time.Now()
	h.lat.Applied("relay", now.Add(-5*time.Millisecond), now, nil)
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // stopped before the first tick
	h.measureLoop(ctx)
	rows, err := st.LatencyStats(now.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Step != state.StepReadApplied || rows[0].Samples != 1 {
		t.Fatalf("rows after stop %+v, want the one buffered read_applied", rows)
	}
}
