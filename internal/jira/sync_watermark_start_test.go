package jira

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
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
	start := time.Date(2026, 3, 1, 10, 0, 0, 0, time.UTC)
	var clock atomic.Int64 // the pass clock, in Unix seconds
	clock.Store(start.Unix())
	var searched atomic.Bool
	mux := http.NewServeMux()
	mux.HandleFunc("/rest/api/3/search/jql", func(w http.ResponseWriter, _ *http.Request) {
		searched.Store(true)
		body, _ := json.Marshal(SearchResult{Issues: []Issue{makeIssue("PROJ-1")}, IsLast: true})
		_, _ = w.Write(body)
	})
	mux.HandleFunc("/rest/api/3/issue/PROJ-1/comment", func(w http.ResponseWriter, _ *http.Request) {
		clock.Add(int64(time.Hour / time.Second)) // a slow comment pass
		_, _ = w.Write([]byte(`{"startAt":0,"maxResults":50,"total":0,"comments":[]}`))
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"values":[]}`))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	s := quietSyncer(t, database, srv.URL)
	s.passClock = func() time.Time { return time.Unix(clock.Load(), 0) }
	s.SetCommentSyncLimit(10)
	_, err := s.Sync(context.Background())
	require.NoError(t, err)

	state, err := database.GetJiraSyncState(1, "PROJ")
	require.NoError(t, err)
	require.NotNil(t, state)
	require.True(t, searched.Load(), "the issue search must have run")
	require.NotEqual(t, start.Unix(), clock.Load(), "the comment pass must have run")
	assert.Equal(t, start.Format(time.RFC3339), state.LastSyncedAt,
		"the watermark is the pass start, not the end of the comment pass")
}
