package db

import (
	"fmt"
	"testing"
)

// NOTE: TestObserverCRUD and TestObserverEvents were removed with migration
// 00008 (custom tracks), which drops the observers/observer_events tables. The
// db.Observer CRUD methods in observers.go are dead code pending removal in a
// later task; the GetObserverActivity watermark tests below still guard the
// activity-gather logic (digests/tracks/inbox), which survives the migration.

// seedActivityRow inserts one row into the given observer-activity source with
// an explicit timestamp (created_at for digests/inbox, updated_at for tracks).
func seedActivityRow(t *testing.T, d *DB, source string, i int, ts string) {
	t.Helper()
	var err error
	switch source {
	case "digest":
		_, err = d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary, created_at)
			VALUES ('C1', ?, ?, 'channel', ?, ?)`, i, i, fmt.Sprintf("digest %d", i), ts)
	case "track":
		_, err = d.Exec(`INSERT INTO tracks (text, context, updated_at)
			VALUES (?, 'ctx', ?)`, fmt.Sprintf("track %d", i), ts)
	case "inbox":
		_, err = d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, created_at)
			VALUES ('C1', ?, 'U1', 'mention', ?, ?)`, fmt.Sprintf("ts-%d", i), fmt.Sprintf("inbox %d", i), ts)
	default:
		t.Fatalf("unknown source %q", source)
	}
	if err != nil {
		t.Fatal(err)
	}
}

// TestGetObserverActivityDrainsSameSecondBoundary guards the capped-watermark
// tie hole: timestamps are second-resolution, so when a capped fetch ends on a
// second shared by more rows, those rows must be drained into the same batch —
// the caller advances its watermark to the boundary timestamp and reopens the
// window with a strict `>`, so any tie left behind would be skipped forever.
// The realistic shape is inbox_items batch-inserted 100-in-one-second on a
// cold start.
func TestGetObserverActivityDrainsSameSecondBoundary(t *testing.T) {
	for _, source := range []string{"digest", "track", "inbox"} {
		t.Run(source, func(t *testing.T) {
			d, err := Open(":memory:")
			if err != nil {
				t.Fatal(err)
			}
			defer d.Close()

			const limit = 5
			const total = limit + 10
			for i := 0; i < total; i++ {
				seedActivityRow(t, d, source, i, "2026-07-01T00:00:00Z")
			}

			act, err := d.GetObserverActivity("2026-01-01T00:00:00Z", limit)
			if err != nil {
				t.Fatal(err)
			}
			got := len(act.Digests) + len(act.Tracks) + len(act.Inbox)
			if got != total {
				t.Fatalf("boundary ties must be drained into the batch: got %d rows, want %d", got, total)
			}
			if act.CappedAt != "2026-07-01T00:00:00Z" {
				t.Fatalf("CappedAt = %q, want the boundary second", act.CappedAt)
			}
		})
	}
}

// TestGetObserverActivityMixedBoundaryTiesNotLost seeds the mixed shape: rows
// with increasing timestamps up to the cap, plus extra rows tied at the
// boundary second. The tied rows must all be in the batch.
func TestGetObserverActivityMixedBoundaryTiesNotLost(t *testing.T) {
	d, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	const limit = 40
	// 39 rows with increasing seconds, then 5 tied at the boundary second.
	for i := 0; i < limit-1; i++ {
		seedActivityRow(t, d, "digest", i, fmt.Sprintf("2026-07-01T00:00:%02dZ", i))
	}
	boundary := fmt.Sprintf("2026-07-01T00:00:%02dZ", limit-1)
	for i := limit - 1; i < limit+4; i++ {
		seedActivityRow(t, d, "digest", i, boundary)
	}

	act, err := d.GetObserverActivity("2026-01-01T00:00:00Z", limit)
	if err != nil {
		t.Fatal(err)
	}
	if len(act.Digests) != limit+4 {
		t.Fatalf("got %d digests, want %d (tied boundary rows lost)", len(act.Digests), limit+4)
	}
	if act.CappedAt != boundary {
		t.Fatalf("CappedAt = %q, want boundary %q", act.CappedAt, boundary)
	}
}

// TestGetObserverActivityCappedAtMinAcrossSources pins the min-fold contract:
// when two sources are capped at different boundary timestamps, CappedAt is
// the smaller one — the watermark must not advance past rows any capped
// source left unread.
func TestGetObserverActivityCappedAtMinAcrossSources(t *testing.T) {
	d, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	const limit = 3
	// Digests cap at 2026-07-01T00:00:03Z; inbox caps a day later.
	for i := 1; i <= limit+1; i++ {
		seedActivityRow(t, d, "digest", i, fmt.Sprintf("2026-07-01T00:00:%02dZ", i))
		seedActivityRow(t, d, "inbox", i, fmt.Sprintf("2026-07-02T00:00:%02dZ", i))
	}

	act, err := d.GetObserverActivity("2026-01-01T00:00:00Z", limit)
	if err != nil {
		t.Fatal(err)
	}
	if len(act.Digests) != limit || len(act.Inbox) != limit {
		t.Fatalf("both sources should be capped: %d digests, %d inbox", len(act.Digests), len(act.Inbox))
	}
	want := fmt.Sprintf("2026-07-01T00:00:%02dZ", limit)
	if act.CappedAt != want {
		t.Fatalf("CappedAt = %q, want the smaller boundary %q", act.CappedAt, want)
	}
}
