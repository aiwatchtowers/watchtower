package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// seedOwnerTrackers seeds one Jira and one Linear account with issues owned
// by different identities: the owner's Jira id "acc-me", the owner's Linear
// id "lin-me", someone else's ids, and the Slack bridge "1:U1".
func seedOwnerTrackers(t *testing.T, d *DB) (jiraAcct, linearAcct int64) {
	t.Helper()
	ja, err := d.CreateJiraAccount(JiraAccount{CloudID: "c", SiteURL: "https://acme.atlassian.net", SiteName: "Acme", Enabled: true})
	require.NoError(t, err)
	jira := func(key, cat, prio string, i JiraIssue) {
		i.AccountID, i.Key, i.ID, i.ProjectKey, i.Summary = ja, key, "id-"+key, "ABC", "Summary "+key
		i.Status, i.StatusCategory, i.Priority = "Status "+cat, cat, prio
		i.Labels, i.Components = `[]`, `[]`
		i.CreatedAt, i.UpdatedAt, i.SyncedAt = "2026-10-01T00:00:00.000Z", "2026-10-02T00:00:00.000Z", "2026-10-02T00:00:00Z"
		require.NoError(t, d.UpsertJiraIssue(i))
	}
	jira("ABC-1", "in_progress", "Low", JiraIssue{AssigneeAccountID: "acc-me", ReporterAccountID: "acc-other"})
	jira("ABC-2", "todo", "Highest", JiraIssue{AssigneeAccountID: "acc-me"})
	jira("ABC-3", "done", "High", JiraIssue{AssigneeAccountID: "acc-me"})
	jira("ABC-4", "todo", "", JiraIssue{AssigneeAccountID: "acc-other", ReporterAccountID: "acc-me"})
	jira("ABC-5", "todo", "", JiraIssue{AssigneeAccountID: "acc-x", AssigneeSlackID: "1:U1"})

	la, err := d.CreateLinearAccount("")
	require.NoError(t, err)
	linear := func(id, key, cat string, prio int, i LinearIssue) {
		i.AccountID, i.ID, i.Key, i.TeamKey, i.TeamID, i.Title = la, id, key, "ENG", "t-1", "Title "+key
		i.StateName, i.StatusCategory, i.Priority = "State "+cat, cat, prio
		i.UpdatedAt = "2026-10-03T00:00:00.000Z"
		require.NoError(t, d.UpsertLinearIssue(i))
	}
	linear("l-1", "ENG-1", "in_progress", 3, LinearIssue{AssigneeID: "lin-me", CreatorID: "lin-other"})
	linear("l-2", "ENG-2", "todo", 1, LinearIssue{AssigneeID: "lin-me"})
	linear("l-3", "ENG-3", "done", 2, LinearIssue{AssigneeID: "lin-me"})
	linear("l-4", "ENG-4", "todo", 0, LinearIssue{AssigneeID: "lin-other", CreatorID: "lin-me"})
	linear("l-5", "ENG-5", "todo", 0, LinearIssue{AssigneeID: "lin-x"})
	_, err = d.Exec(`UPDATE linear_issues SET assignee_slack_id = '1:U1' WHERE id = 'l-5'`)
	require.NoError(t, err)
	return ja, la
}

func trackerKeys(issues []TrackerIssue) []string {
	out := make([]string, len(issues))
	for i, is := range issues {
		out[i] = is.Key
	}
	return out
}

