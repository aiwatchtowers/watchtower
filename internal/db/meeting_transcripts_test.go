package db

import (
	"database/sql"
	"testing"
)

// seedTranscriptEvent inserts a calendar + event so transcript FKs are satisfied.
func seedTranscriptEvent(t *testing.T, database *DB, eventID string) {
	t.Helper()
	if _, err := database.Exec(`INSERT OR IGNORE INTO calendar_calendars (id, name) VALUES ('cal-1', 'Test Calendar')`); err != nil {
		t.Fatalf("seeding calendar: %v", err)
	}
	if _, err := database.Exec(`INSERT INTO calendar_events (id, calendar_id, title, start_time, end_time)
		VALUES (?, 'cal-1', 'Test event', '2026-07-13T10:00:00Z', '2026-07-13T11:00:00Z')`, eventID); err != nil {
		t.Fatalf("seeding event: %v", err)
	}
}

func TestInsertAndGetMeetingTranscript(t *testing.T) {
	database := openTestDB(t)

	id, err := database.InsertMeetingTranscript(MeetingTranscript{
		Title:          "Weekly sync",
		DurationSec:    1800,
		LangStats:      `{"ru":40,"en":5}`,
		TranscriptText: "hello world",
		AudioPath:      sql.NullString{String: "/tmp/rec.m4a", Valid: true},
	})
	if err != nil {
		t.Fatalf("insert: %v", err)
	}
	if id <= 0 {
		t.Fatalf("expected positive id, got %d", id)
	}

	got, err := database.GetMeetingTranscript(id)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got == nil {
		t.Fatal("expected transcript, got nil")
	}
	if got.ID != id {
		t.Errorf("id = %d, want %d", got.ID, id)
	}
	if got.Title != "Weekly sync" {
		t.Errorf("title = %q, want %q", got.Title, "Weekly sync")
	}
	if got.DurationSec != 1800 {
		t.Errorf("duration_sec = %d, want 1800", got.DurationSec)
	}
	if got.LangStats != `{"ru":40,"en":5}` {
		t.Errorf("lang_stats = %q", got.LangStats)
	}
	if got.TranscriptText != "hello world" {
		t.Errorf("transcript_text = %q", got.TranscriptText)
	}
	if !got.AudioPath.Valid || got.AudioPath.String != "/tmp/rec.m4a" {
		t.Errorf("audio_path = %+v, want /tmp/rec.m4a", got.AudioPath)
	}
	if got.EventID.Valid {
		t.Errorf("event_id should be NULL for ad-hoc, got %+v", got.EventID)
	}
	if got.SummaryJSON.Valid {
		t.Errorf("summary_json should be NULL initially, got %+v", got.SummaryJSON)
	}
	if got.CreatedAt == "" || got.UpdatedAt == "" {
		t.Error("timestamps must be set")
	}
}

func TestGetMeetingTranscriptMissing(t *testing.T) {
	database := openTestDB(t)

	got, err := database.GetMeetingTranscript(999)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if got != nil {
		t.Errorf("expected nil for missing transcript, got %+v", got)
	}
}

func TestListMeetingTranscriptsFilters(t *testing.T) {
	database := openTestDB(t)
	seedTranscriptEvent(t, database, "evt-1")

	linkedID, err := database.InsertMeetingTranscript(MeetingTranscript{
		EventID:        sql.NullString{String: "evt-1", Valid: true},
		Title:          "Linked meeting",
		TranscriptText: "linked text",
	})
	if err != nil {
		t.Fatalf("insert linked: %v", err)
	}
	adhocID, err := database.InsertMeetingTranscript(MeetingTranscript{
		Title:          "Ad-hoc meeting",
		TranscriptText: "ad-hoc text",
	})
	if err != nil {
		t.Fatalf("insert ad-hoc: %v", err)
	}

	byEvent, err := database.ListMeetingTranscripts(MeetingTranscriptFilter{EventID: "evt-1"})
	if err != nil {
		t.Fatalf("list by event: %v", err)
	}
	if len(byEvent) != 1 || byEvent[0].ID != linkedID {
		t.Errorf("EventID filter: got %d rows (%+v), want 1 row id=%d", len(byEvent), byEvent, linkedID)
	}

	all, err := database.ListMeetingTranscripts(MeetingTranscriptFilter{})
	if err != nil {
		t.Fatalf("list all: %v", err)
	}
	if len(all) != 2 {
		t.Fatalf("list all: got %d rows, want 2", len(all))
	}
	// Newest first: same created_at second → id DESC tiebreak, ad-hoc was inserted last.
	if all[0].ID != adhocID || all[1].ID != linkedID {
		t.Errorf("order: got [%d, %d], want [%d, %d]", all[0].ID, all[1].ID, adhocID, linkedID)
	}

	limited, err := database.ListMeetingTranscripts(MeetingTranscriptFilter{Limit: 1})
	if err != nil {
		t.Fatalf("list limited: %v", err)
	}
	if len(limited) != 1 {
		t.Errorf("Limit=1: got %d rows, want 1", len(limited))
	}

	// Time-range filters on created_at.
	future, err := database.ListMeetingTranscripts(MeetingTranscriptFilter{FromTime: "2099-01-01T00:00:00Z"})
	if err != nil {
		t.Fatalf("list from future: %v", err)
	}
	if len(future) != 0 {
		t.Errorf("FromTime in future: got %d rows, want 0", len(future))
	}
	past, err := database.ListMeetingTranscripts(MeetingTranscriptFilter{ToTime: "2000-01-01T00:00:00Z"})
	if err != nil {
		t.Fatalf("list to past: %v", err)
	}
	if len(past) != 0 {
		t.Errorf("ToTime in past: got %d rows, want 0", len(past))
	}
}

