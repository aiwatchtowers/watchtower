package memory

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// MEETPRIV-02: the calendar episode of an event never folds in the recap a
// private recording owns; the event itself is still remembered.
func TestMeetPriv02_CalendarIngestSkipsPrivateRecap(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	for _, id := range []string{"evt-priv", "evt-pub"} {
		ev, _ := endedEvent(id, 2)
		seedCalendarEvent(t, d, ev)
	}
	privateID, err := d.InsertMeetingTranscript(db.MeetingTranscript{Title: "p", TranscriptText: "x", Private: true})
	require.NoError(t, err)
	publicID, err := d.InsertMeetingTranscript(db.MeetingTranscript{Title: "q", TranscriptText: "y"})
	require.NoError(t, err)
	require.NoError(t, d.UpsertMeetingRecap("evt-priv", "src", `{"summary":"Secret merger talk."}`, privateID))
	require.NoError(t, d.UpsertMeetingRecap("evt-pub", "src", `{"summary":"Public roadmap talk."}`, publicID))

	p := NewPipeline(d, v, noCallGen(t), calendarPipelineConfig(), t.Logf)
	var stats RunStats
	_, err = p.runCalendarIngest(1, 0, &stats)
	require.NoError(t, err)

	priv, err := Resolve(v, d, "calevent:evt-priv")
	require.NoError(t, err)
	assert.NotContains(t, priv.Body, "Secret merger talk.")
	pub, err := Resolve(v, d, "calevent:evt-pub")
	require.NoError(t, err)
	assert.Contains(t, pub.Body, "Public roadmap talk.")
}
