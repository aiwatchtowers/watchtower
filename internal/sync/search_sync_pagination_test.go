package sync

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestIsScopeError pins isScopeError's distinction from isNonFatalError: a
// rate limit is non-fatal (the sync should keep going / retry later) but is
// NOT a scope error (it must never trigger the full-sync fallback), while
// missing_scope/access_denied are both non-fatal AND scope errors.
func TestIsScopeError(t *testing.T) {
	assert.False(t, isScopeError(nil))
	assert.False(t, isScopeError(errFromString("rate_limited")),
		"a rate limit must not be treated as a scope error")
	assert.True(t, isScopeError(errFromString("missing_scope")))
	assert.True(t, isScopeError(errFromString("access_denied")))
	assert.False(t, isScopeError(errFromString("channel_not_found")),
		"a non-fatal error that isn't scope/permission-shaped must not count")
}

// TestBisectSearchDate pins the pure date-bisection helper: a window of at
// least 2 days splits at its midpoint; a window already down to a single day
// (or less) reports ok=false, since search.messages date filters have no
// finer granularity to split with.
func TestBisectSearchDate(t *testing.T) {
	now := time.Date(2024, 6, 15, 12, 0, 0, 0, time.UTC)

	mid, ok := bisectSearchDate("2024-01-01", "2024-01-11", now)
	assert.True(t, ok)
	assert.Equal(t, "2024-01-06", mid)

	// Open-ended window (before == ""): splits against "now".
	mid, ok = bisectSearchDate("2024-06-01", "", now)
	assert.True(t, ok)
	assert.Equal(t, "2024-06-08", mid)

	_, ok = bisectSearchDate("2024-01-01", "2024-01-02", now)
	assert.False(t, ok, "a 1-day window can't be split further")

	_, ok = bisectSearchDate("2024-01-01", "2024-01-01", now)
	assert.False(t, ok, "a zero-width window can't be split further")

	_, ok = bisectSearchDate("not-a-date", "2024-01-02", now)
	assert.False(t, ok, "an unparseable date must not panic or split")
}

// TestSyncViaSearch_RateLimitedFirstPageDoesNotFallBackToFullSync reproduces
// the "a rate-limited first search page triggers a full conversations sync"
// finding: when Slack is already throttling the token (search.messages
// answers 429 on every attempt), the sync must not fall back to the far more
// expensive full sync (conversations.history/conversations.list) — it should
// just end the cycle with the watermark untouched, letting the next run
// retry via search again.
func TestSyncViaSearch_RateLimitedFirstPageDoesNotFallBackToFullSync(t *testing.T) {
	var historyHits int32
	var mu sync.Mutex

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
	mux.HandleFunc("/search.messages", func(w http.ResponseWriter, _ *http.Request) {
		// A real Slack rate-limit response: HTTP 429 with Retry-After, not a
		// JSON ok:false body — this is what doRequest's retry loop, and in
		// turn isNonFatalError's *slack.RateLimitedError branch, actually see.
		w.Header().Set("Retry-After", "0")
		w.WriteHeader(http.StatusTooManyRequests)
	})
	// Full-sync-only endpoints; a hit on either proves the (undesired)
	// fallback happened.
	mux.HandleFunc("/conversations.list", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		historyHits++
		mu.Unlock()
		jsonOK(w, map[string]any{"ok": true, "channels": []map[string]any{}, "response_metadata": map[string]any{"next_cursor": ""}})
	})
	mux.HandleFunc("/conversations.history", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		historyHits++
		mu.Unlock()
		jsonOK(w, map[string]any{"ok": true, "messages": []any{}, "has_more": false, "response_metadata": map[string]any{"next_cursor": ""}})
	})
	mux.HandleFunc("/users.list", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": true, "members": []map[string]any{}, "response_metadata": map[string]any{"next_cursor": ""}})
	})

	ts := newTestSetup(t, mux)
	require.NoError(t, ts.db.UpsertWorkspace(db.Workspace{ID: "T001", Name: "test", Domain: "test"}))
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, "2020-01-01"))

	err := ts.orch.Run(context.Background(), SyncOptions{})
	require.NoError(t, err, "a rate limit must end the cycle cleanly, not abort the sync")

	mu.Lock()
	defer mu.Unlock()
	assert.Zero(t, historyHits,
		"a rate-limited search page must not fall back to the full conversations sync")

	got, err := ts.db.GetSlackAccountSearchWatermark(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, "2020-01-01", got, "the watermark must stay untouched so the next cycle retries via search")
}

// searchPagingMux builds a /search.messages handler keyed on the request's
// "query"/"page" form values so a test can drive an exact pagination shape
// (including a date-range split) without depending on real Slack pagination
// semantics.
func searchPagingMux(handler http.HandlerFunc) *http.ServeMux {
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
	mux.HandleFunc("/search.messages", handler)
	return mux
}

