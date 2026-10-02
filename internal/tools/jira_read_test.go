package tools

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func jiraReadRegistry(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	require.NoError(t, reg.Register(NewListJiraIssues()))
	require.NoError(t, reg.Register(NewGetJiraIssue()))
	return reg
}

func seedJiraIssue(t *testing.T, d *db.DB, key, summary string, deleted bool) {
	t.Helper()
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		AccountID: 1, Key: key, ID: key, ProjectKey: "ABC", Summary: summary,
		Status: "To Do", StatusCategory: "To Do",
		CreatedAt: "2026-06-01T00:00:00Z", UpdatedAt: "2026-06-02T00:00:00Z", SyncedAt: "2026-06-02T00:00:00Z",
		IsDeleted: deleted,
	}))
}

func TestListJiraIssues_ByProject(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	seedJiraIssue(t, d, "ABC-1", "fix the thing", false)

	got := callReadString(t, jiraReadRegistry(t, d), "list_jira_issues", `{"project":"ABC"}`)
	assert.Contains(t, got, "fix the thing")
}

func TestGetJiraIssue_ReturnsIssue(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	seedJiraIssue(t, d, "ABC-7", "wire the widget", false)

	got := callReadString(t, jiraReadRegistry(t, d), "get_jira_issue", `{"key":"ABC-7"}`)
	assert.Contains(t, got, "wire the widget")
}

