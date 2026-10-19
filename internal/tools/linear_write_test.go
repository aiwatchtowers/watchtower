package tools

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/linear"
)

// fakeLinearWriter records every call; the live lists answer the name
// resolution's refetch on a mirror miss.
type fakeLinearWriter struct {
	states     []linear.WorkflowState
	labels     []linear.Label
	users      []linear.User
	writeErr   error
	refreshErr error

	stateFetches int
	userFetches  int
	creates      []linear.IssueCreateInput
	updates      []linear.IssueUpdateInput
	updatedIDs   []string
	comments     []string
	refreshed    []string
	// landed holds issues Linear already has, by client id (FetchIssueRef).
	landed    map[string]linear.IssueRef
	lookupErr error
	lookups   []string
}

func (f *fakeLinearWriter) calls() int {
	return f.stateFetches + f.userFetches + len(f.creates) + len(f.updates) + len(f.comments) + len(f.refreshed) + len(f.lookups)
}

func (f *fakeLinearWriter) FetchIssueRef(_ context.Context, id string) (linear.IssueRef, bool, error) {
	f.lookups = append(f.lookups, id)
	if f.lookupErr != nil {
		return linear.IssueRef{}, false, f.lookupErr
	}
	ref, ok := f.landed[id]
	return ref, ok, nil
}

func (f *fakeLinearWriter) FetchTeamStates(context.Context, string) ([]linear.WorkflowState, error) {
	f.stateFetches++
	return f.states, nil
}

func (f *fakeLinearWriter) FetchLabels(context.Context, string) ([]linear.Label, error) {
	return f.labels, nil
}

func (f *fakeLinearWriter) FetchUsers(context.Context) ([]linear.User, error) {
	f.userFetches++
	return f.users, nil
}

func (f *fakeLinearWriter) CreateIssue(_ context.Context, in linear.IssueCreateInput) (linear.IssueRef, error) {
	f.creates = append(f.creates, in)
	if f.writeErr != nil {
		return linear.IssueRef{}, f.writeErr
	}
	return linear.IssueRef{ID: "new-id", Identifier: "ENG-99", URL: "https://linear.app/acme/issue/ENG-99"}, nil
}

func (f *fakeLinearWriter) UpdateIssue(_ context.Context, issueID string, in linear.IssueUpdateInput) error {
	f.updatedIDs = append(f.updatedIDs, issueID)
	f.updates = append(f.updates, in)
	return f.writeErr
}

func (f *fakeLinearWriter) CreateComment(_ context.Context, _, body string) (string, error) {
	f.comments = append(f.comments, body)
	if f.writeErr != nil {
		return "", f.writeErr
	}
	return "comment-1", nil
}

func (f *fakeLinearWriter) RefreshIssue(_ context.Context, issueID string) error {
	f.refreshed = append(f.refreshed, issueID)
	return f.refreshErr
}

func linearWriteFactory(f *fakeLinearWriter) LinearWriteClientFactory {
	return func(db.LinearAccount) (LinearWriteClient, error) { return f, nil }
}

// seedLinearWorkspace connects one account (owner u-owner) with team ENG,
// its states and labels, two mapped users and the issue ENG-7.
func seedLinearWorkspace(t *testing.T, d *db.DB) int64 {
	t.Helper()
	acct := seedLinearAccount(t, d, "acme", "u-owner")
	require.NoError(t, d.UpsertLinearTeams(acct, []db.LinearTeam{
		{ID: "team-ENG", Key: "ENG", Name: "Engineering"}, {ID: "team-OPS", Key: "OPS", Name: "Ops"},
	}, map[string]bool{"team-ENG": true}))
	require.NoError(t, d.ReplaceLinearTeamStates(acct, "team-ENG", []db.LinearWorkflowState{
		{ID: "st-todo", Name: "Todo", Type: "unstarted", Position: 1},
		{ID: "st-review", Name: "In Review", Type: "started", Position: 3},
		{ID: "st-progress", Name: "In Progress", Type: "started", Position: 2},
		{ID: "st-done", Name: "Done", Type: "completed", Position: 4},
	}))
	require.NoError(t, d.ReplaceLinearLabels(acct, "team-ENG", []db.LinearLabel{
		{ID: "lb-bug", Name: "Bug"}, {ID: "lb-backend", Name: "backend"},
	}))
	require.NoError(t, d.ReplaceLinearLabels(acct, "", []db.LinearLabel{{ID: "lb-urgent", Name: "Customer"}}))
	require.NoError(t, d.UpsertLinearUsers([]db.LinearUser{
		{ID: "u-ann", Email: "ann@example.com", DisplayName: "ann"},
		{ID: "u-sam1", Email: "sam1@example.com", DisplayName: "sam"},
		{ID: "u-sam2", Email: "sam2@example.com", DisplayName: "sam"},
	}))
	seedLinearIssue(t, d, acct, "ENG-7", "unstarted", "2026-10-18T08:00:00Z", nil)
	return acct
}

