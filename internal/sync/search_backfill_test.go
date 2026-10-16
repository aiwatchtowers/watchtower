package sync

import (
	"context"
	"io"
	"log"
	"net/http"
	gosync "sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestSlackSearchRange(t *testing.T) {
	from := time.Date(2026, 9, 20, 15, 0, 0, 0, time.UTC)
	to := time.Date(2026, 9, 22, 15, 0, 0, 0, time.UTC)
	after, before := slackSearchRange(from, to)
	// after:/before: are exclusive and day-granular: widen by a day on each
	// side so both edge days are inside; the overlap is harmless (upsert).
	assert.Equal(t, "2026-09-19", after)
	assert.Equal(t, "2026-09-23", before)
}

// oneMatchSearch answers search.messages with one match on one page and
// records every query it was sent.
func oneMatchSearch(queries *[]string, mu *gosync.Mutex) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		mu.Lock()
		*queries = append(*queries, r.FormValue("query"))
		mu.Unlock()
		jsonOK(w, map[string]any{
			"ok": true,
			"messages": map[string]any{
				"matches": []map[string]any{
					{"user": "U001", "username": "alice", "ts": "1758380400.000100", "text": "old news",
						"channel": map[string]any{"id": "C001", "name": "general"}},
				},
				"paging": map[string]any{"count": 100, "total": 1, "page": 1, "pages": 1},
				"total":  1,
			},
		})
	}
}

func rateLimitedSearch(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Retry-After", "0")
	w.WriteHeader(http.StatusTooManyRequests)
}

func TestBackfillSearch_SavesRangeWithoutTouchingWatermarkOrAuthState(t *testing.T) {
	var queries []string
	var mu gosync.Mutex
	ts := newTestSetup(t, searchAuditMux(oneMatchSearch(&queries, &mu)))
	ts.orch.logger = log.New(io.Discard, "", 0)
	require.NoError(t, ts.db.SetSlackAccountAuthState(ts.accountID, "error", "prior note"))

	from := time.Date(2026, 9, 20, 15, 0, 0, 0, time.UTC)
	to := time.Date(2026, 9, 22, 15, 0, 0, 0, time.UTC)
	saved, err := ts.orch.BackfillSearch(context.Background(), from, to)
	require.NoError(t, err)
	assert.Equal(t, 1, saved)
	assert.Equal(t, []string{"after:2026-09-19 before:2026-09-23"}, queries)

	msgs, err := ts.db.GetMessagesByChannel(ts.ns("C001"), 10)
	require.NoError(t, err)
	require.Len(t, msgs, 1)
	assert.Equal(t, "old news", msgs[0].Text)

	wm, err := ts.db.GetSlackAccountSearchWatermark(ts.accountID)
	require.NoError(t, err)
	assert.Empty(t, wm, "a backfill must never write the search watermark")
	got, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, "error", got.Status, "a backfill must not touch auth state")
	assert.Equal(t, "prior note", got.Error)
	assert.False(t, ts.orch.searchRateLimited)
	assert.Empty(t, ts.orch.searchGapNote)
	snap := ts.orch.progress.Snapshot()
	assert.Zero(t, snap.MessagesFetched, "a backfill must not feed the progress heartbeat")
	assert.Zero(t, snap.DiscoveryChannels)
}

func TestBackfillSearch_RateLimitedIsAnErrorWithoutRunState(t *testing.T) {
	ts := newTestSetup(t, searchAuditMux(rateLimitedSearch))
	ts.orch.logger = log.New(io.Discard, "", 0)

	_, err := ts.orch.BackfillSearch(context.Background(),
		time.Date(2026, 9, 20, 0, 0, 0, 0, time.UTC), time.Date(2026, 9, 22, 0, 0, 0, 0, time.UTC))
	require.ErrorIs(t, err, ErrBackfillIncomplete, "R23: an incomplete search is a hold, not a failure")
	assert.False(t, ts.orch.searchRateLimited, "a backfill must not flag the forward run as rate-limited")
	assert.Empty(t, ts.orch.searchGapNote)
}

