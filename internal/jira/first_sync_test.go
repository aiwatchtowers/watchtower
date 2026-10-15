package jira

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// R29: the account's first Sync — no watermark before, one after — reports
// when it started; the next Sync, with a watermark, does not.
func TestSync_FirstSyncFrom(t *testing.T) {
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	db.SeedTestJiraAccount(t, database)
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 42, Name: "Test Board", ProjectKey: "TEST", BoardType: "scrum", IsSelected: true,
	}))
	srv := httptest.NewServer(jiraSearchMux())
	t.Cleanup(srv.Close)
	syncer := NewSyncer(makeTestClient(t, srv.URL), database, nil, []int{42}, 1)

	before := time.Now().UTC()
	_, err = syncer.Sync(context.Background())
	require.NoError(t, err)
	from, ok := syncer.FirstSyncFrom()
	require.True(t, ok, "no watermark before, one after: a first sync")
	assert.False(t, from.Before(before.Truncate(time.Second)), "the value is when the sync started")
	assert.False(t, from.After(time.Now()))

	_, err = syncer.Sync(context.Background())
	require.NoError(t, err)
	_, ok = syncer.FirstSyncFrom()
	assert.False(t, ok, "an account with a watermark is not on its first sync")
}

// A first Sync whose projects all fail writes no watermark and is not a
// first sync; the next one that does write one is.
func TestSync_FirstSyncFromNeedsAWatermark(t *testing.T) {
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	db.SeedTestJiraAccount(t, database)
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 42, Name: "Test Board", ProjectKey: "TEST", BoardType: "scrum", IsSelected: true,
	}))
	failing := http.NewServeMux()
	failing.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusInternalServerError) })
	srv := httptest.NewServer(failing)
	t.Cleanup(srv.Close)
	syncer := NewSyncer(makeTestClient(t, srv.URL), database, nil, []int{42}, 1)

	_, _ = syncer.Sync(context.Background())
	_, ok := syncer.FirstSyncFrom()
	assert.False(t, ok, "no watermark written: not a first sync yet")
}
