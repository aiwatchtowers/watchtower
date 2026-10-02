package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func changelogTestIssue(t *testing.T, d *DB, key, id, boardStatusCat, updated string, deleted bool) {
	t.Helper()
	require.NoError(t, d.UpsertJiraIssue(JiraIssue{
		AccountID: 1, Key: key, ID: id, ProjectKey: "PROJ", BoardID: 7, Summary: "S " + key,
		Status: "In Progress", StatusCategory: boardStatusCat, Labels: `[]`, Components: `[]`,
		CreatedAt: updated, UpdatedAt: updated, SyncedAt: updated, IsDeleted: deleted,
	}))
}

func TestReplaceJiraIssueChangelog_ReplacesWholeHistoryAndStampsCursor(t *testing.T) {
	d := openTestDB(t)
	SeedTestJiraAccount(t, d)
	now := time.Now().UTC()
	t1, t2 := FormatJiraTime(now.Add(-2*time.Hour)), FormatJiraTime(now.Add(-time.Hour))

	replaceHistory(t, d, "PROJ-1", t1, []JiraChangelogItem{
		{HistoryID: "1", Field: "status", FromString: "To Do", ToString: "In Progress", ChangedAt: t1},
		{HistoryID: "2", Field: "assignee", ToValue: "acc-a", ToString: "A", ChangedAt: t1},
	})
	replaceHistory(t, d, "PROJ-1", t2, []JiraChangelogItem{
		{HistoryID: "3", Field: "status", FromString: "In Progress", ToString: "Done", ChangedAt: t2},
	})

	got, err := d.ListJiraIssueChangelog(1, []string{"PROJ-1"})
	require.NoError(t, err)
	require.Len(t, got["PROJ-1"], 1, "the second write replaces the first history entirely")
	assert.Equal(t, "Done", got["PROJ-1"][0].ToString)

	var cursor string
	require.NoError(t, d.QueryRow(`SELECT issue_updated_at FROM jira_changelog_sync WHERE account_id = 1 AND issue_key = 'PROJ-1'`).Scan(&cursor))
	assert.Equal(t, t2, cursor)
}

func TestListJiraChangelogDue(t *testing.T) {
	d := openTestDB(t)
	SeedTestJiraAccount(t, d)
	now := time.Now().UTC()
	old, fresh := FormatJiraTime(now.Add(-48*time.Hour)), FormatJiraTime(now.Add(-time.Hour))

	changelogTestIssue(t, d, "PROJ-1", "101", "in_progress", old, false)   // never fetched
	changelogTestIssue(t, d, "PROJ-2", "102", "in_progress", fresh, false) // stale cursor
	changelogTestIssue(t, d, "PROJ-3", "103", "in_progress", old, false)   // up to date
	changelogTestIssue(t, d, "PROJ-4", "104", "in_progress", fresh, true)  // deleted
	replaceHistory(t, d, "PROJ-2", old, nil)
	replaceHistory(t, d, "PROJ-3", old, nil)
	require.NoError(t, d.UpsertJiraLinkedIssues([]JiraLinkedIssue{
		{AccountID: 1, Key: "OTH-1", ID: "201", UpdatedAt: old, SyncedAt: fresh},
		{AccountID: 1, Key: "OTH-2", FetchError: "no access", SyncedAt: fresh},
	}))

	due, err := d.ListJiraChangelogDue(1, 10)
	require.NoError(t, err)
	var keys []string
	for _, x := range due {
		keys = append(keys, x.Key)
	}
	assert.Equal(t, []string{"PROJ-2", "OTH-1", "PROJ-1"}, keys, "newest first; deleted, current and failed rows excluded")

	capped, err := d.ListJiraChangelogDue(1, 1)
	require.NoError(t, err)
	require.Len(t, capped, 1)
	assert.Equal(t, "PROJ-2", capped[0].Key)
}

