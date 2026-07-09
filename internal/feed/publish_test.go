package feed

import (
	"io"
	"log"
	"strings"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

func newTestPipeline(t *testing.T, d *db.DB, leadMinutes int) *Pipeline {
	t.Helper()
	cfg := &config.Config{}
	cfg.Feed.Enabled = true
	cfg.Feed.MeetingLeadMinutes = leadMinutes
	return New(d, cfg, log.New(io.Discard, "", 0))
}

// setCutoff rewinds the bootstrap cutoff so fixture rows created "before the
// feature existed" vs "after" can both be simulated.
func setCutoff(t *testing.T, d *db.DB, ts string) {
	t.Helper()
	if _, err := d.Exec(`UPDATE feed_state SET bootstrap_cutoff = ?`, ts); err != nil {
		t.Fatal(err)
	}
}

func insertCalendarEvent(t *testing.T, d *db.DB, id, start string) {
	t.Helper()
	if _, err := d.Exec(`INSERT OR IGNORE INTO calendar_calendars (id, name) VALUES ('cal1', 'Test')`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO calendar_events (id, calendar_id, title, start_time, end_time)
		VALUES (?, 'cal1', 'Standup', ?, ?)`, id, start, start); err != nil {
		t.Fatal(err)
	}
}

var testNow = time.Date(2026, 7, 9, 12, 0, 0, 0, time.UTC)

func TestPublishEachSourceType(t *testing.T) {
	d := db.OpenTestDB(t)
	setCutoff(t, d, "2026-07-01T00:00:00Z")

	if _, err := d.Exec(`INSERT INTO situations (id, title, priority, status, updated_at)
		VALUES (1, 'release blocked', 'medium', 'open', '2026-07-09T09:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	insertCalendarEvent(t, d, "ev1", "2026-07-09T12:10:00Z") // 10 min away — inside 30-min window
	if _, err := d.Exec(`INSERT INTO briefings (id, user_id, date, created_at)
		VALUES (5, 'U1', '2026-07-09', '2026-07-09T07:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO meeting_recaps (event_id, source_text, recap_json, created_at)
		VALUES ('ev1', '', '{}', '2026-07-09T11:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO day_plans (id, user_id, plan_date, status, generated_at)
		VALUES (3, 'U1', '2026-07-09', 'active', '2026-07-09T06:00:00Z')`); err != nil {
		t.Fatal(err)
	}

	n, err := newTestPipeline(t, d, 30).Publish(testNow)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if n != 5 {
		t.Fatalf("expected 5 published items, got %d", n)
	}
	for _, tc := range []struct {
		typ, id, eventTS string
		importance       int
	}{
		{"situation", "1", "2026-07-09T09:00:00Z", 60},
		{"meeting", "ev1", "2026-07-09T12:10:00Z", 70},
		{"briefing", "5", "2026-07-09T07:00:00Z", 60},
		{"meeting_recap", "ev1", "2026-07-09T11:00:00Z", 60},
		{"day_plan", "3", "2026-07-09T06:00:00Z", 60},
	} {
		item, err := d.GetFeedItem(tc.typ, tc.id)
		if err != nil || item == nil {
			t.Fatalf("%s/%s: %+v %v", tc.typ, tc.id, item, err)
		}
		if item.EventTS != tc.eventTS || item.Importance != tc.importance {
			t.Fatalf("%s/%s: got %+v", tc.typ, tc.id, item)
		}
	}
}

func TestPublishMeetingLeadWindow(t *testing.T) {
	d := db.OpenTestDB(t)
	insertCalendarEvent(t, d, "soon", "2026-07-09T12:10:00Z")  // inside
	insertCalendarEvent(t, d, "later", "2026-07-09T14:00:00Z") // beyond window
	insertCalendarEvent(t, d, "past", "2026-07-09T11:00:00Z")  // already started
	insertCalendarEvent(t, d, "allday", "2026-07-09T12:05:00Z")
	if _, err := d.Exec(`UPDATE calendar_events SET is_all_day = 1 WHERE id = 'allday'`); err != nil {
		t.Fatal(err)
	}

	if _, err := newTestPipeline(t, d, 30).Publish(testNow); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	for id, want := range map[string]bool{"soon": true, "later": false, "past": false, "allday": false} {
		item, err := d.GetFeedItem("meeting", id)
		if err != nil {
			t.Fatal(err)
		}
		if (item != nil) != want {
			t.Fatalf("meeting %q: published=%v, want %v", id, item != nil, want)
		}
	}
}

func TestPublishBootstrapCutoffExcludesBacklog(t *testing.T) {
	d := db.OpenTestDB(t)
	setCutoff(t, d, "2026-07-09T00:00:00Z")
	// Backlog rows from before the cutoff must never enter the feed.
	if _, err := d.Exec(`INSERT INTO briefings (id, user_id, date, created_at)
		VALUES (1, 'U1', '2026-06-01', '2026-06-01T07:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO day_plans (id, user_id, plan_date, status, generated_at, created_at)
		VALUES (1, 'U1', '2026-06-01', 'active', '2026-06-01T06:00:00Z', '2026-06-01T06:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := newTestPipeline(t, d, 30).Publish(testNow); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if n, _ := d.CountFeedItems(); n != 0 {
		t.Fatalf("backlog must not be published, got %d items", n)
	}
}

func TestPublishSituationMergeBumpsEventTS(t *testing.T) {
	d := db.OpenTestDB(t)
	if _, err := d.Exec(`INSERT INTO situations (id, title, priority, status, updated_at)
		VALUES (1, 'story', 'medium', 'open', '2026-07-09T09:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	p := newTestPipeline(t, d, 30)
	if _, err := p.Publish(testNow); err != nil {
		t.Fatal(err)
	}
	// Compose merges a new signal → updated_at bumps → item resurfaces.
	if _, err := d.Exec(`UPDATE situations SET updated_at = '2026-07-09T11:30:00Z' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Publish(testNow); err != nil {
		t.Fatal(err)
	}
	item, _ := d.GetFeedItem("situation", "1")
	if item == nil || item.EventTS != "2026-07-09T11:30:00Z" {
		t.Fatalf("merge should bump event_ts: %+v", item)
	}
}

// DASH-05: the publisher is additive and state-preserving — it never deletes
// feed rows and never resets hidden_at/seen_at on re-upsert.
func TestDash05_RepublishPreservesUserStateAndHistory(t *testing.T) {
	d := db.OpenTestDB(t)
	if _, err := d.Exec(`INSERT INTO situations (id, title, priority, status, updated_at)
		VALUES (1, 'story', 'high', 'open', '2026-07-09T09:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	p := newTestPipeline(t, d, 30)
	if _, err := p.Publish(testNow); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`UPDATE feed_items SET hidden_at = '2026-07-09T10:00:00Z', seen_at = '2026-07-09T10:00:00Z'`); err != nil {
		t.Fatal(err)
	}
	// The situation closes (drops out of the publisher's SELECT) and a rerank
	// happens elsewhere; the feed row must survive both untouched.
	if _, err := d.Exec(`UPDATE situations SET status = 'done' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Publish(testNow); err != nil {
		t.Fatal(err)
	}
	item, _ := d.GetFeedItem("situation", "1")
	if item == nil {
		t.Fatal("DASH-05: closed situation's feed row must not be deleted")
	}
	if item.HiddenAt == "" || item.SeenAt == "" {
		t.Fatalf("DASH-05: republish must preserve user state: %+v", item)
	}
}

// DASH-06: one broken source never blocks the others, and the publisher is
// AI-free by construction (Pipeline holds no generator). Degenerate input:
// a whole source table missing.
func TestDash06_SourceFailureDoesNotBlockOthers(t *testing.T) {
	d := db.OpenTestDB(t)
	setCutoff(t, d, "2026-07-01T00:00:00Z")
	if _, err := d.Exec(`DROP TABLE meeting_recaps`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO briefings (id, user_id, date, created_at)
		VALUES (7, 'U1', '2026-07-09', '2026-07-09T07:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	n, err := newTestPipeline(t, d, 30).Publish(testNow)
	if err == nil || !strings.Contains(err.Error(), "meeting_recap") {
		t.Fatalf("expected a meeting_recap error, got %v", err)
	}
	if n != 1 {
		t.Fatalf("briefing should still publish despite recap failure, got n=%d", n)
	}
	if item, _ := d.GetFeedItem("briefing", "7"); item == nil {
		t.Fatal("briefing must be published despite the recap source failing")
	}
}
