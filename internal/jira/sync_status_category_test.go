package jira

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestSync_StoresStatusCategoryChangedAt reproduces board #184: every
// jira_issues.status_category_changed_at stayed empty because the search
// never asked Jira for statuscategorychangedate and convertIssue hard-coded
// "". The value must be requested and stored as RFC3339 UTC, the shape every
// reader (julianday() in the Desktop stale query, the RFC3339 string cutoff
// in GetStaleJiraIssues, the Go day counters) can parse.
func TestSync_StoresStatusCategoryChangedAt(t *testing.T) {
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	db.SeedTestJiraAccount(t, database)
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 42, Name: "Test Board", ProjectKey: "TEST", BoardType: "scrum", IsSelected: true,
	}))

	// Jira Cloud's own wire shape: millisecond precision, "+hhmm" offset.
	changed := time.Now().Add(-10 * 24 * time.Hour).Truncate(time.Second).In(time.FixedZone("", 3*3600))
	wire := changed.Format("2006-01-02T15:04:05.000-0700")

	var fieldsRequested atomic.Value
	mux := http.NewServeMux()
	mux.HandleFunc("/rest/api/3/search/jql", func(w http.ResponseWriter, r *http.Request) {
		fieldsRequested.Store(r.URL.Query().Get("fields"))
		fields := map[string]any{
			"summary":   "Stuck work",
			"issuetype": map[string]any{"name": "Task"},
			"status":    map[string]any{"name": "In Progress", "statusCategory": map[string]any{"key": "indeterminate"}},
			"created":   wire,
			"updated":   wire,
		}
		if strings.Contains(r.URL.Query().Get("fields"), "statuscategorychangedate") {
			fields["statuscategorychangedate"] = wire
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"issues": []map[string]any{{"id": "1001", "key": "TEST-1", "fields": fields}},
			"isLast": true,
		})
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{}`))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	syncer := NewSyncer(makeTestClient(t, srv.URL), database, nil, []int{42}, 1)
	_, err = syncer.Sync(context.Background())
	require.NoError(t, err)

	got, _ := fieldsRequested.Load().(string)
	assert.Contains(t, strings.Split(got, ","), "statuscategorychangedate",
		"the search must request statuscategorychangedate")

	var stored string
	require.NoError(t, database.QueryRow(
		`SELECT status_category_changed_at FROM jira_issues WHERE key = 'TEST-1'`).Scan(&stored))
	assert.Equal(t, changed.UTC().Format(time.RFC3339), stored)

	// The issue has sat in progress for 10 days, so the 7-day stale query
	// (RFC3339 string cutoff) must find it.
	stale, err := database.GetStaleJiraIssues(time.Now().AddDate(0, 0, -7).UTC().Format(time.RFC3339))
	require.NoError(t, err)
	require.Len(t, stale, 1)
	assert.Equal(t, "TEST-1", stale[0].Key)
}

func TestNormalizeTimestamp(t *testing.T) {
	ts := time.Now().Truncate(time.Second)
	cases := []struct {
		name, in, want string
	}{
		{"empty", "", ""},
		{"jira offset", ts.In(time.FixedZone("", -5*3600)).Format("2006-01-02T15:04:05.000-0700"), ts.UTC().Format(time.RFC3339)},
		{"rfc3339", ts.In(time.FixedZone("", 2*3600)).Format(time.RFC3339), ts.UTC().Format(time.RFC3339)},
		// An unknown shape is kept verbatim rather than dropped.
		{"unparseable", "yesterday", "yesterday"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			assert.Equal(t, tc.want, NormalizeTimestamp(tc.in))
		})
	}
}
