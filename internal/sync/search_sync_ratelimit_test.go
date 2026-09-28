package sync

import (
	"context"
	"net/http"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestIsRateLimitError pins isRateLimitError's narrow scope: it must
// recognize only *slack.RateLimitedError, never any other non-fatal Slack
// error code (a scope/permission problem, a dead account/channel, ...),
// since those must keep falling back to full sync exactly as before the
// rate-limit carve-out.
func TestIsRateLimitError(t *testing.T) {
	assert.False(t, isRateLimitError(nil))
	assert.False(t, isRateLimitError(errFromString("missing_scope")),
		"a scope error must not be treated as a rate limit")
	assert.False(t, isRateLimitError(errFromString("access_denied")))
	assert.False(t, isRateLimitError(errFromString("account_inactive")))
	assert.False(t, isRateLimitError(errFromString("channel_not_found")))
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
		// turn isRateLimitError's *slack.RateLimitedError branch, actually see.
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

// TestSyncSync_NonRateLimitNonFatalFirstPageFallsBackToFullSync is F10's
// negative case: a non-fatal page-1 error that is NOT a rate limit (here,
// channel_not_found — a dead-channel/account-shaped error, not a scope
// problem either) must keep its previous behavior and fall back to the full
// sync, exactly like the pre-existing missing_scope case
// (TestSearchSync_MissingScopeFallsBackToFullSync in watermark_audit_test.go)
// — only an actual rate limit gets the new "don't escalate" handling.
func TestSyncSync_NonRateLimitNonFatalFirstPageFallsBackToFullSync(t *testing.T) {
	var historyHits int
	var mu sync.Mutex

	mux := searchAuditMux(func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{"ok": false, "error": "channel_not_found"})
	})
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
	// so only the non-fatal-error fallback (unrelated to searchRateLimited)
	// can rescue this sync, same shape as the missing_scope precedent.
	require.NoError(t, ts.db.UpsertChannel(db.Channel{ID: ts.ns("C001"), Name: "general", Type: "public", IsMember: true}))

	err := ts.orch.Run(context.Background(), SyncOptions{})
	require.NoError(t, err)

	mu.Lock()
	defer mu.Unlock()
	assert.Positive(t, historyHits,
		"a non-rate-limit non-fatal page-1 error (channel_not_found) must still fall back to full sync, unchanged from before the rate-limit fix")
}