func TestJiraLinkedCandidatesAndPrune(t *testing.T) {
	d := openTestDB(t)
	SeedTestJiraAccount(t, d)
	now := time.Now().UTC()
	ts := FormatJiraTime(now)
	changelogTestIssue(t, d, "PROJ-1", "101", "in_progress", ts, false)
	changelogTestIssue(t, d, "PROJ-2", "102", "in_progress", ts, false)
	for i, target := range []string{"PROJ-2", "OTH-1", "OTH-2", "OTH-3"} {
		require.NoError(t, d.UpsertJiraIssueLink(JiraIssueLink{
			AccountID: 1, ID: string(rune('a' + i)), SourceKey: "PROJ-1", TargetKey: target, LinkType: "Blocks", SyncedAt: ts,
		}))
	}
	require.NoError(t, d.UpsertJiraLinkedIssues([]JiraLinkedIssue{
		{AccountID: 1, Key: "OTH-1", ID: "201", SyncedAt: FormatJiraTime(now.Add(-time.Hour))},
		{AccountID: 1, Key: "OTH-2", ID: "202", SyncedAt: FormatJiraTime(now.Add(-2 * time.Hour))},
		{AccountID: 1, Key: "PROJ-2", ID: "102", SyncedAt: ts}, // now a board issue
		{AccountID: 1, Key: "GONE-1", ID: "301", SyncedAt: ts}, // no link points here
	}))
	replaceHistory(t, d, "GONE-1", ts, []JiraChangelogItem{{HistoryID: "9", Field: "status", ChangedAt: ts}})
	replaceHistory(t, d, "PROJ-2", ts, []JiraChangelogItem{{HistoryID: "8", Field: "status", ChangedAt: ts}})

	cands, err := d.ListJiraLinkedCandidates(1, 10)
	require.NoError(t, err)
	assert.Equal(t, []string{"OTH-3", "OTH-2", "OTH-1"}, cands, "never fetched first, then the oldest refresh; board issues never")

	n, err := d.PruneJiraLinkedIssues(1)
	require.NoError(t, err)
	assert.EqualValues(t, 2, n)

	assert.Equal(t, []string{"OTH-1", "OTH-2"}, queryKeys(t, d, `SELECT key FROM jira_linked_issues ORDER BY key`))
	var cursors int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM jira_changelog_sync WHERE issue_key = 'GONE-1'`).Scan(&cursors))
	assert.Zero(t, cursors, "an unlinked issue's cursor goes with it")
	cl, err := d.ListJiraIssueChangelog(1, []string{"GONE-1", "PROJ-2"})
	require.NoError(t, err)
	assert.Empty(t, cl["GONE-1"], "an unlinked issue's history goes with it")
	assert.Len(t, cl["PROJ-2"], 1, "a key that became a board issue keeps its history")
}

func TestListJiraHistoryIssues_FiltersAndLinkedExpansion(t *testing.T) {
	d := openTestDB(t)
	SeedTestJiraAccount(t, d)
	now := time.Now().UTC()
	recent, old := FormatJiraTime(now.Add(-time.Hour)), FormatJiraTime(now.Add(-90*24*time.Hour))
	changelogTestIssue(t, d, "PROJ-1", "101", "in_progress", recent, false)
	changelogTestIssue(t, d, "PROJ-2", "102", "done", old, false) // done long ago
	require.NoError(t, d.UpsertJiraIssueLink(JiraIssueLink{AccountID: 1, ID: "l1", SourceKey: "PROJ-1", TargetKey: "OTH-1", LinkType: "Blocks", SyncedAt: recent}))
	require.NoError(t, d.UpsertJiraLinkedIssues([]JiraLinkedIssue{
		{AccountID: 1, Key: "OTH-1", ID: "201", Status: "Review", StatusCategory: "in_progress", UpdatedAt: recent, SyncedAt: recent},
	}))
	replaceHistory(t, d, "PROJ-1", recent, nil)

	got, err := d.ListJiraHistoryIssues(JiraHistoryFilter{BoardID: 7, IncludeLinked: true, ActiveSince: FormatJiraTime(now.Add(-30 * 24 * time.Hour))})
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Equal(t, "PROJ-1", got[0].Key)
	assert.Equal(t, recent, got[0].ChangelogUpdatedAt)
	assert.Equal(t, "OTH-1", got[1].Key)
	assert.Equal(t, "linked", got[1].Source)
	assert.Equal(t, "", got[1].ChangelogUpdatedAt)

	byKey, err := d.ListJiraHistoryIssues(JiraHistoryFilter{Keys: []string{"OTH-1", "PROJ-2"}})
	require.NoError(t, err)
	assert.Len(t, byKey, 2, "explicit keys match linked issues too, and ignore ActiveSince when unset")

	cats, err := d.JiraStatusCategories()
	require.NoError(t, err)
	assert.Equal(t, "in_progress", cats["Review"])
}

func replaceHistory(t *testing.T, d *DB, key, updatedAt string, items []JiraChangelogItem) {
	t.Helper()
	require.NoError(t, d.ReplaceJiraIssueChangelogs(1, []JiraIssueHistory{{Key: key, UpdatedAt: updatedAt, Items: items}}))
}

func TestJiraChangelog_AccountsStayApart(t *testing.T) {
	d := openTestDB(t)
	SeedTestJiraAccount(t, d)
	_, err := d.Exec(`INSERT INTO jira_accounts (id, cloud_id) VALUES (2, 'c2')`)
	require.NoError(t, err)
	now := time.Now().UTC()
	ts := FormatJiraTime(now)
	for _, acct := range []int64{1, 2} {
		require.NoError(t, d.UpsertJiraIssue(JiraIssue{
			AccountID: acct, Key: "PROJ-1", ID: "101", ProjectKey: "PROJ", BoardID: 7, Summary: "S",
			Status: "In Progress", StatusCategory: "in_progress", Labels: `[]`, Components: `[]`,
			CreatedAt: ts, UpdatedAt: ts, SyncedAt: ts,
		}))
		require.NoError(t, d.UpsertJiraIssueLink(JiraIssueLink{AccountID: acct, ID: "l1", SourceKey: "PROJ-1", TargetKey: "OTH-1", LinkType: "Blocks", SyncedAt: ts}))
		require.NoError(t, d.UpsertJiraLinkedIssues([]JiraLinkedIssue{{AccountID: acct, Key: "OTH-1", ID: "201", UpdatedAt: ts, SyncedAt: ts}}))
	}
	require.NoError(t, d.ReplaceJiraIssueChangelogs(2, []JiraIssueHistory{
		{Key: "PROJ-1", UpdatedAt: ts, Items: []JiraChangelogItem{{HistoryID: "1", Field: "status", ToString: "In Progress", ChangedAt: ts}}},
		{Key: "OTH-1", UpdatedAt: ts},
	}))

	due1, err := d.ListJiraChangelogDue(1, 10)
	require.NoError(t, err)
	assert.Len(t, due1, 2, "account 2's cursors do not make account 1's issues current")
	due2, err := d.ListJiraChangelogDue(2, 10)
	require.NoError(t, err)
	assert.Empty(t, due2)

	cl1, err := d.ListJiraIssueChangelog(1, []string{"PROJ-1"})
	require.NoError(t, err)
	assert.Empty(t, cl1["PROJ-1"])

	// Account 2 loses its link: only its own linked row and history go.
	_, err = d.Exec(`DELETE FROM jira_issue_links WHERE account_id = 2`)
	require.NoError(t, err)
	n, err := d.PruneJiraLinkedIssues(2)
	require.NoError(t, err)
	assert.EqualValues(t, 1, n)
	cands1, err := d.ListJiraLinkedCandidates(1, 10)
	require.NoError(t, err)
	assert.Equal(t, []string{"OTH-1"}, cands1)
	cands2, err := d.ListJiraLinkedCandidates(2, 10)
	require.NoError(t, err)
	assert.Empty(t, cands2)

	only1, err := d.ListJiraHistoryIssues(JiraHistoryFilter{AccountID: 1, IncludeLinked: true})
	require.NoError(t, err)
	require.Len(t, only1, 2)
	for _, is := range only1 {
		assert.EqualValues(t, 1, is.AccountID)
	}
	both, err := d.ListJiraHistoryIssues(JiraHistoryFilter{Keys: []string{"PROJ-1"}})
	require.NoError(t, err)
	assert.Len(t, both, 2, "account_id 0 reads every account")
}

func TestJiraHistory_BoardIssueWinsOverStaleLinkedRow(t *testing.T) {
	d := openTestDB(t)
	SeedTestJiraAccount(t, d)
	now := time.Now().UTC()
	changelogTestIssue(t, d, "PROJ-2", "102", "in_progress", FormatJiraTime(now), false)
	require.NoError(t, d.UpsertJiraLinkedIssues([]JiraLinkedIssue{
		{AccountID: 1, Key: "PROJ-2", ID: "102", UpdatedAt: FormatJiraTime(now.Add(-time.Hour)), SyncedAt: FormatJiraTime(now)},
	}))

	got, err := d.ListJiraHistoryIssues(JiraHistoryFilter{Keys: []string{"PROJ-2"}})
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, "board", got[0].Source)
	due, err := d.ListJiraChangelogDue(1, 10)
	require.NoError(t, err)
	require.Len(t, due, 1)
	assert.Equal(t, FormatJiraTime(now), due[0].UpdatedAt)
}

func TestListJiraHistoryIssues_FollowsLinksInBothDirections(t *testing.T) {
	d := openTestDB(t)
	SeedTestJiraAccount(t, d)
	ts := FormatJiraTime(time.Now().UTC())
	changelogTestIssue(t, d, "PROJ-1", "101", "in_progress", ts, false)
	changelogTestIssue(t, d, "PROJ-2", "102", "in_progress", ts, false)
	// The shared link row is owned by PROJ-2 (synced last).
	require.NoError(t, d.UpsertJiraIssueLink(JiraIssueLink{AccountID: 1, ID: "l1", SourceKey: "PROJ-2", TargetKey: "PROJ-1", LinkType: "Blocks", SyncedAt: ts}))

	got, err := d.ListJiraHistoryIssues(JiraHistoryFilter{Keys: []string{"PROJ-1"}, IncludeLinked: true})
	require.NoError(t, err)
	var keys []string
	for _, is := range got {
		keys = append(keys, is.Key)
	}
	assert.Equal(t, []string{"PROJ-1", "PROJ-2"}, keys)
}

func TestListJiraIssueChangelog_OrdersHistoryIDsNumerically(t *testing.T) {
	d := openTestDB(t)
	SeedTestJiraAccount(t, d)
	ts := FormatJiraTime(time.Now().UTC())
	replaceHistory(t, d, "PROJ-1", ts, []JiraChangelogItem{
		{HistoryID: "10", Field: "status", FromString: "B", ToString: "C", ChangedAt: ts},
		{HistoryID: "9", Field: "status", FromString: "A", ToString: "B", ChangedAt: ts},
	})
	got, err := d.ListJiraIssueChangelog(1, []string{"PROJ-1"})
	require.NoError(t, err)
	require.Len(t, got["PROJ-1"], 2)
	assert.Equal(t, "9", got["PROJ-1"][0].HistoryID, "same instant: history 9 before 10, not string order")
}

func TestUpsertJiraIssueBatch_ReplacesAnIssuesLinks(t *testing.T) {
	d := openTestDB(t)
	SeedTestJiraAccount(t, d)
	ts := FormatJiraTime(time.Now().UTC())
	issue := JiraIssue{AccountID: 1, Key: "PROJ-1", ID: "101", ProjectKey: "PROJ", Summary: "S", Status: "Open",
		StatusCategory: "todo", Labels: `[]`, Components: `[]`, CreatedAt: ts, UpdatedAt: ts, SyncedAt: ts}
	require.NoError(t, d.UpsertJiraIssueBatch([]JiraIssue{issue}, []JiraIssueLink{
		{AccountID: 1, ID: "l1", SourceKey: "PROJ-1", TargetKey: "OTH-1", LinkType: "Blocks", SyncedAt: ts},
		{AccountID: 1, ID: "l2", SourceKey: "PROJ-1", TargetKey: "OTH-2", LinkType: "Blocks", SyncedAt: ts},
	}))
	require.NoError(t, d.UpsertJiraIssueBatch([]JiraIssue{issue}, []JiraIssueLink{
		{AccountID: 1, ID: "l2", SourceKey: "PROJ-1", TargetKey: "OTH-2", LinkType: "Blocks", SyncedAt: ts},
	}))

	targets := queryKeys(t, d, `SELECT target_key FROM jira_issue_links WHERE account_id = 1 ORDER BY target_key`)
	assert.Equal(t, []string{"OTH-2"}, targets, "a link removed in Jira is gone after the issue is re-synced")
}

func queryKeys(t *testing.T, d *DB, q string) []string {
	t.Helper()
	rows, err := d.Query(q)
	require.NoError(t, err)
	defer rows.Close()
	var out []string
	for rows.Next() {
		var k string
		require.NoError(t, rows.Scan(&k))
		out = append(out, k)
	}
	require.NoError(t, rows.Err())
	return out
}
