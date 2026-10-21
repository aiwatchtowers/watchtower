package jira

import (
	"context"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// #601: a pass reports that it reached Atlassian only when an issue search
// came back; a pass with no selected boards makes no request and proves no
// access.
func TestSync_ReachedSource(t *testing.T) {
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	db.SeedTestJiraAccount(t, database)
	srv := httptest.NewServer(jiraSearchMux())
	t.Cleanup(srv.Close)
	syncer := NewSyncer(makeTestClient(t, srv.URL), database, nil, []int{42}, 1)

	_, err = syncer.Sync(context.Background())
	require.NoError(t, err)
	assert.False(t, syncer.ReachedSource(), "no boards selected: no request, no proof of access")

	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 42, Name: "Test Board", ProjectKey: "TEST", BoardType: "scrum", IsSelected: true,
	}))
	_, err = syncer.Sync(context.Background())
	require.NoError(t, err)
	assert.True(t, syncer.ReachedSource(), "a successful issue search proves access")
}