func linearNormalizedArgs(t *testing.T, raw json.RawMessage) map[string]any {
	t.Helper()
	var m map[string]any
	require.NoError(t, json.Unmarshal(raw, &m))
	return m
}

func TestLinearWriteTools_ExternalOnMainTargetAutomation(t *testing.T) {
	reg := New(openDB(t))
	names := []string{"create_linear_issue", "add_linear_comment", "transition_linear_issue", "assign_linear_issue", "update_linear_issue"}
	ts := LinearWriteTools(linearWriteFactory(&fakeLinearWriter{}))
	require.Len(t, ts, len(names))
	for i, tool := range ts {
		assert.Equal(t, names[i], tool.Name)
		assert.Equal(t, AccessWrite, tool.Access)
		assert.True(t, tool.External, "%s leaves the machine", tool.Name)
		want := []string{"main", "target", AutomationSurface}
		if tool.Name == "create_linear_issue" {
			// The create alone answers an issue reaction, like create_jira_issue.
			want = []string{"main", "target", "reaction", AutomationSurface}
		}
		assert.Equal(t, want, tool.Surfaces)
		assert.Contains(t, tool.InputSchema.Required, "reason")
		assert.Contains(t, tool.InputSchema.Properties, "account_id")
		require.NoError(t, reg.Register(tool))
		assert.ErrorIs(t, reg.SetTrust(tool.Name, "main", TrustExecute), ErrExternalExecute)
	}
}

func TestCreateLinearIssue_PinsAndCreates(t *testing.T) {
	d := openDB(t)
	acct := seedLinearWorkspace(t, d)
	fake := &fakeLinearWriter{}
	tool := NewCreateLinearIssue(linearWriteFactory(fake))
	ctx := context.Background()

	raw := json.RawMessage(`{"team":"eng","title":"Login fails","description":"**steps**","labels":["bug","Customer"],` +
		`"priority":"high","assignee":"me","state":"in progress","reason":"r","label_ids":["forged"],"priority_value":1}`)
	require.NoError(t, tool.Validate(ctx, d, raw))
	pinned := normalized(t, tool, d, raw)
	m := linearNormalizedArgs(t, pinned)
	assert.EqualValues(t, acct, m["account_id"])
	assert.Equal(t, "team-ENG", m["team_id"])
	assert.Equal(t, []any{"lb-bug", "lb-urgent"}, m["label_ids"], "resolved fresh; a model-supplied value is discarded")
	assert.EqualValues(t, 2, m["priority_value"])
	assert.Equal(t, "u-owner", m["assignee_id"])
	assert.Equal(t, "st-progress", m["state_id"])

	out, err := tool.Execute(ctx, d, Call{Args: pinned})
	require.NoError(t, err)
	require.Len(t, fake.creates, 1)
	in := fake.creates[0]
	assert.Equal(t, "team-ENG", in.TeamID)
	assert.Equal(t, "Login fails", in.Title)
	assert.Equal(t, "**steps**", in.Description)
	assert.Equal(t, []string{"lb-bug", "lb-urgent"}, in.LabelIDs)
	require.NotNil(t, in.Priority)
	assert.Equal(t, 2, *in.Priority)
	assert.Equal(t, "u-owner", in.AssigneeID)
	assert.Equal(t, "st-progress", in.StateID)
	res := out.(map[string]any)
	assert.Equal(t, "ENG-99", res["key"])
	assert.Equal(t, "https://linear.app/acme/issue/ENG-99", res["url"])
	assert.Equal(t, []string{"new-id"}, fake.refreshed, "the new issue is pulled into the mirror")
	assert.NotContains(t, res, "warning")

	// No priority: priority_value is pinned to null, whatever the model sent.
	m = linearNormalizedArgs(t, normalized(t, tool, d, json.RawMessage(`{"team":"ENG","title":"x","reason":"r","priority_value":4}`)))
	assert.Nil(t, m["priority_value"])

	// The mirror misses, so the labels are refetched once; the live list is
	// what the refusal names.
	fake.labels = []linear.Label{{ID: "lb-bug", Name: "Bug", TeamID: "team-ENG"}, {ID: "lb-urgent", Name: "Customer"}}
	msg := verr(t, tool.Validate(ctx, d, json.RawMessage(`{"team":"ENG","title":"x","labels":["nope"],"reason":"r"}`)))
	assert.Contains(t, msg, "nope")
	assert.Contains(t, msg, "Bug")
	assert.Contains(t, msg, "Customer", "the miss lists the team's and the workspace's labels")

	msg = verr(t, tool.Validate(ctx, d, json.RawMessage(`{"team":"XYZ","title":"x","reason":"r"}`)))
	assert.Contains(t, msg, "ENG")
	assert.Contains(t, msg, "OPS")
	verr(t, tool.Validate(ctx, d, json.RawMessage(`{"team":"ENG","title":"  ","reason":"r"}`)))
	verr(t, tool.Validate(ctx, d, json.RawMessage(`{"team":"ENG","title":"x","priority":"blocker","reason":"r"}`)))
}

