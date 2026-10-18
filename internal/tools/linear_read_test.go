package tools

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func linearReadRegistry(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	for _, tool := range append(ReadTools(), AutomationReadTools()...) {
		if strings.Contains(tool.Name, "linear") {
			require.NoError(t, reg.Register(tool))
		}
	}
	return reg
}

func seedLinearAccount(t *testing.T, d *db.DB, label, ownerID string) int64 {
	t.Helper()
	id, err := d.CreateLinearAccount(label)
	require.NoError(t, err)
	require.NoError(t, d.UpdateLinearAccountConnection(id, "org-"+label, label, label))
	if ownerID != "" {
		require.NoError(t, d.SetLinearAccountOwner(id, ownerID, ownerID+"@example.com", "Owner "+label))
	}
	return id
}

func seedLinearIssue(t *testing.T, d *db.DB, acct int64, key, stateType, createdAt string, mod func(*db.LinearIssue)) db.LinearIssue {
	t.Helper()
	team, _, _ := strings.Cut(key, "-")
	i := db.LinearIssue{
		AccountID: acct, ID: "id-" + key, Key: key, TeamID: "team-" + team, TeamKey: team, Title: "title " + key,
		StateName: "State " + stateType, StateType: stateType, CreatedAt: createdAt, UpdatedAt: createdAt,
	}
	if mod != nil {
		mod(&i)
	}
	require.NoError(t, d.UpsertLinearIssue(i))
	return i
}

func rowKeys(t *testing.T, raw string) []string {
	t.Helper()
	var rows []struct {
		Key string `json:"key"`
	}
	require.NoError(t, json.Unmarshal([]byte(raw), &rows))
	var out []string
	for _, r := range rows {
		out = append(out, r.Key)
	}
	return out
}

func TestListLinearIssues_Filters(t *testing.T) {
	d := openDB(t)
	acct := seedLinearAccount(t, d, "acme", "")
	seedLinearIssue(t, d, acct, "ENG-1", "triage", "2026-10-16T10:00:00.000Z", nil)
	seedLinearIssue(t, d, acct, "ENG-2", "triage", "2026-10-17T00:00:00.000Z", nil)
	seedLinearIssue(t, d, acct, "ENG-3", "started", "2026-10-18T08:00:00.000Z", func(i *db.LinearIssue) {
		i.DescriptionText = strings.Repeat("é", 400) // 800 bytes
	})
	seedLinearIssue(t, d, acct, "ENG-4", "triage", "2026-10-18T09:00:00.000Z", func(i *db.LinearIssue) { i.IsDeleted = true })
	seedLinearIssue(t, d, acct, "OPS-1", "triage", "2026-10-18T07:00:00.000Z", nil)
	reg := linearReadRegistry(t, d)

	assert.Equal(t, []string{"OPS-1", "ENG-2", "ENG-1"},
		rowKeys(t, callReadString(t, reg, "list_linear_issues", `{"state_type":"triage"}`)), "triage only, newest first, deleted left out")
	assert.Equal(t, []string{"OPS-1", "ENG-2"},
		rowKeys(t, callReadString(t, reg, "list_linear_issues", `{"state_type":"triage","created_after":"2026-10-17"}`)),
		"a date means its midnight UTC, boundary included")
	assert.Equal(t, []string{"ENG-2"},
		rowKeys(t, callReadString(t, reg, "list_linear_issues", `{"team":"eng","created_after":"2026-10-17T00:00:00Z","state_type":"triage"}`)))

	got := callReadString(t, reg, "list_linear_issues", `{"team":"ENG","state":"state started"}`)
	var rows []linearIssueListItem
	require.NoError(t, json.Unmarshal([]byte(got), &rows))
	require.Len(t, rows, 1)
	assert.True(t, rows[0].DescriptionTruncated)
	assert.LessOrEqual(t, len(rows[0].Description), maxListedDescriptionBytes)

	_, err := reg.CallRead(context.Background(), "list_linear_issues", json.RawMessage(`{"state_type":"nope"}`), Binding{})
	var ve *ValidationError
	require.ErrorAs(t, err, &ve)
	_, err = reg.CallRead(context.Background(), "list_linear_issues", json.RawMessage(`{"created_after":"yesterday"}`), Binding{})
	require.ErrorAs(t, err, &ve)
}

