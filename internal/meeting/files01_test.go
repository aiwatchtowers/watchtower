package meeting

import (
	"context"
	"encoding/json"
	"log"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/logcanary"
)

// TestFILES01_MeetingNeverLogsTitles runs every meeting AI call over an event
// and a transcript made of canaries, once with a valid answer that quotes a
// canary and once with unparseable output, and logs each returned error the
// way a caller would. No canary may reach the log.
func TestFILES01_MeetingNeverLogsTitles(t *testing.T) {
	c := logcanary.Text
	sink := logcanary.Capture(t)
	database := openTestDB(t)
	require.NoError(t, database.UpsertCalendar(0, db.CalendarCalendar{ID: "primary", Name: c("calendar.name"), SyncedAt: "2026-04-01T00:00:00Z"}))
	attendees, err := json.Marshal([]attendeeEntry{
		{Email: "a@example.com", DisplayName: c("attendee.display_name"), SlackUserID: "U1"},
		{Email: "b@example.com", DisplayName: c("attendee.display_name")},
	})
	require.NoError(t, err)
	require.NoError(t, database.UpsertCalendarEvent(db.CalendarEvent{
		ID: "evt1", CalendarID: "primary", Title: c("event.title"), Description: c("event.description"),
		StartTime: "2099-04-02T10:00:00Z", EndTime: "2099-04-02T10:30:00Z", Attendees: string(attendees),
	}))

	valid := `{"summary":"` + c("llm.summary") + `","talking_points":[{"text":"` + c("llm.point") + `"}],` +
		`"topics":[{"title":"` + c("llm.topic") + `"}],"chapters":[{"title":"` + c("llm.chapter") + `","start_idx":0}]}`
	invalid := c("llm.output") + ` not json {"x":`
	transcript := c("transcript")
	utterances := []TranscriptUtterance{{Idx: 0, Speaker: c("speaker"), Text: transcript, EndSec: 5}}

	for _, out := range []string{valid, invalid} {
		p := New(database, &config.Config{}, &mockGenerator{response: out}, sink.Logger())
		ctx := context.Background()
		_, err := p.PrepareForEvent(ctx, "evt1", c("user.notes"))
		log.Printf("prep: %v", err)
		_, err = p.GenerateRecap(ctx, "evt1", transcript)
		log.Printf("recap: %v", err)
		_, _, err = p.GenerateTranscriptRecap(ctx, "evt1", transcript)
		log.Printf("transcript recap: %v", err)
		_, err = p.ExtractDiscussionTopics(ctx, transcript, c("event.title"))
		log.Printf("topics: %v", err)
		_, _, err = p.GenerateTranscriptChapters(ctx, "evt1", utterances, 5)
		log.Printf("chapters: %v", err)
	}

	require.Contains(t, sink.String(), "meeting: ", "the pipeline logged nothing; the guard would be vacuous")
	sink.AssertClean(t)
}
