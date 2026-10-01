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
// "". The value must be requested and stored in UTC (db.FormatJiraTime), the shape every
// reader (julianday() in the Desktop stale query, the RFC3339 string cutoff
// in GetStaleJiraIssues, the Go day counters) can parse.
func TestSync_StoresStatusCategoryChangedAt(t *testing.T) {
	database := openTestDB(t)
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
	_, err := syncer.Sync(context.Background())
	require.NoError(t, err)

	got, _ := fieldsRequested.Load().(string)
	assert.Contains(t, strings.Split(got, ","), "statuscategorychangedate",
		"the search must request statuscategorychangedate")

	var stored string
	require.NoError(t, database.QueryRow(
		`SELECT status_category_changed_at FROM jira_issues WHERE key = 'TEST-1'`).Scan(&stored))
	assert.Equal(t, db.FormatJiraTime(changed), stored)

	// The issue has sat in progress for 10 days, so the 7-day stale query
	// (RFC3339 string cutoff) must find it.
	stale, err := database.GetStaleJiraIssues(time.Now().AddDate(0, 0, -7).UTC().Format(time.RFC3339))
	require.NoError(t, err)
	require.Len(t, stale, 1)
	assert.Equal(t, "TEST-1", stale[0].Key)
}

func TestNormalizeTimestamp(t *testing.T) {
	ts := time.Now().Truncate(time.Second)
	want := db.FormatJiraTime(ts)
	west, east := time.FixedZone("", -5*3600), time.FixedZone("", 2*3600)
	cases := []struct {
		name, in, want string
		ok             bool
	}{
		{"jira offset", ts.In(west).Format("2006-01-02T15:04:05.000-0700"), want, true},
		{"jira offset, no fraction", ts.In(west).Format("2006-01-02T15:04:05-0700"), want, true},
		{"jira offset, long fraction", ts.Add(123456 * time.Microsecond).In(east).Format("2006-01-02T15:04:05.000000-0700"), db.FormatJiraTime(ts.Add(123 * time.Millisecond)), true},
		{"rfc3339", ts.In(east).Format(time.RFC3339), want, true},
		// An unknown shape is kept verbatim rather than dropped.
		{"empty", "", "", false},
		{"unparseable", "2024-01-15 10:30", "2024-01-15 10:30", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := NormalizeTimestamp(tc.in)
			assert.Equal(t, tc.want, got)
			assert.Equal(t, tc.ok, ok)
		})
	}
}

// TestFindStaleIssues_CutoffIsUTC: the stale query compares the column's
// RFC3339 UTC strings against the cutoff, so a cutoff rendered in a local
// zone east of UTC would call an issue stale hours before its 7 days are up.
func TestFindStaleIssues_CutoffIsUTC(t *testing.T) {
	database := openTestDB(t)
	now := time.Now().In(time.FixedZone("", 14*3600))
	changed := now.AddDate(0, 0, -7).Add(2 * time.Hour).UTC().Format(time.RFC3339)
	require.NoError(t, database.UpsertJiraIssue(db.JiraIssue{
		AccountID: 1, Key: "TEST-1", ProjectKey: "TEST", Summary: "s", Status: "In Progress",
		StatusCategory: "in_progress", StatusCategoryChangedAt: changed,
		Labels: "[]", Components: "[]", FixVersions: "[]", CreatedAt: changed, UpdatedAt: changed, SyncedAt: changed,
	}))

	stale, err := findStaleIssues(database, now, nil)
	require.NoError(t, err)
	assert.Empty(t, stale, "2 hours inside the 7-day window is not stale in any local zone")
}
