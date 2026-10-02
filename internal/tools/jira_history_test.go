package tools

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func ft(t time.Time) string { return db.FormatJiraTime(t) }

func historyIssue(key string, created time.Time, status, assigneeID, assignee string) db.JiraHistoryIssue {
	return db.JiraHistoryIssue{AccountID: 1, Key: key, Source: "board", CreatedAt: ft(created), UpdatedAt: ft(created),
		ChangelogUpdatedAt: ft(created), Status: status, AssigneeAccountID: assigneeID, AssigneeDisplayName: assignee}
}

func TestBuildStatusIntervals_NoChangesIsOneInterval(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	is := historyIssue("A-1", now.Add(-10*time.Hour), "In Progress", "acc-a", "A")

	got := buildStatusIntervals(is, nil, now)
	require.Len(t, got, 1)
	assert.Equal(t, "In Progress", got[0].Status)
	assert.Equal(t, "A", got[0].Assignee)
	assert.Equal(t, 10.0, got[0].Hours)
}

func TestBuildStatusIntervals_InterleavedStatusAndAssignee(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	created := now.Add(-10 * time.Hour)
	is := historyIssue("A-1", created, "Done", "acc-b", "B")
	items := []db.JiraChangelogItem{
		{Field: "status", FromString: "To Do", ToString: "In Progress", ChangedAt: ft(created.Add(2 * time.Hour))},
		{Field: "assignee", FromValue: "acc-a", FromString: "A", ToValue: "acc-b", ToString: "B", ChangedAt: ft(created.Add(5 * time.Hour))},
		{Field: "status", FromString: "In Progress", ToString: "Done", ChangedAt: ft(created.Add(8 * time.Hour))},
	}

	got := buildStatusIntervals(is, items, now)
	type seg struct {
		status, assignee string
		hours            float64
	}
	var segs []seg
	for _, iv := range got {
		segs = append(segs, seg{iv.Status, iv.Assignee, iv.Hours})
	}
	assert.Equal(t, []seg{
		{"To Do", "A", 2}, {"In Progress", "A", 3}, {"In Progress", "B", 3}, {"Done", "B", 2},
	}, segs, "initial state comes from the first change's from; current values only after the last change")
}

func TestBuildStatusIntervals_EndBeforeLaterChanges(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	created := now.Add(-10 * time.Hour)
	is := historyIssue("A-1", created, "Done", "", "")
	items := []db.JiraChangelogItem{
		{Field: "status", FromString: "To Do", ToString: "Done", ChangedAt: ft(created.Add(6 * time.Hour))},
	}
	got := buildStatusIntervals(is, items, created.Add(4*time.Hour))
	require.Len(t, got, 1)
	assert.Equal(t, "To Do", got[0].Status)
	assert.Equal(t, 4.0, got[0].Hours)
}

func TestTimeInStatus_ClipsFiltersAndSums(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	created := now.Add(-48 * time.Hour)
	since, until := now.Add(-24*time.Hour), now
	issues := []db.JiraHistoryIssue{
		historyIssue("A-1", created, "Done", "acc-a", "Alice"),
		historyIssue("A-2", created, "In Progress", "acc-a", "Alice"),
		{AccountID: 1, Key: "A-3", CreatedAt: ft(created), UpdatedAt: ft(created), Status: "In Progress"}, // no history
	}
	issues[1].UpdatedAt = ft(now) // changed after its history was synced
	changelogs := map[int64]map[string][]db.JiraChangelogItem{1: {
		"A-1": {
			{Field: "status", FromString: "To Do", ToString: "In Progress", ChangedAt: ft(now.Add(-30 * time.Hour))},
			{Field: "status", FromString: "In Progress", ToString: "Done", ChangedAt: ft(now.Add(-12 * time.Hour))},
		},
	}}
	cats := map[string]string{"To Do": "todo", "In Progress": "in_progress", "Done": "done"}

	res := timeInStatus(jiraTimeInStatusArgs{}, issues, changelogs, cats, since, until)

	assert.Equal(t, timeInStatusNote, res.Note)
	assert.Equal(t, []string{"A-3"}, res.IssuesWithoutHistory)
	assert.Equal(t, []string{"A-2"}, res.IssuesWithStaleHistory)
	require.Len(t, res.Totals, 1, "Done is left out by default")
	assert.Equal(t, timeInStatusTotal{AssigneeAccountID: "acc-a", Assignee: "Alice", Status: "In Progress", Hours: 36, Issues: 2}, res.Totals[0],
		"A-1: 12h clipped to the period, A-2: 24h")
	require.Len(t, res.PerAssignee, 1)
	assert.Equal(t, 36.0, res.PerAssignee[0].Hours)
	assert.Len(t, res.Intervals, 2)

	withDone := timeInStatus(jiraTimeInStatusArgs{IncludeDone: true, Limit: 1}, issues, changelogs, cats, since, until)
	assert.Len(t, withDone.Totals, 2)
	assert.True(t, withDone.Truncated)
	assert.Len(t, withDone.Intervals, 1)

	other := timeInStatus(jiraTimeInStatusArgs{Assignee: "bob"}, issues, changelogs, cats, since, until)
	assert.Empty(t, other.Totals)
	byName := timeInStatus(jiraTimeInStatusArgs{Assignee: "ALI", Statuses: []string{"Done"}}, issues, changelogs, cats, since, until)
	require.Len(t, byName.Totals, 1)
	assert.Equal(t, "Done", byName.Totals[0].Status)
	assert.Equal(t, 12.0, byName.Totals[0].Hours)
}

