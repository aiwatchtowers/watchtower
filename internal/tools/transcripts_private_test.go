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

// MEETPRIV-02 (docs/inventory/meetings.md): the transcript tools and the
// task-context meetings never show a private recording or its recap.

// seedPrivateTranscripts adds to seedTranscriptsDB a private recording of
// EV2 that owns EV2's recap, plus a public second recording of EV2.
func seedPrivateTranscripts(t *testing.T) (d *db.DB, privateID, publicTwinID int64) {
	t.Helper()
	d, _ = seedTranscriptsDB(t)
	require.NoError(t, d.UpsertCalendarEvent(db.CalendarEvent{
		ID: "EV2", CalendarID: "cal1", Title: "Board prep",
		StartTime: "2026-07-06T10:00:00Z", EndTime: "2026-07-06T11:00:00Z", EventStatus: "confirmed", RawJSON: "{}",
	}))
	var err error
	privateID, err = d.InsertMeetingTranscript(db.MeetingTranscript{
		EventID: sql.NullString{String: "EV2", Valid: true},
		Title:   "Board prep recording", LangStats: "{}", Private: true,
		TranscriptText: "confidential roadmap acquisition talk PROJ-7",
	})
	require.NoError(t, err)
	require.NoError(t, d.UpsertMeetingRecap("EV2", "source", `{"summary":"Secret acquisition recap"}`, privateID))
	publicTwinID, err = d.InsertMeetingTranscript(db.MeetingTranscript{
		EventID: sql.NullString{String: "EV2", Valid: true},
		Title:   "Board prep second take", LangStats: "{}",
		TranscriptText: "public roadmap remarks",
	})
	require.NoError(t, err)
	return d, privateID, publicTwinID
}

func TestMeetPriv02_ListTranscriptsSkipsPrivate(t *testing.T) {
	d, privateID, twinID := seedPrivateTranscripts(t)
	reg := transcriptsRegistry(t, d)

	got := callReadString(t, reg, "list_transcripts", `{}`)
	assert.NotContains(t, got, "Board prep recording")
	assert.NotContains(t, got, "Secret acquisition recap", "the private recording's recap must not ride along with its public twin")
	assert.Contains(t, got, "Board prep second take")
	assert.Contains(t, got, "Roadmap Sync recording")

	hits := callReadString(t, reg, "list_transcripts", `{"query":"roadmap"}`)
	assert.NotContains(t, hits, `"id":`+strconv.FormatInt(privateID, 10)+`,`)
	assert.NotContains(t, hits, "acquisition")
	assert.Contains(t, hits, `"id":`+strconv.FormatInt(twinID, 10)+`,`)
}

func TestMeetPriv02_GetTranscriptRefusesPrivate(t *testing.T) {
	d, privateID, twinID := seedPrivateTranscripts(t)
	reg := transcriptsRegistry(t, d)

	_, err := reg.CallRead(context.Background(), "get_transcript",
		json.RawMessage(`{"id":`+strconv.FormatInt(privateID, 10)+`}`), Binding{})
	require.Error(t, err)
	assert.Equal(t, "recording "+strconv.FormatInt(privateID, 10)+" is private", err.Error())

	got := callReadString(t, reg, "get_transcript", `{"id":`+strconv.FormatInt(twinID, 10)+`}`)
	assert.Contains(t, got, "public roadmap remarks")
	assert.NotContains(t, got, "Secret acquisition recap")
}

func TestMeetPriv02_TaskContextMeetingsSkipPrivate(t *testing.T) {
	d, privateID, _ := seedPrivateTranscripts(t)
	_, err := d.InsertMeetingTranscript(db.MeetingTranscript{Title: "Public PROJ-7 review", LangStats: "{}", TranscriptText: "we reviewed PROJ-7"})
	require.NoError(t, err)

	for name, meetings := range map[string][]taskMeeting{
		"jira":   func() []taskMeeting { m, _ := collectTaskMeetings(d, "PROJ-7", nil); return m }(),
		"linear": func() []taskMeeting { m, _ := collectLinearTaskMeetings(d, []string{"PROJ-7"}, nil); return m }(),
	} {
		require.Len(t, meetings, 1, name)
		assert.Equal(t, "Public PROJ-7 review", meetings[0].Title, name)
		assert.NotEqual(t, privateID, meetings[0].TranscriptID, name)
	}
}
