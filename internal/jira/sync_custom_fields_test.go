package jira

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestSync_MappedCustomFieldsReachTheIssueRow: a board with a field mapping
// (the MapFieldsForBoard output) must have its mapped custom fields requested
// from the search API and written to the issue row — story points, a
// planned-end date standing in for an empty due date, and a display value for
// any other role. The same pass resolves the assignee's Slack id from the
// user map and records a shell user-map row for a reporter it has not seen.
func TestSync_MappedCustomFieldsReachTheIssueRow(t *testing.T) {
	database := openTestDB(t)
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 42, Name: "Test Board", ProjectKey: "TEST", BoardType: "scrum", IsSelected: true,
	}))
	require.NoError(t, database.UpsertJiraBoardFieldMap(1, 42, []db.JiraBoardFieldMap{
		{FieldID: "customfield_10016", Role: "story_points"},
		{FieldID: "customfield_200", Role: "planned_end"},
		{FieldID: "customfield_300", Role: "team"},
	}))
	require.NoError(t, database.UpsertJiraUserMap(db.JiraUserMap{
		JiraAccountID: "acc-assignee", SlackUserID: "UASSIGNEE", DisplayName: "Assignee", MatchMethod: "manual",
	}))

	plannedEnd := time.Now().UTC().AddDate(0, 0, 10).Format("2006-01-02")
	updated := time.Now().UTC().Add(-time.Hour).Format("2006-01-02T15:04:05.000-0700")
	var mu sync.Mutex
	var requested []string
	mux := http.NewServeMux()
	mux.HandleFunc("/rest/api/3/search/jql", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		requested = append(requested, r.URL.Query().Get("fields"))
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"issues": []map[string]any{{"id": "1001", "key": "TEST-1", "fields": map[string]any{
				"summary":           "Estimated work",
				"issuetype":         map[string]any{"name": "Story"},
				"status":            map[string]any{"name": "In Progress", "statusCategory": map[string]any{"key": "indeterminate"}},
				"created":           updated,
				"updated":           updated,
				"assignee":          map[string]any{"accountId": "acc-assignee", "displayName": "Assignee"},
				"reporter":          map[string]any{"accountId": "acc-reporter", "displayName": "Reporter"},
				"customfield_10016": 5,
				"customfield_200":   plannedEnd,
				"customfield_300":   map[string]any{"value": "Core"},
			}}},
			"isLast": true,
		})
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{}`))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	syncer := NewSyncer(makeTestClient(t, srv.URL), database, NewUserMapper(nil, database), []int{42}, 1)
	_, err := syncer.Sync(context.Background())
	require.NoError(t, err)

	mu.Lock()
	require.NotEmpty(t, requested)
	fields := strings.Split(requested[0], ",")
	mu.Unlock()
	assert.Contains(t, fields, "customfield_10016")
	assert.Contains(t, fields, "customfield_200")
	assert.Contains(t, fields, "customfield_300")

	issue, err := database.GetJiraIssue(1, "TEST-1")
	require.NoError(t, err)
	require.NotNil(t, issue)
	require.NotNil(t, issue.StoryPoints, "story points from the mapped field")
	assert.InDelta(t, 5.0, *issue.StoryPoints, 1e-9)
	assert.Equal(t, plannedEnd, issue.DueDate, "planned_end stands in for an empty due date")
	assert.JSONEq(t, `{"team":"Core"}`, issue.CustomFieldsJSON)
	assert.Equal(t, "UASSIGNEE", issue.AssigneeSlackID)

	reporter, err := database.GetJiraUserMapByAccountID("acc-reporter")
	require.NoError(t, err)
	require.NotNil(t, reporter, "an unseen reporter gets a shell user-map row")
	assert.Equal(t, "Reporter", reporter.DisplayName)
}
