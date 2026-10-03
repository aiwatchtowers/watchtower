package sync

import (
	"context"
	"fmt"
	"net/http"
	"sync"
	"testing"

	goslack "github.com/slack-go/slack"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestIsRateLimitError pins isRateLimitError's narrow scope: it must
// recognize only *slack.RateLimitedError — bare or wrapped — never any other
// non-fatal Slack error code (a scope/permission problem, a dead
// account/channel, ...), since those must keep falling back to full sync
// exactly as before the rate-limit carve-out.
func TestIsRateLimitError(t *testing.T) {
	assert.False(t, isRateLimitError(nil))
	assert.False(t, isRateLimitError(errFromString("missing_scope")),
		"a scope error must not be treated as a rate limit")
	assert.False(t, isRateLimitError(errFromString("access_denied")))
	assert.False(t, isRateLimitError(errFromString("account_inactive")))
	assert.False(t, isRateLimitError(errFromString("channel_not_found")))

	rlErr := &goslack.RateLimitedError{}
	assert.True(t, isRateLimitError(rlErr), "a bare *slack.RateLimitedError must be recognized")
	assert.True(t, isRateLimitError(fmt.Errorf("search sync (page 1): %w", rlErr)),
		"a %w-wrapped *slack.RateLimitedError must still be recognized through errors.As")
}

// TestSyncViaSearch_RateLimitedFirstPageDoesNotFallBackToFullSync reproduces
// the "a rate-limited first search page triggers a full conversations sync"
// finding: when Slack is already throttling the token (search.messages
// answers 429 on every attempt), the sync must not fall back to the far more
// expensive full sync (conversations.history/conversations.list). It must
// also not spend the same throttled budget on runSearchSync's other phases
// (the read-state/roster refreshes, the reactions sync) — the account is
// seeded with an unread digest and a pending inbox item so those phases
// would have real work to do (and real Slack calls to make) if they weren't
// skipped. The cycle must end with the search watermark untouched, the
// read-state/roster refresh timestamps untouched (so both are still due next
// cycle), and a note on the account row (surviving the run's closing "ok"
// auth-state write) so a token throttled for many cycles doesn't look silently
// healthy.
func TestSyncViaSearch_RateLimitedFirstPageDoesNotFallBackToFullSync(t *testing.T) {
	var fullSyncHits, readStateHits, rosterHits, reactionsHits int32
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
	// Full-sync-only endpoints; a hit on any proves the (undesired) fallback
	// happened.
	mux.HandleFunc("/conversations.list", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		fullSyncHits++
		mu.Unlock()
		jsonOK(w, map[string]any{"ok": true, "channels": []map[string]any{}, "response_metadata": map[string]any{"next_cursor": ""}})
	})
	mux.HandleFunc("/conversations.history", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		fullSyncHits++
		mu.Unlock()
		jsonOK(w, map[string]any{"ok": true, "messages": []any{}, "has_more": false, "response_metadata": map[string]any{"next_cursor": ""}})
	})
	// Read-state (Phase 3), roster (Phase 4) and reactions endpoints; a hit on
	// any proves runSearchSync did NOT return early on searchRateLimited.
	mux.HandleFunc("/conversations.info", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		readStateHits++
		mu.Unlock()
		jsonOK(w, map[string]any{"ok": true, "channel": map[string]any{"id": "C001", "last_read": "1700000000.000000"}})
	})
	mux.HandleFunc("/users.list", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		rosterHits++
		mu.Unlock()
		jsonOK(w, map[string]any{"ok": true, "members": []map[string]any{}, "response_metadata": map[string]any{"next_cursor": ""}})
	})
	mux.HandleFunc("/reactions.list", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		reactionsHits++
		mu.Unlock()
		jsonOK(w, map[string]any{"ok": true, "items": []map[string]any{}, "paging": map[string]any{"count": 100, "total": 0, "page": 1, "pages": 1}})
	})

	ts := newTestSetup(t, mux)
	require.NoError(t, ts.db.UpsertWorkspace(db.Workspace{ID: "T001", Name: "test", Domain: "test"}))
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, "2020-01-01"))

	// Give the read-state and reactions phases real work, so their absence
	// below is because they were skipped, not because there was nothing to do.
	_, err := ts.db.UpsertDigest(db.Digest{
		ChannelID: ts.ns("C001"), Type: "channel", PeriodFrom: 100, PeriodTo: 200,
		Summary: "s", Topics: "[]", Decisions: "[]", ActionItems: "[]", Model: "m",
	})
	require.NoError(t, err)
	_, err = ts.db.CreateInboxItem(db.InboxItem{
		ChannelID: ts.ns("C001"), MessageTS: "1700000000.000100",
		TriggerType: "mention", Status: "pending",
	})
	require.NoError(t, err)

	err = ts.orch.Run(context.Background(), SyncOptions{})
	require.NoError(t, err, "a rate limit must end the cycle cleanly, not abort the sync")

	mu.Lock()
	defer mu.Unlock()
	assert.Zero(t, fullSyncHits,
		"a rate-limited search page must not fall back to the full conversations sync")
	assert.Zero(t, readStateHits, "a rate-limited cycle must skip the channel read-state refresh")
	assert.Zero(t, rosterHits, "a rate-limited cycle must skip the user roster refresh")
	assert.Zero(t, reactionsHits, "a rate-limited cycle must skip the inbox reactions sync")

	got, err := ts.db.GetSlackAccountSearchWatermark(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, "2020-01-01", got, "the watermark must stay untouched so the next cycle retries via search")
	assert.True(t, ts.orch.SearchIncomplete(), "a rate-limited cycle reports its data as incomplete (INBOX-09)")

	assert.True(t, ts.orch.readStateSyncedAt.IsZero(), "the read-state refresh must still be due next cycle")
	rosterSyncedAt, err := ts.db.SlackRosterSyncedAt(ts.accountID)
	require.NoError(t, err)
	assert.True(t, rosterSyncedAt.IsZero(), "the roster refresh must still be due next cycle")

	acct, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, "ok", acct.Status, "a rate limit is not an auth failure")
	assert.Contains(t, acct.Error, "rate-limited",
		"the rate-limited cycle must leave a note on the account row, surviving the run's closing ok write")
}

// TestSyncViaSearch_NonRateLimitNonFatalFirstPageFallsBackToFullSync is F10's
// negative case: a non-fatal page-1 error that is NOT a rate limit (here,
// channel_not_found — a dead-channel/account-shaped error, not a scope
// problem either) must keep its previous behavior and fall back to the full
// sync, exactly like the pre-existing missing_scope case
// (TestSearchSync_MissingScopeFallsBackToFullSync in watermark_audit_test.go)
// — only an actual rate limit gets the new "don't escalate" handling.
func TestSyncViaSearch_NonRateLimitNonFatalFirstPageFallsBackToFullSync(t *testing.T) {
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
