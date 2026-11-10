package state

import (
	"slices"
	"testing"
	"time"
)

func TestLatencyStatsNearestRank(t *testing.T) {
	s := openTest(t)
	t0 := time.Unix(1_800_000_000, 0).UTC()
	var xs []LatencySample
	// relay read_saved: 1..10 ms → p50 = rank ceil(5) = 5, p90 = rank 9 = 9.
	for i := 1; i <= 10; i++ {
		xs = append(xs, LatencySample{At: t0, Transport: "relay", Step: StepReadSaved, MS: int64(i)})
	}
	// cloudkit read_applied: 40, 10, 30, 20 → sorted 10 20 30 40; p50 rank 2 = 20, p90 rank ceil(3.6) = 4 = 40.
	for _, ms := range []int64{40, 10, 30, 20} {
		xs = append(xs, LatencySample{At: t0, Transport: "cloudkit", Step: StepReadApplied, MS: ms})
	}
	// One sample: p50 = p90 = it.
	xs = append(xs, LatencySample{At: t0, Transport: "relay", Step: StepAppliedSaved, MS: 7})
	// Before the window: not counted.
	xs = append(xs, LatencySample{At: t0.Add(-2 * time.Hour), Transport: "relay", Step: StepReadSaved, MS: 9999})
	if err := s.AddLatencySamples(xs); err != nil {
		t.Fatal(err)
	}
	rows, err := s.LatencyStats(t0.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	ms := time.Millisecond
	want := []LatencyRow{
		{Step: StepAppliedSaved, Transport: "relay", P50: 7 * ms, P90: 7 * ms, Samples: 1},
		{Step: StepReadApplied, Transport: "cloudkit", P50: 20 * ms, P90: 40 * ms, Samples: 4},
		{Step: StepReadSaved, Transport: "relay", P50: 5 * ms, P90: 9 * ms, Samples: 10},
	}
	if !slices.Equal(rows, want) {
		t.Fatalf("stats\n got  %+v\n want %+v", rows, want)
	}
	empty, err := s.LatencyStats(t0.Add(time.Hour))
	if err != nil || len(empty) != 0 {
		t.Fatalf("no samples in the window: %+v, %v", empty, err)
	}
}

// TestLatencySamplesAreContentFreeAndBoundedPrune: the table holds a time,
// the transport, the step and a duration, nothing else; a prune drops what
// is older than the window and then the oldest rows past the cap.
func TestLatencySamplesAreContentFreeAndBoundedPrune(t *testing.T) {
	s := openTest(t)
	rows, err := s.db.Query(`SELECT name FROM pragma_table_info('latency_samples') ORDER BY cid`)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = rows.Close() }()
	var cols []string
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			t.Fatal(err)
		}
		cols = append(cols, c)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if want := []string{"at", "transport", "step", "ms"}; !slices.Equal(cols, want) {
		t.Fatalf("latency_samples columns %v, want %v", cols, want)
	}
	if err := s.AddLatencySamples([]LatencySample{{At: time.Now(), Transport: "relay", Step: "title", MS: 1}}); err == nil {
		t.Fatal("a step outside the enum was stored")
	}
	if err := s.AddLatencySamples([]LatencySample{{At: time.Now(), Transport: "memfake", Step: StepReadSaved, MS: 1}}); err == nil {
		t.Fatal("a transport outside the enum was stored")
	}

	now := time.Unix(1_800_000_000, 0).UTC()
	const keep = 20000
	xs := []LatencySample{{At: now.Add(-8 * 24 * time.Hour), Transport: "relay", Step: StepReadSaved, MS: 1}}
	for i := 0; i <= keep; i++ { // 20 001 fresh rows, the oldest first
		xs = append(xs, LatencySample{At: now.Add(time.Duration(i-keep) * time.Second), Transport: "relay", Step: StepReadApplied, MS: int64(i)})
	}
	if err := s.AddLatencySamples(xs); err != nil {
		t.Fatal(err)
	}
	if err := s.PruneLatency(now.Add(-7*24*time.Hour), keep); err != nil {
		t.Fatal(err)
	}
	var n, minMS int
	if err := s.db.QueryRow(`SELECT count(*), min(ms) FROM latency_samples`).Scan(&n, &minMS); err != nil {
		t.Fatal(err)
	}
	if n != keep || minMS != 1 {
		t.Fatalf("after prune: %d rows, min ms %d; want %d rows, the oldest fresh row (ms 0) and the 8-day-old row gone", n, minMS, keep)
	}
	var old int
	if err := s.db.QueryRow(`SELECT count(*) FROM latency_samples WHERE step = 'read_saved'`).Scan(&old); err != nil || old != 0 {
		t.Fatalf("the 8-day-old row is still there (%d, %v)", old, err)
	}
}
