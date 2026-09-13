package jira

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestSyncer_Sync_RecordsPerProjectFailure pins the half of a sync pass that
// used to leave no trace anywhere but the daemon log. Sync swallows ordinary
// per-project failures and returns (total, nil), so a pass in which every
// project 503'd is indistinguishable from a quiet one — and the code that
// looked like it recorded the reason assigned LastError onto a struct it then
// dropped, calling an update that named four columns and wrote two.
func TestSyncer_Sync_RecordsPerProjectFailure(t *testing.T) {
	database := revokedSyncerDB(t)
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 3, Name: "Ops", ProjectKey: "OPS", IsSelected: true, SyncedAt: "now",
	}))

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"errorMessages":["jira is down"]}`))
	}))
	t.Cleanup(srv.Close)

	// A pass where every project failed still reports success to the caller —
	// which is exactly why the failure has to land on the row.
	_, err := quietSyncer(t, database, srv.URL).Sync(context.Background())
	require.NoError(t, err)

	state, err := database.GetJiraSyncState(1, "OPS")
	require.NoError(t, err)
	require.NotNil(t, state, "a failed project must still get a row")
	assert.Contains(t, state.LastError, "jira is down", "the reason must be recorded, not only logged")
	assert.NotEmpty(t, state.LastErrorAt, "an error with no timestamp cannot be told from a stale one")
	assert.Empty(t, state.LastSyncedAt, "a failed attempt synced nothing and must not move the watermark")
}

// TestSyncer_Sync_FailureKeepsEarlierWatermark is the other half of "the
// failure path owns no watermark": a project that synced yesterday and fails
// today keeps yesterday's timestamp and issue count next to today's error.
func TestSyncer_Sync_FailureKeepsEarlierWatermark(t *testing.T) {
	database := revokedSyncerDB(t)
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 3, Name: "Ops", ProjectKey: "OPS", IsSelected: true, SyncedAt: "now",
	}))
	require.NoError(t, database.UpdateJiraSyncState(1, "OPS", "2026-09-12T00:00:00Z", 42))

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"errorMessages":["jira is down"]}`))
	}))
	t.Cleanup(srv.Close)

	_, err := quietSyncer(t, database, srv.URL).Sync(context.Background())
	require.NoError(t, err)

	state, err := database.GetJiraSyncState(1, "OPS")
	require.NoError(t, err)
	require.NotNil(t, state)
	assert.Equal(t, "2026-09-12T00:00:00Z", state.LastSyncedAt, "a failure must not rewrite the watermark")
	assert.Equal(t, 42, state.IssuesSynced)
	assert.Contains(t, state.LastError, "jira is down")
}

// TestSyncer_Sync_SecondFailureReplacesTheFirstOne covers the conflict path of
// the failure writer, which the other two tests reach only for the text.
//
// A project that failed on Monday and fails again on Friday with a different
// reason must carry Friday's reason under FRIDAY's timestamp. Updating the text
// while leaving the timestamp at its first value is the wrong implementation
// this pins: `jira status` would then print the new error dated a week ago,
// which is precisely the "a stale error reads as a current one" hazard the
// renderer prints the timestamp to avoid — and it stays that way for as long as
// the project keeps failing, because only a success ever clears the pair.
func TestSyncer_Sync_SecondFailureReplacesTheFirstOne(t *testing.T) {
	database := revokedSyncerDB(t)
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 3, Name: "Ops", ProjectKey: "OPS", IsSelected: true, SyncedAt: "now",
	}))

	const firstFailure = "2026-09-07T00:00:00Z"
	require.NoError(t, database.RecordJiraSyncError(1, "OPS", "connection reset by peer", firstFailure))

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"errorMessages":["jira is down"]}`))
	}))
	t.Cleanup(srv.Close)

	_, err := quietSyncer(t, database, srv.URL).Sync(context.Background())
	require.NoError(t, err)

	state, err := database.GetJiraSyncState(1, "OPS")
	require.NoError(t, err)
	require.NotNil(t, state)
	assert.Contains(t, state.LastError, "jira is down", "the newer reason must replace the older one")
	assert.NotContains(t, state.LastError, "connection reset", "the older reason must not survive")
	assert.NotEqual(t, firstFailure, state.LastErrorAt,
		"the timestamp must move with the error, or the newest failure reads as a week-old one")
	assert.Greater(t, state.LastErrorAt, firstFailure, "the replacement timestamp must be the newer one")
}

// TestSyncer_Sync_SuccessClearsPreviousFailure pins the clear condition the
// column names imply: last_error is the error from the MOST RECENT attempt, so
// a project that recovers stops reporting one. Without this, `jira status`
// would print a recent sync beside a weeks-old error and the operator would
// have no way to tell whether the project is broken now.
func TestSyncer_Sync_SuccessClearsPreviousFailure(t *testing.T) {
	database := revokedSyncerDB(t)
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 3, Name: "Ops", ProjectKey: "OPS", IsSelected: true, SyncedAt: "now",
	}))

	var failNext atomic.Bool
	failNext.Store(true)
	mux := http.NewServeMux()
	mux.HandleFunc("/rest/api/3/search/jql", func(w http.ResponseWriter, _ *http.Request) {
		if failNext.Load() {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"errorMessages":["jira is down"]}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"issues":[],"isLast":true}`))
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{}`))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	syncer := quietSyncer(t, database, srv.URL)

	_, err := syncer.Sync(context.Background())
	require.NoError(t, err)
	state, err := database.GetJiraSyncState(1, "OPS")
	require.NoError(t, err)
	require.NotNil(t, state)
	require.NotEmpty(t, state.LastError, "the first pass must have recorded a failure to clear")

	failNext.Store(false)
	_, err = syncer.Sync(context.Background())
	require.NoError(t, err)

	state, err = database.GetJiraSyncState(1, "OPS")
	require.NoError(t, err)
	require.NotNil(t, state)
	assert.Empty(t, state.LastError, "a successful pass must clear the previous failure")
	assert.Empty(t, state.LastErrorAt, "clearing the text without the timestamp leaves a half-stale row")
	assert.NotEmpty(t, state.LastSyncedAt, "the successful pass must still stamp the watermark")
}
