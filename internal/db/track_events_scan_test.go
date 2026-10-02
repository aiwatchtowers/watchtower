package db

import (
	"fmt"
	"slices"
	"testing"
	"time"
)

// scanTS returns an ISO8601 second-resolution timestamp n minutes after base.
func scanTS(base time.Time, n int) string {
	return base.Add(time.Duration(n) * time.Minute).Format("2006-01-02T15:04:05Z")
}

// scanBase anchors seeded activity an hour in the past, so every seeded row is
// in the past regardless of when the test runs.
func scanBase() time.Time {
	return time.Now().UTC().Add(-time.Hour).Truncate(time.Second)
}

func seedScanDigest(t *testing.T, d *DB, typ, summary, createdAt string) int {
	t.Helper()
	res, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary, created_at)
		VALUES ('C1', (SELECT COUNT(*) FROM digests), 0, ?, ?, ?)`, typ, summary, createdAt)
	if err != nil {
		t.Fatalf("seed digest: %v", err)
	}
	id, _ := res.LastInsertId()
	return int(id)
}

func seedScanTrack(t *testing.T, d *DB, origin, text, dismissedAt, updatedAt string) int {
	t.Helper()
	res, err := d.Exec(`INSERT INTO tracks (text, origin, dismissed_at, updated_at) VALUES (?, ?, ?, ?)`,
		text, origin, dismissedAt, updatedAt)
	if err != nil {
		t.Fatalf("seed track: %v", err)
	}
	id, _ := res.LastInsertId()
	return int(id)
}

func seedScanInbox(t *testing.T, d *DB, snippet, createdAt string) int {
	t.Helper()
	res, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, created_at)
		VALUES ('C1', ?, 'U2', 'mention', ?, ?)`, snippet, snippet, createdAt)
	if err != nil {
		t.Fatalf("seed inbox: %v", err)
	}
	id, _ := res.LastInsertId()
	return int(id)
}

// TestGetScanActivity_UncappedWindow pins the source filters and order of an
// uncapped window: strictly after the watermark, channel digests only, live
// auto tracks only, oldest first, and no CappedAt (the caller may advance its
// watermark to now).
func TestGetScanActivity_UncappedWindow(t *testing.T) {
	d := openTestDB(t)
	base := scanBase()
	since := scanTS(base, 0)

	seedScanDigest(t, d, "channel", "at the watermark", since) // strict >, excluded
	d2 := seedScanDigest(t, d, "channel", "newer", scanTS(base, 2))
	d1 := seedScanDigest(t, d, "channel", "older", scanTS(base, 1))
	seedScanDigest(t, d, "daily", "cross-channel rollup", scanTS(base, 3))

	tr := seedScanTrack(t, d, "auto", "live auto", "", scanTS(base, 1))
	seedScanTrack(t, d, "auto", "dismissed auto", scanTS(base, 2), scanTS(base, 2))
	seedScanTrack(t, d, "custom", "another custom track", "", scanTS(base, 2))

	in := seedScanInbox(t, d, "mention", scanTS(base, 1))
	seedScanInbox(t, d, "before the watermark", scanTS(base, -1))

	act, err := d.GetScanActivity(since, 10)
	if err != nil {
		t.Fatalf("GetScanActivity: %v", err)
	}
	if len(act.Digests) != 2 || act.Digests[0].ID != d1 || act.Digests[1].ID != d2 {
		t.Errorf("digests = %+v; want [%d %d] oldest first", act.Digests, d1, d2)
	}
	if len(act.Tracks) != 1 || act.Tracks[0].ID != tr {
		t.Errorf("tracks = %+v; want only live auto track %d", act.Tracks, tr)
	}
	if len(act.Inbox) != 1 || act.Inbox[0].ID != in {
		t.Errorf("inbox = %+v; want only %d", act.Inbox, in)
	}
	if act.CappedAt != "" {
		t.Errorf("CappedAt = %q on an uncapped window; want empty", act.CappedAt)
	}
}

// TestGetScanActivity_CapDrainsBoundaryTies pins the tie drain: when a source
// hits the cap mid-second, every remaining row of that second is loaded too, so
// the next window (strict > CappedAt) loses nothing. Without the drain the two
// tied rows past the cap are skipped forever.
func TestGetScanActivity_CapDrainsBoundaryTies(t *testing.T) {
	d := openTestDB(t)
	base := scanBase()
	since := scanTS(base, 0)

	first := seedScanInbox(t, d, "first", scanTS(base, 1))
	var tied []int
	for i := 0; i < 3; i++ {
		tied = append(tied, seedScanInbox(t, d, fmt.Sprintf("tied-%d", i), scanTS(base, 2)))
	}
	later := seedScanInbox(t, d, "later", scanTS(base, 3))

	act, err := d.GetScanActivity(since, 2)
	if err != nil {
		t.Fatalf("GetScanActivity: %v", err)
	}
	var got []int
	for _, a := range act.Inbox {
		got = append(got, a.ID)
	}
	want := append([]int{first}, tied...)
	if !slices.Equal(got, want) {
		t.Fatalf("inbox ids = %v; want %v (cap 2 + drained ties)", got, want)
	}
	if act.CappedAt != scanTS(base, 2) {
		t.Fatalf("CappedAt = %q; want the boundary second %q", act.CappedAt, scanTS(base, 2))
	}

	// The next window opens at CappedAt and picks up exactly the overflow.
	next, err := d.GetScanActivity(act.CappedAt, 2)
	if err != nil {
		t.Fatalf("GetScanActivity(next): %v", err)
	}
	if len(next.Inbox) != 1 || next.Inbox[0].ID != later {
		t.Fatalf("next window inbox = %+v; want only the overflow row %d", next.Inbox, later)
	}
	if next.CappedAt != "" {
		t.Errorf("next window CappedAt = %q; want empty", next.CappedAt)
	}
}

