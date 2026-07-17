package mcp

import (
	"context"
	"database/sql"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

// seedTranscriptsDB seeds three transcripts:
//   - id "adhoc-old": ad-hoc (no event), own summary_json, created 2026-07-01
//   - id "linked":    linked to event EV1 (recap in meeting_recaps), created 2026-07-05
//   - id "adhoc-new": ad-hoc, no summary at all, created 2026-07-10
//
// Returns the database plus the three transcript ids in insertion order.
func seedTranscriptsDB(t *testing.T) (*db.DB, [3]int64) {
	t.Helper()
	database := seedDB(t)
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatalf("seed: %v", err)
		}
	}

	must(database.UpsertCalendar(db.CalendarCalendar{ID: "cal1", Name: "Work"}))
	must(database.UpsertCalendarEvent(db.CalendarEvent{
		ID: "EV1", CalendarID: "cal1", Title: "Roadmap Sync",
		StartTime: "2026-07-05T10:00:00Z", EndTime: "2026-07-05T11:00:00Z",
		EventStatus: "confirmed", RawJSON: "{}",
	}))
	must(database.UpsertMeetingRecap("EV1", "source",
		`{"summary":"Agreed to ship the roadmap Friday","key_decisions":["Ship Friday"],"action_items":["Vadym: draft announcement"],"open_questions":[]}`))

	var ids [3]int64
	insert := func(idx int, tr db.MeetingTranscript, createdAt string) {
		t.Helper()
		id, err := database.InsertMeetingTranscript(tr)
		must(err)
		_, err = database.Exec(`UPDATE meeting_transcripts SET created_at = ? WHERE id = ?`, createdAt, id)
		must(err)
		ids[idx] = id
	}

	insert(0, db.MeetingTranscript{
		Title: "Ad-hoc brainstorm", DurationSec: 300, LangStats: "{}",
		TranscriptText: "we talked about the ad-hoc brainstorm plan",
		SummaryJSON:    sql.NullString{String: `{"summary":"Brainstormed the Q3 plan","key_decisions":["Focus on Q3"],"action_items":[],"open_questions":["Budget?"]}`, Valid: true},
	}, "2026-07-01T09:00:00Z")

	insert(1, db.MeetingTranscript{
		EventID: sql.NullString{String: "EV1", Valid: true},
		Title:   "Roadmap Sync recording", DurationSec: 3600, LangStats: "{}",
		TranscriptText: "full roadmap sync transcript body",
	}, "2026-07-05T10:00:00Z")

	insert(2, db.MeetingTranscript{
		Title: "Hallway chat", DurationSec: 45, LangStats: "{}",
		TranscriptText: "quick hallway chat, nothing summarized",
	}, "2026-07-10T15:00:00Z")

	return database, ids
}

