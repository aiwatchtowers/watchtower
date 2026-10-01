package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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
	// onCreate runs after the request is recorded and before CreateIssue
	// returns — the seam a test needs to break a table the executor writes
	// AFTER the Jira call has already left the machine.
	onCreate func()
	// searched records each JQL query; found/searchErr answer it.
	searched  []string
	found     []jira.Issue
	searchErr error
}

func (f *fakeJira) SearchIssues(_ context.Context, jql string, _ int, _ string) (*jira.SearchResult, error) {
	f.searched = append(f.searched, jql)
	if f.searchErr != nil {
		return nil, f.searchErr
	}
	return &jira.SearchResult{Issues: f.found, IsLast: true}, nil
}

func (f *fakeJira) CreateIssue(_ context.Context, req jira.CreateIssueRequest) (jira.CreatedIssue, error) {
	f.created = append(f.created, req)
	if f.onCreate != nil {
		f.onCreate()
	}
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

// The revoked marking is a side write on the auth-revoked path (spec §12). It
// has no logger to fall back on, so its failure rides the error it accompanies
// instead of leaving the owner with an account that looks fine.
func TestCreateJiraIssue_RevokedRecordingFailureRidesTheError(t *testing.T) {
	database := openDB(t)
	seedJira(t, database)
	fake := &fakeJira{createErr: jira.ErrAuthRevoked}
	fake.onCreate = func() {
		_, derr := database.Exec(`DROP TABLE jira_accounts`)
		require.NoError(t, derr)
	}
	tool := NewCreateJiraIssue(func(db.JiraAccount) (JiraIssueClient, error) { return fake, nil })
	_, err := tool.Execute(context.Background(), database, Call{Args: json.RawMessage(
		`{"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r"}`)})
	require.Error(t, err)
	assert.True(t, errors.Is(err, jira.ErrAuthRevoked), "the primary Jira error must survive the wrap")
	assert.Contains(t, err.Error(), "recording the revoked state failed")
}

// The issue exists in Jira the moment CreateIssue returns, so a failure to
// mirror it locally can never fail the action — but it must not be invisible
// either: the result carries the warning, and the next sync fixes the mirror.
func TestCreateJiraIssue_MirrorFailureWarnsOnASuccessfulResult(t *testing.T) {
	database := openDB(t)
	seedJira(t, database)
	fake := &fakeJira{key: "ABC-7"}
	fake.onCreate = func() {
		_, derr := database.Exec(`DROP TABLE jira_issues`)
		require.NoError(t, derr)
	}
	tool := NewCreateJiraIssue(func(db.JiraAccount) (JiraIssueClient, error) { return fake, nil })
	out, err := tool.Execute(context.Background(), database, Call{Args: json.RawMessage(
		`{"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r"}`)})
	require.NoError(t, err)
	res := out.(map[string]any)
	assert.Equal(t, "ABC-7", res["key"])
	assert.Contains(t, res["warning"], "the local mirror was not updated")
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

// A lookup that FAILS is not a lookup that found nothing: only the miss is the
// model's mistake, and only the miss may come back as a ValidationError the
// model is shown verbatim (review-rules §9, absent-vs-error).
func TestResolveJiraAccount_LookupFailureIsNotAValidationError(t *testing.T) {
	database := openDB(t)
	id := seedJira(t, database)

	var verr *ValidationError
	_, err := ResolveJiraAccount(database, id+999)
	require.ErrorAs(t, err, &verr, "a missing account IS the model's mistake")

	_, derr := database.Exec(`DROP TABLE jira_accounts`)
	require.NoError(t, derr)
	_, err = ResolveJiraAccount(database, id)
	require.Error(t, err)
	assert.False(t, errors.As(err, &verr), "a broken lookup must not be reported as a missing account")
	assert.NotContains(t, err.Error(), "no Jira account")
	assert.Contains(t, err.Error(), "looking up Jira account")
}

// The account an omitted account_id resolves to at propose time is pinned
// into the stored args: a second site connected before the owner approves
// neither fails the apply ("several Jira sites") nor redirects the write, and
// a pinned site disabled in between fails it instead of filing elsewhere.
func TestCreateJiraIssue_ProposePinsTheAccount(t *testing.T) {
	d := openDB(t)
	a1 := seedJira(t, d)
	var used []int64
	fake := &fakeJira{key: "ABC-7"}
	reg := New(d)
	require.NoError(t, reg.Register(NewCreateJiraIssue(func(a db.JiraAccount) (JiraIssueClient, error) {
		used = append(used, a.ID)
		return fake, nil
	})))
	propose := func() int64 {
		t.Helper()
		rc, err := reg.Propose(context.Background(), "create_jira_issue",
			json.RawMessage(`{"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r"}`), Binding{Surface: "main"})
		require.NoError(t, err)
		require.Equal(t, "pending", rc.Status)
		return rc.ActionID
	}
	first, second := propose(), propose()
	row, err := d.GetAgentAction(first)
	require.NoError(t, err)
	assert.JSONEq(t, fmt.Sprintf(`{"account_id":%d,"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r"}`, a1), row.ArgsJSON)

	// A second site with the same project key is connected before approval.
	a2 := seedJiraAccountWithProject(t, d, "c2", "ABC")
	approve(t, d, first)
	applied, err := reg.Apply(context.Background(), first)
	require.NoError(t, err)
	assert.Equal(t, "applied", applied.Status)
	assert.Equal(t, []int64{a1}, used, "the write goes to the site the owner approved")

	// The pinned site is disabled: the apply fails rather than landing on a2.
	require.NoError(t, d.SetJiraAccountEnabled(a1, false))
	approve(t, d, second)
	failed, err := reg.Apply(context.Background(), second)
	require.NoError(t, err)
	assert.Equal(t, "failed", failed.Status)
	assert.Contains(t, failed.Error, "not enabled")
	assert.NotContains(t, used, a2)
}

// Execute checks the project again: a pinned account whose project stopped
// syncing between propose and apply is refused, not written.
func TestCreateJiraIssue_ExecuteRechecksTheProject(t *testing.T) {
	d := openDB(t)
	a1 := seedJira(t, d)
	fake := &fakeJira{key: "ABC-7"}
	tool := NewCreateJiraIssue(func(db.JiraAccount) (JiraIssueClient, error) { return fake, nil })
	_, err := d.Exec(`DELETE FROM jira_sync_state WHERE account_id = ?`, a1)
	require.NoError(t, err)
	_, err = tool.Execute(context.Background(), d, Call{Args: json.RawMessage(
		fmt.Sprintf(`{"account_id":%d,"project_key":"ABC","issue_type":"Task","summary":"s","reason":"r"}`, a1))})
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Empty(t, fake.created)
}

func seedJiraAccountWithProject(t *testing.T, d *db.DB, cloudID, projectKey string) int64 {
	t.Helper()
	id, err := d.CreateJiraAccount(db.JiraAccount{CloudID: cloudID, SiteURL: "https://" + cloudID + ".atlassian.net"})
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO jira_sync_state (account_id, project_key, last_synced_at, issues_synced) VALUES (?, ?, '', 0)`, id, projectKey)
	require.NoError(t, err)
	return id
}

// landedIssue is an issue a failed create attempt may have left in Jira.
func landedIssue(key, summary, issueType string) jira.Issue {
	var issue jira.Issue
	issue.Key = key
	issue.Fields.Summary = summary
	issue.Fields.IssueType.Name = issueType
	return issue
}

// proposeFailedCreate records an approved create_jira_issue and applies it
// once against a failing Jira, leaving the row failed.
func proposeFailedCreate(t *testing.T, d *db.DB, fake *fakeJira) (*Registry, int64) {
	t.Helper()
	reg := New(d)
	require.NoError(t, reg.Register(NewCreateJiraIssue(func(db.JiraAccount) (JiraIssueClient, error) { return fake, nil })))
	rc, err := reg.Propose(context.Background(), "create_jira_issue",
		json.RawMessage(`{"project_key":"ABC","issue_type":"Task","summary":"Fix login","reason":"r"}`), Binding{Surface: "main"})
	require.NoError(t, err)
	approve(t, d, rc.ActionID)
	fake.createErr = errors.New("context deadline exceeded")
	row, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	require.Equal(t, "failed", row.Status)
	assert.Empty(t, fake.searched, "a first attempt does not search")
	fake.createErr = nil
	return reg, rc.ActionID
}

// A retry of a failed create whose request actually landed finds that issue
// and reports it instead of filing a duplicate.
func TestCreateJiraIssue_RetryFindsTheIssueTheFailedAttemptCreated(t *testing.T) {
	d := openDB(t)
	seedJira(t, d)
	fake := &fakeJira{key: "ABC-9"}
	reg, id := proposeFailedCreate(t, d, fake)
	fake.found = []jira.Issue{landedIssue("ABC-5", "Other work", "Task"), landedIssue("ABC-7", "Fix login", "task")}

	row, err := reg.Apply(context.Background(), id)
	require.NoError(t, err)
	require.Equal(t, "applied", row.Status, row.Error)
	assert.Len(t, fake.created, 1, "the request is not sent a second time")
	assert.Contains(t, row.ResultJSON, `"key":"ABC-7"`)
	require.Len(t, fake.searched, 1)
	assert.Contains(t, fake.searched[0], `project = "ABC" AND reporter = currentUser() AND created >= -`)
}

// With nothing landed, the retry creates the issue as usual.
func TestCreateJiraIssue_RetryCreatesWhenNothingLanded(t *testing.T) {
	d := openDB(t)
	seedJira(t, d)
	fake := &fakeJira{key: "ABC-9"}
	reg, id := proposeFailedCreate(t, d, fake)
	fake.found = []jira.Issue{landedIssue("ABC-5", "Fix login", "Bug")}

	row, err := reg.Apply(context.Background(), id)
	require.NoError(t, err)
	require.Equal(t, "applied", row.Status, row.Error)
	assert.Len(t, fake.created, 2)
	assert.Contains(t, row.ResultJSON, `"key":"ABC-9"`)
}

// A retry that cannot tell whether the first attempt landed does not send
// the request again.
func TestCreateJiraIssue_RetryLookupFailureDoesNotResend(t *testing.T) {
	d := openDB(t)
	seedJira(t, d)
	fake := &fakeJira{key: "ABC-9"}
	reg, id := proposeFailedCreate(t, d, fake)
	fake.searchErr = errors.New("503")

	row, err := reg.Apply(context.Background(), id)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Contains(t, row.Error, "checking whether the failed attempt created the issue")
	assert.Len(t, fake.created, 1)
}
