package jira

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// A Linear link (issue_slack_links, tracker linear) is not a Jira link: a
// channel discussing only a Linear issue is still "without Jira".
func TestWithoutJira_LinearLinkDoesNotExcludeTheChannel(t *testing.T) {
	d := withoutJiraTestDB(t)
	seedChannel(t, d, "C1", "general")
	base := time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC)
	for i := range 4 {
		day := base.AddDate(0, 0, i)
		seedDigest(t, d, "C1", float64(day.Unix()), 5, day.Format(time.RFC3339))
	}
	_, err := d.Exec(`INSERT INTO issue_slack_links (tracker, issue_key, channel_id, message_ts, link_type, detected_at)
		VALUES ('linear', 'ENG-1', 'C1', '1.1', 'mention', ?)`, base.AddDate(0, 0, 1).Format(time.RFC3339))
	require.NoError(t, err)

	result, err := DetectWithoutJira(d, withoutJiraConfig(true), base.AddDate(0, 0, -1))
	require.NoError(t, err)
	require.Len(t, result, 1)
	assert.Equal(t, "C1", result[0].ChannelID)
}

// Who-to-ping's Slack participants come from the Jira issue's own links only:
// a Linear link on the same key adds nobody.
func TestFetchSlackParticipants_IgnoresLinearLinks(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertMessage(db.Message{ChannelID: "C1", TS: "1.1", UserID: "U-JIRA", Text: "ABC-1?"}))
	require.NoError(t, d.UpsertMessage(db.Message{ChannelID: "C1", TS: "1.2", UserID: "U-LINEAR", Text: "ABC-1?"}))
	require.NoError(t, d.UpsertIssueSlackLink(db.IssueSlackLink{Tracker: "jira", IssueKey: "ABC-1", ChannelID: "C1", MessageTS: "1.1"}))
	require.NoError(t, d.UpsertIssueSlackLink(db.IssueSlackLink{Tracker: "linear", IssueKey: "ABC-1", ChannelID: "C1", MessageTS: "1.2"}))

	got := fetchSlackParticipants("ABC-1", d)
	require.Len(t, got, 1)
	assert.Equal(t, "U-JIRA", got[0].SlackUserID)
}