func TestTimeInStatusPeriod(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	since, until, err := timeInStatusPeriod("", "", now)
	require.NoError(t, err)
	assert.Equal(t, now, until)
	assert.Equal(t, now.AddDate(0, 0, -defaultTimeInStatusDays), since)

	_, _, err = timeInStatusPeriod(now.Format(time.RFC3339), now.Add(-time.Hour).Format(time.RFC3339), now)
	var ve *ValidationError
	assert.ErrorAs(t, err, &ve)
	_, _, err = timeInStatusPeriod("yesterday", "", now)
	assert.ErrorAs(t, err, &ve)
}

func TestJiraHistoryTools_EndToEnd(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	now := time.Now().UTC().Truncate(time.Second)
	created := now.Add(-5 * 24 * time.Hour)
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		AccountID: 1, Key: "ABC-1", ID: "101", ProjectKey: "ABC", BoardID: 3, Summary: "board task",
		Status: "In Progress", StatusCategory: "in_progress", AssigneeAccountID: "acc-a", AssigneeDisplayName: "Alice",
		Labels: `[]`, Components: `[]`, CreatedAt: ft(created), UpdatedAt: ft(created.Add(time.Hour)), SyncedAt: ft(now),
	}))
	require.NoError(t, d.UpsertJiraIssueLink(db.JiraIssueLink{AccountID: 1, ID: "l1", SourceKey: "ABC-1", TargetKey: "XYZ-9", LinkType: "Blocks", SyncedAt: ft(now)}))
	require.NoError(t, d.UpsertJiraLinkedIssues([]db.JiraLinkedIssue{{
		AccountID: 1, Key: "XYZ-9", ID: "909", Status: "Review", StatusCategory: "in_progress",
		AssigneeAccountID: "acc-b", AssigneeDisplayName: "Bob", CreatedAt: ft(created), UpdatedAt: ft(created), SyncedAt: ft(now),
	}}))
	replaceHistory(t, d, "ABC-1", ft(created.Add(time.Hour)), []db.JiraChangelogItem{
		{HistoryID: "1", Field: "status", FromString: "To Do", ToString: "In Progress", AuthorDisplayName: "Alice", ChangedAt: ft(created.Add(time.Hour))},
	})
	replaceHistory(t, d, "XYZ-9", ft(created), nil)

	reg := New(d)
	require.NoError(t, reg.Register(NewGetJiraStatusHistory()))
	require.NoError(t, reg.Register(NewGetJiraTimeInStatus()))

	var hist statusHistoryResult
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, reg, "get_jira_status_history", `{"keys":["abc-1","NOPE-1"]}`)), &hist))
	require.Len(t, hist.Issues, 1)
	assert.Equal(t, "synced", hist.Issues[0].History)
	require.Len(t, hist.Issues[0].Events, 1)
	assert.Equal(t, "Alice", hist.Issues[0].Events[0].Author)
	assert.Len(t, hist.Issues[0].StatusIntervals, 2)
	assert.Equal(t, []string{"NOPE-1"}, hist.NotFound)

	var tis timeInStatusResult
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, reg, "get_jira_time_in_status", `{"board_id":3}`)), &tis))
	assert.Equal(t, 2, tis.IssuesConsidered, "the board issue and the issue it links to on another board")
	names := map[string]bool{}
	for _, tot := range tis.PerAssignee {
		names[tot.Assignee] = true
	}
	assert.Equal(t, map[string]bool{"Alice": true, "Bob": true}, names)

	var noLinked timeInStatusResult
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, reg, "get_jira_time_in_status", `{"board_id":3,"include_linked":false}`)), &noLinked))
	assert.Equal(t, 1, noLinked.IssuesConsidered)
}

func replaceHistory(t *testing.T, d *db.DB, key, updatedAt string, items []db.JiraChangelogItem) {
	t.Helper()
	require.NoError(t, d.ReplaceJiraIssueChangelogs(1, []db.JiraIssueHistory{{Key: key, UpdatedAt: updatedAt, Items: items}}))
}
