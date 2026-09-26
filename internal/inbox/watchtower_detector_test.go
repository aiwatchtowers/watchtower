package inbox

import (
	"context"
	"testing"
	"time"

	"watchtower/internal/db"
)

// newTestDB creates an in-memory DB for testing (alias used by this test file).
func newTestDB(t *testing.T) *db.DB {
	t.Helper()
	return testDB(t)
}

// seedBriefing inserts a briefing row for the given userID and date, stamped
// with createdAt so the detector's sinceTS filter can be exercised.
func seedBriefing(t *testing.T, d *db.DB, userID, date string, createdAt time.Time) {
	t.Helper()
	ts := createdAt.UTC().Format(time.RFC3339)
	_, err := d.Exec(`INSERT INTO briefings
		(user_id, date, created_at)
		VALUES (?, ?, ?)`,
		userID, date, ts)
	if err != nil {
		t.Fatalf("seedBriefing: %v", err)
	}
}

func TestWatchtowerDetector_BriefingReady(t *testing.T) {
	d := newTestDB(t)
	seedBriefing(t, d, "alice", time.Now().Format("2006-01-02"), time.Now())

	n, err := DetectWatchtowerInternal(context.Background(), d, time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n < 1 {
		t.Errorf("want >=1 briefing_ready, got %d", n)
	}
}

func TestWatchtowerDetector_BriefingDedup(t *testing.T) {
	d := newTestDB(t)
	seedBriefing(t, d, "alice", time.Now().Format("2006-01-02"), time.Now())

	n1, err := DetectWatchtowerInternal(context.Background(), d, time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n1 < 1 {
		t.Fatalf("first run: want >=1, got %d", n1)
	}

	n2, err := DetectWatchtowerInternal(context.Background(), d, time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n2 != 0 {
		t.Errorf("second run: want 0 duplicates, got %d", n2)
	}
}

func TestWatchtowerDetector_OlderThanSinceSkipped(t *testing.T) {
	d := newTestDB(t)
	// Briefing created 2 hours ago, but sinceTS is 1 hour ago.
	seedBriefing(t, d, "alice", time.Now().Format("2006-01-02"), time.Now().Add(-2*time.Hour))

	n, err := DetectWatchtowerInternal(context.Background(), d, time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("old briefing should be skipped, got %d items", n)
	}
}
