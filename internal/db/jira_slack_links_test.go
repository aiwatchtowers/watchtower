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

// A link kind with no identity matches no partial index, so every write would
// insert. An empty link_type is what a caller gets by forgetting a field.
func TestUpsertJiraSlackLink_EmptyLinkTypeIsStoredAndDedupedAsMention(t *testing.T) {
	database := openTestDB(t)

	link := JiraSlackLink{IssueKey: "PROJ-5", ChannelID: "1:C1", MessageTS: "1000.001"}
	require.NoError(t, database.UpsertJiraSlackLink(link))
	require.NoError(t, database.UpsertJiraSlackLink(link))

	links, err := database.GetJiraSlackLinksByIssue("PROJ-5")
	require.NoError(t, err)
	require.Len(t, links, 1, "a link with no kind must still dedupe, not grow the table")
	assert.Equal(t, "mention", links[0].LinkType)
}

func TestUpsertJiraSlackLink_UnknownLinkTypeIsRefused(t *testing.T) {
	database := openTestDB(t)

	err := database.UpsertJiraSlackLink(JiraSlackLink{
		IssueKey: "PROJ-6", ChannelID: "1:C1", MessageTS: "1000.001", LinkType: "sighting",
	})
	require.Error(t, err)
	assert.Contains(t, err.Error(), `unknown link_type "sighting"`)

	links, err := database.GetJiraSlackLinksByIssue("PROJ-6")
	require.NoError(t, err)
	assert.Empty(t, links, "a refused link must write nothing")
}

// The new per-kind indexes are narrower on some axes than the constraint they
// replace, so a pair that was legal before can be illegal after. The migration
// must dedupe such a pair rather than abort — an aborted migration means goose
// fails, db.Open errors, and neither the daemon nor the Desktop starts.
func TestMigration00067_DedupesLegacyRowsTheNewIndexesCannotHold(t *testing.T) {
	path := filepath.Join(t.TempDir(), "jira-slack-link-legacy.db")
	d, err := Open(path)
	require.NoError(t, err)
	defer d.Close()

	require.NoError(t, goose.DownTo(d.DB, "migrations", 66))

	// PROJ-1: two rows legal under UNIQUE(issue_key, channel_id, message_ts) but
	// illegal under the track identity — what the old upsert could write, since
	// ProcessTrack takes channel_id from the first entry of the track's
	// channel_ids JSON, which can reorder between runs. The copy must dedupe.
	_, err = d.Exec(`INSERT INTO jira_slack_links (issue_key, channel_id, message_ts, track_id, link_type)
		VALUES ('PROJ-1', '1:C1', '', 5, 'track'), ('PROJ-1', '1:C2', '', 5, 'track')`)
	require.NoError(t, err)

	// PROJ-2 / PROJ-3: a kind's id is NULL, which the unique indexes treat as
	// distinct — so both rows are legal after the migration and the copy must
	// keep both. GROUP BY treats NULLs as equal, so the discriminator has to
	// fall back to the row id; a bare CAST would drop the older row silently.
	_, err = d.Exec(`INSERT INTO jira_slack_links (issue_key, channel_id, message_ts, track_id, link_type)
		VALUES ('PROJ-2', '1:C1', '', NULL, 'track'), ('PROJ-2', '1:C2', '', NULL, 'track')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO jira_slack_links (issue_key, channel_id, message_ts, digest_id, link_type)
		VALUES ('PROJ-3', '1:C1', '', NULL, 'decision'), ('PROJ-3', '1:C2', '', NULL, 'decision')`)
	require.NoError(t, err)

	// PROJ-4: two distinct mentions whose channel_id and message_ts concatenate
	// to the same string. Unreachable with real Slack ids, but it is what the
	// separator in the mention discriminator is there for.
	_, err = d.Exec(`INSERT INTO jira_slack_links (issue_key, channel_id, message_ts, link_type)
		VALUES ('PROJ-4', '1:C1', '12', 'mention'), ('PROJ-4', '1:C11', '2', 'mention')`)
	require.NoError(t, err)

	require.NoError(t, goose.Up(d.DB, "migrations"), "the migration must survive legacy rows")

	links, err := d.GetJiraSlackLinksByIssue("PROJ-1")
	require.NoError(t, err)
	require.Len(t, links, 1, "the copy keeps one row per kind identity")
	assert.Equal(t, "1:C2", links[0].ChannelID, "the newest row wins")

	for _, issueKey := range []string{"PROJ-2", "PROJ-3", "PROJ-4"} {
		links, err := d.GetJiraSlackLinksByIssue(issueKey)
		require.NoError(t, err)
		assert.Len(t, links, 2, "%s: the copy must not drop a row the new indexes accept", issueKey)
	}
}

