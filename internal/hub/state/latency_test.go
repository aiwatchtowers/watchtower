package state

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/pressly/goose/v3"
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
// the transport, the step, a duration and the action kind, nothing else; a prune drops what
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
	if want := []string{"at", "transport", "step", "ms", "kind"}; !slices.Equal(cols, want) {
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

// TestLatencyStatsGroupsByKind: by kind, a step on a transport is one row per
// action kind, the kind ” (event_read, rows from before 00018) a row of its
// own; LatencyStats keeps one row per step and transport over every kind.
func TestLatencyStatsGroupsByKind(t *testing.T) {
	s := openTest(t)
	t0 := time.Unix(1_800_000_000, 0).UTC()
	if err := s.AddLatencySamples([]LatencySample{
		{At: t0, Transport: "relay", Step: StepNudgeSaved, Kind: "board_target_create", MS: 40},
		{At: t0, Transport: "relay", Step: StepNudgeSaved, Kind: "ask_answer", MS: 10},
		{At: t0, Transport: "relay", Step: StepNudgeSaved, Kind: "ask_answer", MS: 30},
		{At: t0, Transport: "relay", Step: StepEventRead, MS: 15},
	}); err != nil {
		t.Fatal(err)
	}
	rows, err := s.LatencyStatsByKind(t0.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	ms := time.Millisecond
	want := []LatencyRow{
		{Step: StepEventRead, Transport: "relay", P50: 15 * ms, P90: 15 * ms, Samples: 1},
		{Step: StepNudgeSaved, Transport: "relay", Kind: "ask_answer", P50: 10 * ms, P90: 30 * ms, Samples: 2},
		{Step: StepNudgeSaved, Transport: "relay", Kind: "board_target_create", P50: 40 * ms, P90: 40 * ms, Samples: 1},
	}
	if !slices.Equal(rows, want) {
		t.Fatalf("stats\n got  %+v\n want %+v", rows, want)
	}
	all, err := s.LatencyStats(t0.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	wantAll := []LatencyRow{
		{Step: StepEventRead, Transport: "relay", P50: 15 * ms, P90: 15 * ms, Samples: 1},
		{Step: StepNudgeSaved, Transport: "relay", P50: 30 * ms, P90: 40 * ms, Samples: 3},
	}
	if !slices.Equal(all, wantAll) {
		t.Fatalf("over every kind\n got  %+v\n want %+v", all, wantAll)
	}
}

// TestMigration00018_KeepsRowsAndAcceptsNewSteps: a file at 00017 with
// samples keeps them (kind ”) through the rebuild, takes the two new steps
// and still refuses a step outside the enum; the at index is back.
func TestMigration00018_KeepsRowsAndAcceptsNewSteps(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "hub")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	raw, err := sql.Open("sqlite3", filepath.Join(dir, FileName))
	if err != nil {
		t.Fatal(err)
	}
	migrations, err := Migrations()
	if err != nil {
		t.Fatal(err)
	}
	p, err := goose.NewProvider(goose.DialectSQLite3, raw, migrations, goose.WithDisableGlobalRegistry(true))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := p.UpTo(context.Background(), 17); err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec(`INSERT INTO latency_samples (at, transport, step, ms) VALUES
		(1800000000.5, 'relay', 'read_applied', 12), (1800000001.0, 'cloudkit', 'read_saved', 340)`); err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec(`INSERT INTO latency_samples (at, transport, step, ms) VALUES (1800000002, 'relay', 'event_read', 1)`); err == nil {
		t.Fatal("00017 took a step it does not know")
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(dir)
	if err != nil {
		t.Fatalf("Open (migrating to 00018): %v", err)
	}
	defer func() { _ = s.Close() }()
	rows, err := s.LatencyStats(time.Unix(1_799_999_000, 0))
	if err != nil {
		t.Fatal(err)
	}
	ms := time.Millisecond
	want := []LatencyRow{
		{Step: StepReadApplied, Transport: "relay", P50: 12 * ms, P90: 12 * ms, Samples: 1},
		{Step: StepReadSaved, Transport: "cloudkit", P50: 340 * ms, P90: 340 * ms, Samples: 1},
	}
	if !slices.Equal(rows, want) {
		t.Fatalf("rows after 00018\n got  %+v\n want %+v", rows, want)
	}
	at := time.Unix(1_800_000_010, 0)
	if err := s.AddLatencySamples([]LatencySample{
		{At: at, Transport: "relay", Step: StepEventRead, MS: 15},
		{At: at, Transport: "relay", Step: StepNudgeSaved, Kind: "board_target_create", MS: 40},
	}); err != nil {
		t.Fatalf("the new steps: %v", err)
	}
	if err := s.AddLatencySamples([]LatencySample{{At: at, Transport: "relay", Step: "title", MS: 1}}); err == nil {
		t.Fatal("a step outside the enum was stored")
	}
	var idx int
	if err := s.db.QueryRow(`SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'latency_samples_at' AND tbl_name = 'latency_samples'`).Scan(&idx); err != nil || idx != 1 {
		t.Fatalf("index latency_samples_at present = %d %v", idx, err)
	}
}
