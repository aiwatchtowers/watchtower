package db

import (
	"testing"
	"time"
)

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

	items, total, err := d.GetUnreadDigests(3, 0)
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

func TestCatchup02_InboxEmptyStringReadAtIsUnread(t *testing.T) {
	d := openTestDB(t)
	// Inbox uniquely treats read_at='' (not just NULL) as unread.
	if _, err := d.Exec(
		`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, status, priority, read_at)
		 VALUES ('C1', '1.1', 'U1', 'mention', 'pending', 'medium', '')`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(
		`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, status, priority, read_at)
		 VALUES ('C1', '2.2', 'U1', 'mention', 'pending', 'medium', NULL)`); err != nil {
		t.Fatal(err)
	}
	// An already-read item must be excluded.
	if _, err := d.Exec(
		`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, status, priority, read_at)
		 VALUES ('C1', '3.3', 'U1', 'mention', 'pending', 'medium', '2026-01-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}

	items, total, err := d.GetUnreadInboxItems(100, 0)
	if err != nil {
		t.Fatal(err)
	}
	if total != 2 {
		t.Fatalf("unread inbox total = %d, want 2 (empty-string and NULL read_at)", total)
	}
	if len(items) != 2 {
		t.Fatalf("len(items) = %d, want 2", len(items))
	}
}

func TestCatchup03_MaxAgeExcludesOldUnread(t *testing.T) {
	d := openTestDB(t)

	nowUnix := float64(time.Now().UTC().Unix())
	oldUnix := float64(time.Now().UTC().AddDate(0, 0, -60).Unix())
	recentISO := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	oldISO := time.Now().UTC().AddDate(0, 0, -60).Format("2006-01-02T15:04:05Z")
	recentDate := time.Now().UTC().Format("2006-01-02")
	oldDate := time.Now().UTC().AddDate(0, 0, -60).Format("2006-01-02")

	// Digests: one recent, one old (by period_to).
	if _, err := d.Exec(
		`INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at)
		 VALUES ('C1', ?, ?, 'channel', 'recent', NULL)`, nowUnix-1, nowUnix); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(
		`INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at)
		 VALUES ('C1', ?, ?, 'channel', 'old', NULL)`, oldUnix-1, oldUnix); err != nil {
		t.Fatal(err)
	}

	// Tracks: one recently updated, one old (by updated_at).
	if _, err := d.Exec(
		`INSERT INTO tracks (text, has_updates, dismissed_at, priority, updated_at)
		 VALUES ('recent track', 1, '', 'medium', ?)`, recentISO); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(
		`INSERT INTO tracks (text, has_updates, dismissed_at, priority, updated_at)
		 VALUES ('old track', 1, '', 'medium', ?)`, oldISO); err != nil {
		t.Fatal(err)
	}

	// Inbox: one recently updated, one old (by updated_at).
	if _, err := d.Exec(
		`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, status, priority, updated_at)
		 VALUES ('C1', '1.1', 'U1', 'mention', 'pending', 'medium', ?)`, recentISO); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(
		`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, status, priority, updated_at)
		 VALUES ('C1', '2.2', 'U1', 'mention', 'pending', 'medium', ?)`, oldISO); err != nil {
		t.Fatal(err)
	}

	// Briefings: one recent, one old (by date).
	if _, err := d.Exec(
		`INSERT INTO briefings (user_id, date, read_at) VALUES ('U1', ?, NULL)`, recentDate); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(
		`INSERT INTO briefings (user_id, date, read_at) VALUES ('U1', ?, NULL)`, oldDate); err != nil {
		t.Fatal(err)
	}

	const maxAge = 30
	cases := []struct {
		name string
		get  func() ([]UnreadItem, int, error)
	}{
		{"digests", func() ([]UnreadItem, int, error) { return d.GetUnreadDigests(100, maxAge) }},
		{"tracks", func() ([]UnreadItem, int, error) { return d.GetUnreadTracks(100, maxAge) }},
		{"inbox", func() ([]UnreadItem, int, error) { return d.GetUnreadInboxItems(100, maxAge) }},
		{"briefings", func() ([]UnreadItem, int, error) { return d.GetUnreadBriefings(100, maxAge) }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			items, total, err := tc.get()
			if err != nil {
				t.Fatal(err)
			}
			// The old (60d) item must be excluded from both items and total.
			if total != 1 {
				t.Fatalf("%s: total = %d, want 1 (old excluded)", tc.name, total)
			}
			if len(items) != 1 {
				t.Fatalf("%s: len(items) = %d, want 1 (old excluded)", tc.name, len(items))
			}
		})
	}

	// maxAgeDays <= 0 disables the filter: both rows are returned per area.
	for _, tc := range []struct {
		name string
		get  func() ([]UnreadItem, int, error)
	}{
		{"digests", func() ([]UnreadItem, int, error) { return d.GetUnreadDigests(100, 0) }},
		{"tracks", func() ([]UnreadItem, int, error) { return d.GetUnreadTracks(100, 0) }},
		{"inbox", func() ([]UnreadItem, int, error) { return d.GetUnreadInboxItems(100, 0) }},
		{"briefings", func() ([]UnreadItem, int, error) { return d.GetUnreadBriefings(100, 0) }},
	} {
		t.Run("nofilter_"+tc.name, func(t *testing.T) {
			_, total, err := tc.get()
			if err != nil {
				t.Fatal(err)
			}
			if total != 2 {
				t.Fatalf("%s: total = %d, want 2 (no filter)", tc.name, total)
			}
		})
	}
}
