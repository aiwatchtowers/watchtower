package measure

import (
	"slices"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/state"
)

type fixture struct {
	t     *testing.T
	st    *state.Store
	r     *Recorder
	mu    sync.Mutex
	now   time.Time
	start time.Time
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	st, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	f := &fixture{t: t, st: st, now: time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)}
	f.start = f.now
	f.r = New(st, f.clock)
	return f
}

func (f *fixture) clock() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now
}

// at is the fixture's start plus d.
func (f *fixture) at(d time.Duration) time.Time { return f.start.Add(d) }

// stats flushes and returns every row since the start, per action kind.
func (f *fixture) stats() []state.LatencyRow {
	f.t.Helper()
	if err := f.r.Flush(); err != nil {
		f.t.Fatal(err)
	}
	rows, err := f.st.LatencyStatsByKind(f.start.Add(-time.Hour))
	if err != nil {
		f.t.Fatal(err)
	}
	return rows
}

func one(step, tr string, ms int) state.LatencyRow {
	d := time.Duration(ms) * time.Millisecond
	return state.LatencyRow{Step: step, Transport: tr, P50: d, P90: d, Samples: 1}
}

func TestAppliedActionGivesReadAppliedSample(t *testing.T) {
	f := newFixture(t)
	f.r.Applied("relay", "", f.at(0), f.at(40*time.Millisecond), nil)
	if got, want := f.stats(), []state.LatencyRow{one(state.StepReadApplied, "relay", 40)}; !slices.Equal(got, want) {
		t.Fatalf("rows %+v, want %+v", got, want)
	}
}

func TestHeldThenAppliedGivesNoSample(t *testing.T) {
	f := newFixture(t)
	// A held action drained later has no read time of its own.
	f.r.Applied("relay", "", time.Time{}, f.at(time.Second), []string{"owner_ask"})
	f.r.Saved("relay", "owner_ask", f.at(2*time.Second), f.at(3*time.Second))
	if got := f.stats(); len(got) != 0 {
		t.Fatalf("rows %+v, want none", got)
	}
}

func TestSliceSaveResolvesAppliedSaved(t *testing.T) {
	f := newFixture(t)
	// An ask_answer read at 0, applied at 30 ms, nudging owner_ask.
	f.r.Applied("relay", "", f.at(0), f.at(30*time.Millisecond), []string{"owner_ask"})
	// A source read that began before the apply does not count; another kind
	// does not count.
	f.r.Saved("relay", "owner_ask", f.at(10*time.Millisecond), f.at(50*time.Millisecond))
	f.r.Saved("relay", "workbench", f.at(60*time.Millisecond), f.at(80*time.Millisecond))
	// The owner_ask save whose read began after it does.
	f.r.Saved("relay", "owner_ask", f.at(100*time.Millisecond), f.at(230*time.Millisecond))
	// Once resolved, a later save writes nothing more.
	f.r.Saved("relay", "owner_ask", f.at(300*time.Millisecond), f.at(400*time.Millisecond))
	want := []state.LatencyRow{
		one(state.StepAppliedSaved, "relay", 200),
		one(state.StepReadApplied, "relay", 30),
		one(state.StepReadSaved, "relay", 230),
	}
	if got := f.stats(); !slices.Equal(got, want) {
		t.Fatalf("rows\n got  %+v\n want %+v", got, want)
	}
}

func TestNoSaveWithin60sGivesNoSample(t *testing.T) {
	f := newFixture(t)
	f.r.Applied("relay", "", f.at(0), f.at(10*time.Millisecond), []string{"owner_ask"})
	f.r.Saved("relay", "owner_ask", f.at(time.Second), f.at(SaveWait+11*time.Millisecond))
	// A second apply left waiting is dropped by a flush past SaveWait, so a
	// later save resolves nothing.
	f.r.Applied("relay", "", f.at(0), f.at(20*time.Millisecond), []string{"board"})
	f.mu.Lock()
	f.now = f.at(SaveWait + time.Second)
	f.mu.Unlock()
	if err := f.r.Flush(); err != nil {
		t.Fatal(err)
	}
	f.r.Saved("relay", "board", f.at(30*time.Millisecond), f.at(50*time.Millisecond))
	got := f.stats()
	want := []state.LatencyRow{{Step: state.StepReadApplied, Transport: "relay", P50: 10 * time.Millisecond, P90: 20 * time.Millisecond, Samples: 2}}
	if !slices.Equal(got, want) {
		t.Fatalf("rows %+v, want only the read_applied samples %+v", got, want)
	}
}

