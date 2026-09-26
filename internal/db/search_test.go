package db

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func seedSearchMessages(t *testing.T, db *DB) {
	t.Helper()
	msgs := []Message{
		{ChannelID: "C001", TS: "1700000001.000001", UserID: "U001", Text: "deployment to production successful", RawJSON: "{}"},
		{ChannelID: "C001", TS: "1700000002.000001", UserID: "U002", Text: "the bug in login flow is fixed", RawJSON: "{}"},
		{ChannelID: "C002", TS: "1700000003.000001", UserID: "U001", Text: "deploying new feature to staging", RawJSON: "{}"},
		{ChannelID: "C002", TS: "1700000500.000001", UserID: "U003", Text: "database migration completed", RawJSON: "{}"},
		{ChannelID: "C003", TS: "1700001000.000001", UserID: "U002", Text: "production deployment rollback needed", RawJSON: "{}"},
	}
	for _, msg := range msgs {
		require.NoError(t, db.UpsertMessage(msg))
	}
}

func TestSearchMessagesBasic(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()
	seedSearchMessages(t, db)

	results, err := db.SearchMessages("deployment", SearchOpts{})
	require.NoError(t, err)
	assert.Len(t, results, 2) // "deployment to production" and "production deployment rollback"
}

func TestSearchMessagesStemming(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()
	seedSearchMessages(t, db)

	// "deploying" should match via porter stemmer
	results, err := db.SearchMessages("deploying", SearchOpts{})
	require.NoError(t, err)
	assert.GreaterOrEqual(t, len(results), 1, "stemming should match deploying")

	// "deployment" should match both deployment messages
	results, err = db.SearchMessages("deployment", SearchOpts{})
	require.NoError(t, err)
	assert.Equal(t, 2, len(results), "should match 'deployment' in two messages")
}

func TestSearchMessagesChannelFilter(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()
	seedSearchMessages(t, db)

	results, err := db.SearchMessages("deployment", SearchOpts{ChannelIDs: []string{"C001"}})
	require.NoError(t, err)
	assert.Len(t, results, 1)
	assert.Equal(t, "C001", results[0].ChannelID)
}

func TestSearchMessagesUserFilter(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()
	seedSearchMessages(t, db)

	results, err := db.SearchMessages("deployment", SearchOpts{UserIDs: []string{"U001"}})
	require.NoError(t, err)
	require.Len(t, results, 1)
	assert.Equal(t, "U001", results[0].UserID)
}

func TestListRecentMessagesByUser(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()
	seedSearchMessages(t, db)

	// No keyword: every message from U001, newest first.
	results, err := db.ListRecentMessages(SearchOpts{UserIDs: []string{"U001"}})
	require.NoError(t, err)
	require.Len(t, results, 2)
	assert.Equal(t, "U001", results[0].UserID)
	assert.Equal(t, "U001", results[1].UserID)
	// Newest first: C002/1700000003 before C001/1700000001.
	assert.True(t, results[0].TSUnix > results[1].TSUnix, "results must be newest first")
}

func TestListRecentMessagesChannelAndLimit(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()
	seedSearchMessages(t, db)

	results, err := db.ListRecentMessages(SearchOpts{ChannelIDs: []string{"C002"}, Limit: 1})
	require.NoError(t, err)
	require.Len(t, results, 1)
	assert.Equal(t, "C002", results[0].ChannelID)
	// Limit honoured, newest of C002 wins (1700000500 database migration).
	assert.Contains(t, results[0].Text, "migration")
}

func TestListRecentMessagesNoFilterReturnsNothing(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()
	seedSearchMessages(t, db)

	// An unfiltered call must not dump the whole table — the MCP tool relies on
	// this to force at least one narrowing filter.
	results, err := db.ListRecentMessages(SearchOpts{})
	require.NoError(t, err)
	assert.Empty(t, results)
}

func TestSearchMessagesTimeFilter(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()
	seedSearchMessages(t, db)

	// Only the late deployment message
	results, err := db.SearchMessages("deployment", SearchOpts{FromUnix: 1700000900})
	require.NoError(t, err)
	require.Len(t, results, 1)
	assert.Contains(t, results[0].Text, "rollback")
}

func TestSearchMessagesTimeRangeFilter(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()
	seedSearchMessages(t, db)

	// Only early deployment message
	results, err := db.SearchMessages("deployment", SearchOpts{ToUnix: 1700000100})
	require.NoError(t, err)
	require.Len(t, results, 1)
	assert.Contains(t, results[0].Text, "production successful")
}

func TestSearchMessagesCombinedFilters(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()
	seedSearchMessages(t, db)

	results, err := db.SearchMessages("deployment", SearchOpts{
		ChannelIDs: []string{"C001", "C003"},
		UserIDs:    []string{"U001"},
		ToUnix:     1700000100,
	})
	require.NoError(t, err)
	assert.Len(t, results, 1)
	assert.Equal(t, "C001", results[0].ChannelID)
	assert.Equal(t, "U001", results[0].UserID)
}

