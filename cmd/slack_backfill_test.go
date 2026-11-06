package cmd

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	gosync "sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"
	"watchtower/internal/slackbackfill"
)

// slackBackfillEnv is a workspace with digests off and Slack account #1 on
// rowTeamID (the legacy workspace row names T_HOME), its token pointed at a
// stub Slack whose search answers one message and records each query.
func slackBackfillEnv(t *testing.T, rowTeamID string) (*db.DB, *[]string) {
	t.Helper()
	for _, name := range agentEnvMarkers {
		t.Setenv(name, "")
		require.NoError(t, os.Unsetenv(name))
	}
	t.Setenv("HOME", t.TempDir())
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte("active_workspace: test\ndigest:\n  enabled: false\n"), 0o600))
	original := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = original })
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })

	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T_HOME", Name: "Acme"}))
	id, err := database.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)
	require.NoError(t, database.UpdateSlackAccountConnection(id, rowTeamID, "Some Team", "", "1:U_OWNER"))
	require.NoError(t, database.SetSlackAccountSearchWatermark(id, "2026-03-20"))
	require.NoError(t, watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id).Save(
		&watchtowerslack.Token{AccessToken: "xoxp-test", TeamID: rowTeamID}))

	var queries []string
	var mu gosync.Mutex
	mux := http.NewServeMux()
	mux.HandleFunc("/search.messages", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		mu.Lock()
		queries = append(queries, r.FormValue("query"))
		mu.Unlock()
		if slackBackfillRateLimited {
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "messages": map[string]any{
			"matches": []map[string]any{{"user": "U001", "username": "alice", "ts": "1773403200.000100", "text": "hello",
				"channel": map[string]any{"id": "C001", "name": "general"}}},
			"paging": map[string]any{"count": 100, "total": 1, "page": 1, "pages": 1}, "total": 1,
		}})
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": "unknown_method"})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	orig := newSlackClientForToken
	newSlackClientForToken = func(token string) *watchtowerslack.Client {
		return watchtowerslack.NewClientWithAPIURLUnlimited(token, srv.URL+"/")
	}
	t.Cleanup(func() { newSlackClientForToken = orig })
	return database, &queries
}

func runSlackBackfillCmd(args ...string) (string, error) {
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs(append([]string{"slack", "backfill"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	return out.String(), err
}

func TestSlackBackfill_FetchesTheRangeNewestFirstWithoutMovingTheWatermark(t *testing.T) {
	database, queries := slackBackfillEnv(t, "T_HOME")

	out, err := runSlackBackfillCmd("--account", "1", "--from", "2026-03-10", "--to", "2026-03-12")
	require.NoError(t, err, out)
	// Three days are two 2-day chunks, newest first; each search is widened
	// by a day on both sides (exclusive, day-granular operators).
	// (The dates depend on the zone: the search sends UTC days.)
	require.Len(t, *queries, 2)
	assert.Regexp(t, `^after:2026-03-\d\d before:2026-03-\d\d$`, (*queries)[0])
	assert.Regexp(t, `^after:2026-03-\d\d before:2026-03-\d\d$`, (*queries)[1])
	assert.Greater(t, (*queries)[0], (*queries)[1], "the newer chunk is fetched first")
	assert.Contains(t, out, "1 messages")
	assert.Contains(t, out, "Slack account 1: 2026-03-10..2026-03-12 done")

	has, err := database.SlackAccountHasMessages(1)
	require.NoError(t, err)
	assert.True(t, has)
	acct, err := database.GetSlackAccount(1)
	require.NoError(t, err)
	assert.Equal(t, "2026-03-20", acct.SearchLastDate, "the backfill moves no watermark")
	assert.Equal(t, "ok", acct.Status)
}

func TestSlackBackfill_RefusesAMovedAccount(t *testing.T) {
	_, queries := slackBackfillEnv(t, "T_OTHER")

	out, err := runSlackBackfillCmd("--account", "1", "--from", "2026-03-10", "--to", "2026-03-12")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "Re-login to Acme", out)
	assert.Empty(t, *queries, "nothing is searched for another team's token")
}

func TestSlackBackfill_RefusesADisabledAccount(t *testing.T) {
	database, queries := slackBackfillEnv(t, "T_HOME")
	require.NoError(t, database.SetSlackAccountEnabled(1, false))

	_, err := runSlackBackfillCmd("--account", "1", "--from", "2026-03-10", "--to", "2026-03-12")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "disabled")
	assert.Empty(t, *queries)
}

// slackBackfillRateLimited makes slackBackfillEnv's search answer 429.
var slackBackfillRateLimited bool

func TestSlackBackfill_RateLimitNamesTheResumeDay(t *testing.T) {
	_, queries := slackBackfillEnv(t, "T_HOME")
	slackBackfillRateLimited = true
	t.Cleanup(func() { slackBackfillRateLimited = false })

	_, err := runSlackBackfillCmd("--account", "1", "--from", "2026-03-10", "--to", "2026-03-12")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "rate limit")
	assert.Contains(t, err.Error(), "resume with --to 2026-03-12", "the newest chunk was not finished")
	assert.NotEmpty(t, *queries)
}

func TestSlackBackfill_RefusesARevokedAccount(t *testing.T) {
	database, queries := slackBackfillEnv(t, "T_HOME")
	require.NoError(t, database.SetSlackAccountAuthState(1, "revoked", "token_revoked"))

	_, err := runSlackBackfillCmd("--account", "1", "--from", "2026-03-10", "--to", "2026-03-12")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "Re-login first")
	assert.Empty(t, *queries)
}

// PURGE-01: a backfill must not refill an account a purge is deleting.
func TestSlackBackfill_RefusesDuringAPurge(t *testing.T) {
	database, queries := slackBackfillEnv(t, "T_HOME")
	_, err := database.Exec(`INSERT INTO account_purges (source, account_id, reason, due_at, state)
		VALUES ('slack', 1, 'revoked', '2026-01-01T00:00:00Z', 'running')`)
	require.NoError(t, err)

	_, err = runSlackBackfillCmd("--account", "1", "--from", "2026-03-10", "--to", "2026-03-12")
	require.ErrorIs(t, err, slackbackfill.ErrPurgeRunning)
	assert.Contains(t, err.Error(), "run the backfill again once it finishes")
	assert.Empty(t, *queries)
}

func TestSlackBackfill_UnknownAccountIsNotFound(t *testing.T) {
	slackBackfillEnv(t, "T_HOME")
	_, err := runSlackBackfillCmd("--account", "9", "--from", "2026-03-10", "--to", "2026-03-12")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "slack account 9 not found")
}

// The row is on the home team but the token file names another one (a
// token save that failed after the row was written): nothing is searched.
func TestSlackBackfill_RefusesATokenOfAnotherTeam(t *testing.T) {
	_, queries := slackBackfillEnv(t, "T_HOME")
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	require.NoError(t, watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), 1).Save(
		&watchtowerslack.Token{AccessToken: "xoxp-test", TeamID: "T_OTHER"}))

	_, err = runSlackBackfillCmd("--account", "1", "--from", "2026-03-10", "--to", "2026-03-12")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "Re-login to Acme")
	assert.Empty(t, *queries)
}
