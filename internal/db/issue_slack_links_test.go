package db

import (
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Migration 00144 moves every jira_slack_links row into issue_slack_links as a
// Jira link, keeping its id, and the Down moves the Jira links back.
func TestMigration00144_CopiesJiraLinksAndDownUp(t *testing.T) {
	t.Parallel()
	d, err := Open(filepath.Join(t.TempDir(), "issue-slack-links.db"))
	require.NoError(t, err)
	defer d.Close()

	require.NoError(t, goose.DownTo(d.DB, "migrations", 143))
	_, err = d.Exec(`INSERT INTO jira_slack_links (id, issue_key, channel_id, message_ts, link_type)
		VALUES (7, 'PROJ-1', '1:C1', '1.1', 'mention'), (9, 'PROJ-2', '', '', 'track')`)
	require.NoError(t, err)
	require.NoError(t, goose.Up(d.DB, "migrations"))

	links, err := d.GetIssueSlackLinksByKeys("jira", []string{"PROJ-1", "PROJ-2"})
	require.NoError(t, err)
	require.Len(t, links, 2)
	ids := map[int]string{}
	for _, l := range links {
		assert.Equal(t, "jira", l.Tracker)
		ids[l.ID] = l.IssueKey
	}
	assert.Equal(t, map[int]string{7: "PROJ-1", 9: "PROJ-2"}, ids, "ids survive the copy")

	// A new row never reuses an id at or below the copied high-water mark.
	require.NoError(t, d.UpsertIssueSlackLink(IssueSlackLink{Tracker: "linear", IssueKey: "ENG-1", ChannelID: "1:C1", MessageTS: "1.2"}))
	var maxID int
	require.NoError(t, d.QueryRow(`SELECT MAX(id) FROM issue_slack_links`).Scan(&maxID))
	assert.Greater(t, maxID, 9)

	// Down keeps the Jira links and drops the Linear one; Up restores them.
	require.NoError(t, goose.DownTo(d.DB, "migrations", 143))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM jira_slack_links`).Scan(&n))
	assert.Equal(t, 2, n)
	require.NoError(t, goose.Up(d.DB, "migrations"))
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM issue_slack_links WHERE tracker = 'jira'`).Scan(&n))
	assert.Equal(t, 2, n)
}

// The same key and message linked to both trackers are two links; each
// tracker's own identity still dedupes.
func TestUpsertIssueSlackLink_IdentityIsPerTracker(t *testing.T) {
	d := openTestDB(t)
	for range 2 {
		for _, tracker := range []string{"jira", "linear"} {
			require.NoError(t, d.UpsertIssueSlackLink(IssueSlackLink{
				Tracker: tracker, IssueKey: "ABC-1", ChannelID: "1:C1", MessageTS: "1.1", LinkType: "mention",
			}))
		}
	}
	jira, err := d.GetJiraSlackLinksByIssue("ABC-1")
	require.NoError(t, err)
	require.Len(t, jira, 1, "Jira readers see only the Jira link")
	assert.Equal(t, "jira", jira[0].Tracker)

	linear, err := d.GetIssueSlackLinksByKeys("linear", []string{"ABC-1"})
	require.NoError(t, err)
	require.Len(t, linear, 1)
	assert.Equal(t, "linear", linear[0].Tracker)
}

func TestUpsertIssueSlackLink_RefusesUnknownTracker(t *testing.T) {
	d := openTestDB(t)
	err := d.UpsertIssueSlackLink(IssueSlackLink{Tracker: "asana", IssueKey: "X-1"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "unknown tracker")
}

// An empty tracker is a Jira link (the column default), so pre-Linear callers
// keep writing what they always wrote.
func TestUpsertIssueSlackLink_EmptyTrackerIsJira(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertIssueSlackLink(IssueSlackLink{IssueKey: "PROJ-9", ChannelID: "1:C1", MessageTS: "1.1"}))
	links, err := d.GetJiraSlackLinksByIssue("PROJ-9")
	require.NoError(t, err)
	require.Len(t, links, 1)
	assert.Equal(t, "jira", links[0].Tracker)
}