func TestSearchMessagesEmptyQuery(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	results, err := db.SearchMessages("", SearchOpts{})
	require.NoError(t, err)
	assert.Nil(t, results)
}

func TestSearchMessagesNoResults(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()
	seedSearchMessages(t, db)

	results, err := db.SearchMessages("nonexistenttermxyz", SearchOpts{})
	require.NoError(t, err)
	assert.Empty(t, results)
}

func TestSearchMessagesLimit(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()
	seedSearchMessages(t, db)

	results, err := db.SearchMessages("deploy", SearchOpts{Limit: 1})
	require.NoError(t, err)
	assert.Len(t, results, 1)
}

func TestSearchMessagesMultipleChannelFilter(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()
	seedSearchMessages(t, db)

	results, err := db.SearchMessages("deployment", SearchOpts{ChannelIDs: []string{"C001", "C003"}})
	require.NoError(t, err)
	assert.Len(t, results, 2)
	for _, r := range results {
		assert.Contains(t, []string{"C001", "C003"}, r.ChannelID)
	}
}

func TestSearchMessagesMultiWord(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()
	seedSearchMessages(t, db)

	// Multi-word FTS5 query — matches messages containing both stems
	results, err := db.SearchMessages("production deployment", SearchOpts{})
	require.NoError(t, err)
	assert.GreaterOrEqual(t, len(results), 1)
	for _, r := range results {
		assert.Contains(t, r.Text, "production")
	}
}

func TestSearchMessagesUnicode(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	require.NoError(t, db.UpsertMessage(Message{
		ChannelID: "C001", TS: "1700000001.000001", UserID: "U001",
		Text: "café deployment naïve approach", RawJSON: "{}",
	}))

	results, err := db.SearchMessages("deployment", SearchOpts{})
	require.NoError(t, err)
	assert.Len(t, results, 1)
	assert.Contains(t, results[0].Text, "café")
}

func TestSearchMessagesDefaultLimit(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	// Insert more messages than default limit (50)
	for i := 0; i < 60; i++ {
		ts := fmt.Sprintf("17000%05d.000001", i)
		require.NoError(t, db.UpsertMessage(Message{
			ChannelID: "C001", TS: ts, UserID: "U001",
			Text: "searchable keyword here", RawJSON: "{}",
		}))
	}

	results, err := db.SearchMessages("searchable", SearchOpts{})
	require.NoError(t, err)
	assert.Equal(t, 50, len(results))
}

func TestSearchTranscriptsFindsAndSnippets(t *testing.T) {
	database := openTestDB(t)

	// Insert two transcripts that match the search term, with different created_at timestamps.
	// The newer one should come back first (ordering test).
	olderID, err := database.InsertMeetingTranscript(MeetingTranscript{
		Title:          "Payments sync (older)",
		TranscriptText: "[Я] the decision is to keep tokens in a file, not the keychain",
	})
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE meeting_transcripts SET created_at = ? WHERE id = ?`, "2026-07-01T10:00:00Z", olderID)
	require.NoError(t, err)

	newerID, err := database.InsertMeetingTranscript(MeetingTranscript{
		Title:          "Token storage discussion",
		TranscriptText: "[Я] we decided the keychain approach is unsafe for a daemon",
	})
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE meeting_transcripts SET created_at = ? WHERE id = ?`, "2026-07-10T15:00:00Z", newerID)
	require.NoError(t, err)

	// Insert an unrelated transcript to ensure filtering works.
	_, err = database.InsertMeetingTranscript(MeetingTranscript{
		Title:          "Unrelated",
		TranscriptText: "[Я] discussed hiring",
	})
	require.NoError(t, err)

	// Search for "keychain" — should find both matching transcripts, newest first.
	got, err := database.SearchTranscripts("keychain", 10)
	require.NoError(t, err)
	require.Len(t, got, 2)
	// Verify ordering: newest first (2026-07-10 before 2026-07-01).
	assert.Equal(t, newerID, got[0].ID)
	assert.Equal(t, olderID, got[1].ID)
	// Verify snippets contain the search term.
	assert.Contains(t, got[0].Snippet, "keychain")
	assert.Contains(t, got[1].Snippet, "keychain")
	// Verify event_id path: both have NULL event_id, should resolve to empty string.
	assert.Equal(t, "", got[0].EventID)
	assert.Equal(t, "", got[1].EventID)

	// Empty query is a no-op, not an error — mirrors SearchMessages.
	empty, err := database.SearchTranscripts("", 10)
	require.NoError(t, err)
	assert.Empty(t, empty)

	// FTS5 operators are sanitized away rather than erroring.
	safe, err := database.SearchTranscripts(`keychain OR "`, 10)
	require.NoError(t, err)
	assert.NotEmpty(t, safe)
}
