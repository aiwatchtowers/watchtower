package meeting

import (
	"context"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// MEETPRIV-02: notes for one recording of an event never carry the recap a
// private recording of the same event owns; a recap with no recording does.
func TestMeetPriv02_NotesPromptSkipsPrivateRecap(t *testing.T) {
	database := openTestDB(t)
	seedTestEvent(t, database)
	privateID, err := database.InsertMeetingTranscript(db.MeetingTranscript{Title: "p", TranscriptText: "secret", Private: true})
	require.NoError(t, err)
	require.NoError(t, database.UpsertMeetingRecap("evt1", "src", `{"summary":"SECRET-RECAP"}`, privateID))

	mock := &recordingMockGenerator{response: "# Notes"}
	pipe := &Pipeline{db: database, generator: mock}
	_, _, err = pipe.GenerateTranscriptNotes(context.Background(), "evt1", "public take of the meeting")
	require.NoError(t, err)
	if strings.Contains(mock.lastSystemPrompt, "SECRET-RECAP") {
		t.Fatal("a private recording's recap reached the notes prompt")
	}

	// A recap with no recording: the upsert keeps an existing owner, so the
	// private one's row goes first.
	_, err = database.Exec(`DELETE FROM meeting_recaps WHERE event_id = 'evt1'`)
	require.NoError(t, err)
	require.NoError(t, database.UpsertMeetingRecap("evt1", "src", `{"summary":"PASTED-RECAP"}`, 0))
	_, _, err = pipe.GenerateTranscriptNotes(context.Background(), "evt1", "public take of the meeting")
	require.NoError(t, err)
	if !strings.Contains(mock.lastSystemPrompt, "PASTED-RECAP") {
		t.Fatal("a recap with no recording must still reach the notes prompt")
	}
}
