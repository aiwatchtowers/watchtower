package cmd

import (
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMapJiraUserToSlack_NamespacesBareArgument pins the first of the two paths
// that could still inject a bare Slack id. `jira users map <jira_id> <slack_id>`
// took argv verbatim, and argv is whatever the operator copied out of Slack —
// a bare "U0123ABCD", which has matched no column since migration 00048. The
// mapping then propagates onto every one of that person's issues at the next
// upsert, so this is the source the backfill would otherwise keep re-opening.
func TestMapJiraUserToSlack_NamespacesBareArgument(t *testing.T) {
	database := db.OpenTestDB(t)
	require.NoError(t, database.UpsertUser(db.User{ID: "1:U0123ABCD", Name: "alice"}))

	resolved, err := mapJiraUserToSlack(database, "jira-alice", "U0123ABCD")
	require.NoError(t, err)
	assert.Equal(t, "1:U0123ABCD", resolved, "the command must report the id it actually stored")

	got, err := database.GetJiraUserMapByAccountID("jira-alice")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "1:U0123ABCD", got.SlackUserID)
	assert.Equal(t, "manual", got.MatchMethod)
}

// An id naming no synced user is refused and nothing is written: a mapping row
// nothing can join is invisible to every reader, so a typo has to fail at the
// prompt or it never surfaces at all.
func TestMapJiraUserToSlack_RefusesUnknownIDAndWritesNothing(t *testing.T) {
	database := db.OpenTestDB(t)
	require.NoError(t, database.UpsertUser(db.User{ID: "1:U0123ABCD", Name: "alice"}))

	_, err := mapJiraUserToSlack(database, "jira-alice", "UNOBODY")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "UNOBODY")

	got, err := database.GetJiraUserMapByAccountID("jira-alice")
	require.NoError(t, err)
	assert.Nil(t, got, "a refused mapping must leave no row behind")
}

// An already-namespaced argument is stored unchanged — the operator who pastes
// the full id must not end up with "1:1:U...".
func TestMapJiraUserToSlack_AcceptsNamespacedArgument(t *testing.T) {
	database := db.OpenTestDB(t)
	require.NoError(t, database.UpsertUser(db.User{ID: "1:U0123ABCD", Name: "alice"}))

	resolved, err := mapJiraUserToSlack(database, "jira-alice", "1:U0123ABCD")
	require.NoError(t, err)
	assert.Equal(t, "1:U0123ABCD", resolved)
}