func TestCreateLinearIssue_PinsFreshIssueUUID(t *testing.T) {
	d := openDB(t)
	seedLinearWorkspace(t, d)
	tool := NewCreateLinearIssue(linearWriteFactory(&fakeLinearWriter{}))
	raw := json.RawMessage(`{"team":"ENG","title":"x","reason":"r","issue_uuid":"forged"}`)
	first := linearNormalizedArgs(t, normalized(t, tool, d, raw))["issue_uuid"]
	second := linearNormalizedArgs(t, normalized(t, tool, d, raw))["issue_uuid"]
	require.IsType(t, "", first)
	assert.NotEqual(t, "forged", first, "a model-supplied id is overwritten")
	assert.Regexp(t, `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`, first)
	assert.NotEqual(t, first, second, "one id per proposal")
}

func TestCreateLinearIssue_RetryFindsTheLandedIssue(t *testing.T) {
	d := openDB(t)
	seedLinearWorkspace(t, d)
	fake := &fakeLinearWriter{}
	tool := NewCreateLinearIssue(linearWriteFactory(fake))
	pinned := normalized(t, tool, d, json.RawMessage(`{"team":"ENG","title":"x","reason":"r"}`))
	id := linearNormalizedArgs(t, pinned)["issue_uuid"].(string)
	fake.landed = map[string]linear.IssueRef{id: {ID: id, Identifier: "ENG-42", URL: "https://linear.app/acme/issue/ENG-42"}}

	out, err := tool.Execute(context.Background(), d, Call{Args: pinned, Retry: true})
	require.NoError(t, err)
	assert.Empty(t, fake.creates, "the landed issue is reported, never created twice")
	assert.Equal(t, []string{id}, fake.lookups)
	res := out.(map[string]any)
	assert.Equal(t, "ENG-42", res["key"])
	assert.Equal(t, "https://linear.app/acme/issue/ENG-42", res["url"])
	assert.Equal(t, true, res["reused"])
	assert.Equal(t, []string{id}, fake.refreshed)
}

func TestCreateLinearIssue_RetryCreatesWhenNothingLanded(t *testing.T) {
	d := openDB(t)
	seedLinearWorkspace(t, d)
	fake := &fakeLinearWriter{}
	tool := NewCreateLinearIssue(linearWriteFactory(fake))
	pinned := normalized(t, tool, d, json.RawMessage(`{"team":"ENG","title":"x","reason":"r"}`))
	id := linearNormalizedArgs(t, pinned)["issue_uuid"].(string)

	out, err := tool.Execute(context.Background(), d, Call{Args: pinned, Retry: true})
	require.NoError(t, err)
	require.Len(t, fake.creates, 1)
	assert.Equal(t, id, fake.creates[0].ID, "created under the pinned id")
	assert.NotContains(t, out.(map[string]any), "reused")

	// A first attempt makes no lookup.
	fake.lookups = nil
	_, err = tool.Execute(context.Background(), d, Call{Args: pinned})
	require.NoError(t, err)
	assert.Empty(t, fake.lookups)
	assert.Equal(t, id, fake.creates[1].ID)
}

