package atlassianpdr

import (
	"context"
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// fakeUsers answers UsersBulk.
type fakeUsers struct {
	users []jira.BulkUser
	err   error
	asked [][]string
}

func (f *fakeUsers) UsersBulkStatus(_ context.Context, ids []string) ([]jira.BulkUser, error) {
	f.asked = append(f.asked, ids)
	return f.users, f.err
}

func newTokenAccount(t *testing.T, d *db.DB) int64 {
	t.Helper()
	id, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c", SiteURL: "https://acme.atlassian.net", AuthKind: jira.AuthKindAPIToken})
	require.NoError(t, err)
	return id
}

// TestTokenLookup_ClosedErased (D23): an API-token account looks its stored
// ids up every 7 days and a profile Atlassian shows as closed gets the same
// erase as a PDR "closed".
func TestTokenLookup_ClosedErased(t *testing.T) {
	d := db.OpenTestDB(t)
	acct := newTokenAccount(t, d)
	seedPeople(t, d, acct)
	users := &fakeUsers{users: []jira.BulkUser{
		{AccountID: closedID, DisplayName: "Former user", Active: ptr(false), AccountType: "atlassian"},
		{AccountID: liveID, DisplayName: "Person", Active: ptr(true), AccountType: "atlassian"},
	}}

	res, err := Run(context.Background(), d, acct, LookupReporter{Users: users}, t0)
	require.NoError(t, err)
	assert.Equal(t, 1, res.Closed)
	require.Len(t, users.asked, 1)
	assert.ElementsMatch(t, []string{closedID, liveID}, users.asked[0])
	assert.True(t, erased(t, d, acct))
	assert.Equal(t, 1, count(t, d, `SELECT count(*) FROM jira_user_map WHERE jira_account_id = ?`, liveID))
	assert.NotEmpty(t, lastPDR(t, d, acct))

	// Not due again for 7 days.
	res, err = Run(context.Background(), d, acct, LookupReporter{Users: users}, t0.Add(Every/2))
	require.NoError(t, err)
	assert.True(t, res.NotDue)
	assert.Len(t, users.asked, 1)
}

// TestTokenLookup_AmbiguousErasesNothing: a refused lookup (403), a network
// error, an id left out, or a deactivated person with a name is not a
// closed account — nothing is erased (spike S1.5 open: the conservative
// reading).
func TestTokenLookup_AmbiguousErasesNothing(t *testing.T) {
	cases := []struct {
		name  string
		users *fakeUsers
	}{
		{"403", &fakeUsers{err: &jira.HTTPStatusError{Status: 403, Body: "forbidden"}}},
		{"network", &fakeUsers{err: errors.New("dial tcp: connection refused")}},
		{"not found", &fakeUsers{users: []jira.BulkUser{{AccountID: liveID, DisplayName: "Person", Active: ptr(true)}}}},
		{"deactivated, named", &fakeUsers{users: []jira.BulkUser{{AccountID: closedID, DisplayName: "Person", Active: ptr(false)}}}},
		{"anonymised but active", &fakeUsers{users: []jira.BulkUser{{AccountID: closedID, DisplayName: "Former user", Active: ptr(true)}}}},
		{"anonymised, no active field", &fakeUsers{users: []jira.BulkUser{{AccountID: closedID, DisplayName: "Former user"}}}},
		{"an id not asked for", &fakeUsers{users: []jira.BulkUser{{AccountID: "someone-else", DisplayName: "Former user", Active: ptr(false)}}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := db.OpenTestDB(t)
			acct := newTokenAccount(t, d)
			seedPeople(t, d, acct)
			_, err := Run(context.Background(), d, acct, LookupReporter{Users: tc.users}, t0)
			if tc.users.err != nil {
				require.Error(t, err)
				assert.Empty(t, lastPDR(t, d, acct), "a failed lookup stamps nothing")
			} else {
				require.NoError(t, err)
			}
			assert.False(t, erased(t, d, acct))
			assert.Equal(t, 1, count(t, d, `SELECT count(*) FROM jira_user_map WHERE jira_account_id = ?`, closedID))
		})
	}
}

func TestClassifyBulkUsers(t *testing.T) {
	got := classifyBulkUsers([]string{"a", "b", "c"}, []jira.BulkUser{
		{AccountID: "a", DisplayName: " former USER ", Active: ptr(false)},
		{AccountID: "b", DisplayName: "Person B", Active: ptr(false)},
		{AccountID: "c", DisplayName: "Former user"},
	})
	assert.Equal(t, map[string]Status{"a": StatusClosed}, got)
}

func ptr[T any](v T) *T { return &v }