// GetIssueSlackLinksByKeys matches any of the keys (a moved Linear issue's
// previous keys included) and only the named tracker.
func TestGetIssueSlackLinksByKeys_AnyKeyOneTracker(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertIssueSlackLink(IssueSlackLink{Tracker: "linear", IssueKey: "ENG-12", ChannelID: "1:C1", MessageTS: "1.1"}))
	require.NoError(t, d.UpsertIssueSlackLink(IssueSlackLink{Tracker: "linear", IssueKey: "OPS-40", ChannelID: "1:C1", MessageTS: "1.2"}))
	require.NoError(t, d.UpsertIssueSlackLink(IssueSlackLink{Tracker: "jira", IssueKey: "ENG-12", ChannelID: "1:C1", MessageTS: "1.3"}))

	links, err := d.GetIssueSlackLinksByKeys("linear", []string{"OPS-40", "ENG-12"})
	require.NoError(t, err)
	assert.Len(t, links, 2)
	for _, l := range links {
		assert.Equal(t, "linear", l.Tracker)
	}
	none, err := d.GetIssueSlackLinksByKeys("linear", nil)
	require.NoError(t, err)
	assert.Empty(t, none)
}

// The Jira-only readers (track and digest issue lists, decision counts) never
// pick up a Linear link that shares a key with a Jira issue.
func TestJiraLinkReaders_IgnoreLinearLinks(t *testing.T) {
	d := openTestDB(t)
	SeedTestJiraAccount(t, d)
	require.NoError(t, d.UpsertJiraIssue(JiraIssue{
		AccountID: 1, Key: "ABC-1", ProjectKey: "ABC", Summary: "S", Status: "Open", StatusCategory: "todo",
		CreatedAt: "2026-09-01T00:00:00Z", UpdatedAt: "2026-09-01T00:00:00Z", SyncedAt: "2026-09-01T00:00:00Z",
	}))
	track, digest := 3, 4
	require.NoError(t, d.UpsertIssueSlackLink(IssueSlackLink{Tracker: "linear", IssueKey: "ABC-1", TrackID: &track, LinkType: "track"}))
	require.NoError(t, d.UpsertIssueSlackLink(IssueSlackLink{Tracker: "linear", IssueKey: "ABC-1", DigestID: &digest, LinkType: "decision"}))

	byTrack, err := d.GetJiraIssuesForTrack(track)
	require.NoError(t, err)
	assert.Empty(t, byTrack)
	byTracks, err := d.GetJiraIssuesForTracks([]int{track})
	require.NoError(t, err)
	assert.Empty(t, byTracks)
	byDigest, err := d.GetJiraIssuesForDigest(digest)
	require.NoError(t, err)
	assert.Empty(t, byDigest)
	n, err := d.GetJiraDecisionCountByIssueKeys([]string{"ABC-1"})
	require.NoError(t, err)
	assert.Zero(t, n)
	trackLinks, err := d.GetJiraSlackLinksByTrackID(track)
	require.NoError(t, err)
	assert.Empty(t, trackLinks)
}

// A track linked to only a Linear issue counts as "has a ticket".
func TestTrackFilterHasJira_CountsLinearLinks(t *testing.T) {
	d := openTestDB(t)
	id, err := d.UpsertTrack(Track{Text: "t", ChannelIDs: `[]`})
	require.NoError(t, err)
	tid := int(id)
	require.NoError(t, d.UpsertIssueSlackLink(IssueSlackLink{Tracker: "linear", IssueKey: "ENG-1", TrackID: &tid, LinkType: "track"}))

	yes := true
	got, err := d.GetTracks(TrackFilter{HasJira: &yes})
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, tid, got[0].ID)
}