func TestListLinearIssues_AssigneeMe(t *testing.T) {
	d := openDB(t)
	acct := seedLinearAccount(t, d, "acme", "u-owner")
	seedLinearIssue(t, d, acct, "ENG-1", "started", "2026-10-18T08:00:00Z", func(i *db.LinearIssue) {
		i.AssigneeID, i.AssigneeEmail = "u-owner", "Owner@Example.com"
	})
	seedLinearIssue(t, d, acct, "ENG-2", "started", "2026-10-18T07:00:00Z", func(i *db.LinearIssue) {
		i.AssigneeID, i.AssigneeEmail = "u-other", "other@example.com"
	})
	reg := linearReadRegistry(t, d)

	assert.Equal(t, []string{"ENG-1"}, rowKeys(t, callReadString(t, reg, "list_linear_issues", `{"assignee":"me"}`)))
	assert.Equal(t, []string{"ENG-1"}, rowKeys(t, callReadString(t, reg, "list_linear_issues", `{"assignee":"owner@example.com"}`)))
	assert.Equal(t, []string{"ENG-2"}, rowKeys(t, callReadString(t, reg, "list_linear_issues", `{"assignee":"u-other"}`)))

	d2 := openDB(t)
	seedLinearAccount(t, d2, "acme", "")
	_, err := linearReadRegistry(t, d2).CallRead(context.Background(), "list_linear_issues", json.RawMessage(`{"assignee":"me"}`), Binding{})
	var ve *ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, err.Error(), "run linear sync")
}

func TestGetLinearIssue_PreviousKeyAndComments(t *testing.T) {
	d := openDB(t)
	acct := seedLinearAccount(t, d, "acme", "")
	i := seedLinearIssue(t, d, acct, "NEW-5", "started", "2026-10-18T08:00:00Z", func(i *db.LinearIssue) {
		i.PreviousKeys = []string{"OLD-1"}
		i.DescriptionText = "full description"
	})
	for _, c := range []db.LinearComment{
		{AccountID: acct, ID: "c2", IssueID: i.ID, IssueKey: "NEW-5", BodyText: "second", CreatedAt: "2026-10-18T10:00:00Z"},
		{AccountID: acct, ID: "c1", IssueID: i.ID, IssueKey: "OLD-1", BodyText: "first", CreatedAt: "2026-10-18T09:00:00Z"},
	} {
		require.NoError(t, d.UpsertLinearComment(c))
	}

	got := callReadString(t, linearReadRegistry(t, d), "get_linear_issue", `{"key":"old-1"}`)
	var v linearIssueView
	require.NoError(t, json.Unmarshal([]byte(got), &v))
	assert.Equal(t, "NEW-5", v.Key)
	assert.Equal(t, "full description", v.Description)
	require.Len(t, v.Comments, 2)
	assert.Equal(t, []string{"first", "second"}, []string{v.Comments[0].Body, v.Comments[1].Body})
}

func TestLinearIssueTarget_AmbiguousKey(t *testing.T) {
	d := openDB(t)
	a1 := seedLinearAccount(t, d, "acme", "")
	a2 := seedLinearAccount(t, d, "globex", "")
	seedLinearIssue(t, d, a1, "ENG-1", "started", "2026-10-18T08:00:00Z", nil)
	seedLinearIssue(t, d, a2, "ENG-1", "started", "2026-10-18T08:00:00Z", nil)
	seedLinearIssue(t, d, a1, "ENG-9", "started", "2026-10-18T08:00:00Z", func(i *db.LinearIssue) { i.IsDeleted = true })

	_, err := linearIssuesByKey(d, 0, "ENG-1")
	var ve *ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, err.Error(), "account_id")
	assert.Contains(t, err.Error(), "list_linear_teams")

	got, err := linearIssuesByKey(d, a2, "eng-1")
	require.NoError(t, err)
	assert.Equal(t, a2, got.AccountID)

	_, err = linearIssuesByKey(d, 0, "ENG-9")
	require.Error(t, err, "a deleted issue is not returned")
	assert.NotErrorAs(t, err, &ve)
	_, err = linearIssuesByKey(d, 0, "not a key")
	require.ErrorAs(t, err, &ve)

	require.NoError(t, d.SetLinearAccountEnabled(a1, false))
	got, err = linearIssuesByKey(d, 0, "ENG-1")
	require.NoError(t, err, "a disabled account's copy does not make the key ambiguous")
	assert.Equal(t, a2, got.AccountID)
}