func TestOwnerAssignedTrackerIssues_PerTrackerIdentity(t *testing.T) {
	d := openTestDB(t)
	seedOwnerTrackers(t, d)
	owner := Owner{ID: "1:U1", SlackUserID: "1:U1", JiraAccountID: "acc-me", LinearUserIDs: []string{"lin-me"}}

	got, err := d.OwnerAssignedTrackerIssues(owner, TrackerJira)
	require.NoError(t, err)
	assert.Equal(t, []string{"ABC-2", "ABC-1"}, trackerKeys(got), "own id wins over the Slack bridge; priority first; done left out")

	got, err = d.OwnerAssignedTrackerIssues(owner, TrackerLinear)
	require.NoError(t, err)
	assert.Equal(t, []string{"ENG-2", "ENG-1"}, trackerKeys(got))

	slackOnly := Owner{ID: "1:U1", SlackUserID: "1:U1"}
	got, err = d.OwnerAssignedTrackerIssues(slackOnly, TrackerLinear)
	require.NoError(t, err)
	assert.Equal(t, []string{"ENG-5"}, trackerKeys(got), "no Linear id: the Slack bridge")

	got, err = d.OwnerAssignedTrackerIssues(Owner{ID: "google:me@example.com"}, TrackerJira)
	require.NoError(t, err)
	assert.Empty(t, got, "no identity never matches the empty bridge column")
}

// A Jira row read through the view carries every field the shared formatters
// read, equal to the jira_issues read the briefing used before.
func TestTrackerIssue_AsJiraIssueMatchesJiraRead(t *testing.T) {
	d := openTestDB(t)
	seedOwnerTrackers(t, d)
	owner := Owner{ID: "jira:acc-me", JiraAccountID: "acc-me"}
	direct, err := d.GetOwnerAssignedJiraIssues(owner)
	require.NoError(t, err)
	viaView, err := d.OwnerAssignedTrackerIssues(owner, TrackerJira)
	require.NoError(t, err)
	require.Len(t, viaView, len(direct))
	for i := range direct {
		j := viaView[i].AsJiraIssue()
		assert.Equal(t, direct[i].Key, j.Key)
		assert.Equal(t, direct[i].Summary, j.Summary)
		assert.Equal(t, direct[i].Status, j.Status)
		assert.Equal(t, direct[i].StatusCategory, j.StatusCategory)
		assert.Equal(t, direct[i].StatusCategoryChangedAt, j.StatusCategoryChangedAt)
		assert.Equal(t, direct[i].Priority, j.Priority)
		assert.Equal(t, direct[i].DueDate, j.DueDate)
		assert.Equal(t, direct[i].SprintName, j.SprintName)
		assert.Equal(t, direct[i].EpicKey, j.EpicKey)
		assert.Equal(t, direct[i].AssigneeDisplayName, j.AssigneeDisplayName)
	}
}

func TestOwnerReportedActiveTrackerIssues(t *testing.T) {
	d := openTestDB(t)
	seedOwnerTrackers(t, d)
	owner := Owner{ID: "1:U1", SlackUserID: "1:U1", JiraAccountID: "acc-me", LinearUserIDs: []string{"lin-me"}}
	got, err := d.OwnerReportedActiveTrackerIssues(owner, TrackerJira, 20)
	require.NoError(t, err)
	assert.Equal(t, []string{"ABC-4"}, trackerKeys(got))
	got, err = d.OwnerReportedActiveTrackerIssues(owner, TrackerLinear, 20)
	require.NoError(t, err)
	assert.Equal(t, []string{"ENG-4"}, trackerKeys(got))
}

func TestUnambiguousTrackerIssue(t *testing.T) {
	d := openTestDB(t)
	_, la := seedOwnerTrackers(t, d)

	got, err := d.UnambiguousTrackerIssue(TrackerLinear, "ENG-1")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "l-1", got.IssueID)

	// A team move: the old key resolves to the issue under its new key.
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: la, ID: "l-1", Key: "OPS-9", PreviousKeys: []string{"ENG-1"},
		TeamKey: "OPS", StatusCategory: "done", UpdatedAt: "2026-10-04T00:00:00.000Z"}))
	got, err = d.UnambiguousTrackerIssue(TrackerLinear, "ENG-1")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "OPS-9", got.Key)
	assert.Equal(t, "done", got.StatusCategory)

	// The same key on two Linear workspaces is ambiguous: nil.
	lb, err := d.CreateLinearAccount("b")
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: lb, ID: "x-2", Key: "ENG-2", StatusCategory: "todo", UpdatedAt: "2026-10-04T00:00:00.000Z"}))
	got, err = d.UnambiguousTrackerIssue(TrackerLinear, "ENG-2")
	require.NoError(t, err)
	assert.Nil(t, got)

	// The tracker scopes the key: a Jira key never resolves as Linear.
	got, err = d.UnambiguousTrackerIssue(TrackerLinear, "ABC-1")
	require.NoError(t, err)
	assert.Nil(t, got)
}

