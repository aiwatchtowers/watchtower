package db

import (
	"database/sql"
	"testing"
)

func TestMeetingRecapUpsertAndGet(t *testing.T) {
	database := openTestDB(t)

	// Seed calendar_calendars (required by FK chain: meeting_recaps -> calendar_events -> calendar_calendars)
	if _, err := database.Exec(`INSERT INTO calendar_calendars (id, name) VALUES ('cal-1', 'Test Calendar')`); err != nil {
		t.Fatalf("seeding calendar: %v", err)
	}

	// Need a calendar event to satisfy FK
	if _, err := database.Exec(`INSERT INTO calendar_events (id, calendar_id, title, start_time, end_time)
		VALUES ('evt-1', 'cal-1', 'Test event', '2026-04-27T10:00:00Z', '2026-04-27T11:00:00Z')`); err != nil {
		t.Fatalf("seeding event: %v", err)
	}

	if err := database.UpsertMeetingRecap("evt-1", "raw notes here", `{"summary":"x"}`, 0); err != nil {
		t.Fatalf("first upsert: %v", err)
	}

	got, err := database.GetMeetingRecap("evt-1")
	if err != nil {
		t.Fatalf("get after upsert: %v", err)
	}
	if got == nil {
		t.Fatal("expected recap, got nil")
	}
	if got.SourceText != "raw notes here" {
		t.Errorf("source_text = %q, want %q", got.SourceText, "raw notes here")
	}
	if got.RecapJSON != `{"summary":"x"}` {
		t.Errorf("recap_json = %q, want %q", got.RecapJSON, `{"summary":"x"}`)
	}
	if got.CreatedAt == "" || got.UpdatedAt == "" {
		t.Error("timestamps must be set")
	}

	// Idempotent re-upsert overrides
	if err := database.UpsertMeetingRecap("evt-1", "edited", `{"summary":"y"}`, 0); err != nil {
		t.Fatalf("re-upsert: %v", err)
	}
	got2, _ := database.GetMeetingRecap("evt-1")
	if got2.SourceText != "edited" || got2.RecapJSON != `{"summary":"y"}` {
		t.Errorf("re-upsert failed: %+v", got2)
	}
}

func TestMeetingRecapGetMissing(t *testing.T) {
	database := openTestDB(t)

	got, err := database.GetMeetingRecap("nope")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if got != nil {
		t.Errorf("expected nil for missing event, got %+v", got)
	}
}

