package sync

import (
	"context"
	"encoding/json"
	"net/http"
	gosync "sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// pathCounter wraps a mux and counts the requests per Slack API path.
type pathCounter struct {
	mu   gosync.Mutex
	hits map[string]int
}

func countingMux(t *testing.T, inner *http.ServeMux) (*http.ServeMux, *pathCounter) {
	t.Helper()
	c := &pathCounter{hits: map[string]int{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		c.mu.Lock()
		c.hits[r.URL.Path]++
		c.mu.Unlock()
		inner.ServeHTTP(w, r)
	})
	return mux, c
}

func (c *pathCounter) count(path string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.hits[path]
}

func (c *pathCounter) paths() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []string
	for p := range c.hits {
		out = append(out, p)
	}
	return out
}

func TestRunUsersOnly_FetchesTheRosterAndNothingElse(t *testing.T) {
	inner := defaultMux()
	inner.HandleFunc("/auth.test", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "user_id": "U001", "user": "alice", "team_id": "T024BE7LD"})
	})
	mux, calls := countingMux(t, inner)
	ts := newTestSetup(t, mux)

	before := time.Now().Add(-time.Second)
	require.NoError(t, ts.orch.RunUsersOnly(context.Background()))

	users, err := ts.db.GetUsers(db.UserFilter{})
	require.NoError(t, err)
	assert.Len(t, users, 3, "every roster user is saved")
	alice, err := ts.db.GetUserByName("alice")
	require.NoError(t, err)
	require.NotNil(t, alice)
	assert.Equal(t, "1:U001", alice.ID, "users are namespaced to the account")

	acct, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, "T024BE7LD", acct.TeamID, "the team is resolved")
	assert.Equal(t, "1:U001", acct.CurrentUserID, "the current user is resolved")

	assert.ElementsMatch(t, []string{"/team.info", "/auth.test", "/users.list"}, calls.paths(),
		"users-only calls no search, channel, message, emoji or reaction API")

	stats, err := ts.db.GetStats()
	require.NoError(t, err)
	assert.Zero(t, stats.ChannelCount, "channels untouched")
	assert.Zero(t, stats.MessageCount, "messages untouched")

	stamp, err := ts.db.SlackRosterSyncedAt(ts.accountID)
	require.NoError(t, err)
	assert.False(t, stamp.Before(before.Truncate(time.Second)), "the roster marker is stamped: %s", stamp)
	assert.Equal(t, PhaseDone, ts.orch.Progress().Snapshot().Phase)
}

// The flag ignores the daily throttle: the picker needs the roster now, even
// when the daemon fetched it an hour ago.
func TestRunUsersOnly_IgnoresTheRosterThrottle(t *testing.T) {
	mux, calls := countingMux(t, defaultMux())
	ts := newTestSetup(t, mux)
	require.NoError(t, ts.db.SetSlackRosterSyncedAt(ts.accountID, time.Now().Add(-time.Hour)))

	require.NoError(t, ts.orch.RunUsersOnly(context.Background()))
	assert.Equal(t, 1, calls.count("/users.list"))
}

// The marker is shared: a regular sync after a users-only run, in a fresh
// orchestrator as a separate daemon process would have, skips the roster for
// the day instead of fetching it again.
func TestRunUsersOnly_NextRegularSyncSkipsTheRoster(t *testing.T) {
	mux, calls := countingMux(t, defaultMux())
	ts := newTestSetup(t, mux)
	require.NoError(t, ts.orch.RunUsersOnly(context.Background()))
	require.Equal(t, 1, calls.count("/users.list"))

	daemonOrch := NewOrchestrator(ts.db, ts.orch.slackClient, ts.orch.config, ts.accountID)
	daemonOrch.SetLogger(ts.orch.logger)
	require.NoError(t, daemonOrch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, 1, calls.count("/search.messages"), "the regular sync still searches")
	assert.Equal(t, 1, calls.count("/users.list"), "the roster fetched by users-only is not fetched again within the day")
}

func TestRunUsersOnly_FailureRecordsAuthState(t *testing.T) {
	inner := defaultMux()
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/users.list" {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": "token_revoked"})
			return
		}
		inner.ServeHTTP(w, r)
	})
	ts := newTestSetup(t, mux)

	err := ts.orch.RunUsersOnly(context.Background())
	require.ErrorContains(t, err, "user roster sync")

	acct, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, "revoked", acct.Status)
	stamp, err := ts.db.SlackRosterSyncedAt(ts.accountID)
	require.NoError(t, err)
	assert.True(t, stamp.IsZero(), "a failed fetch is not stamped")
}

// A successful users-only run never searched, so it must not erase the
// search-gap note the last full cycle left on the account row.
func TestRunUsersOnly_SuccessKeepsTheAccountNote(t *testing.T) {
	ts := newTestSetup(t, defaultMux())
	const note = "search sync clamped: some history was not fetched"
	require.NoError(t, ts.db.SetSlackAccountAuthState(ts.accountID, "ok", note))

	require.NoError(t, ts.orch.RunUsersOnly(context.Background()))

	acct, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, "ok", acct.Status)
	assert.Equal(t, note, acct.Error)
}
