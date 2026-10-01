package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// fakeJiraWriter records every write; GetIssue returns the issue the last
// write left behind (status/assignee), so the mirror refresh can be asserted.
type fakeJiraWriter struct {
	transitions []jira.Transition
	users       []jira.User
	writeErr    error
	getErr      error
	status      string
	// statusCategoryKey/resolvedAt track what a real Jira workflow would set
	// alongside status on a transition, so a test can assert the mirror
	// refresh stores the syncer's normalized category and resolved_at
	// (I-1), not just the status name. TransitionIssue keeps them in sync
	// with the matched transition's To.StatusCategory.
	statusCategoryKey string
	resolvedAt        string
	// categoryChangedAt is Jira's statuscategorychangedate, which a
	// transition across categories moves.
	categoryChangedAt string
	assigneeID        string
	assignee          string
	comments          []string
	moved             []string
	assigned          []string
	updates           []jira.IssueUpdate
	searches          []string
	// onWrite runs inside every write call, before it returns — the seam a
	// test needs to break a table the executor touches after the write.
	onWrite func()
}

func (f *fakeJiraWriter) wrote() error {
	if f.onWrite != nil {
		f.onWrite()
	}
	return f.writeErr
}

func (f *fakeJiraWriter) GetIssue(_ context.Context, key string) (jira.Issue, error) {
	if f.getErr != nil {
		return jira.Issue{}, f.getErr
	}
	status := f.status
	if status == "" {
		status = "To Do"
	}
	category := f.statusCategoryKey
	if category == "" {
		category = "indeterminate"
	}
	assignee := `null`
	if f.assigneeID != "" {
		assignee = `{"accountId":"` + f.assigneeID + `","displayName":"` + f.assignee + `"}`
	}
	resolutionDate := `null`
	if f.resolvedAt != "" {
		resolutionDate = `"` + f.resolvedAt + `"`
	}
	categoryChanged := `null`
	if f.categoryChangedAt != "" {
		categoryChanged = `"` + f.categoryChangedAt + `"`
	}
	var issue jira.Issue
	err := json.Unmarshal([]byte(`{"id":"1","key":"`+key+`","fields":{"summary":"Fix login","issuetype":{"name":"Task"},`+
		`"status":{"name":"`+status+`","statusCategory":{"key":"`+category+`"}},"priority":{"name":"High"},`+
		`"labels":["backend"],"duedate":"2026-10-01","assignee":`+assignee+`,"resolutiondate":`+resolutionDate+`,"statuscategorychangedate":`+categoryChanged+`,`+
		`"created":"2026-09-04T10:00:00.000+0000","updated":"2026-09-26T10:00:00.000+0000"}}`), &issue)
	return issue, err
}

func (f *fakeJiraWriter) AddComment(_ context.Context, _, body string) (string, error) {
	f.comments = append(f.comments, body)
	if err := f.wrote(); err != nil {
		return "", err
	}
	return "10042", nil
}

func (f *fakeJiraWriter) GetTransitions(context.Context, string) ([]jira.Transition, error) {
	return f.transitions, f.getErr
}

func (f *fakeJiraWriter) TransitionIssue(_ context.Context, _, id string) error {
	f.moved = append(f.moved, id)
	for _, t := range f.transitions {
		if t.ID == id {
			if t.To.StatusCategory.Key != f.statusCategoryKey {
				f.categoryChangedAt = time.Now().Format("2006-01-02T15:04:05.000-0700")
			}
			f.status, f.statusCategoryKey = t.To.Name, t.To.StatusCategory.Key
			f.resolvedAt = ""
			if f.statusCategoryKey == "done" {
				f.resolvedAt = "2026-09-27T12:00:00.000+0000"
			}
		}
	}
	return f.wrote()
}

func (f *fakeJiraWriter) AssignIssue(_ context.Context, _, accountID string) error {
	f.assigned = append(f.assigned, accountID)
	f.assigneeID, f.assignee = accountID, "Assigned Person"
	return f.wrote()
}

func (f *fakeJiraWriter) UpdateIssue(_ context.Context, _ string, u jira.IssueUpdate) error {
	f.updates = append(f.updates, u)
	return f.wrote()
}

