package sync

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// jsonOK writes an ok:true JSON body.
func jsonOK(w http.ResponseWriter, body map[string]any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(body)
}

// searchAuditMux registers the endpoints a search-path sync needs, wiring the
// caller-supplied search.messages handler. It intentionally avoids baseMux()
// (which already owns /search.messages) so tests can drive pagination.
func searchAuditMux(searchHandler http.HandlerFunc) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/team.info", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": true, "team": map[string]any{"id": "T001", "name": "test", "domain": "test"}})
	})
	mux.HandleFunc("/auth.test", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": true, "user_id": "U001", "user": "alice", "team_id": "T001"})
	})
	mux.HandleFunc("/emoji.list", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": true, "emoji": map[string]string{}})
	})
	mux.HandleFunc("/users.list", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": true, "members": []map[string]any{}, "response_metadata": map[string]any{"next_cursor": ""}})
	})
	mux.HandleFunc("/users.info", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": false, "error": "user_not_found"})
	})
	mux.HandleFunc("/conversations.info", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": true, "channel": map[string]any{"id": "C001", "last_read": ""}})
	})
	mux.HandleFunc("/search.messages", searchHandler)
	return mux
}

// TestSearchSync_PartialPaginationKeepsWatermark reproduces audit bug 2.1: when
// search.messages pagination breaks early (non-fatal error on a later page), the
// watermark must NOT jump to today, otherwise the unfetched older pages are lost
// forever. Page 1 succeeds (pages=3), page 2 errors → watermark stays put.
func TestSearchSync_PartialPaginationKeepsWatermark(t *testing.T) {
	// slack-go does not surface the page number as a stable form field, so drive
	// pagination by call order: first call is page 1 (of 3), second call errors.
	var calls int
	var mu sync.Mutex
	search := func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		calls++
		n := calls
		mu.Unlock()
		if n == 1 {
			jsonOK(w, map[string]any{
				"ok": true,
				"messages": map[string]any{
					"matches": []map[string]any{
						{"user": "U001", "username": "alice", "ts": "1700000000.000100", "text": "hi",
							"channel": map[string]any{"id": "C001", "name": "general"}},
					},
					"paging": map[string]any{"count": 100, "total": 250, "page": 1, "pages": 3},
					"total":  250,
				},
			})
			return
		}
		// Second page: non-fatal error interrupts pagination mid-stream.
		jsonOK(w, map[string]any{"ok": false, "error": "missing_scope"})
	}

	ts := newTestSetup(t, searchAuditMux(http.HandlerFunc(search)))
	require.NoError(t, ts.db.UpsertWorkspace(db.Workspace{ID: "T001", Name: "test", Domain: "test"}))
	require.NoError(t, ts.db.SetSearchLastDate("2020-01-01"))

	err := ts.orch.Run(context.Background(), SyncOptions{})
	require.NoError(t, err)

	got, err := ts.db.GetSearchLastDate()
	require.NoError(t, err)
	assert.Equal(t, "2020-01-01", got,
		"interrupted pagination must leave search_last_date untouched to avoid dropping unfetched pages")
}

// TestSearchSync_MissingScopeFallsBackToFullSync reproduces audit bug 2.2: a
// token without search:read makes search.messages fail non-fatally on page 1.
// With channels already in the DB, the old code reported success with zero
// messages. The fix must fall back to full sync (conversations.history) instead.
func TestSearchSync_MissingScopeFallsBackToFullSync(t *testing.T) {
	var historyHits int
	var mu sync.Mutex

	mux := searchAuditMux(func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": false, "error": "missing_scope"})
	})
	// Full-sync-only endpoints; a hit on conversations.history proves fallback.
	mux.HandleFunc("/conversations.list", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{
			"ok": true,
			"channels": []map[string]any{
				{"id": "C001", "name": "general", "is_channel": true, "is_member": true,
					"topic": map[string]any{"value": ""}, "purpose": map[string]any{"value": ""}},
			},
			"response_metadata": map[string]any{"next_cursor": ""},
		})
	})
	mux.HandleFunc("/conversations.history", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		historyHits++
		mu.Unlock()
		jsonOK(w, map[string]any{"ok": true, "messages": []any{}, "has_more": false, "response_metadata": map[string]any{"next_cursor": ""}})
	})
	mux.HandleFunc("/conversations.replies", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": true, "messages": []any{}, "has_more": false, "response_metadata": map[string]any{"next_cursor": ""}})
	})

	ts := newTestSetup(t, mux)
	require.NoError(t, ts.db.UpsertWorkspace(db.Workspace{ID: "T001", Name: "test", Domain: "test"}))
	// A pre-existing channel means the "0 channels" fallback would NOT fire —
	// so only the scope-error fallback can rescue this sync.
	require.NoError(t, ts.db.UpsertChannel(db.Channel{ID: "C001", Name: "general", Type: "public", IsMember: true}))

	err := ts.orch.Run(context.Background(), SyncOptions{})
	require.NoError(t, err)

	mu.Lock()
	defer mu.Unlock()
	assert.Positive(t, historyHits,
		"missing search:read scope must fall back to full sync (conversations.history), not report a silent zero-message success")
}
