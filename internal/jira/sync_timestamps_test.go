package jira

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestSync_StoresIssueAndCommentTimestampsUTC: Jira returns every timestamp
// in the Jira profile's own "+hhmm" offset. The syncer stores issue
// created/updated/resolution and comment created/updated in UTC, so
// julianday() can read them (the dashboards' cycle time) and string order is
// instant order.
func TestSync_StoresIssueAndCommentTimestampsUTC(t *testing.T) {
	database := openTestDB(t)
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 42, Name: "Test Board", ProjectKey: "TEST", BoardType: "scrum", IsSelected: true,
	}))

	now := time.Now().UTC().Truncate(time.Second)
	east, west := time.FixedZone("", 3*3600), time.FixedZone("", -4*3600)
	wire := func(tm time.Time, zone *time.Location) string {
		return tm.In(zone).Format("2006-01-02T15:04:05.000-0700")
	}
	created, resolved := now.Add(-72*time.Hour), now.Add(-12*time.Hour)

	mux := http.NewServeMux()
	mux.HandleFunc("/rest/api/3/search/jql", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"issues": []map[string]any{{"id": "1001", "key": "TEST-1", "fields": map[string]any{
				"summary":        "Shipped",
				"issuetype":      map[string]any{"name": "Task"},
				"status":         map[string]any{"name": "Done", "statusCategory": map[string]any{"key": "done"}},
				"created":        wire(created, west),
				"updated":        wire(resolved, east),
				"resolutiondate": wire(resolved, east),
			}}},
			"isLast": true,
		})
	})
	mux.HandleFunc("/rest/api/3/issue/TEST-1/comment", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"total": 1, "comments": []map[string]any{{
			"id": "c1", "body": "done", "created": wire(created, west), "updated": wire(resolved, east),
		}}})
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{}`))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	syncer := NewSyncer(makeTestClient(t, srv.URL), database, nil, []int{42}, 1)
	syncer.SetCommentSyncLimit(10)
	_, err := syncer.Sync(context.Background())
	require.NoError(t, err)

	utc := db.FormatJiraTime
	issue, err := database.GetJiraIssue(1, "TEST-1")
	require.NoError(t, err)
	require.NotNil(t, issue)
	assert.Equal(t, utc(created), issue.CreatedAt)
	assert.Equal(t, utc(resolved), issue.UpdatedAt)
	assert.Equal(t, utc(resolved), issue.ResolvedAt)

	var commentCreated, commentUpdated string
	require.NoError(t, database.QueryRow(`SELECT created_at, updated_at FROM jira_comments WHERE id = 'c1'`).
		Scan(&commentCreated, &commentUpdated))
	assert.Equal(t, utc(created), commentCreated)
	assert.Equal(t, utc(resolved), commentUpdated)

	// A dashboard computation over the stored values: the cycle time is
	// julianday(resolved_at) - julianday(created_at), NULL (0 days) before.
	_, err = database.Exec(`UPDATE jira_issues SET assignee_slack_id = 'U1' WHERE key = 'TEST-1'`)
	require.NoError(t, err)
	stats, err := database.GetJiraDeliveryStats("U1", db.FormatJiraTime(now.Add(-24*time.Hour)), db.FormatJiraTime(now))
	require.NoError(t, err)
	assert.Equal(t, 1, stats.IssuesClosed, "the UTC range bounds find the issue resolved inside them")
	assert.InDelta(t, resolved.Sub(created).Hours()/24, stats.AvgCycleTimeDays, 1e-6)
}
