package jira

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestSyncer_Sync_WatermarkIsThePassStart pins that the project watermark is
// the moment the pass started, not when its comment pass finished: the next
// JQL only overlaps the watermark by 2 minutes, so a finish-time stamp after a
// long comment pass would skip every issue updated between the reader's last
// page and the stamp.
func TestSyncer_Sync_WatermarkIsThePassStart(t *testing.T) {
	database := syncerDBWithBoard(t, "PROJ")
	require.NoError(t, database.UpdateJiraSyncState(1, "PROJ", "2026-01-01T00:00:00Z", 0))
	var (
		mu       sync.Mutex
		searchAt time.Time
	)
	mux := http.NewServeMux()
	mux.HandleFunc("/rest/api/3/search/jql", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		if searchAt.IsZero() {
			searchAt = time.Now().UTC()
		}
		mu.Unlock()
		body, _ := json.Marshal(SearchResult{Issues: []Issue{makeIssue("PROJ-1")}, IsLast: true})
		_, _ = w.Write(body)
	})
	mux.HandleFunc("/rest/api/3/issue/PROJ-1/comment", func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(1100 * time.Millisecond) // a slow comment pass, past the next second
		_, _ = w.Write([]byte(`{"startAt":0,"maxResults":50,"total":0,"comments":[]}`))
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"values":[]}`))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	s := quietSyncer(t, database, srv.URL)
	s.SetCommentSyncLimit(10)
	_, err := s.Sync(context.Background())
	require.NoError(t, err)

	state, err := database.GetJiraSyncState(1, "PROJ")
	require.NoError(t, err)
	require.NotNil(t, state)
	wm, err := time.Parse(time.RFC3339, state.LastSyncedAt)
	require.NoError(t, err)
	mu.Lock()
	defer mu.Unlock()
	require.False(t, searchAt.IsZero(), "the issue search must have run")
	assert.False(t, wm.After(searchAt),
		"watermark %s must not be later than the issue search (%s)", wm, searchAt)
}
