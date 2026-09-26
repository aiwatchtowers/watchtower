package jira

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// --- Audit 2.4: incremental JQL must be timezone-independent ---

// TestBuildIncrementalJQL_TimezoneIndependent reproduces audit bug 2.4: an
// absolute JQL datetime literal (e.g. "2026-07-05 11:00") is interpreted in the
// Jira user's profile timezone, so a UTC watermark skips updates for any profile
// west of UTC. The incremental JQL must instead use a relative, timezone-agnostic
// window.
func TestBuildIncrementalJQL_TimezoneIndependent(t *testing.T) {
	now := time.Date(2026, 7, 5, 12, 0, 0, 0, time.UTC)
	watermark := now.Add(-1 * time.Hour).Format(time.RFC3339) // 60 minutes ago, UTC

	jql := buildIncrementalJQL("PROJ", watermark, now)

	assert.Contains(t, jql, "project = PROJ")
	assert.Contains(t, jql, "ORDER BY updated ASC")
	// 60 minutes elapsed + 2 minutes overlap = 62.
	assert.Contains(t, jql, "updated >= -62m",
		"incremental JQL must use a relative window that Jira evaluates the same in every timezone")
	assert.NotContains(t, jql, "2026-07-05 11",
		"incremental JQL must not embed an absolute wall-clock datetime (timezone-ambiguous)")
}

func TestBuildIncrementalJQL_NoWatermark(t *testing.T) {
	assert.Equal(t, "project = PROJ ORDER BY updated ASC",
		buildIncrementalJQL("PROJ", "", time.Now()))
}

func TestBuildIncrementalJQL_UnparseableWatermark(t *testing.T) {
	assert.Equal(t, "project = PROJ ORDER BY updated ASC",
		buildIncrementalJQL("PROJ", "not-a-timestamp", time.Now()))
}

// --- Audit 2.5: SyncBoard must not block backfill of closed issues ---

// jiraSearchMux serves /rest/api/3/search/jql, returning different issues based
// on whether the JQL filters out Done issues (SyncBoard) or scans the whole
// project (the daemon's full Sync). Unknown paths return an empty object so
// sprint/release syncs fail non-fatally without hanging.
func jiraSearchMux() *http.ServeMux {
	activeIssue := map[string]any{
		"id": "1001", "key": "TEST-1",
		"fields": map[string]any{
			"summary":   "Active work",
			"issuetype": map[string]any{"name": "Task"},
			"status":    map[string]any{"name": "In Progress", "statusCategory": map[string]any{"key": "indeterminate"}},
			"created":   "2026-07-01T10:00:00.000+0000",
			"updated":   "2026-07-05T10:00:00.000+0000",
		},
	}
	closedIssue := map[string]any{
		"id": "1002", "key": "TEST-2",
		"fields": map[string]any{
			"summary":   "Finished work",
			"issuetype": map[string]any{"name": "Task"},
			"status":    map[string]any{"name": "Done", "statusCategory": map[string]any{"key": "done"}},
			"created":   "2026-06-01T10:00:00.000+0000",
			"updated":   "2026-06-02T10:00:00.000+0000",
		},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/rest/api/3/search/jql", func(w http.ResponseWriter, r *http.Request) {
		jql := r.URL.Query().Get("jql")
		issues := []map[string]any{activeIssue}
		if !strings.Contains(jql, "statusCategory != Done") {
			// Full project scan (no watermark) backfills the closed issue too.
			issues = append(issues, closedIssue)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"issues": issues, "isLast": true})
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{}`))
	})
	return mux
}

// TestSyncBoard_LeavesBacklogForDaemonBackfill reproduces audit bug 2.5:
// SyncBoard fast-loads only non-terminal issues but then wrote the project
// watermark, so the daemon's incremental Sync() never backfilled historical
// closed issues. The fix leaves the watermark unset so the first Sync() does a
// full project scan and picks up the closed issue.
func TestSyncBoard_LeavesBacklogForDaemonBackfill(t *testing.T) {
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	db.SeedTestJiraAccount(t, database)

	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 42, Name: "Test Board", ProjectKey: "TEST", BoardType: "scrum", IsSelected: true,
	}))

	srv := httptest.NewServer(jiraSearchMux())
	t.Cleanup(srv.Close)
	client := makeTestClient(t, srv.URL)
	syncer := NewSyncer(client, database, nil, []int{42}, 1)

	// Fast initial load: active issues only, no closed backfill yet.
	n, err := syncer.SyncBoard(context.Background(), 42)
	require.NoError(t, err)
	assert.Equal(t, 1, n, "SyncBoard should load only the active issue")

	// SyncBoard must NOT write a watermark, otherwise the daemon's incremental
	// Sync() would skip the historical closed issue forever.
	state, err := database.GetJiraSyncState(1, "TEST")
	require.NoError(t, err)
	if state != nil {
		assert.Empty(t, state.LastSyncedAt,
			"SyncBoard must not set a sync watermark; the first full Sync() backfills closed issues")
	}

	// The daemon's regular cycle: with no watermark it scans the whole project.
	_, err = syncer.Sync(context.Background())
	require.NoError(t, err)

	var statusCat string
	err = database.QueryRow(`SELECT status_category FROM jira_issues WHERE key = 'TEST-2'`).Scan(&statusCat)
	require.NoError(t, err, "closed issue TEST-2 must be backfilled into the DB by the daemon Sync()")
	assert.Equal(t, "done", statusCat)

	// After a full Sync(), the watermark is now set correctly.
	state, err = database.GetJiraSyncState(1, "TEST")
	require.NoError(t, err)
	require.NotNil(t, state)
	assert.NotEmpty(t, state.LastSyncedAt, "Sync() should record a watermark after the full pass")
}
