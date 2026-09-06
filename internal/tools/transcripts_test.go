package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func transcriptsRegistry(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	require.NoError(t, reg.Register(NewListTranscripts()))
	require.NoError(t, reg.Register(NewGetTranscript()))
	return reg
}

// seedTranscriptsDB seeds three transcripts: an ad-hoc one with its own recap
// (2026-07-01), an event-linked one whose recap lives in meeting_recaps
// (2026-07-05), and an ad-hoc one with no recap (2026-07-10).
func seedTranscriptsDB(t *testing.T) (*db.DB, [3]int64) {
	t.Helper()
	d := openDB(t)
	require.NoError(t, d.UpsertCalendar(0, db.CalendarCalendar{ID: "cal1", Name: "Work"}))
	require.NoError(t, d.UpsertCalendarEvent(db.CalendarEvent{
		ID: "EV1", CalendarID: "cal1", Title: "Roadmap Sync",
		StartTime: "2026-07-05T10:00:00Z", EndTime: "2026-07-05T11:00:00Z", EventStatus: "confirmed", RawJSON: "{}",
	}))
	require.NoError(t, d.UpsertMeetingRecap("EV1", "source",
		`{"summary":"Agreed to ship the roadmap Friday","key_decisions":["Ship Friday"],"action_items":["Vadym: draft announcement"],"open_questions":[]}`, 0))

	var ids [3]int64
	insert := func(idx int, tr db.MeetingTranscript, createdAt string) {
		id, err := d.InsertMeetingTranscript(tr)
		require.NoError(t, err)
		_, err = d.Exec(`UPDATE meeting_transcripts SET created_at = ? WHERE id = ?`, createdAt, id)
		require.NoError(t, err)
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
	return d, ids
}

// A plain listing carries the recap summary, never the full transcript text.
func TestListTranscripts_ListingCarriesRecapNotText(t *testing.T) {
	d, _ := seedTranscriptsDB(t)
	got := callReadString(t, transcriptsRegistry(t, d), "list_transcripts", `{}`)
	assert.Contains(t, got, "Brainstormed the Q3 plan")
	assert.Contains(t, got, "Agreed to ship the roadmap Friday")
	assert.NotContains(t, got, "full roadmap sync transcript body", "a listing must not include the full text")
}

func TestListTranscripts_EventIDFilter(t *testing.T) {
	d, _ := seedTranscriptsDB(t)
	got := callReadString(t, transcriptsRegistry(t, d), "list_transcripts", `{"event_id":"EV1"}`)
	assert.Contains(t, got, "Roadmap Sync recording")
	assert.NotContains(t, got, "Ad-hoc brainstorm")
	assert.NotContains(t, got, "Hallway chat")
}

func TestListTranscripts_BadDateErrors(t *testing.T) {
	d, _ := seedTranscriptsDB(t)
	_, err := transcriptsRegistry(t, d).CallRead(context.Background(), "list_transcripts", json.RawMessage(`{"from":"July"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
}

// The query path returns snippet hits, resolves the event title, and never
// includes the full transcript text.
func TestListTranscripts_QueryFindsAndSnippets(t *testing.T) {
	d, _ := seedTranscriptsDB(t)
	got := callReadString(t, transcriptsRegistry(t, d), "list_transcripts", `{"query":"brainstorm"}`)
	assert.Contains(t, got, "Ad-hoc brainstorm")
	assert.Contains(t, got, `"snippet"`)
	assert.NotContains(t, got, "transcript_text")
}

func TestListTranscripts_QueryCannotCombineWithFilters(t *testing.T) {
	d, _ := seedTranscriptsDB(t)
	_, err := transcriptsRegistry(t, d).CallRead(context.Background(), "list_transcripts", json.RawMessage(`{"query":"x","event_id":"EV1"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
}

// get_transcript returns the full text plus the parsed recap fields.
func TestGetTranscript_FullTextAndRecap(t *testing.T) {
	d, ids := seedTranscriptsDB(t)
	got := callReadString(t, transcriptsRegistry(t, d), "get_transcript", `{"id":`+strconv.FormatInt(ids[0], 10)+`}`)
	assert.Contains(t, got, "we talked about the ad-hoc brainstorm plan")
	assert.Contains(t, got, "Focus on Q3")
	assert.Contains(t, got, "Budget?")
}

// An event-linked transcript's recap comes from the linked meeting_recaps row.
func TestGetTranscript_EventLinkedRecap(t *testing.T) {
	d, ids := seedTranscriptsDB(t)
	got := callReadString(t, transcriptsRegistry(t, d), "get_transcript", `{"id":`+strconv.FormatInt(ids[1], 10)+`}`)
	assert.Contains(t, got, "full roadmap sync transcript body")
	assert.Contains(t, got, "Ship Friday")
	assert.Contains(t, got, "Vadym: draft announcement")
}

func TestGetTranscript_NotFound(t *testing.T) {
	d, _ := seedTranscriptsDB(t)
	_, err := transcriptsRegistry(t, d).CallRead(context.Background(), "get_transcript", json.RawMessage(`{"id":99999}`))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no transcript with id 99999")
}
