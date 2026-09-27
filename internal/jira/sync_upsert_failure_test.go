package jira

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestSyncer_Sync_UpsertFailureKeepsProjectWatermark pins that a failed
// issue-batch DB write is a project failure, not a log line: the project's
// watermark must not advance past issues that never reached jira_issues
// (the next incremental JQL only asks for `updated >= -Nm`, so they would be
// lost until someone edits them again). Other projects still sync.
func TestSyncer_Sync_UpsertFailureKeepsProjectWatermark(t *testing.T) {
	database := revokedSyncerDB(t)
	for i, key := range []string{"OPS", "SEC"} {
		require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
			AccountID: 1, ID: i + 1, Name: key, ProjectKey: key, IsSelected: true, SyncedAt: "now",
		}))
	}
	// Simulate a transient write failure (e.g. SQLITE_BUSY) for OPS only.
	_, err := database.Exec(`CREATE TRIGGER fail_ops BEFORE INSERT ON jira_issues
		WHEN NEW.key LIKE 'OPS-%'
		BEGIN SELECT RAISE(ABORT, 'injected issue write failure'); END`)
	require.NoError(t, err)

	mux := http.NewServeMux()
	mux.HandleFunc("/rest/api/3/search/jql", func(w http.ResponseWriter, r *http.Request) {
		project := "SEC"
		if strings.Contains(r.URL.Query().Get("jql"), "project = OPS") {
			project = "OPS"
		}
		issue := map[string]any{
			"id": project + "1", "key": project + "-1",
			"fields": map[string]any{
				"summary":   "work",
				"issuetype": map[string]any{"name": "Task"},
				"status":    map[string]any{"name": "In Progress", "statusCategory": map[string]any{"key": "indeterminate"}},
				"created":   "2026-07-01T10:00:00.000+0000",
				"updated":   "2026-07-05T10:00:00.000+0000",
			},
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"issues": []any{issue}, "isLast": true})
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{}`))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	n, err := quietSyncer(t, database, srv.URL).Sync(context.Background())
	require.NoError(t, err, "a per-project failure stays a nil return")
	assert.Equal(t, 1, n, "only the SEC issue was written")

	ops, err := database.GetJiraSyncState(1, "OPS")
	require.NoError(t, err)
	require.NotNil(t, ops, "the failed project must get an error row")
	assert.Empty(t, ops.LastSyncedAt, "a failed write must not advance the watermark past the lost issues")
	assert.Contains(t, ops.LastError, "injected issue write failure")

	sec, err := database.GetJiraSyncState(1, "SEC")
	require.NoError(t, err)
	require.NotNil(t, sec)
	assert.NotEmpty(t, sec.LastSyncedAt, "a sibling project must still sync")
	assert.Empty(t, sec.LastError)
}

// pagedOPSServer serves project OPS as three single-issue pages (OPS-1,
// OPS-2, OPS-3), chained by nextPageToken.
func pagedOPSServer(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/rest/api/3/search/jql", func(w http.ResponseWriter, r *http.Request) {
		page := map[string]int{"": 1, "p2": 2, "p3": 3}[r.URL.Query().Get("nextPageToken")]
		issue := map[string]any{
			"id": fmt.Sprintf("OPS%d", page), "key": fmt.Sprintf("OPS-%d", page),
			"fields": map[string]any{
				"summary":   "work",
				"issuetype": map[string]any{"name": "Task"},
				"status":    map[string]any{"name": "In Progress", "statusCategory": map[string]any{"key": "indeterminate"}},
				"created":   "2026-07-01T10:00:00.000+0000",
				"updated":   "2026-07-05T10:00:00.000+0000",
			},
		}
		body := map[string]any{"issues": []any{issue}, "isLast": page == 3}
		if page < 3 {
			body["nextPageToken"] = fmt.Sprintf("p%d", page+1)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(body)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{}`))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

// failMiddleBatchDB seeds one selected OPS board and makes the OPS-2 write
// (the middle page) fail.
func failMiddleBatchDB(t *testing.T) *db.DB {
	t.Helper()
	database := revokedSyncerDB(t)
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 1, Name: "OPS", ProjectKey: "OPS", IsSelected: true, SyncedAt: "now",
	}))
	_, err := database.Exec(`CREATE TRIGGER fail_ops2 BEFORE INSERT ON jira_issues
		WHEN NEW.key = 'OPS-2'
		BEGIN SELECT RAISE(ABORT, 'injected issue write failure'); END`)
	require.NoError(t, err)
	return database
}

func assertMiddleBatchFailure(t *testing.T, database *db.DB) {
	t.Helper()
	for _, key := range []string{"OPS-1", "OPS-3"} {
		issue, err := database.GetJiraIssueByKey(key)
		require.NoError(t, err)
		assert.NotNil(t, issue, "%s: a failed batch must not stop the batches around it", key)
	}
	ops, err := database.GetJiraSyncState(1, "OPS")
	require.NoError(t, err)
	require.NotNil(t, ops, "the failed project must get an error row")
	assert.Empty(t, ops.LastSyncedAt, "a failed batch must not advance the watermark")
	assert.Contains(t, ops.LastError, "injected issue write failure")
}

// TestSyncer_Sync_FailedMiddleBatchKeepsWritingLaterBatches: one failed
// batch no longer stops the pass — a deterministic poison batch would
// otherwise freeze every later issue of the project behind it on every
// cycle. The batches after it are still written; the first error is still
// returned, so the watermark stays put and the lost batch is re-asked.
func TestSyncer_Sync_FailedMiddleBatchKeepsWritingLaterBatches(t *testing.T) {
	database := failMiddleBatchDB(t)
	n, err := quietSyncer(t, database, pagedOPSServer(t).URL).Sync(context.Background())
	require.NoError(t, err, "a per-project failure stays a nil return")
	assert.Equal(t, 0, n, "a failed project contributes nothing to the count")
	assertMiddleBatchFailure(t, database)
}
