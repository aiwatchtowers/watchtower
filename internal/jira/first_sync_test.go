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

// R32: a first Sync that stamps a watermark and then errs late (here a
// revoked grant in the changelog step of syncHistory) is still a first sync,
// whatever Sync returned — otherwise the next Sync sees a watermark and the
// account's month is never mined. A second Sync is not.
func TestSync_FirstSyncFromWhenSyncErrsLate(t *testing.T) {
	database := revokedSyncerDB(t)
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 3, Name: "Ops", ProjectKey: "OPS", IsSelected: true, SyncedAt: "now",
	}))
	mux := http.NewServeMux()
	mux.HandleFunc("/rest/api/3/search/jql", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"isLast":true,"issues":[{"id":"1001","key":"OPS-1","fields":{"summary":"s",
			"issuetype":{"name":"Task"},"status":{"name":"Open","statusCategory":{"key":"new"}},
			"created":"2026-07-01T10:00:00.000+0000","updated":"2026-07-05T10:00:00.000+0000"}}]}`))
	})
	mux.HandleFunc("/rest/agile/1.0/board/3/sprint", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"values":[]}`))
	})
	mux.HandleFunc("/rest/api/3/project/OPS/versions", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`[]`))
	})
	mux.HandleFunc("/rest/api/3/changelog/bulkfetch", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	stubTokenEndpoint(t)
	syncer := quietSyncer(t, database, srv.URL)
	syncer.SetChangelogLimit(10)

	_, err := syncer.Sync(context.Background())
	require.ErrorIs(t, err, ErrAuthRevoked, "the late step fails")
	state, err := database.GetJiraSyncState(1, "OPS")
	require.NoError(t, err)
	require.NotNil(t, state)
	require.NotEmpty(t, state.LastSyncedAt, "the watermark was stamped before the failure")
	_, ok := syncer.FirstSyncFrom()
	assert.True(t, ok, "watermark written: a first sync, whatever Sync returned")

	_, _ = syncer.Sync(context.Background())
	_, ok = syncer.FirstSyncFrom()
	assert.False(t, ok, "the next Sync is not a first sync")
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