func TestListLinearTeams_StatesAndLabels(t *testing.T) {
	d := openDB(t)
	acct := seedLinearAccount(t, d, "acme", "")
	require.NoError(t, d.UpsertLinearTeams(acct, []db.LinearTeam{{ID: "t-eng", Key: "ENG", Name: "Engineering"}}, map[string]bool{"t-eng": true}))
	require.NoError(t, d.ReplaceLinearTeamStates(acct, "t-eng", []db.LinearWorkflowState{
		{ID: "s2", Name: "Done", Type: "completed", Position: 2}, {ID: "s1", Name: "Triage", Type: "triage", Position: 1},
	}))
	require.NoError(t, d.ReplaceLinearLabels(acct, "t-eng", []db.LinearLabel{{ID: "l1", Name: "bug"}}))
	require.NoError(t, d.ReplaceLinearLabels(acct, "", []db.LinearLabel{{ID: "l2", Name: "customer"}}))

	var views []linearAccountView
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, linearReadRegistry(t, d), "list_linear_teams", `{}`)), &views))
	require.Len(t, views, 1)
	require.Len(t, views[0].Teams, 1)
	team := views[0].Teams[0]
	assert.Equal(t, "ENG", team.Key)
	assert.True(t, team.Selected)
	assert.Equal(t, []linearStateView{{"Triage", "triage", 1}, {"Done", "completed", 2}}, team.States)
	assert.Equal(t, []string{"bug"}, team.Labels)
	assert.Equal(t, []string{"customer"}, views[0].WorkspaceLabels)
}

func TestGetLinearStatusHistory_MaxKeys(t *testing.T) {
	d := openDB(t)
	acct := seedLinearAccount(t, d, "acme", "")
	i := seedLinearIssue(t, d, acct, "ENG-1", "started", "2026-10-18T08:00:00Z", nil)
	require.NoError(t, d.UpsertLinearHistory([]db.LinearHistoryEntry{
		{AccountID: acct, ID: "h2", Field: "status", IssueID: i.ID, FromString: "Todo", ToString: "Doing", ChangedAt: "2026-10-18T10:00:00Z"},
		{AccountID: acct, ID: "h1", Field: "assignee", IssueID: i.ID, ToString: "Ann", ChangedAt: "2026-10-18T09:00:00Z"},
	}))
	reg := linearReadRegistry(t, d)

	var res linearHistoryResult
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, reg, "get_linear_status_history", `{"keys":["eng-1","ENG-77"]}`)), &res))
	require.Len(t, res.Issues, 1)
	assert.Equal(t, []string{"ENG-77"}, res.NotFound)
	require.Len(t, res.Issues[0].Events, 2)
	assert.Equal(t, "assignee", res.Issues[0].Events[0].Field)
	assert.Equal(t, "Doing", res.Issues[0].Events[1].To)

	keys := make([]string, 21)
	for n := range keys {
		keys[n] = "ENG-" + string(rune('A'+n))
	}
	raw, err := json.Marshal(map[string]any{"keys": keys})
	require.NoError(t, err)
	_, err = reg.CallRead(context.Background(), "get_linear_status_history", raw, Binding{})
	var ve *ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, err.Error(), "at most 20")
}

func TestListLinearCycles_DerivedState(t *testing.T) {
	d := openDB(t)
	acct := seedLinearAccount(t, d, "acme", "")
	require.NoError(t, d.UpsertLinearTeams(acct, []db.LinearTeam{{ID: "t-eng", Key: "ENG", Name: "Engineering"}}, nil))
	day := 24 * time.Hour
	f := func(off time.Duration) string { return time.Now().UTC().Add(off).Format(time.RFC3339) }
	require.NoError(t, d.UpsertLinearCycles([]db.LinearCycle{
		{AccountID: acct, ID: "c-past", TeamID: "t-eng", Number: 1, StartsAt: f(-20 * day), EndsAt: f(-6 * day), CompletedAt: f(-6 * day)},
		{AccountID: acct, ID: "c-now", TeamID: "t-eng", Number: 2, StartsAt: f(-3 * day), EndsAt: f(11 * day), Progress: 0.4},
		{AccountID: acct, ID: "c-next", TeamID: "t-eng", Number: 3, StartsAt: f(12 * day), EndsAt: f(26 * day)},
	}))

	var res struct {
		Cycles []linearCycleView `json:"cycles"`
	}
	require.NoError(t, json.Unmarshal([]byte(callReadString(t, linearReadRegistry(t, d), "list_linear_cycles", `{"team":"eng"}`)), &res))
	var states []string
	for _, c := range res.Cycles {
		states = append(states, c.ID+"="+c.State)
	}
	assert.Equal(t, []string{"c-next=upcoming", "c-now=active", "c-past=past"}, states)

	_, err := linearReadRegistry(t, d).CallRead(context.Background(), "list_linear_cycles", json.RawMessage(`{}`), Binding{})
	var ve *ValidationError
	require.ErrorAs(t, err, &ve)
}
