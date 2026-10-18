package tools

import (
	"database/sql"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedLinearTaskFixture stores a Linear issue that moved from ENG-7 to OPS-3,
// one comment, a Slack thread linked under the OLD key, a meeting naming the
// new key and a decision whose mention cites the old key.
func seedLinearTaskFixture(t *testing.T, d *db.DB) int64 {
	t.Helper()
	acct := db.SeedLinearTestAccount(t, d)
	now := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	db.SeedLinearTestIssue(t, d, db.LinearIssue{
		AccountID: acct, ID: "u1", Key: "OPS-3", PreviousKeys: []string{"ENG-7"}, TeamKey: "OPS",
		Title: "Move billing to the new queue", DescriptionText: "the queue must stay ordered",
		StateName: "In Progress", StatusCategory: "in_progress", Priority: 2,
		AssigneeID: "lu-ann", AssigneeDisplayName: "Ann", CreatorID: "lu-bob", CreatorDisplayName: "Bob",
		CreatedAt: now, UpdatedAt: now,
	}, "U0ANN", "U0BOB")
	require.NoError(t, d.UpsertLinearComment(db.LinearComment{
		AccountID: acct, ID: "c1", IssueID: "u1", IssueKey: "OPS-3", AuthorID: "lu-cat", AuthorDisplayName: "Cat",
		BodyText: "watch the retry storm", CreatedAt: now, UpdatedAt: now,
	}))
	require.NoError(t, d.EnsureChannel("C010", "eng-billing", "public", ""))
	require.NoError(t, d.UpsertMessage(db.Message{ChannelID: "C010", TS: "1690000000.000100", UserID: "U0DAN", Text: "is ENG-7 safe to ship?"}))
	require.NoError(t, d.UpsertMessage(db.Message{ChannelID: "C010", TS: "1690000000.000200", UserID: "U0ANN", Text: "only behind the flag",
		ThreadTS: sql.NullString{String: "1690000000.000100", Valid: true}}))
	require.NoError(t, d.UpsertIssueSlackLink(db.IssueSlackLink{Tracker: "linear", IssueKey: "ENG-7", ChannelID: "C010", MessageTS: "1690000000.000100", LinkType: "mention"}))
	_, err := d.InsertMeetingTranscript(db.MeetingTranscript{Title: "Billing sync", TranscriptText: "OPS-3 ships next week behind the flag."})
	require.NoError(t, err)

	tx, err := d.Begin()
	require.NoError(t, err)
	ideaID, err := d.CreateIdeaTx(tx, db.Idea{Kind: "decision", Title: "Billing ships behind a flag", Essence: "e", Status: "active", Source: "mined"})
	require.NoError(t, err)
	require.NoError(t, d.InsertIdeaMentionTx(tx, db.IdeaMention{IdeaID: ideaID, Source: "linear", Ref: "ENG-7", Quote: "q", SaidAt: now}))
	require.NoError(t, tx.Commit())
	return acct
}

// get_task_context resolves a Linear key — current or previous — into the
// same dossier shape as a Jira one.
func TestGetTaskContext_LinearIssueByCurrentOrPreviousKey(t *testing.T) {
	d := openDB(t)
	seedLinearTaskFixture(t, d)
	for _, key := range []string{"OPS-3", "ENG-7"} {
		got := taskContextDossier(t, d, key)
		assert.Equal(t, "OPS-3", got.Issue.Key, key)
		assert.Equal(t, "Move billing to the new queue", got.Issue.Summary)
		assert.Equal(t, "In Progress", got.Issue.Status)
		assert.Equal(t, "High", got.Issue.Priority)
		assert.Equal(t, "Ann", got.Issue.Assignee)
		assert.Equal(t, "Bob", got.Issue.Reporter)
		require.Len(t, got.Comments, 1)
		assert.Equal(t, "watch the retry storm", got.Comments[0].Body)
		require.Len(t, got.Threads, 1, "the thread linked under the old key is found")
		assert.Len(t, got.Threads[0].Messages, 2)
		require.Len(t, got.Meetings, 1)
		require.Len(t, got.Decisions, 1, "the mention citing the old key is found")
		assert.Equal(t, "Billing ships behind a flag", got.Decisions[0].Title)
		assert.Subset(t, got.People, []string{"Ann", "Bob", "Cat"})
		assert.Empty(t, got.Notes)
	}
}

// A key both trackers carry resolves to the Jira issue: Jira behaviour is
// unchanged.
func TestGetTaskContext_JiraWinsAKeyBothTrackersCarry(t *testing.T) {
	d := openDB(t)
	seedTaskContextFixture(t, d) // Jira PROJ-1
	acct := db.SeedLinearTestAccount(t, d)
	db.SeedLinearTestIssue(t, d, db.LinearIssue{AccountID: acct, ID: "x", Key: "PROJ-1", Title: "Linear twin", UpdatedAt: "2026-01-01T00:00:00.000Z"}, "", "")
	got := taskContextDossier(t, d, "PROJ-1")
	assert.Equal(t, "Rewrite the payment flow", got.Issue.Summary)
}