func TestCreateLinearIssue_RetryLookupFailureDoesNotCreate(t *testing.T) {
	d := openDB(t)
	seedLinearWorkspace(t, d)
	fake := &fakeLinearWriter{lookupErr: errors.New("linear graphql: boom")}
	tool := NewCreateLinearIssue(linearWriteFactory(fake))
	pinned := normalized(t, tool, d, json.RawMessage(`{"team":"ENG","title":"x","reason":"r"}`))
	_, err := tool.Execute(context.Background(), d, Call{Args: pinned, Retry: true})
	require.ErrorContains(t, err, "boom")
	assert.Empty(t, fake.creates, "cannot tell whether it landed: never re-send")
}

func TestAddLinearComment_BodyRules(t *testing.T) {
	d := openDB(t)
	tool := NewAddLinearComment(linearWriteFactory(&fakeLinearWriter{}))
	ctx := context.Background()
	assert.Contains(t, verr(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ENG-7","body":"hi","reason":"r"}`))), "linear add")

	seedLinearWorkspace(t, d)
	require.NoError(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"eng-7","body":"hi","reason":"r"}`)))
	for name, raw := range map[string]string{
		"empty body":    `{"key":"ENG-7","body":"  ","reason":"r"}`,
		"long body":     `{"key":"ENG-7","body":"` + strings.Repeat("é", 32001) + `","reason":"r"}`,
		"bad key":       `{"key":"ENG7","body":"hi","reason":"r"}`,
		"unknown issue": `{"key":"ENG-404","body":"hi","reason":"r"}`,
		"unknown field": `{"key":"ENG-7","body":"hi","reason":"r","visibility":"x"}`,
	} {
		t.Run(name, func(t *testing.T) { verr(t, tool.Validate(ctx, d, json.RawMessage(raw))) })
	}
	require.NoError(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ENG-7","body":"`+strings.Repeat("é", 32000)+`","reason":"r"}`)))
}

// The 32000-rune cap is checked on the trimmed body, so the trimmed body is
// the one sent.
func TestAddLinearComment_SendsTrimmedBody(t *testing.T) {
	d := openDB(t)
	seedLinearWorkspace(t, d)
	fake := &fakeLinearWriter{}
	tool := NewAddLinearComment(linearWriteFactory(fake))
	padded := "  " + strings.Repeat("é", 32000) + " \n"
	raw, err := json.Marshal(map[string]string{"key": "ENG-7", "body": padded, "reason": "r"})
	require.NoError(t, err)
	require.NoError(t, tool.Validate(context.Background(), d, raw))
	pinned := normalized(t, tool, d, raw)

	_, err = tool.Execute(context.Background(), d, Call{Args: pinned})
	require.NoError(t, err)
	assert.Equal(t, []string{strings.Repeat("é", 32000)}, fake.comments)
}

func TestAddLinearComment_RefreshesMirror(t *testing.T) {
	d := openDB(t)
	acct := seedLinearWorkspace(t, d)
	fake := &fakeLinearWriter{}
	tool := NewAddLinearComment(linearWriteFactory(fake))
	pinned := normalized(t, tool, d, json.RawMessage(`{"key":"eng-7","body":"Ship it.","reason":"r"}`))
	m := linearNormalizedArgs(t, pinned)
	assert.EqualValues(t, acct, m["account_id"])
	assert.Equal(t, "ENG-7", m["key"])
	assert.Equal(t, "id-ENG-7", m["issue_id"])

	out, err := tool.Execute(context.Background(), d, Call{Args: pinned})
	require.NoError(t, err)
	assert.Equal(t, []string{"Ship it."}, fake.comments)
	assert.Equal(t, []string{"id-ENG-7"}, fake.refreshed)
	res := out.(map[string]any)
	assert.Equal(t, "ENG-7", res["key"])
	assert.Equal(t, "https://linear.app/acme/issue/ENG-7", res["url"])
	assert.NotContains(t, res, "warning")

	fake.refreshErr = errors.New("refreshing linear issue id-ENG-7: not found")
	out, err = tool.Execute(context.Background(), d, Call{Args: pinned})
	require.NoError(t, err, "the comment was posted; a failed refresh never fails the write")
	assert.Contains(t, out.(map[string]any)["warning"], "next sync")
}