// TestMeetingRecapSurvivesEventDelete pins the 00056 behavior: meeting_recaps.event_id
// is ON DELETE SET NULL (not CASCADE), so the daemon's stale-event cleanup no longer
// wipes a meeting's AI recap when its event ages out. The recap survives with event_id
// nulled AND stays reachable via its durable transcript_id link.
func TestMeetingRecapSurvivesEventDelete(t *testing.T) {
	database := openTestDB(t)

	if _, err := database.Exec(`INSERT INTO calendar_calendars (id, name) VALUES ('cal-1', 'Test Calendar')`); err != nil {
		t.Fatalf("seeding calendar: %v", err)
	}
	if _, err := database.Exec(`INSERT INTO calendar_events (id, calendar_id, title, start_time, end_time)
		VALUES ('evt-2', 'cal-1', 't', '2026-04-27T10:00:00Z', '2026-04-27T11:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	transcriptID, err := database.InsertMeetingTranscript(MeetingTranscript{
		EventID: sql.NullString{String: "evt-2", Valid: true}, Title: "t", TranscriptText: "hello",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := database.UpsertMeetingRecap("evt-2", "x", "{}", transcriptID); err != nil {
		t.Fatal(err)
	}

	// While the event exists the recap is addressable by event_id.
	if got, err := database.GetMeetingRecap("evt-2"); err != nil || got == nil {
		t.Fatalf("expected recap before event delete, got %+v err %v", got, err)
	}

	if _, err := database.Exec(`DELETE FROM calendar_events WHERE id='evt-2'`); err != nil {
		t.Fatal(err)
	}

	// event_id is nulled (not cascade-deleted), so the by-event lookup no longer
	// finds it — but the durable transcript_id link still resolves the survivor.
	if got, _ := database.GetMeetingRecap("evt-2"); got != nil {
		t.Errorf("expected by-event lookup to miss after event delete, got %+v", got)
	}
	got, err := database.GetMeetingRecapByTranscript(transcriptID)
	if err != nil {
		t.Fatal(err)
	}
	if got == nil {
		t.Fatal("expected the orphaned recap to be reachable via GetMeetingRecapByTranscript")
	}
	if got.EventID != "" {
		t.Errorf("expected event_id nulled after event delete, got %q", got.EventID)
	}
	if got.RecapJSON != "{}" || got.SourceText != "x" {
		t.Errorf("recap content not preserved: %+v", got)
	}
}

func TestGetMeetingNotesForEvent(t *testing.T) {
	database := openTestDB(t)

	// meeting_notes has no FK constraint on event_id, so no calendar seeding needed
	inserts := []struct {
		typ  string
		text string
		ord  int
	}{
		{"question", "topic A", 0},
		{"note", "freeform B", 0},
		{"question", "topic C", 1},
	}
	for _, ins := range inserts {
		if _, err := database.Exec(`INSERT INTO meeting_notes (event_id, type, text, sort_order)
			VALUES ('evt-3', ?, ?, ?)`, ins.typ, ins.text, ins.ord); err != nil {
			t.Fatal(err)
		}
	}

	notes, err := database.GetMeetingNotesForEvent("evt-3")
	if err != nil {
		t.Fatalf("get notes: %v", err)
	}
	if len(notes) != 3 {
		t.Fatalf("expected 3 rows, got %d", len(notes))
	}
	// Assert all texts present
	seen := map[string]bool{}
	for _, n := range notes {
		seen[n.Text] = true
	}
	for _, want := range []string{"topic A", "topic C", "freeform B"} {
		if !seen[want] {
			t.Errorf("missing note %q", want)
		}
	}
}

// seedOwnRecap inserts a transcript with a summary_json copy plus its own
// orphan meeting_recaps row, both stamped in 2020.
func seedOwnRecap(t *testing.T, database *DB) (transcriptID, recapID int64) {
	t.Helper()
	transcriptID, err := database.InsertMeetingTranscript(MeetingTranscript{
		Title: "t", TranscriptText: "hello", SummaryJSON: sql.NullString{String: "{}", Valid: true},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`UPDATE meeting_transcripts SET summary_updated_at = '2020-01-01T00:00:00Z' WHERE id = ?`, transcriptID); err != nil {
		t.Fatal(err)
	}
	res, err := database.Exec(`INSERT INTO meeting_recaps (event_id, transcript_id, source_text, recap_json, updated_at)
		VALUES (NULL, ?, 'old', '{}', '2020-01-01T00:00:00Z')`, transcriptID)
	if err != nil {
		t.Fatal(err)
	}
	recapID, _ = res.LastInsertId()
	return transcriptID, recapID
}

// TestWriteTranscriptRecapRewritesOwnRowAndSummary pins the by-id rewrite the
// recap retry uses for a recording's own row: content and both stamps move,
// the row's links stay.
func TestWriteTranscriptRecapRewritesOwnRowAndSummary(t *testing.T) {
	database := openTestDB(t)
	transcriptID, recapID := seedOwnRecap(t, database)

	err := database.WriteTranscriptRecap(TranscriptRecapRow{
		OwnRecapID: recapID, TranscriptID: transcriptID,
		SourceText: "new text", RecapJSON: `{"summary":"n"}`, SyncSummary: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	got, err := database.GetMeetingRecapByTranscript(transcriptID)
	if err != nil || got == nil {
		t.Fatalf("expected the row, got %+v err %v", got, err)
	}
	if got.SourceText != "new text" || got.RecapJSON != `{"summary":"n"}` {
		t.Errorf("content not rewritten: %+v", got)
	}
	if got.UpdatedAt <= "2020-01-01T00:00:00Z" {
		t.Errorf("updated_at = %q, want bumped", got.UpdatedAt)
	}
	if got.EventID != "" || !got.TranscriptID.Valid || got.TranscriptID.Int64 != transcriptID {
		t.Errorf("links changed: %+v", got)
	}
	var summary, stamp string
	if err := database.QueryRow(`SELECT summary_json, summary_updated_at FROM meeting_transcripts WHERE id = ?`, transcriptID).
		Scan(&summary, &stamp); err != nil {
		t.Fatal(err)
	}
	if summary != `{"summary":"n"}` || stamp <= "2020-01-01T00:00:00Z" {
		t.Errorf("summary copy not refreshed: %q %q", summary, stamp)
	}
}

// TestWriteTranscriptRecapIsAtomic: when the summary_json write fails, the
// recap row write rolls back with it — the row and its copy never diverge.
func TestWriteTranscriptRecapIsAtomic(t *testing.T) {
	database := openTestDB(t)
	transcriptID, recapID := seedOwnRecap(t, database)
	if _, err := database.Exec(`CREATE TRIGGER fail_summary BEFORE UPDATE OF summary_json ON meeting_transcripts
		BEGIN SELECT RAISE(ABORT, 'injected summary write failure'); END`); err != nil {
		t.Fatal(err)
	}

	err := database.WriteTranscriptRecap(TranscriptRecapRow{
		OwnRecapID: recapID, TranscriptID: transcriptID,
		SourceText: "new text", RecapJSON: `{"summary":"n"}`, SyncSummary: true,
	})
	if err == nil {
		t.Fatal("expected the injected failure")
	}
	got, err := database.GetMeetingRecapByTranscript(transcriptID)
	if err != nil || got == nil {
		t.Fatalf("expected the row, got %+v err %v", got, err)
	}
	if got.RecapJSON != "{}" || got.SourceText != "old" || got.UpdatedAt != "2020-01-01T00:00:00Z" {
		t.Errorf("recap row must roll back with the failed summary write: %+v", got)
	}
	var summary string
	if err := database.QueryRow(`SELECT summary_json FROM meeting_transcripts WHERE id = ?`, transcriptID).Scan(&summary); err != nil {
		t.Fatal(err)
	}
	if summary != "{}" {
		t.Errorf("summary_json = %q, want untouched", summary)
	}
}