func TestSetMeetingTranscriptSummary(t *testing.T) {
	database := openTestDB(t)

	id, err := database.InsertMeetingTranscript(MeetingTranscript{
		Title:          "Summarized meeting",
		TranscriptText: "some text",
	})
	if err != nil {
		t.Fatalf("insert: %v", err)
	}

	payload := `{"summary":"we agreed on things"}`
	if err := database.SetMeetingTranscriptSummary(id, payload); err != nil {
		t.Fatalf("set summary: %v", err)
	}

	got, err := database.GetMeetingTranscript(id)
	if err != nil {
		t.Fatalf("refetch: %v", err)
	}
	if !got.SummaryJSON.Valid || got.SummaryJSON.String != payload {
		t.Errorf("summary_json = %+v, want %q", got.SummaryJSON, payload)
	}
}

func TestTranscriptAudioRetention(t *testing.T) {
	database := openTestDB(t)

	oldID, err := database.InsertMeetingTranscript(MeetingTranscript{
		Title:          "Old recording",
		TranscriptText: "old text",
		AudioPath:      sql.NullString{String: "/tmp/old.m4a", Valid: true},
	})
	if err != nil {
		t.Fatalf("insert old: %v", err)
	}
	if _, err := database.InsertMeetingTranscript(MeetingTranscript{
		Title:          "Fresh recording",
		TranscriptText: "fresh text",
		AudioPath:      sql.NullString{String: "/tmp/fresh.m4a", Valid: true},
	}); err != nil {
		t.Fatalf("insert fresh: %v", err)
	}

	if _, err := database.Exec(`UPDATE meeting_transcripts SET created_at = '2020-01-01T00:00:00Z' WHERE id = ?`, oldID); err != nil {
		t.Fatalf("backdating: %v", err)
	}

	expired, err := database.ExpiredTranscriptAudio("2025-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("expired: %v", err)
	}
	if len(expired) != 1 || expired[0].ID != oldID {
		t.Fatalf("expired: got %d rows (%+v), want 1 row id=%d", len(expired), expired, oldID)
	}

	if err := database.ClearMeetingTranscriptAudio(oldID); err != nil {
		t.Fatalf("clear audio: %v", err)
	}
	got, err := database.GetMeetingTranscript(oldID)
	if err != nil {
		t.Fatalf("refetch: %v", err)
	}
	if got.AudioPath.Valid {
		t.Errorf("audio_path should be NULL after clear, got %+v", got.AudioPath)
	}
	if got.TranscriptText != "old text" {
		t.Errorf("transcript_text must survive audio clear, got %q", got.TranscriptText)
	}

	expired2, err := database.ExpiredTranscriptAudio("2025-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("expired second pass: %v", err)
	}
	if len(expired2) != 0 {
		t.Errorf("expired second pass: got %d rows, want 0", len(expired2))
	}
}

func TestTranscriptSurvivesEventDeletion(t *testing.T) {
	database := openTestDB(t)
	seedTranscriptEvent(t, database, "evt-1")

	id, err := database.InsertMeetingTranscript(MeetingTranscript{
		EventID:        sql.NullString{String: "evt-1", Valid: true},
		Title:          "Doomed event meeting",
		TranscriptText: "text",
	})
	if err != nil {
		t.Fatalf("insert: %v", err)
	}

	if _, err := database.Exec(`DELETE FROM calendar_events WHERE id = 'evt-1'`); err != nil {
		t.Fatalf("deleting event: %v", err)
	}

	got, err := database.GetMeetingTranscript(id)
	if err != nil {
		t.Fatalf("refetch: %v", err)
	}
	if got == nil {
		t.Fatal("transcript must survive event deletion")
	}
	if got.EventID.Valid {
		t.Errorf("event_id should be NULL after event deletion, got %+v", got.EventID)
	}
}