func TestSamplesTaggedWithTheActiveTransport(t *testing.T) {
	f := newFixture(t)
	f.r.Applied("cloudkit", "", f.at(0), f.at(5*time.Millisecond), []string{"owner_ask"})
	f.r.Applied("relay", "", f.at(0), f.at(7*time.Millisecond), []string{"owner_ask"})
	// A transport the table does not know records nothing.
	f.r.Applied("memfake", "", f.at(0), f.at(9*time.Millisecond), []string{"owner_ask"})
	// The relay's save resolves only the relay's apply.
	f.r.Saved("relay", "owner_ask", f.at(10*time.Millisecond), f.at(17*time.Millisecond))
	f.r.Saved("memfake", "owner_ask", f.at(10*time.Millisecond), f.at(19*time.Millisecond))
	want := []state.LatencyRow{
		one(state.StepAppliedSaved, "relay", 10),
		one(state.StepReadApplied, "cloudkit", 5),
		one(state.StepReadApplied, "relay", 7),
		one(state.StepReadSaved, "relay", 17),
	}
	if got := f.stats(); !slices.Equal(got, want) {
		t.Fatalf("rows\n got  %+v\n want %+v", got, want)
	}
}

// TestRecorderBuffersUntilFlush: Applied and Saved only buffer (they never
// touch the database, so a caller inside a transaction cannot meet a write
// of theirs); Flush writes.
func TestRecorderBuffersUntilFlush(t *testing.T) {
	f := newFixture(t)
	f.r.Applied("relay", "", f.at(0), f.at(time.Millisecond), []string{"owner_ask"})
	f.r.Saved("relay", "owner_ask", f.at(2*time.Millisecond), f.at(3*time.Millisecond))
	rows, err := f.st.LatencyStats(f.start.Add(-time.Hour))
	if err != nil || len(rows) != 0 {
		t.Fatalf("written before Flush: %+v, %v", rows, err)
	}
	if got := f.stats(); len(got) != 3 {
		t.Fatalf("after Flush %+v, want 3 rows", got)
	}
}

func TestWaitingAppliesAreCapped(t *testing.T) {
	f := newFixture(t)
	for i := range maxWaiting + 1 {
		f.r.Applied("relay", "", f.at(0), f.at(time.Duration(i)*time.Millisecond), []string{"owner_ask"})
	}
	f.r.mu.Lock()
	n, first := len(f.r.waiting), f.r.waiting[0].appliedAt
	f.r.mu.Unlock()
	if n != maxWaiting || !first.Equal(f.at(time.Millisecond)) {
		t.Fatalf("waiting %d (first applied at %v), want %d with the oldest dropped", n, first, maxWaiting)
	}
}

func TestNilRecorderIsANoOp(t *testing.T) {
	var r *Recorder
	r.Applied("relay", "", time.Now(), time.Now(), []string{"owner_ask"})
	r.Saved("relay", "owner_ask", time.Now(), time.Now())
	r.NudgeCycleDone("relay", "owner_ask", time.Now(), time.Now())
	r.EventRead("relay", time.Now(), time.Now())
	if err := r.Flush(); err != nil {
		t.Fatal(err)
	}
	if err := r.Prune(); err != nil {
		t.Fatal(err)
	}
}

func TestPruneKeepsTheWindow(t *testing.T) {
	f := newFixture(t)
	if err := f.st.AddLatencySamples([]state.LatencySample{
		{At: f.at(-Window - time.Hour), Transport: "relay", Step: state.StepReadSaved, MS: 1},
		{At: f.at(-time.Hour), Transport: "relay", Step: state.StepReadSaved, MS: 2},
	}); err != nil {
		t.Fatal(err)
	}
	if err := f.r.Prune(); err != nil {
		t.Fatal(err)
	}
	rows, err := f.st.LatencyStats(f.at(-2 * Window))
	if err != nil {
		t.Fatal(err)
	}
	if want := []state.LatencyRow{one(state.StepReadSaved, "relay", 2)}; !slices.Equal(rows, want) {
		t.Fatalf("after prune %+v, want %+v", rows, want)
	}
}