func TestActiveTrackerIterationStats_LinearCycle(t *testing.T) {
	d := openTestDB(t)
	la, err := d.CreateLinearAccount("")
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearTeams(la, []LinearTeam{{ID: "t-1", Key: "ENG", Name: "Eng"}}, nil))
	now := time.Now().UTC()
	require.NoError(t, d.UpsertLinearCycles([]LinearCycle{
		{AccountID: la, ID: "c-1", TeamID: "t-1", Number: 4, StartsAt: now.AddDate(0, 0, -3).Format(time.RFC3339),
			EndsAt: now.Add(36 * time.Hour).Format(time.RFC3339)},
		{AccountID: la, ID: "c-0", TeamID: "t-1", Number: 3, StartsAt: now.AddDate(0, 0, -20).Format(time.RFC3339),
			EndsAt: now.AddDate(0, 0, -6).Format(time.RFC3339)},
	}))
	for i, cat := range []string{"done", "in_progress", "todo", "todo"} {
		require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: la, ID: string(rune('a' + i)), Key: "ENG-" + string(rune('1'+i)),
			StatusCategory: cat, CycleID: "c-1", UpdatedAt: "2026-10-03T00:00:00.000Z"}))
	}
	got, err := d.ActiveTrackerIterationStats(TrackerLinear)
	require.NoError(t, err)
	require.Len(t, got, 1, "the past cycle is closed")
	assert.Equal(t, "ENG", got[0].ProjectKey)
	assert.Equal(t, SprintStats{SprintName: "Cycle 4", Total: 4, Done: 1, InProgress: 1, Todo: 2, DaysLeft: 2}, got[0].SprintStats)
}