func TestBackfillSearch_RevokedTokenStaysDetectable(t *testing.T) {
	ts := newTestSetup(t, searchAuditMux(func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": false, "error": "invalid_auth"})
	}))
	ts.orch.logger = log.New(io.Discard, "", 0)
	require.NoError(t, ts.db.SetSlackAccountAuthState(ts.accountID, "ok", ""))

	_, err := ts.orch.BackfillSearch(context.Background(),
		time.Date(2026, 9, 20, 0, 0, 0, 0, time.UTC), time.Date(2026, 9, 22, 0, 0, 0, 0, time.UTC))
	require.Error(t, err)
	assert.True(t, IsRevokedAuthError(err), "got %v", err)
	got, gerr := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, gerr)
	assert.Equal(t, "ok", got.Status, "the backfill caller, not BackfillSearch, decides what to record")
}

func TestFirstSyncFrom_FreshAccountCompletedRun(t *testing.T) {
	// F7: the after: date is a local date (searchWindow formats a local
	// now), so its day boundary is local midnight. A zone far from UTC makes
	// a UTC-midnight reading visibly wrong.
	zone := time.FixedZone("UTC+9", 9*3600)
	prevLocal := time.Local
	time.Local = zone
	t.Cleanup(func() { time.Local = prevLocal })

	var queries []string
	var mu gosync.Mutex
	ts := newTestSetup(t, searchAuditMux(oneMatchSearch(&queries, &mu)))
	ts.orch.logger = log.New(io.Discard, "", 0)

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	from, ok := ts.orch.FirstSyncFrom()
	require.True(t, ok, "a completed run on an account with no watermark is a first sync")
	require.NotEmpty(t, queries)
	after, err := time.ParseInLocation(searchDateFormat, queries[0][len("after:"):], zone)
	require.NoError(t, err)
	// R19: after:D is exclusive, so the first instant the first sync covered
	// is local midnight of D + 1 — the backfill's upper bound.
	want := after.AddDate(0, 0, 1)
	assert.True(t, want.Equal(from), "want %v, got %v", want, from)
	assert.Equal(t, 0, from.In(zone).Hour(), "local midnight")

	// The watermark now exists: the next Run is not a first sync.
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	_, ok = ts.orch.FirstSyncFrom()
	assert.False(t, ok)
}

// F5: an established account that always fell back to full sync has no
// search watermark; the first completed search must not read as a first
// sync, since the account already holds its history.
func TestFirstSyncFrom_AccountWithStoredMessagesIsNotAFirstSync(t *testing.T) {
	var queries []string
	var mu gosync.Mutex
	ts := newTestSetup(t, searchAuditMux(oneMatchSearch(&queries, &mu)))
	ts.orch.logger = log.New(io.Discard, "", 0)
	require.NoError(t, ts.db.UpsertMessage(db.Message{ChannelID: ts.ns("C009"), TS: "1600000000.000001",
		UserID: ts.ns("U001"), Text: "stored by an earlier full sync"}))

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	_, ok := ts.orch.FirstSyncFrom()
	assert.False(t, ok)
	wm, err := ts.db.GetSlackAccountSearchWatermark(ts.accountID)
	require.NoError(t, err)
	assert.NotEmpty(t, wm, "the search itself completed")
}

func TestFirstSyncFrom_RateLimitedFirstRunIsNotAFirstSync(t *testing.T) {
	ts := newTestSetup(t, searchAuditMux(rateLimitedSearch))
	ts.orch.logger = log.New(io.Discard, "", 0)

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	_, ok := ts.orch.FirstSyncFrom()
	assert.False(t, ok)
}

func TestFirstSyncFrom_IncompletePaginationIsNotAFirstSync(t *testing.T) {
	var calls int
	var mu gosync.Mutex
	ts := newTestSetup(t, searchAuditMux(func(w http.ResponseWriter, _ *http.Request) {
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
		jsonOK(w, map[string]any{"ok": false, "error": "missing_scope"})
	}))
	ts.orch.logger = log.New(io.Discard, "", 0)

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	_, ok := ts.orch.FirstSyncFrom()
	assert.False(t, ok)
}
