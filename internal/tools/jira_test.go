package tools

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

type fakeJira struct {
	created   []jira.CreateIssueRequest
	createErr error
	key       string
}

func (f *fakeJira) CreateIssue(_ context.Context, req jira.CreateIssueRequest) (jira.CreatedIssue, error) {
	f.created = append(f.created, req)
	if f.createErr != nil {
		return jira.CreatedIssue{}, f.createErr
	}
	return jira.CreatedIssue{ID: "1", Key: f.key}, nil
}

func (f *fakeJira) GetIssue(_ context.Context, key string) (jira.Issue, error) {
	var issue jira.Issue
	_ = json.Unmarshal([]byte(`{"id":"1","key":"`+key+`","fields":{"summary":"Fix login","issuetype":{"name":"Task"},"status":{"name":"To Do","statusCategory":{"key":"new","name":"To Do"}},"priority":{"name":"High"},"labels":["backend"],"created":"2026-09-04T10:00:00.000+0000","updated":"2026-09-04T10:00:00.000+0000","description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"body"}]}]}}}`), &issue)
	return issue, nil
}

func seedJira(t *testing.T, d *db.DB) int64 {
	t.Helper()
	id, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "cloud", SiteURL: "https://acme.atlassian.net", SiteName: "Acme"})
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO jira_sync_state (account_id, project_key, last_synced_at, issues_synced) VALUES (?, 'ABC', '2026-09-01T00:00:00Z', 1)`, id)
	require.NoError(t, err)
	return id
}

func TestCreateJiraIssue_ValidateChecksAccountAndProject(t *testing.T) {
	database := openDB(t)
	tool := NewCreateJiraIssue(func(db.JiraAccount) (JiraIssueClient, error) { return &fakeJira{}, nil })
	ctx := context.Background()

	// No account connected yet.
	err := tool.Validate(ctx, database, json.RawMessage(`{"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "no Jira site")

	seedJira(t, database)
	assert.NoError(t, tool.Validate(ctx, database, json.RawMessage(`{"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r"}`)))

	cases := map[string]string{
		"unsynced project": `{"project_key":"ZZZ","issue_type":"Task","summary":"s","reason":"r"}`,
		"empty summary":    `{"project_key":"ABC","issue_type":"Task","summary":" ","reason":"r"}`,
		"empty type":       `{"project_key":"ABC","issue_type":"","summary":"s","reason":"r"}`,
		"unknown field":    `{"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r","assignee":"me"}`,
		"unknown account":  `{"account_id":99,"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r"}`,
	}
	for name, raw := range cases {
		assert.ErrorAs(t, tool.Validate(ctx, database, json.RawMessage(raw)), &verr, name)
	}
}

func TestCreateJiraIssue_ExecuteCreatesFetchesAndStores(t *testing.T) {
	database := openDB(t)
	accountID := seedJira(t, database)
	fake := &fakeJira{key: "ABC-7"}
	tool := NewCreateJiraIssue(func(a db.JiraAccount) (JiraIssueClient, error) {
		assert.Equal(t, accountID, a.ID)
		return fake, nil
	})
	out, err := tool.Execute(context.Background(), database, Call{ActionID: 5, Args: json.RawMessage(
		`{"project_key":"ABC","issue_type":"Task","summary":"Fix login","description":"body","labels":["backend"],"priority":"High","reason":"r"}`)})
	require.NoError(t, err)
	res := out.(map[string]any)
	assert.Equal(t, "ABC-7", res["key"])
	assert.Equal(t, "https://acme.atlassian.net/browse/ABC-7", res["url"])
	require.Len(t, fake.created, 1)
	assert.Equal(t, "Fix login", fake.created[0].Summary)

	row, err := database.GetJiraIssueByKey("ABC-7")
	require.NoError(t, err)
	require.NotNil(t, row)
	assert.Equal(t, accountID, row.AccountID)
	assert.Equal(t, "ABC", row.ProjectKey)
	assert.Equal(t, "Task", row.IssueType)
	assert.Equal(t, "To Do", row.Status)
	assert.Equal(t, "body", row.DescriptionText)
	assert.Equal(t, `["backend"]`, row.Labels)
}

func TestCreateJiraIssue_AuthRevokedMarksAccount(t *testing.T) {
	database := openDB(t)
	accountID := seedJira(t, database)
	fake := &fakeJira{createErr: jira.ErrAuthRevoked}
	tool := NewCreateJiraIssue(func(db.JiraAccount) (JiraIssueClient, error) { return fake, nil })
	_, err := tool.Execute(context.Background(), database, Call{Args: json.RawMessage(
		`{"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r"}`)})
	assert.True(t, errors.Is(err, jira.ErrAuthRevoked))
	acct, _ := database.GetJiraAccount(accountID)
	assert.Equal(t, "revoked", acct.Status)
}

func TestCreateJiraIssue_APIErrorSurfacesMessage(t *testing.T) {
	database := openDB(t)
	seedJira(t, database)
	fake := &fakeJira{createErr: &jira.APIError{Status: 400, Message: "issuetype: invalid"}}
	tool := NewCreateJiraIssue(func(db.JiraAccount) (JiraIssueClient, error) { return fake, nil })
	_, err := tool.Execute(context.Background(), database, Call{Args: json.RawMessage(
		`{"project_key":"ABC","issue_type":"Nope","summary":"s","reason":"r"}`)})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "issuetype: invalid")
}

func TestCreateJiraIssue_Registration(t *testing.T) {
	tool := NewCreateJiraIssue(nil)
	assert.Equal(t, "create_jira_issue", tool.Name)
	assert.True(t, tool.External)
	assert.ElementsMatch(t, []string{"main", "target"}, tool.Surfaces)
}

func TestResolveJiraAccount_SingleDefaultAndAmbiguity(t *testing.T) {
	database := openDB(t)
	_, err := ResolveJiraAccount(database, 0)
	require.Error(t, err)
	first := seedJira(t, database)
	a, err := ResolveJiraAccount(database, 0)
	require.NoError(t, err)
	assert.Equal(t, first, a.ID)
	_, err = database.CreateJiraAccount(db.JiraAccount{CloudID: "c2", SiteURL: "https://two.atlassian.net"})
	require.NoError(t, err)
	_, err = ResolveJiraAccount(database, 0)
	assert.Error(t, err, "two enabled accounts need an explicit id")
	a, err = ResolveJiraAccount(database, first)
	require.NoError(t, err)
	assert.Equal(t, first, a.ID)
}