func TestGetJiraIssue_NotFound(t *testing.T) {
	_, err := jiraReadRegistry(t, openDB(t)).CallRead(context.Background(), "get_jira_issue", json.RawMessage(`{"key":"NOPE-1"}`), Binding{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no jira issue with key NOPE-1")
}

// A soft-deleted (tombstoned) issue is treated as not-found, consistent with
// list_jira_issues (which filters is_deleted = 0).
func TestGetJiraIssue_TombstoneIsNotFound(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	seedJiraIssue(t, d, "ABC-9", "deleted issue", true)

	_, err := jiraReadRegistry(t, d).CallRead(context.Background(), "get_jira_issue", json.RawMessage(`{"key":"ABC-9"}`), Binding{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no jira issue with key ABC-9")
}

// list_jira_projects groups synced projects and their issue types per account.
func TestListJiraProjects_GroupsByAccount(t *testing.T) {
	d := openDB(t)
	acct, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c", SiteURL: "https://acme.atlassian.net", SiteName: "Acme"})
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO jira_sync_state (account_id, project_key, last_synced_at, issues_synced) VALUES (?, 'ABC', 'x', 2)`, acct)
	require.NoError(t, err)
	for _, it := range []string{"Task", "Bug", "Task"} {
		require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
			AccountID: acct, Key: "ABC-" + it + "1", ID: "ABC-" + it + "1", ProjectKey: "ABC", Summary: "s", IssueType: it,
			Status: "To Do", StatusCategory: "new", Labels: "[]", Components: "[]", FixVersions: "[]",
			CreatedAt: "2026-01-01T00:00:00Z", UpdatedAt: "2026-01-01T00:00:00Z", SyncedAt: "2026-01-01T00:00:00Z",
		}))
	}
	reg := New(d)
	require.NoError(t, reg.Register(NewListJiraProjects()))

	got := callReadString(t, reg, "list_jira_projects", `{}`)
	assert.Contains(t, got, `"account_id":`+strconv.FormatInt(acct, 10))
	assert.Contains(t, got, `"project_key":"ABC"`)
	assert.Contains(t, got, `"Bug"`)
	assert.Contains(t, got, `"Task"`)
}

// listJiraProjectsFor runs list_jira_projects and returns the project views
// keyed by account id.
func listJiraProjectsFor(t *testing.T, d *db.DB) map[int64][]jiraProjectView {
	t.Helper()
	reg := New(d)
	require.NoError(t, reg.Register(NewListJiraProjects()))
	var views []jiraProjectsView
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, reg, "list_jira_projects", `{}`)), &views))
	out := map[int64][]jiraProjectView{}
	for _, v := range views {
		out[v.AccountID] = v.Projects
	}
	return out
}

func seedJiraProjectIssue(t *testing.T, d *db.DB, acct int64, key, project, issueType string, boardID int) {
	t.Helper()
	now := time.Now().UTC().Format(time.RFC3339)
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		AccountID: acct, Key: key, ID: key, ProjectKey: project, Summary: "s", IssueType: issueType,
		Status: "To Do", StatusCategory: "todo", Labels: "[]", Components: "[]", FixVersions: "[]",
		BoardID:   boardID,
		CreatedAt: now, UpdatedAt: now, SyncedAt: now,
	}))
}

func seedJiraBoard(t *testing.T, d *db.DB, acct int64, id int, project string, selected bool) {
	t.Helper()
	require.NoError(t, d.UpsertJiraBoard(db.JiraBoard{
		AccountID: acct, ID: id, Name: project + " board", ProjectKey: project, BoardType: "scrum", IsSelected: selected,
	}))
}

// A board selected in the app syncs its active issues at once (SyncBoard)
// but writes no jira_sync_state row; the project must still be listed.
func TestListJiraProjects_SelectedBoardFastPathWithoutSyncState(t *testing.T) {
	d := openDB(t)
	acct := db.SeedTestJiraAccount(t, d)
	seedJiraBoard(t, d, acct, 10, "ACME", true)
	seedJiraProjectIssue(t, d, acct, "ACME-1", "ACME", "Story", 10)
	seedJiraProjectIssue(t, d, acct, "ACME-2", "ACME", "Bug", 10)

	got := listJiraProjectsFor(t, d)[acct]
	require.Len(t, got, 1)
	assert.Equal(t, "ACME", got[0].ProjectKey)
	assert.Equal(t, 2, got[0].IssueCount)
	assert.ElementsMatch(t, []string{"Bug", "Story"}, got[0].IssueTypes)
}

// A selected board whose issues have not landed yet is listed with zero
// issues; unselected boards and boards without a project key are not.
func TestListJiraProjects_SelectedBoardWithoutIssues(t *testing.T) {
	d := openDB(t)
	acct := db.SeedTestJiraAccount(t, d)
	seedJiraBoard(t, d, acct, 11, "ZETA", true)
	seedJiraBoard(t, d, acct, 12, "OFF", false)
	seedJiraBoard(t, d, acct, 13, "", true)

	got := listJiraProjectsFor(t, d)[acct]
	require.Len(t, got, 1)
	assert.Equal(t, "ZETA", got[0].ProjectKey)
	assert.Equal(t, 0, got[0].IssueCount)
	assert.Empty(t, got[0].IssueTypes)
}

// A project known through a sync-state row, a selected board and issues is
// listed once; projects come out sorted by key.
func TestListJiraProjects_NoDuplicatesAndSorted(t *testing.T) {
	d := openDB(t)
	acct := db.SeedTestJiraAccount(t, d)
	_, err := d.Exec(`INSERT INTO jira_sync_state (account_id, project_key, last_synced_at, issues_synced) VALUES (?, 'BETA', 'x', 1)`, acct)
	require.NoError(t, err)
	seedJiraBoard(t, d, acct, 20, "BETA", true)
	seedJiraProjectIssue(t, d, acct, "BETA-1", "BETA", "Task", 20)
	seedJiraBoard(t, d, acct, 21, "ACME", true)

	got := listJiraProjectsFor(t, d)[acct]
	require.Len(t, got, 2)
	assert.Equal(t, "ACME", got[0].ProjectKey)
	assert.Equal(t, "BETA", got[1].ProjectKey)
	assert.Equal(t, 1, got[1].IssueCount)
}

// Another account's selected boards never leak into an account's list.
func TestListJiraProjects_AccountScoped(t *testing.T) {
	d := openDB(t)
	a1, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c1", SiteURL: "https://acme.atlassian.net", SiteName: "Acme"})
	require.NoError(t, err)
	a2, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c2", SiteURL: "https://example.atlassian.net", SiteName: "Example"})
	require.NoError(t, err)
	seedJiraBoard(t, d, a1, 30, "ACME", true)
	seedJiraBoard(t, d, a2, 31, "OTHER", true)

	got := listJiraProjectsFor(t, d)
	require.Len(t, got[a1], 1)
	assert.Equal(t, "ACME", got[a1][0].ProjectKey)
	require.Len(t, got[a2], 1)
	assert.Equal(t, "OTHER", got[a2][0].ProjectKey)
}

// Mirrored issues alone do not make a project synced: an issue-key write
// mirrors a row for an unwatched project, and a board deselected after its
// fast sync leaves its issues behind. Neither is listed nor creatable.
func TestListJiraProjects_IssuesWithoutBoardOrWatermarkAreNotSynced(t *testing.T) {
	d := openDB(t)
	acct := db.SeedTestJiraAccount(t, d)
	seedJiraProjectIssue(t, d, acct, "SIDE-1", "SIDE", "Task", 0)
	seedJiraBoard(t, d, acct, 50, "GONE", false)
	seedJiraProjectIssue(t, d, acct, "GONE-1", "GONE", "Task", 50)

	assert.Empty(t, listJiraProjectsFor(t, d)[acct])
	tool := NewCreateJiraIssue(func(db.JiraAccount) (JiraIssueClient, error) { return &fakeJira{}, nil })
	var verr *ValidationError
	for _, project := range []string{"SIDE", "GONE"} {
		raw := `{"project_key":"` + project + `","issue_type":"Task","summary":"s","reason":"r"}`
		assert.ErrorAs(t, tool.Validate(context.Background(), d, json.RawMessage(raw)), &verr, project)
	}
}

// create_jira_issue accepts exactly the projects list_jira_projects lists: a
// just-selected board's project passes before any full sync, an unselected
// board's project without issues or a watermark does not.
func TestCreateJiraIssue_AcceptsSelectedBoardProjectBeforeFullSync(t *testing.T) {
	d := openDB(t)
	acct := db.SeedTestJiraAccount(t, d)
	seedJiraBoard(t, d, acct, 40, "ACME", true)
	seedJiraBoard(t, d, acct, 41, "OFF", false)
	tool := NewCreateJiraIssue(func(db.JiraAccount) (JiraIssueClient, error) { return &fakeJira{}, nil })
	ctx := context.Background()

	assert.NoError(t, tool.Validate(ctx, d, json.RawMessage(`{"project_key":"acme","issue_type":"Task","summary":"s","reason":"r"}`)))
	var verr *ValidationError
	assert.ErrorAs(t, tool.Validate(ctx, d, json.RawMessage(`{"project_key":"OFF","issue_type":"Task","summary":"s","reason":"r"}`)), &verr)
}