func (f *fakeJiraWriter) SearchUsers(_ context.Context, q string) ([]jira.User, error) {
	f.searches = append(f.searches, q)
	return f.users, nil
}

func writeFactory(f *fakeJiraWriter) JiraWriteClientFactory {
	return func(db.JiraAccount) (JiraWriteClient, error) { return f, nil }
}

func seedIssueRow(t *testing.T, d *db.DB, accountID int64, key string) {
	t.Helper()
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{AccountID: accountID, Key: key, ID: "1", ProjectKey: "ABC",
		Summary: "Old", Status: "To Do", Labels: "[]", Components: "[]", FixVersions: "[]",
		BoardID: 7, SprintName: "Sprint 12", EpicKey: "ABC-1", ReporterDisplayName: "Rita",
		StatusCategoryChangedAt: time.Now().AddDate(0, 0, -30).UTC().Format(time.RFC3339)}))
}

func twoTransitions() []jira.Transition {
	return []jira.Transition{
		{ID: "21", Name: "Start work", To: jira.Status{Name: "In Progress", StatusCategory: jira.StatusCategory{Key: "indeterminate"}}},
		{ID: "31", Name: "Close", To: jira.Status{Name: "Done", StatusCategory: jira.StatusCategory{Key: "done"}}},
	}
}

func verr(t *testing.T, err error) string {
	t.Helper()
	var ve *ValidationError
	require.ErrorAs(t, err, &ve)
	return ve.Msg
}

// normalized runs tool.Normalize the way Propose does before persisting args
// — what a direct-Execute test must feed in to exercise the pinned-value path
// (account_id, and for assign_jira_issue the resolved assignee) instead of
// Execute's own "no Normalize ran" error.
func normalized(t *testing.T, tool *Tool, d *db.DB, raw json.RawMessage) json.RawMessage {
	t.Helper()
	require.NotNil(t, tool.Normalize, "%s has no Normalize", tool.Name)
	out, err := tool.Normalize(context.Background(), d, raw)
	require.NoError(t, err)
	return out
}

func TestJiraWriteTools_ExternalOnMainAndTargetWithReason(t *testing.T) {
	reg := New(openDB(t))
	names := []string{"add_jira_comment", "transition_jira_issue", "assign_jira_issue", "update_jira_issue"}
	tools := JiraWriteTools(writeFactory(&fakeJiraWriter{}))
	require.Len(t, tools, len(names))
	for i, tool := range tools {
		assert.Equal(t, names[i], tool.Name)
		assert.Equal(t, AccessWrite, tool.Access)
		assert.True(t, tool.External, "%s leaves the machine", tool.Name)
		assert.ElementsMatch(t, []string{"main", "target"}, tool.Surfaces)
		assert.Contains(t, tool.InputSchema.Required, "reason")
		assert.Contains(t, tool.InputSchema.Required, "key")
		require.NoError(t, reg.Register(tool))
		// AGENT-03: an external write can never be trusted to execute.
		assert.ErrorIs(t, reg.SetTrust(tool.Name, TrustExecute), ErrExternalExecute)
	}
}