// UpsertJiraSlackLinkBatch is the message-sync path's writer: same per-link
// semantics as UpsertJiraSlackLink, one commit for the whole page. It must
// route each kind to its own conflict target — a batch that prepared one
// statement for everything would silently give the other two kinds no dedup.
func TestUpsertJiraSlackLinkBatch_RoutesEachKindToItsOwnIdentity(t *testing.T) {
	database := openTestDB(t)

	trackID, digestID := 7, 9
	links := []JiraSlackLink{
		{IssueKey: "PROJ-1", ChannelID: "1:C1", MessageTS: "1000.001", LinkType: "mention"},
		{IssueKey: "PROJ-1", ChannelID: "1:C1", MessageTS: "1000.002", LinkType: "mention"},
		// Each kind's second entry differs only outside that kind's own
		// identity, so it must merge into the first — which it can only do if
		// the batch routed it to its own conflict target.
		{IssueKey: "PROJ-1", ChannelID: "1:C1", TrackID: &trackID, LinkType: "track"},
		{IssueKey: "PROJ-1", ChannelID: "1:C2", TrackID: &trackID, LinkType: "track"},
		{IssueKey: "PROJ-1", ChannelID: "1:C1", DigestID: &digestID, LinkType: "decision"},
		{IssueKey: "PROJ-1", ChannelID: "1:C2", DigestID: &digestID, LinkType: "decision"},
	}

	tx, err := database.Begin()
	require.NoError(t, err)
	require.NoError(t, database.UpsertJiraSlackLinkBatch(tx, links))
	require.NoError(t, tx.Commit())

	stored, err := database.GetJiraSlackLinksByIssue("PROJ-1")
	require.NoError(t, err)

	kinds := map[string]int{}
	for _, l := range stored {
		kinds[l.LinkType]++
	}
	assert.Equal(t, map[string]int{"mention": 2, "track": 1, "decision": 1}, kinds,
		"each kind must conflict on its own identity inside one batch")
}

// Re-syncing a page re-processes its messages, so a repeated batch must dedupe
// exactly as the single-link writer does.
func TestUpsertJiraSlackLinkBatch_IsIdempotent(t *testing.T) {
	database := openTestDB(t)

	links := []JiraSlackLink{
		{IssueKey: "PROJ-1", ChannelID: "1:C1", MessageTS: "1000.001", LinkType: "mention"},
	}
	for range 2 {
		tx, err := database.Begin()
		require.NoError(t, err)
		require.NoError(t, database.UpsertJiraSlackLinkBatch(tx, links))
		require.NoError(t, tx.Commit())
	}

	stored, err := database.GetJiraSlackLinksByIssue("PROJ-1")
	require.NoError(t, err)
	assert.Len(t, stored, 1)
}

// The batch shares the single writer's refusal of an unknown kind (such a row
// matches no partial index and would never dedupe), and it refuses the batch
// WHOLE: the links ahead of the bad one must not already be in the caller's
// transaction.
//
// The transaction is deliberately COMMITTED after the error rather than rolled
// back. A rollback here would pin the test's own cleanup instead of the
// function — the version of this test that rolled back passed even when the
// batch wrote the first link before refusing the second.
func TestUpsertJiraSlackLinkBatch_UnknownLinkTypeIsRefusedWholeBatch(t *testing.T) {
	database := openTestDB(t)

	tx, err := database.Begin()
	require.NoError(t, err)
	err = database.UpsertJiraSlackLinkBatch(tx, []JiraSlackLink{
		{IssueKey: "PROJ-1", ChannelID: "1:C1", MessageTS: "1000.001", LinkType: "mention"},
		{IssueKey: "PROJ-2", ChannelID: "1:C1", MessageTS: "1000.002", LinkType: "sighting"},
	})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "sighting")
	require.NoError(t, tx.Commit())

	stored, err := database.GetJiraSlackLinksByIssue("PROJ-1")
	require.NoError(t, err)
	assert.Empty(t, stored, "the link ahead of the refused one must not have been written")
}

func TestUpsertJiraSlackLinkBatch_NilTransactionIsRefused(t *testing.T) {
	database := openTestDB(t)
	assert.Error(t, database.UpsertJiraSlackLinkBatch(nil, []JiraSlackLink{
		{IssueKey: "PROJ-1", ChannelID: "1:C1", MessageTS: "1000.001", LinkType: "mention"},
	}))
}