func TestTransitionLinearIssue_ByNameAndType(t *testing.T) {
	d := openDB(t)
	seedLinearWorkspace(t, d)
	fake := &fakeLinearWriter{}
	tool := NewTransitionLinearIssue(linearWriteFactory(fake))
	ctx := context.Background()

	pinned := normalized(t, tool, d, json.RawMessage(`{"key":"ENG-7","state":"in review","reason":"r"}`))
	assert.Equal(t, "st-review", linearNormalizedArgs(t, pinned)["state_id"])
	out, err := tool.Execute(ctx, d, Call{Args: pinned})
	require.NoError(t, err)
	require.Len(t, fake.updates, 1)
	assert.Equal(t, "id-ENG-7", fake.updatedIDs[0])
	require.NotNil(t, fake.updates[0].StateID)
	assert.Equal(t, "st-review", *fake.updates[0].StateID)
	assert.Equal(t, "ENG-7 → In Review", out.(map[string]any)["label"])

	pinned = normalized(t, tool, d, json.RawMessage(`{"key":"ENG-7","state_type":"started","reason":"r"}`))
	assert.Equal(t, "st-progress", linearNormalizedArgs(t, pinned)["state_id"], "the lowest-position started state")

	verr(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ENG-7","state":"Done","state_type":"completed","reason":"r"}`)))
	verr(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ENG-7","reason":"r"}`)))
	verr(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ENG-7","state_type":"finished","reason":"r"}`)))
}

func TestResolveLinearState_LiveRefetchOnMiss(t *testing.T) {
	d := openDB(t)
	acct := seedLinearWorkspace(t, d)
	account, err := d.GetLinearAccount(acct)
	require.NoError(t, err)
	fake := &fakeLinearWriter{states: []linear.WorkflowState{
		{ID: "st-todo", Name: "Todo", Type: "unstarted", Position: 1},
		{ID: "st-qa", Name: "QA", Type: "started", Position: 5},
	}}
	ctx := context.Background()

	got, err := resolveLinearState(ctx, d, fake, account, "team-ENG", "todo", "")
	require.NoError(t, err)
	assert.Equal(t, "st-todo", got.ID)
	assert.Zero(t, fake.stateFetches, "a mirror hit makes no live call")

	got, err = resolveLinearState(ctx, d, fake, account, "team-ENG", "qa", "")
	require.NoError(t, err)
	assert.Equal(t, "st-qa", got.ID)
	assert.Equal(t, 1, fake.stateFetches)

	_, err = resolveLinearState(ctx, d, fake, account, "team-ENG", "Shipped", "")
	msg := verr(t, err)
	assert.Contains(t, msg, "Shipped")
	assert.Contains(t, msg, "QA")
	assert.Contains(t, msg, "Todo")
}

func TestAssignLinearIssue_MeNoneAmbiguous(t *testing.T) {
	d := openDB(t)
	seedLinearWorkspace(t, d)
	fake := &fakeLinearWriter{users: []linear.User{
		{ID: "u-kim", Name: "Kim Lee", DisplayName: "kim", Email: "kim@example.com"},
	}}
	tool := NewAssignLinearIssue(linearWriteFactory(fake))
	ctx := context.Background()

	assignee := func(raw string) (any, map[string]any) {
		pinned := normalized(t, tool, d, json.RawMessage(raw))
		_, err := tool.Execute(ctx, d, Call{Args: pinned})
		require.NoError(t, err)
		return linearNormalizedArgs(t, pinned)["assignee_id"], linearNormalizedArgs(t, pinned)
	}
	id, _ := assignee(`{"key":"ENG-7","assignee":"me","reason":"r"}`)
	assert.Equal(t, "u-owner", id)
	require.NotNil(t, fake.updates[0].AssigneeID)
	assert.Equal(t, "u-owner", *fake.updates[0].AssigneeID)

	id, _ = assignee(`{"key":"ENG-7","assignee":"none","reason":"r"}`)
	assert.Equal(t, "", id)
	require.NotNil(t, fake.updates[1].AssigneeID, "none unassigns: a pointer to empty")
	assert.Equal(t, "", *fake.updates[1].AssigneeID)

	id, _ = assignee(`{"key":"ENG-7","assignee":"ANN@example.com","reason":"r"}`)
	assert.Equal(t, "u-ann", id)
	assert.Zero(t, fake.userFetches, "a user-map hit makes no live call")

	id, _ = assignee(`{"key":"ENG-7","assignee":"Kim Lee","reason":"r"}`)
	assert.Equal(t, "u-kim", id)
	assert.Equal(t, 1, fake.userFetches, "a miss fetches the workspace users once")

	msg := verr(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ENG-7","assignee":"sam","reason":"r"}`)))
	assert.Contains(t, msg, "sam1@example.com")
	assert.Contains(t, msg, "sam2@example.com")
	verr(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ENG-7","assignee":"nobody-here","reason":"r"}`)))
	verr(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ENG-7","assignee":" ","reason":"r"}`)))
}

// With several Linear workspaces the account-less linear_user_map could name
// another workspace's user: it is skipped, and the issue's own account's
// client answers.
func TestAssignLinearIssue_SeveralAccountsSkipsUserMap(t *testing.T) {
	d := openDB(t)
	acct := seedLinearWorkspace(t, d) // the map has ann@example.com → u-ann
	other := seedLinearAccount(t, d, "beta", "")
	own := &fakeLinearWriter{users: []linear.User{{ID: "u-ann-acme", DisplayName: "ann", Email: "ann@example.com"}}}
	foreign := &fakeLinearWriter{users: []linear.User{{ID: "u-ann-beta", DisplayName: "ann", Email: "ann@example.com"}}}
	factory := func(a db.LinearAccount) (LinearWriteClient, error) {
		switch a.ID {
		case acct:
			return own, nil
		case other:
			return foreign, nil
		}
		return nil, errors.New("unexpected account")
	}
	m := linearNormalizedArgs(t, normalized(t, NewAssignLinearIssue(factory), d,
		json.RawMessage(`{"key":"ENG-7","assignee":"ann@example.com","reason":"r"}`)))
	assert.Equal(t, "u-ann-acme", m["assignee_id"], "the live user of the issue's workspace, not the map's u-ann")
	assert.Equal(t, 1, own.userFetches)
	assert.Zero(t, foreign.calls())
}

func TestUpdateLinearIssue_Rules(t *testing.T) {
	d := openDB(t)
	seedLinearWorkspace(t, d)
	fake := &fakeLinearWriter{}
	tool := NewUpdateLinearIssue(linearWriteFactory(fake))
	ctx := context.Background()

	for name, raw := range map[string]string{
		"no fields":          `{"key":"ENG-7","reason":"r"}`,
		"add and remove":     `{"key":"ENG-7","labels_add":["Bug"],"labels_remove":["bug"],"reason":"r"}`,
		"fractional":         `{"key":"ENG-7","estimate":2.5,"reason":"r"}`,
		"bad due date":       `{"key":"ENG-7","due_date":"next week","reason":"r"}`,
		"unknown label":      `{"key":"ENG-7","labels_add":["nope"],"reason":"r"}`,
		"unknown priority":   `{"key":"ENG-7","priority":"p0","reason":"r"}`,
		"blank title only":   `{"key":"ENG-7","title":"  ","reason":"r"}`,
		"negative estimate":  `{"key":"ENG-7","estimate":-1,"reason":"r"}`,
		"labels blank names": `{"key":"ENG-7","labels_add":[" "],"reason":"r"}`,
	} {
		t.Run(name, func(t *testing.T) { verr(t, tool.Validate(ctx, d, json.RawMessage(raw))) })
	}

	pinned := normalized(t, tool, d, json.RawMessage(`{"key":"ENG-7","priority":"normal","estimate":3,`+
		`"labels_add":["bug"],"labels_remove":["backend"],"due_date":"2026-11-01","title":"New title","reason":"r"}`))
	m := linearNormalizedArgs(t, pinned)
	assert.EqualValues(t, 3, m["priority_value"])
	assert.Equal(t, []any{"lb-bug"}, m["label_ids_add"])
	assert.Equal(t, []any{"lb-backend"}, m["label_ids_remove"])

	out, err := tool.Execute(ctx, d, Call{Args: pinned})
	require.NoError(t, err)
	require.Len(t, fake.updates, 1)
	u := fake.updates[0]
	require.NotNil(t, u.Priority)
	assert.Equal(t, 3, *u.Priority)
	require.NotNil(t, u.Estimate)
	assert.InDelta(t, 3.0, *u.Estimate, 0)
	require.NotNil(t, u.Title)
	assert.Equal(t, "New title", *u.Title)
	require.NotNil(t, u.DueDate)
	assert.Equal(t, "2026-11-01", *u.DueDate)
	assert.Equal(t, []string{"lb-bug"}, u.AddedLabelIDs)
	assert.Equal(t, []string{"lb-backend"}, u.RemovedLabelIDs)
	assert.Nil(t, u.StateID)
	assert.Nil(t, u.AssigneeID)
	assert.Equal(t, "ENG-7 updated", out.(map[string]any)["label"])
}

func TestLinearWrite_PinnedAccountDisabledAtApply(t *testing.T) {
	d := openDB(t)
	acct := seedLinearWorkspace(t, d)
	fake := &fakeLinearWriter{}
	reg := New(d)
	for _, tool := range LinearWriteTools(linearWriteFactory(fake)) {
		require.NoError(t, reg.Register(tool))
	}
	ctx := context.Background()
	var ids []int64
	for tool, args := range map[string]string{
		"create_linear_issue":     `{"team":"ENG","title":"x","reason":"r"}`,
		"add_linear_comment":      `{"key":"ENG-7","body":"hi","reason":"r"}`,
		"transition_linear_issue": `{"key":"ENG-7","state":"Done","reason":"r"}`,
		"assign_linear_issue":     `{"key":"ENG-7","assignee":"me","reason":"r"}`,
		"update_linear_issue":     `{"key":"ENG-7","title":"y","reason":"r"}`,
	} {
		rc, err := reg.Propose(ctx, tool, json.RawMessage(args), Binding{Surface: "main"})
		require.NoError(t, err, tool)
		ids = append(ids, rc.ActionID)
	}
	before := fake.calls()

	require.NoError(t, d.SetLinearAccountEnabled(acct, false))
	for _, id := range ids {
		approve(t, d, id)
		row, err := reg.Apply(ctx, id)
		require.NoError(t, err)
		assert.Equal(t, "failed", row.Status, row.Tool)
		assert.Contains(t, row.Error, "not enabled", row.Tool)
	}
	assert.Equal(t, before, fake.calls(), "never reached Linear")
}

func TestLinearWrite_RevokedMarksAccount(t *testing.T) {
	d := openDB(t)
	acct := seedLinearWorkspace(t, d)
	fake := &fakeLinearWriter{writeErr: linear.ErrAuthRevoked}
	tool := NewUpdateLinearIssue(linearWriteFactory(fake))
	pinned := normalized(t, tool, d, json.RawMessage(`{"key":"ENG-7","title":"y","reason":"r"}`))
	_, err := tool.Execute(context.Background(), d, Call{Args: pinned})
	assert.ErrorIs(t, err, linear.ErrAuthRevoked)
	account, err := d.GetLinearAccount(acct)
	require.NoError(t, err)
	assert.Equal(t, "revoked", account.Status)
	assert.Empty(t, fake.refreshed, "a failed write refreshes nothing")
}

func TestLinearWrite_ExecuteWithoutPinsRefuses(t *testing.T) {
	d := openDB(t)
	seedLinearWorkspace(t, d)
	fake := &fakeLinearWriter{}
	_, err := NewAddLinearComment(linearWriteFactory(fake)).Execute(context.Background(), d,
		Call{Args: json.RawMessage(`{"key":"ENG-7","body":"hi","reason":"r"}`)})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "re-propose")
	assert.Empty(t, fake.comments)
}

func TestCreateLinearIssue_TeamOnTwoWorkspacesNeedsAccountID(t *testing.T) {
	d := openDB(t)
	seedLinearWorkspace(t, d)
	other := seedLinearAccount(t, d, "beta", "")
	require.NoError(t, d.UpsertLinearTeams(other, []db.LinearTeam{{ID: "team-ENG-2", Key: "ENG", Name: "Eng"}}, nil))
	tool := NewCreateLinearIssue(linearWriteFactory(&fakeLinearWriter{}))
	ctx := context.Background()
	assert.Contains(t, verr(t, tool.Validate(ctx, d, json.RawMessage(`{"team":"ENG","title":"x","reason":"r"}`))), "account_id")

	m := linearNormalizedArgs(t, normalized(t, tool, d,
		json.RawMessage(`{"team":"ENG","title":"x","reason":"r","account_id":`+jsonInt(other)+`}`)))
	assert.Equal(t, "team-ENG-2", m["team_id"])
	// OPS lives only on the first workspace: no account_id needed.
	require.NoError(t, tool.Validate(ctx, d, json.RawMessage(`{"team":"OPS","title":"x","reason":"r"}`)))
}

func jsonInt(v int64) string {
	b, _ := json.Marshal(v)
	return string(b)
}