// TestGetScanActivity_CappedAtIsMinAcrossSources pins that the safe watermark
// is the earliest coverage among capped sources: advancing to a later source's
// boundary would skip the other source's unread rows.
func TestGetScanActivity_CappedAtIsMinAcrossSources(t *testing.T) {
	d := openTestDB(t)
	base := scanBase()
	since := scanTS(base, 0)

	// Digests capped at minute 4, tracks capped at minute 2, inbox uncapped.
	for i := 1; i <= 5; i++ {
		seedScanDigest(t, d, "channel", fmt.Sprintf("d%d", i), scanTS(base, i+2))
	}
	for i := 1; i <= 3; i++ {
		seedScanTrack(t, d, "auto", fmt.Sprintf("t%d", i), "", scanTS(base, i))
	}
	seedScanInbox(t, d, "only one", scanTS(base, 9))

	act, err := d.GetScanActivity(since, 2)
	if err != nil {
		t.Fatalf("GetScanActivity: %v", err)
	}
	if len(act.Digests) != 2 || len(act.Tracks) != 2 || len(act.Inbox) != 1 {
		t.Fatalf("rows = %d/%d/%d; want 2/2/1", len(act.Digests), len(act.Tracks), len(act.Inbox))
	}
	if want := scanTS(base, 2); act.CappedAt != want {
		t.Fatalf("CappedAt = %q; want min across capped sources %q", act.CappedAt, want)
	}
}

// TestGetScanActivityTitles_MergesNewestFirstAndCaps pins the stage-1 title
// feed: the three sources merge newest first, the overall limit keeps the
// newest, and the same source filters as the forward scan apply.
func TestGetScanActivityTitles_MergesNewestFirstAndCaps(t *testing.T) {
	d := openTestDB(t)
	base := scanBase()
	since := scanTS(base, 0)

	seedScanDigest(t, d, "channel", "digest m1", scanTS(base, 1))
	seedScanDigest(t, d, "weekly", "weekly rollup", scanTS(base, 5))
	seedScanTrack(t, d, "auto", "track m3", "", scanTS(base, 3))
	seedScanTrack(t, d, "custom", "custom track", "", scanTS(base, 6))
	seedScanInbox(t, d, "inbox m2", scanTS(base, 2))
	seedScanInbox(t, d, "inbox m4", scanTS(base, 4))

	titles, err := d.GetScanActivityTitles(since, 3)
	if err != nil {
		t.Fatalf("GetScanActivityTitles: %v", err)
	}
	var got []string
	for _, ttl := range titles {
		got = append(got, ttl.Kind+":"+ttl.Title)
	}
	want := []string{"inbox:inbox m4", "track:track m3", "inbox:inbox m2"}
	if !slices.Equal(got, want) {
		t.Fatalf("titles = %v; want %v", got, want)
	}
}

// TestGetScanActivityByIDs_RoutesPerSource pins the stage-2 load: ids are
// looked up in their own source only, custom tracks never load, and an empty
// id slice skips its source.
func TestGetScanActivityByIDs_RoutesPerSource(t *testing.T) {
	d := openTestDB(t)
	base := scanBase()

	dg := seedScanDigest(t, d, "channel", "digest", scanTS(base, 1))
	tr := seedScanTrack(t, d, "auto", "auto track", "", scanTS(base, 1))
	custom := seedScanTrack(t, d, "custom", "custom track", "", scanTS(base, 1))
	in := seedScanInbox(t, d, "inbox", scanTS(base, 1))

	act, err := d.GetScanActivityByIDs([]int{dg}, []int{tr, custom}, nil)
	if err != nil {
		t.Fatalf("GetScanActivityByIDs: %v", err)
	}
	if len(act.Digests) != 1 || act.Digests[0].ID != dg {
		t.Errorf("digests = %+v; want [%d]", act.Digests, dg)
	}
	if len(act.Tracks) != 1 || act.Tracks[0].ID != tr {
		t.Errorf("tracks = %+v; want only the auto track %d", act.Tracks, tr)
	}
	if len(act.Inbox) != 0 {
		t.Errorf("inbox = %+v; want none for a nil id slice (inbox %d exists)", act.Inbox, in)
	}
}
