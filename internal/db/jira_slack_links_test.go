package db

import (
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The three link kinds are written with three different natural identities
// (migration 00067). Before that, all three shared UNIQUE(issue_key,
// channel_id, message_ts) while only a mention carried a real message_ts, so a
// track link, a decision link and every later track for the same issue key and
// channel all landed on one row, each write discarding the previous one.

func TestUpsertJiraSlackLink_TracksForSameKeyAndChannelCoexist(t *testing.T) {
	database := openTestDB(t)
	SeedTestJiraAccount(t, database)
	require.NoError(t, database.UpsertJiraIssue(JiraIssue{
		AccountID: 1, Key: "PROJ-1", ProjectKey: "PROJ", Summary: "S",
		Status: "Open", StatusCategory: "todo",
		CreatedAt: "2026-09-01T00:00:00Z", UpdatedAt: "2026-09-01T00:00:00Z", SyncedAt: "2026-09-01T00:00:00Z",
	}))

	first, second := 41, 42
	require.NoError(t, database.UpsertJiraSlackLink(JiraSlackLink{
		IssueKey: "PROJ-1", ChannelID: "1:C1", TrackID: &first, LinkType: "track",
	}))
	require.NoError(t, database.UpsertJiraSlackLink(JiraSlackLink{
		IssueKey: "PROJ-1", ChannelID: "1:C1", TrackID: &second, LinkType: "track",
	}))

	links, err := database.GetJiraSlackLinksByIssue("PROJ-1")
	require.NoError(t, err)
	require.Len(t, links, 2, "a second track must not overwrite the first track's link")

	tracks := map[int]bool{}
	for _, l := range links {
		require.NotNil(t, l.TrackID)
		tracks[*l.TrackID] = true
	}
	assert.Equal(t, map[int]bool{41: true, 42: true}, tracks)

	// Both tracks resolve back to the issue through the reader the Desktop
	// "Linked Jira Issues" list uses.
	for _, trackID := range []int{41, 42} {
		issues, err := database.GetJiraIssuesForTrack(trackID)
		require.NoError(t, err)
		require.Len(t, issues, 1, "track %d lost its Jira link", trackID)
		assert.Equal(t, "PROJ-1", issues[0].Key)
	}
}

func TestUpsertJiraSlackLink_TrackAndDecisionCoexist(t *testing.T) {
	database := openTestDB(t)

	trackID, digestID := 7, 9
	require.NoError(t, database.UpsertJiraSlackLink(JiraSlackLink{
		IssueKey: "PROJ-2", ChannelID: "1:C1", TrackID: &trackID, LinkType: "track",
	}))
	require.NoError(t, database.UpsertJiraSlackLink(JiraSlackLink{
		IssueKey: "PROJ-2", ChannelID: "1:C1", DigestID: &digestID, LinkType: "decision",
	}))

	links, err := database.GetJiraSlackLinksByIssue("PROJ-2")
	require.NoError(t, err)
	require.Len(t, links, 2, "a decision link and a track link are two different links")

	kinds := map[string]bool{}
	for _, l := range links {
		kinds[l.LinkType] = true
	}
	assert.Equal(t, map[string]bool{"track": true, "decision": true}, kinds,
		"link_type must not flip-flop between the two kinds")
}

func TestUpsertJiraSlackLink_RollupDecisionsKeepTheirDigest(t *testing.T) {
	database := openTestDB(t)

	// Daily/weekly rollups store decisions with an empty channel_id, so under a
	// shared identity every rollup in the workspace collapsed onto one row.
	daily, weekly := 100, 200
	require.NoError(t, database.UpsertJiraSlackLink(JiraSlackLink{
		IssueKey: "PROJ-3", DigestID: &daily, LinkType: "decision",
	}))
	require.NoError(t, database.UpsertJiraSlackLink(JiraSlackLink{
		IssueKey: "PROJ-3", DigestID: &weekly, LinkType: "decision",
	}))

	links, err := database.GetJiraSlackLinksByIssue("PROJ-3")
	require.NoError(t, err)
	require.Len(t, links, 2, "a rollup decision must not clobber another rollup's link")

	digests := map[int]bool{}
	for _, l := range links {
		require.NotNil(t, l.DigestID)
		digests[*l.DigestID] = true
	}
	assert.Equal(t, map[int]bool{100: true, 200: true}, digests)
}

func TestUpsertJiraSlackLink_MentionStaysIdempotent(t *testing.T) {
	database := openTestDB(t)

	mention := JiraSlackLink{
		IssueKey: "PROJ-4", ChannelID: "1:C1", MessageTS: "1000.001", LinkType: "mention",
	}
	require.NoError(t, database.UpsertJiraSlackLink(mention))
	require.NoError(t, database.UpsertJiraSlackLink(mention))

	links, err := database.GetJiraSlackLinksByIssue("PROJ-4")
	require.NoError(t, err)
	assert.Len(t, links, 1, "re-detecting the same message must not add a second link")
}

func TestMigration00067DownUpCycle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "jira-slack-link-identity-cycle.db")
	d, err := Open(path)
	require.NoError(t, err)
	defer d.Close()

	first, second := 41, 42
	require.NoError(t, d.UpsertJiraSlackLink(JiraSlackLink{
		IssueKey: "PROJ-1", ChannelID: "1:C1", TrackID: &first, LinkType: "track",
	}))
	require.NoError(t, d.UpsertJiraSlackLink(JiraSlackLink{
		IssueKey: "PROJ-1", ChannelID: "1:C1", TrackID: &second, LinkType: "track",
	}))

	require.NoError(t, goose.DownTo(d.DB, "migrations", 66))

	// The legacy shared identity is back: the two track rows differ only in
	// track_id, so the Down keeps one of them and a third write is refused.
	var count int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM jira_slack_links`).Scan(&count))
	assert.Equal(t, 1, count, "Down collapses the rows the old UNIQUE could not hold")

	_, err = d.Exec(`INSERT INTO jira_slack_links (issue_key, channel_id, message_ts, track_id, link_type)
		VALUES ('PROJ-1', '1:C1', '', 43, 'track')`)
	assert.Error(t, err, "the shared UNIQUE(issue_key, channel_id, message_ts) must be restored")

	require.NoError(t, goose.Up(d.DB, "migrations"))

	third := 43
	require.NoError(t, d.UpsertJiraSlackLink(JiraSlackLink{
		IssueKey: "PROJ-1", ChannelID: "1:C1", TrackID: &third, LinkType: "track",
	}))
	links, err := d.GetJiraSlackLinksByIssue("PROJ-1")
	require.NoError(t, err)
	assert.Len(t, links, 2, "re-applying 00067 restores the per-kind identity")
}
