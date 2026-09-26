package cmd

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// fakeMyselfGetter is a one-method stand-in for *jira.Client so
// recordJiraOwner/maybeRecordJiraOwner can be tested without OAuth.
type fakeMyselfGetter struct {
	calls int
	me    jira.Myself
	err   error
}

func (f *fakeMyselfGetter) GetMyself(context.Context) (jira.Myself, error) {
	f.calls++
	return f.me, f.err
}

func openJiraOwnerTestDB(t *testing.T) *db.DB {
	t.Helper()
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	return database
}

// TestRecordJiraOwner_Success stores all three /myself fields on the account
// row, checked by value — a fixture that only checked one field could not
// tell a swapped accountId/email from a correct write.
func TestRecordJiraOwner_Success(t *testing.T) {
	database := openJiraOwnerTestDB(t)
	id := db.SeedTestJiraAccount(t, database)
	getter := &fakeMyselfGetter{me: jira.Myself{AccountID: "acc-9", EmailAddress: "j@x.com", DisplayName: "J Doe"}}

	var out bytes.Buffer
	recordJiraOwner(context.Background(), &out, database, id, getter)

	got, err := database.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "acc-9", got.OwnerAccountID)
	assert.Equal(t, "j@x.com", got.OwnerEmail)
	assert.Equal(t, "J Doe", got.OwnerDisplayName)
	assert.Empty(t, out.String())
}

// TestRecordJiraOwner_MyselfError leaves the owner columns empty and writes
// a warning instead of failing — a revoked/401ing account at connect must
// never fail jira add/login (Review Focus item 3).
func TestRecordJiraOwner_MyselfError(t *testing.T) {
	database := openJiraOwnerTestDB(t)
	id := db.SeedTestJiraAccount(t, database)
	getter := &fakeMyselfGetter{err: errors.New("401 unauthorized")}

	var out bytes.Buffer
	recordJiraOwner(context.Background(), &out, database, id, getter)

	got, err := database.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Empty(t, got.OwnerAccountID)
	assert.Empty(t, got.OwnerEmail)
	assert.Empty(t, got.OwnerDisplayName)
	assert.Contains(t, out.String(),
		"warning: could not read your Jira identity (/myself): 401 unauthorized; it will be retried on the next sync")
}

// TestMaybeRecordJiraOwner_SkipsWhenAlreadySet is the wireJiraSyncers
// lazy-fill guard: an account that already has an owner identity is never
// re-fetched — one attempt per account per daemon start, not every wiring
// pass.
func TestMaybeRecordJiraOwner_SkipsWhenAlreadySet(t *testing.T) {
	getter := &fakeMyselfGetter{me: jira.Myself{AccountID: "acc-9"}}
	acct := db.JiraAccount{ID: 1, OwnerAccountID: "acc-existing"}

	// database is nil on purpose: an already-set account must never touch
	// the DB, so a nil pointer here would panic if the guard were dropped.
	maybeRecordJiraOwner(context.Background(), &bytes.Buffer{}, nil, acct, getter)

	assert.Zero(t, getter.calls)
}

// TestMaybeRecordJiraOwner_FetchesWhenEmpty is the mutation-check partner:
// without the OwnerAccountID == "" guard being honored on the fetch side too,
// this would also pass with zero calls.
func TestMaybeRecordJiraOwner_FetchesWhenEmpty(t *testing.T) {
	database := openJiraOwnerTestDB(t)
	id := db.SeedTestJiraAccount(t, database)
	getter := &fakeMyselfGetter{me: jira.Myself{AccountID: "acc-9", EmailAddress: "j@x.com", DisplayName: "J Doe"}}
	acct, err := database.GetJiraAccount(id)
	require.NoError(t, err)
	require.Empty(t, acct.OwnerAccountID)

	maybeRecordJiraOwner(context.Background(), &bytes.Buffer{}, database, acct, getter)

	assert.Equal(t, 1, getter.calls)
	got, err := database.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "acc-9", got.OwnerAccountID)
}