func TestAddJiraComment_ValidateRejectsBadInput(t *testing.T) {
	d := openDB(t)
	tool := NewAddJiraComment(writeFactory(&fakeJiraWriter{}))
	ctx := context.Background()
	assert.Contains(t, verr(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ABC-7","body":"hi","reason":"r"}`))), "no Jira site")

	seedJira(t, d)
	require.NoError(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"abc-7","body":"hi","reason":"r"}`)), "lower-case key is normalized")
	for name, raw := range map[string]string{
		"bad key":       `{"key":"ABC7","body":"hi","reason":"r"}`,
		"empty body":    `{"key":"ABC-7","body":"  ","reason":"r"}`,
		"unknown field": `{"key":"ABC-7","body":"hi","reason":"r","visibility":"x"}`,
	} {
		t.Run(name, func(t *testing.T) { verr(t, tool.Validate(ctx, d, json.RawMessage(raw))) })
	}
}

func TestAddJiraComment_ExecutePostsAndRefreshesMirror(t *testing.T) {
	d := openDB(t)
	accountID := seedJira(t, d)
	seedIssueRow(t, d, accountID, "ABC-7")
	fake := &fakeJiraWriter{}
	out, err := NewAddJiraComment(writeFactory(fake)).Execute(context.Background(), d,
		Call{Args: json.RawMessage(`{"key":"ABC-7","body":"Looks good.\n\nShip it.","reason":"r"}`)})
	require.NoError(t, err)
	assert.Equal(t, []string{"Looks good.\n\nShip it."}, fake.comments)
	res := out.(map[string]any)
	assert.Equal(t, "ABC-7", res["key"])
	assert.Equal(t, "https://acme.atlassian.net/browse/ABC-7?focusedCommentId=10042", res["url"])
	assert.Equal(t, "Comment on ABC-7", res["label"])
	assert.NotContains(t, res, "warning")
}

func TestTransitionJiraIssue_ValidateListsReachableStatuses(t *testing.T) {
	d := openDB(t)
	seedJira(t, d)
	tool := NewTransitionJiraIssue(writeFactory(&fakeJiraWriter{transitions: twoTransitions()}))
	msg := verr(t, tool.Validate(context.Background(), d, json.RawMessage(`{"key":"ABC-7","status":"Review","reason":"r"}`)))
	assert.Contains(t, msg, `"Review"`)
	assert.Contains(t, msg, "In Progress, Done")
	require.NoError(t, tool.Validate(context.Background(), d, json.RawMessage(`{"key":"ABC-7","status":"done","reason":"r"}`)))
}

// A read failure in Validate is not the model's mistake and must not be
// reported as one — nor may Validate mark the account (AGENT-01: validation
// writes nothing).
func TestTransitionJiraIssue_ValidateReadFailureIsPlainErrorAndWritesNothing(t *testing.T) {
	d := openDB(t)
	accountID := seedJira(t, d)
	tool := NewTransitionJiraIssue(writeFactory(&fakeJiraWriter{getErr: jira.ErrAuthRevoked}))
	err := tool.Validate(context.Background(), d, json.RawMessage(`{"key":"ABC-7","status":"Done","reason":"r"}`))
	require.Error(t, err)
	var ve *ValidationError
	assert.False(t, errors.As(err, &ve))
	acct, _ := d.GetJiraAccount(accountID)
	assert.NotEqual(t, "revoked", acct.Status)
}

func TestTransitionJiraIssue_ExecuteMovesByStatusOrTransitionName(t *testing.T) {
	d := openDB(t)
	accountID := seedJira(t, d)
	seedIssueRow(t, d, accountID, "ABC-7")
	fake := &fakeJiraWriter{transitions: twoTransitions()}
	tool := NewTransitionJiraIssue(writeFactory(fake))

	out, err := tool.Execute(context.Background(), d, Call{Args: json.RawMessage(`{"key":"ABC-7","status":"DONE","reason":"r"}`)})
	require.NoError(t, err)
	assert.Equal(t, "ABC-7 → Done", out.(map[string]any)["label"])

	// I-1: a transition to Done sets both the normalized "done" category and
	// resolved_at (the same fields the syncer writes), not just the status
	// name — the dashboards and memory's resolved check key on these.
	done, err := d.GetJiraIssue(accountID, "ABC-7")
	require.NoError(t, err)
	assert.Equal(t, "done", done.StatusCategory)
	assert.Equal(t, "2026-09-27T12:00:00.000+0000", done.ResolvedAt)

	_, err = tool.Execute(context.Background(), d, Call{Args: json.RawMessage(`{"key":"ABC-7","status":"start work","reason":"r"}`)})
	require.NoError(t, err)
	assert.Equal(t, []string{"31", "21"}, fake.moved)

	row, err := d.GetJiraIssue(accountID, "ABC-7")
	require.NoError(t, err)
	assert.Equal(t, "In Progress", row.Status, "mirror refreshed from the fetched issue")
	assert.Equal(t, "in_progress", row.StatusCategory, "normalized, not the raw Jira key")
	assert.Empty(t, row.ResolvedAt, "reopening clears a stale resolved_at")
	wantChanged, _ := jira.NormalizeTimestamp(fake.categoryChangedAt)
	assert.Equal(t, wantChanged, row.StatusCategoryChangedAt,
		"a category move refreshes status_category_changed_at, normalized like the syncer's")
	assert.NotEmpty(t, row.StatusCategoryChangedAt)
}

func TestTransitionJiraIssue_ExecuteFailsWhenStatusNoLongerReachable(t *testing.T) {
	d := openDB(t)
	seedJira(t, d)
	fake := &fakeJiraWriter{transitions: twoTransitions()[:1]}
	_, err := NewTransitionJiraIssue(writeFactory(fake)).Execute(context.Background(), d,
		Call{Args: json.RawMessage(`{"key":"ABC-7","status":"Done","reason":"r"}`)})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "In Progress")
	assert.Empty(t, fake.moved)
}

func TestAssignJiraIssue_MeUsesTheSiteOwnerThenTheOwnerIdentity(t *testing.T) {
	d := openDB(t)
	accountID := seedJira(t, d)
	tool := NewAssignJiraIssue(writeFactory(&fakeJiraWriter{}))
	ctx := context.Background()
	args := json.RawMessage(`{"key":"ABC-7","assignee":"Me","reason":"r"}`)

	assert.Contains(t, verr(t, tool.Validate(ctx, d, args)), "jira login --account")

	// Another site recorded the owner's Atlassian id (global across sites).
	other, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c2", SiteURL: "https://two.atlassian.net"})
	require.NoError(t, err)
	require.NoError(t, d.SetJiraAccountOwner(other, "acc-owner", "me@example.com", "Owner"))
	seedIssueRow(t, d, accountID, "ABC-7") // pins the key to the first site
	fake := &fakeJiraWriter{}
	tool2 := NewAssignJiraIssue(writeFactory(fake))
	_, err = tool2.Execute(ctx, d, Call{Args: normalized(t, tool2, d, args)})
	require.NoError(t, err)
	assert.Equal(t, []string{"acc-owner"}, fake.assigned)

	require.NoError(t, d.SetJiraAccountOwner(accountID, "acc-site-owner", "me@example.com", "Owner"))
	_, err = tool2.Execute(ctx, d, Call{Args: normalized(t, tool2, d, args)})
	require.NoError(t, err)
	assert.Equal(t, "acc-site-owner", fake.assigned[1], "the site's own recorded owner wins")
}

func TestAssignJiraIssue_ResolvesFromUserMapThenSearch(t *testing.T) {
	d := openDB(t)
	accountID := seedJira(t, d)
	seedIssueRow(t, d, accountID, "ABC-7")
	require.NoError(t, d.UpsertJiraUserMap(db.JiraUserMap{JiraAccountID: "acc-jane", Email: "jane@example.com", DisplayName: "Jane Doe"}))
	fake := &fakeJiraWriter{users: []jira.User{
		{AccountID: "acc-bot", DisplayName: "Bob Bot", Active: true, AccountType: "app"},
		{AccountID: "acc-bob", DisplayName: "Bob Stone", Active: true, AccountType: "atlassian"},
	}}
	tool := NewAssignJiraIssue(writeFactory(fake))
	ctx := context.Background()

	for _, who := range []string{"JANE@example.com", "jane doe"} {
		raw := json.RawMessage(`{"key":"ABC-7","assignee":"` + who + `","reason":"r"}`)
		out, err := tool.Execute(ctx, d, Call{Args: normalized(t, tool, d, raw)})
		require.NoError(t, err)
		assert.Equal(t, "acc-jane", fake.assigned[len(fake.assigned)-1])
		assert.Equal(t, "ABC-7 → Jane Doe", out.(map[string]any)["label"])
	}
	assert.Empty(t, fake.searches, "a local hit never calls Jira")

	raw := json.RawMessage(`{"key":"ABC-7","assignee":"bob","reason":"r"}`)
	_, err := tool.Execute(ctx, d, Call{Args: normalized(t, tool, d, raw)})
	require.NoError(t, err)
	assert.Equal(t, "acc-bob", fake.assigned[len(fake.assigned)-1], "the app account is ignored; one person left")
	assert.Equal(t, []string{"bob"}, fake.searches)
}

func TestAssignJiraIssue_AmbiguousOrUnknownIsValidationError(t *testing.T) {
	d := openDB(t)
	seedJira(t, d)
	require.NoError(t, d.UpsertJiraUserMap(db.JiraUserMap{JiraAccountID: "a1", Email: "a1@x.io", DisplayName: "Alex"}))
	require.NoError(t, d.UpsertJiraUserMap(db.JiraUserMap{JiraAccountID: "a2", Email: "a2@x.io", DisplayName: "alex"}))
	ctx := context.Background()

	msg := verr(t, NewAssignJiraIssue(writeFactory(&fakeJiraWriter{})).Validate(ctx, d,
		json.RawMessage(`{"key":"ABC-7","assignee":"Alex","reason":"r"}`)))
	assert.Contains(t, msg, "several Jira users")
	assert.Contains(t, msg, "a2@x.io")

	msg = verr(t, NewAssignJiraIssue(writeFactory(&fakeJiraWriter{})).Validate(ctx, d,
		json.RawMessage(`{"key":"ABC-7","assignee":"Nobody Here","reason":"r"}`)))
	assert.Contains(t, msg, "no active Jira user")

	two := &fakeJiraWriter{users: []jira.User{
		{AccountID: "s1", DisplayName: "Sam One", Active: true, AccountType: "atlassian"},
		{AccountID: "s2", DisplayName: "Sam Two", Active: true, AccountType: "atlassian"},
	}}
	msg = verr(t, NewAssignJiraIssue(writeFactory(two)).Validate(ctx, d,
		json.RawMessage(`{"key":"ABC-7","assignee":"sam","reason":"r"}`)))
	assert.Contains(t, msg, "Sam One")
	assert.Contains(t, msg, "Sam Two")
}

func TestUpdateJiraIssue_ValidateNeedsAFieldAndWellFormedValues(t *testing.T) {
	d := openDB(t)
	seedJira(t, d)
	tool := NewUpdateJiraIssue(writeFactory(&fakeJiraWriter{}))
	ctx := context.Background()
	assert.Contains(t, verr(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ABC-7","reason":"r"}`))), "at least one")
	assert.Contains(t, verr(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ABC-7","due_date":"next friday","reason":"r"}`))), "YYYY-MM-DD")
	assert.Contains(t, verr(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ABC-7","labels_add":["two words"],"reason":"r"}`))), "spaces")
	require.NoError(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ABC-7","priority":"High","reason":"r"}`)))
}

func TestUpdateJiraIssue_ExecuteSendsOnlyTheGivenFields(t *testing.T) {
	d := openDB(t)
	seedJira(t, d)
	fake := &fakeJiraWriter{}
	out, err := NewUpdateJiraIssue(writeFactory(fake)).Execute(context.Background(), d, Call{Args: json.RawMessage(
		`{"key":"ABC-7","summary":" New title ","labels_add":["backend"],"labels_remove":["stale"],"due_date":"2026-10-01","reason":"r"}`)})
	require.NoError(t, err)
	require.Len(t, fake.updates, 1)
	u := fake.updates[0]
	require.NotNil(t, u.Summary)
	assert.Equal(t, "New title", *u.Summary)
	assert.Nil(t, u.Priority)
	assert.Equal(t, "2026-10-01", *u.DueDate)
	assert.Equal(t, []string{"backend"}, u.LabelsAdd)
	assert.Equal(t, []string{"stale"}, u.LabelsRemove)
	assert.Equal(t, "ABC-7 updated", out.(map[string]any)["label"])
}

func TestJiraIssueWrite_KeyOnTwoSitesNeedsAccountID(t *testing.T) {
	d := openDB(t)
	a1 := seedJira(t, d)
	a2, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c2", SiteURL: "https://two.atlassian.net"})
	require.NoError(t, err)
	seedIssueRow(t, d, a1, "ABC-7")
	seedIssueRow(t, d, a2, "ABC-7")
	tool := NewAddJiraComment(writeFactory(&fakeJiraWriter{}))
	assert.Contains(t, verr(t, tool.Validate(context.Background(), d,
		json.RawMessage(`{"key":"ABC-7","body":"x","reason":"r"}`))), "account_id")
	require.NoError(t, tool.Validate(context.Background(), d,
		json.RawMessage(fmt.Sprintf(`{"account_id":%d,"key":"ABC-7","body":"x","reason":"r"}`, a2))))
}

// The refresh overlays what the write changed onto the stored row: the
// syncer-owned columns (board, sprint, epic, reporter) survive until the
// next sync instead of being blanked by a partial row.
func TestJiraIssueWrite_MirrorRefreshKeepsSyncerColumns(t *testing.T) {
	d := openDB(t)
	accountID := seedJira(t, d)
	seedIssueRow(t, d, accountID, "ABC-7")
	require.NoError(t, d.UpsertJiraUserMap(db.JiraUserMap{JiraAccountID: "acc-jane", SlackUserID: "1:UJANE", DisplayName: "Jane Doe"}))
	fake := &fakeJiraWriter{}
	tool := NewAssignJiraIssue(writeFactory(fake))
	ctx := context.Background()
	raw := json.RawMessage(`{"key":"ABC-7","assignee":"Jane Doe","reason":"r"}`)
	_, err := tool.Execute(ctx, d, Call{Args: normalized(t, tool, d, raw)})
	require.NoError(t, err)

	row, err := d.GetJiraIssue(accountID, "ABC-7")
	require.NoError(t, err)
	assert.Equal(t, "acc-jane", row.AssigneeAccountID)
	assert.Equal(t, "1:UJANE", row.AssigneeSlackID)
	assert.Equal(t, "Fix login", row.Summary)
	assert.Equal(t, "2026-10-01", row.DueDate)
	assert.Equal(t, 7, row.BoardID)
	assert.Equal(t, "Sprint 12", row.SprintName)
	assert.Equal(t, "ABC-1", row.EpicKey)
	assert.Equal(t, "Rita", row.ReporterDisplayName)
	// I-1: the mirror stores the syncer's normalized category ("in_progress"),
	// never the raw Jira key ("indeterminate") the fake's fixture carries —
	// otherwise the briefing's status_category filter drops the issue.
	assert.Equal(t, "in_progress", row.StatusCategory)
}

func TestJiraIssueWrite_MirrorFailureWarnsOnASuccessfulResult(t *testing.T) {
	d := openDB(t)
	seedJira(t, d)
	fake := &fakeJiraWriter{}
	fake.onWrite = func() {
		_, derr := d.Exec(`DROP TABLE jira_issues`)
		require.NoError(t, derr)
	}
	out, err := NewAddJiraComment(writeFactory(fake)).Execute(context.Background(), d,
		Call{Args: json.RawMessage(`{"key":"ABC-7","body":"x","reason":"r"}`)})
	require.NoError(t, err, "the comment exists in Jira; a stale mirror never fails the action")
	res := out.(map[string]any)
	assert.Equal(t, "Comment on ABC-7", res["label"])
	assert.Contains(t, res["warning"], "the local mirror was not updated")
}

func TestJiraIssueWrite_AuthRevokedMarksAccount(t *testing.T) {
	d := openDB(t)
	accountID := seedJira(t, d)
	fake := &fakeJiraWriter{writeErr: jira.ErrAuthRevoked}
	_, err := NewUpdateJiraIssue(writeFactory(fake)).Execute(context.Background(), d,
		Call{Args: json.RawMessage(`{"key":"ABC-7","priority":"High","reason":"r"}`)})
	assert.ErrorIs(t, err, jira.ErrAuthRevoked)
	acct, _ := d.GetJiraAccount(accountID)
	assert.Equal(t, "revoked", acct.Status)
}

// approve moves a pending proposal to approved the way an owner's Approve
// click does, so a test can drive the real Propose → Apply path.
func approve(t *testing.T, d *db.DB, actionID int64) {
	t.Helper()
	ok, err := d.TransitionAgentAction(actionID, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	require.True(t, ok)
}

// Controller ruling (fix round 1, I-2): what the owner approves must be what
// executes. A key mirrored on exactly one site at propose time must still
// target that site at apply time even if a second site's mirror later picks
// up the same key — resolveIssueTarget's ambiguity error must never surface
// at Apply, and the write must never land on the wrong site.
func TestJiraIssueWrite_ProposeApplyPinsSiteAcrossResolutionChange(t *testing.T) {
	d := openDB(t)
	a1 := seedJira(t, d)
	seedIssueRow(t, d, a1, "ABC-7")
	fake := &fakeJiraWriter{}
	reg := New(d)
	require.NoError(t, reg.Register(NewAddJiraComment(writeFactory(fake))))

	rc, err := reg.Propose(context.Background(), "add_jira_comment",
		json.RawMessage(`{"key":"ABC-7","body":"hi","reason":"r"}`), Binding{Surface: "main"})
	require.NoError(t, err)
	assert.Equal(t, "pending", rc.Status)

	// A second site's mirror now claims the same key too — re-resolving
	// "ABC-7" with no account_id today would be a ValidationError asking
	// which site. The pinned account_id in the persisted proposal must make
	// Apply skip that lookup entirely.
	a2, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c2", SiteURL: "https://two.atlassian.net"})
	require.NoError(t, err)
	seedIssueRow(t, d, a2, "ABC-7")

	approve(t, d, rc.ActionID)
	row, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	require.Equal(t, "applied", row.Status)
	assert.Equal(t, []string{"hi"}, fake.comments)

	site1, err := d.GetJiraIssue(a1, "ABC-7")
	require.NoError(t, err)
	assert.NotEmpty(t, site1.SyncedAt, "the mirror refresh landed on the pinned site")
	site2, err := d.GetJiraIssue(a2, "ABC-7")
	require.NoError(t, err)
	assert.Empty(t, site2.SyncedAt, "never touched the other site's mirror")
}

// Controller ruling (fix round 1, I-2): a resolved assignee must be pinned
// too, not just the site. If the person "bob" resolves to at propose time
// stops being the only match by the time the owner approves, Apply must
// still assign the originally resolved person.
func TestAssignJiraIssue_ProposeApplyPinsAssigneeAcrossResolutionChange(t *testing.T) {
	d := openDB(t)
	accountID := seedJira(t, d)
	seedIssueRow(t, d, accountID, "ABC-7")
	fake := &fakeJiraWriter{users: []jira.User{
		{AccountID: "acc-bob", DisplayName: "Bob Stone", Active: true, AccountType: "atlassian"},
	}}
	reg := New(d)
	require.NoError(t, reg.Register(NewAssignJiraIssue(writeFactory(fake))))

	rc, err := reg.Propose(context.Background(), "assign_jira_issue",
		json.RawMessage(`{"key":"ABC-7","assignee":"bob","reason":"r"}`), Binding{Surface: "main"})
	require.NoError(t, err)
	assert.Equal(t, "pending", rc.Status)

	// Bob Stone leaves and a new "Bobby" becomes the sole match for "bob".
	fake.users = []jira.User{{AccountID: "acc-bobby", DisplayName: "Bobby New", Active: true, AccountType: "atlassian"}}

	approve(t, d, rc.ActionID)
	row, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	require.Equal(t, "applied", row.Status)
	assert.Equal(t, []string{"acc-bob"}, fake.assigned, "the pinned assignee, never whoever 'bob' resolves to now")
}

// Controller ruling (fix round 1, I-2): a pinned value that is no longer
// valid at apply time must fail with a clear error, not silently re-pick.
func TestJiraIssueWrite_ApplyFailsClearlyWhenPinnedAccountRemoved(t *testing.T) {
	d := openDB(t)
	accountID := seedJira(t, d)
	seedIssueRow(t, d, accountID, "ABC-7")
	fake := &fakeJiraWriter{}
	reg := New(d)
	require.NoError(t, reg.Register(NewAddJiraComment(writeFactory(fake))))

	rc, err := reg.Propose(context.Background(), "add_jira_comment",
		json.RawMessage(`{"key":"ABC-7","body":"hi","reason":"r"}`), Binding{Surface: "main"})
	require.NoError(t, err)

	require.NoError(t, d.SetJiraAccountRemoved(accountID))

	approve(t, d, rc.ActionID)
	row, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Contains(t, row.Error, "not enabled")
	assert.Empty(t, fake.comments, "never reached Jira")
}