func TestOwnerLinearIDs_UnionsUserMap(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO linear_user_map (linear_user_id, email, slack_user_id, match_method)
		VALUES ('lin-map', 'me@example.com', '1:U1', 'email'), ('lin-me', 'me@example.com', 'U1', 'email')`)
	require.NoError(t, err)
	ids, err := d.OwnerLinearIDs(Owner{SlackUserID: "1:U1", LinearUserIDs: []string{"lin-me"}})
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"lin-me", "lin-map"}, ids)
	ids, err = d.OwnerLinearIDs(Owner{})
	require.NoError(t, err)
	assert.Empty(t, ids)
}

func TestLinearComments_MentionsAndOwn(t *testing.T) {
	d := openTestDB(t)
	la, err := d.CreateLinearAccount("")
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: la, ID: "l-1", Key: "ENG-1", StatusCategory: "todo", UpdatedAt: "2026-10-03T00:00:00.000Z"}))
	for _, c := range []LinearComment{
		{ID: "c1", AuthorID: "lin-other", MentionedUserIDs: []string{"lin-me"}, BodyText: "ping", CreatedAt: "2026-10-03T10:00:00.000Z"},
		{ID: "c2", AuthorID: "lin-other", MentionedUserIDs: []string{"lin-x"}, BodyText: "not me", CreatedAt: "2026-10-03T11:00:00.000Z"},
		{ID: "c3", AuthorID: "lin-other", MentionedUserIDs: []string{"lin-me"}, BodyText: "old", CreatedAt: "2026-10-01T10:00:00.000Z"},
		{ID: "c4", AuthorID: "lin-me", BodyText: "mine", CreatedAt: "2026-10-03T12:00:00.000Z"},
	} {
		c.AccountID, c.IssueID, c.IssueKey, c.UpdatedAt = la, "l-1", "ENG-1", c.CreatedAt
		require.NoError(t, d.UpsertLinearComment(c))
	}
	got, err := d.LinearCommentsMentioning([]string{"lin-me"}, "2026-10-02T00:00:00.000Z")
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, "c1", got[0].ID)
	assert.Equal(t, "ENG-1", got[0].IssueKey)

	none, err := d.LinearCommentsMentioning(nil, "2026-10-02T00:00:00.000Z")
	require.NoError(t, err)
	assert.Empty(t, none)

	own, err := d.LinearOwnComments([]string{"ENG-1"}, []string{"lin-me"})
	require.NoError(t, err)
	require.Len(t, own, 1)
	assert.Equal(t, "c4", own[0].ID)
}

// The hot consumer reads (briefing, day plan, inbox, target sync) reach an
// index on each branch of the compound views (spec §4.2); a view that stops
// pushing a filter down fails here instead of slowing the daemon.
func TestTrackerConsumerQueries_UseIndexes(t *testing.T) {
	d := openTestDB(t)
	cases := []struct {
		name string
		f    TrackerIssueFilter
		want []string
	}{
		{"jira assigned by id", TrackerIssueFilter{Tracker: TrackerJira, AssigneeIDs: []string{"a"}, OpenOnly: true},
			[]string{"SEARCH ji USING INDEX idx_jira_issues_assignee (assignee_account_id=?)"}},
		{"linear assigned by ids", TrackerIssueFilter{Tracker: TrackerLinear, AssigneeIDs: []string{"a", "b"}, OpenOnly: true},
			[]string{"SEARCH li USING INDEX idx_linear_issues_assignee (assignee_id=?)"}},
		{"assigned by slack", TrackerIssueFilter{Tracker: TrackerLinear, AssigneeSlackID: "1:U1", OpenOnly: true},
			[]string{"SEARCH li USING INDEX idx_linear_issues_assignee_status"}},
		{"inbox assigned since", TrackerIssueFilter{Tracker: TrackerLinear, AssigneeIDs: []string{"a"}, UpdatedAfter: "x"},
			[]string{"SEARCH li USING INDEX idx_linear_issues_assignee"}},
		{"target by key", TrackerIssueFilter{Tracker: TrackerJira, Key: "ABC-1"},
			[]string{"SEARCH ji USING INDEX idx_jira_issues_key (key=?)"}},
		{"linear target by key", TrackerIssueFilter{Tracker: TrackerLinear, Key: "ENG-1"},
			[]string{"SEARCH li USING INDEX idx_linear_issues_key (key=?)"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			q, args := trackerIssueQuery(tc.f)
			plan := explainDetails(t, d, q, args...)
			for _, w := range tc.want {
				assert.Contains(t, plan, w, plan)
			}
			assert.NotRegexp(t, `(?m)^SCAN (ji|li)$`, plan)
		})
	}

	count := explainDetails(t, d, `SELECT status_category, COUNT(*) FROM tracker_issues
		WHERE tracker = ? AND account_id = ? AND iteration_id = ? AND is_deleted = 0 GROUP BY status_category`, "linear", 1, "c-1")
	assert.Contains(t, count, "SEARCH li USING INDEX idx_linear_issues_cycle (cycle_id=?)", count)

	mentions := explainDetails(t, d, linearMentionQuery(1), "2026-10-01", "lin-me")
	assert.Contains(t, mentions, "USING INDEX idx_linear_comments_created (created_at>?)", mentions)

	own := explainDetails(t, d, linearOwnCommentsQuery(2, 1), "ENG-1", "ENG-2", "lin-me")
	assert.Contains(t, own, "USING INDEX idx_linear_comments_issue_author", own)
	assert.NotContains(t, own, "SCAN linear_comments", own)
}