// TestRecorder_NudgeCycleDoneResolvesWithoutWrite: a cycle that handled the
// apply's nudged kind and wrote nothing (every hash unchanged) gives one
// nudge_saved of apply → cycle end, tagged with the action kind; the apply
// still waits for a save of its own for applied_saved and read_saved.
func TestRecorder_NudgeCycleDoneResolvesWithoutWrite(t *testing.T) {
	f := newFixture(t)
	f.r.Applied("relay", "board_target_create", f.at(-5*time.Millisecond), f.at(0), []string{"workbench"})
	// A cycle whose read of the kind began before the apply did not see it;
	// another kind does not count.
	f.r.NudgeCycleDone("relay", "workbench", f.at(-time.Millisecond), f.at(20*time.Millisecond))
	f.r.NudgeCycleDone("relay", "owner_ask", f.at(time.Millisecond), f.at(30*time.Millisecond))
	f.r.NudgeCycleDone("relay", "workbench", f.at(time.Millisecond), f.at(40*time.Millisecond))
	// Once resolved, a later cycle end adds nothing.
	f.r.NudgeCycleDone("relay", "workbench", f.at(50*time.Millisecond), f.at(60*time.Millisecond))
	want := []state.LatencyRow{
		{Step: state.StepNudgeSaved, Transport: "relay", Kind: "board_target_create", P50: 40 * time.Millisecond, P90: 40 * time.Millisecond, Samples: 1},
		{Step: state.StepReadApplied, Transport: "relay", Kind: "board_target_create", P50: 5 * time.Millisecond, P90: 5 * time.Millisecond, Samples: 1},
	}
	if got := f.stats(); !slices.Equal(got, want) {
		t.Fatalf("rows\n got  %+v\n want %+v", got, want)
	}
	f.r.mu.Lock()
	n := len(f.r.waiting)
	f.r.mu.Unlock()
	if n != 1 {
		t.Fatalf("waiting %d, want the apply still waiting for its save", n)
	}
	// The save then resolves applied_saved and read_saved; nothing waits.
	f.r.Saved("relay", "workbench", f.at(70*time.Millisecond), f.at(90*time.Millisecond))
	got := f.stats()
	steps := map[string]int{}
	for _, r := range got {
		steps[r.Step] += r.Samples
		if r.Kind != "board_target_create" {
			t.Fatalf("row %+v not tagged with the action kind", r)
		}
	}
	if steps[state.StepAppliedSaved] != 1 || steps[state.StepReadSaved] != 1 || steps[state.StepNudgeSaved] != 1 {
		t.Fatalf("steps %+v", steps)
	}
	f.r.mu.Lock()
	n = len(f.r.waiting)
	f.r.mu.Unlock()
	if n != 0 {
		t.Fatalf("waiting %d after both resolved, want 0", n)
	}
}

// TestRecorder_WrittenCycleGivesBothSavedAndNudgeSaved: a cycle that wrote
// the kind stamps Saved mid-cycle and NudgeCycleDone at its end: the apply
// gets applied_saved, read_saved and nudge_saved, then stops waiting.
func TestRecorder_WrittenCycleGivesBothSavedAndNudgeSaved(t *testing.T) {
	f := newFixture(t)
	f.r.Applied("relay", "ask_answer", f.at(0), f.at(10*time.Millisecond), []string{"owner_ask"})
	f.r.Saved("relay", "owner_ask", f.at(20*time.Millisecond), f.at(50*time.Millisecond))
	f.r.NudgeCycleDone("relay", "owner_ask", f.at(20*time.Millisecond), f.at(60*time.Millisecond))
	d := func(n int) time.Duration { return time.Duration(n) * time.Millisecond }
	want := []state.LatencyRow{
		{Step: state.StepAppliedSaved, Transport: "relay", Kind: "ask_answer", P50: d(40), P90: d(40), Samples: 1},
		{Step: state.StepNudgeSaved, Transport: "relay", Kind: "ask_answer", P50: d(50), P90: d(50), Samples: 1},
		{Step: state.StepReadApplied, Transport: "relay", Kind: "ask_answer", P50: d(10), P90: d(10), Samples: 1},
		{Step: state.StepReadSaved, Transport: "relay", Kind: "ask_answer", P50: d(50), P90: d(50), Samples: 1},
	}
	if got := f.stats(); !slices.Equal(got, want) {
		t.Fatalf("rows\n got  %+v\n want %+v", got, want)
	}
	f.r.mu.Lock()
	n := len(f.r.waiting)
	f.r.mu.Unlock()
	if n != 0 {
		t.Fatalf("waiting %d, want 0", n)
	}
}

// TestRecorder_EventRead: event arrival → mailbox read, kind "" (no action
// is known yet); a zero arrival or an unmeasured transport records nothing.
func TestRecorder_EventRead(t *testing.T) {
	f := newFixture(t)
	f.r.EventRead("relay", f.at(0), f.at(15*time.Millisecond))
	f.r.EventRead("relay", time.Time{}, f.at(15*time.Millisecond))
	f.r.EventRead("memfake", f.at(0), f.at(15*time.Millisecond))
	if got, want := f.stats(), []state.LatencyRow{one(state.StepEventRead, "relay", 15)}; !slices.Equal(got, want) {
		t.Fatalf("rows %+v, want %+v", got, want)
	}
}
