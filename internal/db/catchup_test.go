package db

import "testing"

func TestCatchup01_GetUnreadDigestsCapAndTotal(t *testing.T) {
	d := openTestDB(t)
	for i := 0; i < 5; i++ {
		if _, err := d.Exec(
			`INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at)
			 VALUES (?, ?, ?, 'channel', ?, NULL)`,
			"C1", float64(i), float64(i+1), "summary text "+itoa(i)); err != nil {
			t.Fatal(err)
		}
	}
	// One already-read digest must be excluded.
	if _, err := d.Exec(
		`INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at)
		 VALUES ('C1', 99, 100, 'channel', 'read one', '2026-01-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}

	items, total, err := d.GetUnreadDigests(3)
	if err != nil {
		t.Fatal(err)
	}
	if total != 5 {
		t.Fatalf("total = %d, want 5", total)
	}
	if len(items) != 3 {
		t.Fatalf("len(items) = %d, want 3 (capped)", len(items))
	}
	if items[0].ID == 0 {
		t.Fatal("expected populated item ID")
	}
}

func itoa(i int) string { return string(rune('0' + i)) }
