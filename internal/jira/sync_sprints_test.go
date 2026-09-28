package jira

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// sprintPageServer serves /rest/agile/1.0/board/1/sprint the way Jira Agile
// does: per state, sprints in a fixed order, sliced by startAt into pages of
// pageSize regardless of the requested maxResults, with isLast on the final
// page. It counts requests per state.
func sprintPageServer(t *testing.T, byState map[string][]Sprint, pageSize int, calls map[string]*atomic.Int32) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/rest/agile/1.0/board/1/sprint", func(w http.ResponseWriter, r *http.Request) {
		state := r.URL.Query().Get("state")
		if c := calls[state]; c != nil {
			c.Add(1)
		}
		startAt, _ := strconv.Atoi(r.URL.Query().Get("startAt"))
		all := byState[state]
		end := min(startAt+pageSize, len(all))
		page := SprintList{StartAt: startAt, MaxResults: pageSize, IsLast: end >= len(all)}
		if startAt < len(all) {
			page.Values = all[startAt:end]
		}
		_ = json.NewEncoder(w).Encode(page)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func seedSprintBoard(t *testing.T, database *db.DB) {
	t.Helper()
	require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
		AccountID: 1, ID: 1, Name: "B", ProjectKey: "PROJ", IsSelected: true, SyncedAt: "now",
	}))
}

func sprintState(t *testing.T, database *db.DB, id int) string {
	t.Helper()
	var state string
	require.NoError(t, database.QueryRow(
		`SELECT state FROM jira_sprints WHERE account_id = 1 AND id = ?`, id).Scan(&state))
	return state
}

// TestSyncSprints_PagesThroughClosedSprints pins the pagination fix: Jira
// returns closed sprints oldest first, so on a board with more closed sprints
// than one page holds, the sprint that just ended is only on a later page.
// Reading page one alone left its row 'active' forever.
func TestSyncSprints_PagesThroughClosedSprints(t *testing.T) {
	database := revokedSyncerDB(t)
	seedSprintBoard(t, database)
	// The previous sync saw sprint 5 while it was running.
	require.NoError(t, database.UpsertJiraSprint(db.JiraSprint{
		AccountID: 1, ID: 5, BoardID: 1, Name: "Sprint 5", State: "active", SyncedAt: "then",
	}))

	closed := make([]Sprint, 0, 5)
	for id := 1; id <= 5; id++ {
		closed = append(closed, Sprint{ID: id, Name: "Sprint " + strconv.Itoa(id), State: "closed"})
	}
	calls := map[string]*atomic.Int32{"active": {}, "closed": {}}
	srv := sprintPageServer(t, map[string][]Sprint{
		"active": {{ID: 6, Name: "Sprint 6", State: "active"}},
		"closed": closed,
	}, 2, calls)

	require.NoError(t, quietSyncer(t, database, srv.URL).SyncSprints(context.Background()))

	assert.Equal(t, "closed", sprintState(t, database, 5), "the recently finished sprint sits on the last closed page")
	for id := 1; id <= 4; id++ {
		assert.Equal(t, "closed", sprintState(t, database, id))
	}
	active, err := database.GetJiraActiveSprints(1, 1)
	require.NoError(t, err)
	require.Len(t, active, 1)
	assert.Equal(t, 6, active[0].ID)
	assert.Equal(t, int32(3), calls["closed"].Load(), "5 closed sprints in pages of 2 = 3 requests")
	assert.Equal(t, int32(1), calls["active"].Load())
}

// TestSyncSprints_StopsAtPageCap guards the upper bound: a server that never
// reports isLast must not keep the sync paging forever.
func TestSyncSprints_StopsAtPageCap(t *testing.T) {
	database := revokedSyncerDB(t)
	seedSprintBoard(t, database)

	var closedCalls atomic.Int32
	mux := http.NewServeMux()
	mux.HandleFunc("/rest/agile/1.0/board/1/sprint", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("state") == "active" {
			_, _ = w.Write([]byte(`{"values":[],"isLast":true}`))
			return
		}
		n := closedCalls.Add(1)
		_ = json.NewEncoder(w).Encode(SprintList{Values: []Sprint{{ID: int(n), Name: "S", State: "closed"}}})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	require.NoError(t, quietSyncer(t, database, srv.URL).SyncSprints(context.Background()))

	assert.Equal(t, int32(maxSprintPages), closedCalls.Load())
	assert.Equal(t, "closed", sprintState(t, database, maxSprintPages), "pages fetched before the cap are still stored")
}

// A non-auth failure on a later page is logged and skipped, but the sprints
// already read for that board and state are still stored.
func TestSyncSprints_MidPaginationFailureKeepsEarlierPages(t *testing.T) {
	database := revokedSyncerDB(t)
	seedSprintBoard(t, database)
	require.NoError(t, database.UpsertJiraSprint(db.JiraSprint{
		AccountID: 1, ID: 1, BoardID: 1, Name: "Sprint 1", State: "active", SyncedAt: "then",
	}))

	mux := http.NewServeMux()
	mux.HandleFunc("/rest/agile/1.0/board/1/sprint", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("state") != "closed" {
			_ = json.NewEncoder(w).Encode(SprintList{IsLast: true})
			return
		}
		if startAt, _ := strconv.Atoi(r.URL.Query().Get("startAt")); startAt > 0 {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(w).Encode(SprintList{MaxResults: 2, Values: []Sprint{
			{ID: 1, Name: "Sprint 1", State: "closed"},
			{ID: 2, Name: "Sprint 2", State: "closed"},
		}})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	require.NoError(t, quietSyncer(t, database, srv.URL).SyncSprints(context.Background()))
	assert.Equal(t, "closed", sprintState(t, database, 1), "page 1 is stored despite the page-2 failure")
	assert.Equal(t, "closed", sprintState(t, database, 2))
}
