package jira

import (
	"bytes"
	"context"
	"log"
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// newTestMapper builds a UserMapper over a temp database with a captured log,
// so the "reported, not stored" half of the manual-map contract is checkable.
func newTestMapper(t *testing.T, database *db.DB) (*UserMapper, *bytes.Buffer) {
	t.Helper()
	var logs bytes.Buffer
	m := NewUserMapper(nil, database)
	m.SetLogger(log.New(&logs, "", 0))
	return m, &logs
}

func seedShellJiraUser(t *testing.T, database *db.DB, jiraAccountID string) {
	t.Helper()
	require.NoError(t, database.UpsertJiraUserMap(db.JiraUserMap{
		JiraAccountID: jiraAccountID,
		Email:         jiraAccountID + "@example.com",
		DisplayName:   "Nobody In Slack",
	}))
}

// TestResolveAll_ManualMapNamespacesConfigID pins the second of the two paths
// that could still inject a bare Slack id. jira.user_map is hand-written in
// config.yaml, so it carries the bare "U..." an operator sees in Slack; stored
// verbatim it lands on every one of that person's issues at the next upsert,
// where every reader comparing against an external identity sees nothing.
func TestResolveAll_ManualMapNamespacesConfigID(t *testing.T) {
	database := db.OpenTestDB(t)
	require.NoError(t, database.UpsertUser(db.User{ID: "1:U0123ABCD", Name: "alice"}))
	seedShellJiraUser(t, database, "jira-alice")

	m, _ := newTestMapper(t, database)
	require.NoError(t, m.ResolveAll(context.Background(), map[string]string{"jira-alice": "U0123ABCD"}))

	got, err := database.GetJiraUserMapByAccountID("jira-alice")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "1:U0123ABCD", got.SlackUserID, "a bare config id must be resolved before it is stored")
	assert.Equal(t, "manual", got.MatchMethod)
}

// An override naming nobody is reported and skipped: an unusable mapping is
// worse than none, because it silently overrides whatever the email and fuzzy
// phases did find.
func TestResolveAll_ManualMapRejectsUnknownID(t *testing.T) {
	database := db.OpenTestDB(t)
	require.NoError(t, database.UpsertUser(db.User{
		ID: "1:U0123ABCD", Name: "alice", Email: "jira-alice@example.com",
	}))
	seedShellJiraUser(t, database, "jira-alice")

	m, logs := newTestMapper(t, database)
	require.NoError(t, m.ResolveAll(context.Background(), map[string]string{"jira-alice": "UNOBODY"}))

	got, err := database.GetJiraUserMapByAccountID("jira-alice")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "1:U0123ABCD", got.SlackUserID, "a bad override must not replace the email match")
	assert.Equal(t, "email", got.MatchMethod)
	assert.Contains(t, logs.String(), "UNOBODY", "an ignored override must be reported")
}

// The email phase already writes users.id, which is namespaced — this pins that
// the manual phase did not become the only correct writer by accident.
func TestResolveAll_EmailMatchStoresNamespacedID(t *testing.T) {
	database := db.OpenTestDB(t)
	require.NoError(t, database.UpsertUser(db.User{
		ID: "1:U0123ABCD", Name: "alice", Email: "jira-alice@example.com",
	}))
	seedShellJiraUser(t, database, "jira-alice")

	m, _ := newTestMapper(t, database)
	require.NoError(t, m.ResolveAll(context.Background(), nil))

	got, err := database.GetJiraUserMapByAccountID("jira-alice")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "1:U0123ABCD", got.SlackUserID)
}