func searchMatch(id string) map[string]any {
	return map[string]any{
		"user": "U001", "username": "alice", "ts": id + ".000100", "text": "hi",
		"channel": map[string]any{"id": "C001", "name": "general"},
	}
}

// TestRunSearchWindow_SplitsOverCapWindowByDate reproduces the "search sync
// can never finish a window with more than 100 result pages" finding: the
// window's own page 1 reports more pages than maxSearchResultPages allows
// paging through (Slack's ~10k-match practical cap). The fix must never
// attempt page 2 of that over-full window (a wasted/likely-failing call);
// instead it bisects the window by date and completes each half, ultimately
// covering the whole original range.
func TestRunSearchWindow_SplitsOverCapWindowByDate(t *testing.T) {
	var mu sync.Mutex
	var calls []string // one entry per request, e.g. "1:has-before" / "1:open"

	search := func(w http.ResponseWriter, r *http.Request) {
		require.NoError(t, r.ParseForm())
		query := r.FormValue("query")
		page := r.FormValue("page")
		if page == "" {
			page = "1"
		}
		if page != "1" {
			t.Errorf("unexpected request for page %s (query=%q): an over-cap window must never be paged past page 1", page, query)
		}

		mu.Lock()
		n := len(calls) + 1
		if strings.Contains(query, "before:") {
			calls = append(calls, "has-before")
		} else {
			calls = append(calls, "open")
		}
		mu.Unlock()

		if n == 1 {
			// The very first request: the whole, unsplit window. Report far
			// more pages than maxSearchResultPages allows.
			jsonOK(w, map[string]any{
				"ok": true,
				"messages": map[string]any{
					"matches": []map[string]any{searchMatch("170000000" + strconv.Itoa(n))},
					"paging":  map[string]any{"count": 100, "total": 20000, "page": 1, "pages": maxSearchResultPages * 2},
					"total":   20000,
				},
			})
			return
		}
		// Every split sub-window: small enough to complete in one page.
		jsonOK(w, map[string]any{
			"ok": true,
			"messages": map[string]any{
				"matches": []map[string]any{searchMatch("170000000" + strconv.Itoa(n))},
				"paging":  map[string]any{"count": 100, "total": 1, "page": 1, "pages": 1},
				"total":   1,
			},
		})
	}

	ts := newTestSetup(t, searchPagingMux(search))
	require.NoError(t, ts.db.UpsertWorkspace(db.Workspace{ID: "T001", Name: "test", Domain: "test"}))

	state := &searchSyncState{seenChannels: map[string]bool{}, seenUsers: map[string]bool{}}
	reached, err := ts.orch.runSearchWindow(context.Background(), state, "2024-01-01", "", 0)
	require.NoError(t, err)

	today := time.Now().Format(searchDateFormat)
	assert.Equal(t, today, reached, "a window that fully splits and completes must report reaching all the way to today")
	assert.Equal(t, 2, state.totalMessages, "one message from each split half; the outer over-cap detection request's own page 1 is discarded, never processed")

	mu.Lock()
	defer mu.Unlock()
	require.Len(t, calls, 3, "outer detection page 1, then exactly one page-1 request per split half")
	assert.Equal(t, "open", calls[0])
	assert.Equal(t, "has-before", calls[1], "the older half must carry an explicit before: bound")
	assert.Equal(t, "open", calls[2], "the newer half reuses the original (open-ended) upper bound")
}

// TestRunSearchWindow_UnsplittableFloorRecordsGapAndAdvances covers the
// safety-net floor: a window already down to a single day (search.messages
// date filters have no finer granularity) that still reports more than
// maxSearchResultPages pages can't be split any further. Rather than
// re-fetching the same over-full day forever (never advancing, burning
// maxSearchResultPages calls every cycle for zero progress), it must be
// accepted as a logged, permanent gap and skipped.
func TestRunSearchWindow_UnsplittableFloorRecordsGapAndAdvances(t *testing.T) {
	search := func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{
			"ok": true,
			"messages": map[string]any{
				"matches": []map[string]any{searchMatch("1700000000")},
				"paging":  map[string]any{"count": 100, "total": 20000, "page": 1, "pages": maxSearchResultPages * 2},
				"total":   20000,
			},
		})
	}

	ts := newTestSetup(t, searchPagingMux(search))
	require.NoError(t, ts.db.UpsertWorkspace(db.Workspace{ID: "T001", Name: "test", Domain: "test"}))

	state := &searchSyncState{seenChannels: map[string]bool{}, seenUsers: map[string]bool{}}
	reached, err := ts.orch.runSearchWindow(context.Background(), state, "2024-01-01", "2024-01-02", 0)
	require.NoError(t, err)
	assert.Equal(t, "2024-01-02", reached, "an unsplittable over-full day is still accepted as reached (skipped), not retried forever")

	got, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.Contains(t, got.Error, "still exceeds", "the permanent gap must be recorded on the account's error column")
	assert.Contains(t, got.Error, "2024-01-01")
	assert.Contains(t, got.Error, "2024-01-02")
}