func TestListTranscripts_NewestFirst(t *testing.T) {
	database, _ := seedTranscriptsDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_transcripts",
		Arguments: map[string]any{},
	})
	if err != nil {
		t.Fatalf("call list_transcripts: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	got := textContent(t, res)

	for _, title := range []string{"Ad-hoc brainstorm", "Roadmap Sync recording", "Hallway chat"} {
		if !strings.Contains(got, title) {
			t.Fatalf("expected transcript %q in result, got: %s", title, got)
		}
	}
	// Newest first: Hallway (07-10) before Roadmap (07-05) before Ad-hoc (07-01).
	hallway := strings.Index(got, "Hallway chat")
	roadmap := strings.Index(got, "Roadmap Sync recording")
	adhoc := strings.Index(got, "Ad-hoc brainstorm")
	if !(hallway < roadmap && roadmap < adhoc) {
		t.Fatalf("expected newest-first order (hallway=%d roadmap=%d adhoc=%d), got: %s", hallway, roadmap, adhoc, got)
	}
	// One-line summaries: from summary_json for the ad-hoc row, from
	// meeting_recaps for the event-linked row.
	if !strings.Contains(got, "Brainstormed the Q3 plan") {
		t.Fatalf("expected ad-hoc summary from summary_json, got: %s", got)
	}
	if !strings.Contains(got, "Agreed to ship the roadmap Friday") {
		t.Fatalf("expected event-linked summary from meeting_recaps, got: %s", got)
	}
	// List rows must not dump the full transcript text.
	if strings.Contains(got, "full roadmap sync transcript body") {
		t.Fatalf("list must not include full transcript text, got: %s", got)
	}
}

func TestListTranscripts_EventIDFilter(t *testing.T) {
	database, _ := seedTranscriptsDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_transcripts",
		Arguments: map[string]any{"event_id": "EV1"},
	})
	if err != nil {
		t.Fatalf("call list_transcripts: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	got := textContent(t, res)
	if !strings.Contains(got, "Roadmap Sync recording") {
		t.Fatalf("expected the EV1 transcript, got: %s", got)
	}
	if strings.Contains(got, "Ad-hoc brainstorm") || strings.Contains(got, "Hallway chat") {
		t.Fatalf("event_id filter must exclude other transcripts, got: %s", got)
	}
	// Linked calendar event rendered with its title.
	if !strings.Contains(got, "Roadmap Sync") {
		t.Fatalf("expected event_title from the calendar event, got: %s", got)
	}
}

func TestListTranscripts_DateFilter(t *testing.T) {
	database, _ := seedTranscriptsDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_transcripts",
		Arguments: map[string]any{"from": "2026-07-03", "to": "2026-07-07"},
	})
	if err != nil {
		t.Fatalf("call list_transcripts: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	got := textContent(t, res)
	if !strings.Contains(got, "Roadmap Sync recording") {
		t.Fatalf("expected the 07-05 transcript inside the window, got: %s", got)
	}
	if strings.Contains(got, "Ad-hoc brainstorm") {
		t.Fatalf("from must exclude the 07-01 transcript, got: %s", got)
	}
	if strings.Contains(got, "Hallway chat") {
		t.Fatalf("to must exclude the 07-10 transcript, got: %s", got)
	}
}

func TestListTranscripts_BadDateErrors(t *testing.T) {
	database, _ := seedTranscriptsDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_transcripts",
		Arguments: map[string]any{"from": "last tuesday"},
	})
	if err != nil {
		t.Fatalf("call list_transcripts: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected an error for a malformed date, got: %s", textContent(t, res))
	}
}

func TestGetTranscript_FullText(t *testing.T) {
	database, ids := seedTranscriptsDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_transcript",
		Arguments: map[string]any{"id": ids[0]},
	})
	if err != nil {
		t.Fatalf("call get_transcript: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	got := textContent(t, res)
	if !strings.Contains(got, "we talked about the ad-hoc brainstorm plan") {
		t.Fatalf("expected full transcript text, got: %s", got)
	}
	// Parsed recap fields from summary_json.
	if !strings.Contains(got, "Brainstormed the Q3 plan") || !strings.Contains(got, "Focus on Q3") || !strings.Contains(got, "Budget?") {
		t.Fatalf("expected parsed recap fields, got: %s", got)
	}
}

func TestGetTranscript_EventLinkedRecap(t *testing.T) {
	database, ids := seedTranscriptsDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_transcript",
		Arguments: map[string]any{"id": ids[1]},
	})
	if err != nil {
		t.Fatalf("call get_transcript: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	got := textContent(t, res)
	if !strings.Contains(got, "full roadmap sync transcript body") {
		t.Fatalf("expected full transcript text, got: %s", got)
	}
	// Recap resolved through meeting_recaps via the linked event.
	if !strings.Contains(got, "Ship Friday") || !strings.Contains(got, "Vadym: draft announcement") {
		t.Fatalf("expected recap fields from meeting_recaps, got: %s", got)
	}
	if !strings.Contains(got, "Roadmap Sync") {
		t.Fatalf("expected event title, got: %s", got)
	}
}

func TestGetTranscript_UnknownIDErrors(t *testing.T) {
	database, _ := seedTranscriptsDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_transcript",
		Arguments: map[string]any{"id": 99999},
	})
	if err != nil {
		t.Fatalf("call get_transcript: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected an error for an unknown id, got: %s", textContent(t, res))
	}
}
