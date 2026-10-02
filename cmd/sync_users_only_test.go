package cmd

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	gosync "sync"
	"testing"

	goslack "github.com/slack-go/slack"
	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"
)

// usersOnlySlack is a fake Slack API: users.list answers with a roster per
// token (one user named after the token), and every request path is counted.
type usersOnlySlack struct {
	mu   gosync.Mutex
	hits map[string]int
}

func (f *usersOnlySlack) count(path string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits[path]
}

func (f *usersOnlySlack) total() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, v := range f.hits {
		n += v
	}
	return n
}

func stubUsersOnlySlack(t *testing.T) *usersOnlySlack {
	t.Helper()
	f := &usersOnlySlack{hits: map[string]int{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.hits[r.URL.Path]++
		f.mu.Unlock()
		_ = r.ParseForm()
		token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if token == "" {
			token = r.Form.Get("token")
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/auth.test":
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "user_id": "UOWNER", "user": "owner"})
		case "/users.list":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"ok": true,
				"members": []map[string]any{
					{"id": "UOWNER", "name": "owner", "real_name": "Owner", "profile": map[string]any{}},
					{"id": "U" + strings.ToUpper(token), "name": token, "real_name": "Colleague " + token, "profile": map[string]any{}},
				},
				"response_metadata": map[string]any{"next_cursor": ""},
			})
		default:
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": "unexpected_call"})
		}
	}))
	t.Cleanup(srv.Close)

	original := newSlackClientForToken
	newSlackClientForToken = func(token string) *watchtowerslack.Client {
		return watchtowerslack.NewClientWithAPIUnlimited(goslack.New(token, goslack.OptionAPIURL(srv.URL+"/")))
	}
	t.Cleanup(func() { newSlackClientForToken = original })
	return f
}

// usersOnlyWorkspace creates a workspace with one connected Slack account per
// token (team already resolved, so no team.info call) and returns its config
// path and the account ids.
func usersOnlyWorkspace(t *testing.T, tokens ...string) (string, []int64) {
	t.Helper()
	_, configPath := workspaceInitHome(t)
	_, err := initWorkspace(configPath, "default")
	require.NoError(t, err)
	cfg, err := config.Load(configPath)
	require.NoError(t, err)

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()
	var ids []int64
	for _, tok := range tokens {
		id, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T" + tok, TeamName: "Team " + tok})
		require.NoError(t, err)
		require.NoError(t, database.UpdateSlackAccountConnection(id, "T"+tok, "Team "+tok, tok, watchtowerslack.Namespace(id, "UOWNER")))
		require.NoError(t, watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id).Save(&watchtowerslack.Token{AccessToken: tok}))
		ids = append(ids, id)
	}
	return configPath, ids
}

func usersOnlyDB(t *testing.T, configPath string) *db.DB {
	t.Helper()
	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	return database
}

func TestSyncUsersOnly_FillsUsersAndNothingElse(t *testing.T) {
	fake := stubUsersOnlySlack(t)
	configPath, ids := usersOnlyWorkspace(t, "alpha")

	stdout, _, err := runRootCmd(t, []*cobra.Command{syncCmd},
		"sync", "--users-only", "--progress-json", "--config", configPath)
	require.NoError(t, err)

	assert.Equal(t, 1, fake.count("/users.list"))
	assert.Equal(t, fake.count("/users.list"), fake.total(),
		"only users.list: no search, channels, history, emoji or reactions (team and current user are cached)")

	database := usersOnlyDB(t, configPath)
	users, err := database.GetUsers(db.UserFilter{})
	require.NoError(t, err)
	assert.Len(t, users, 2)
	stats, err := database.GetStats()
	require.NoError(t, err)
	assert.Zero(t, stats.ChannelCount)
	assert.Zero(t, stats.MessageCount)
	stamp, err := database.SlackRosterSyncedAt(ids[0])
	require.NoError(t, err)
	assert.False(t, stamp.IsZero(), "the shared roster marker is stamped")

	// Every stdout line is a progress JSON line (no pipeline spinner output),
	// and the last one reports the finished roster.
	lines := strings.Split(strings.TrimSpace(stdout), "\n")
	require.NotEmpty(t, lines)
	var last progressJSON
	for _, line := range lines {
		require.NoError(t, json.Unmarshal([]byte(line), &last), "not a JSON line: %q", line)
	}
	assert.Equal(t, "Done", last.Phase)
	assert.Equal(t, 2, last.UserProfilesTotal)
	assert.Equal(t, 2, last.UserProfilesDone)
	assert.Empty(t, last.Error)

	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	assert.NoFileExists(t, syncResultPath(cfg), "a users-only run is not a sync result")
	assert.NoFileExists(t, filepath.Join(cfg.WorkspaceDir(), "sync.lock"), "users-only takes no sync lock")
}

func TestSyncUsersOnly_EveryAccountByDefault(t *testing.T) {
	fake := stubUsersOnlySlack(t)
	configPath, _ := usersOnlyWorkspace(t, "alpha", "beta")

	_, _, err := runRootCmd(t, []*cobra.Command{syncCmd},
		"sync", "--users-only", "--progress-json", "--config", configPath)
	require.NoError(t, err)
	assert.Equal(t, 2, fake.count("/users.list"))

	database := usersOnlyDB(t, configPath)
	for _, id := range []string{"1:UALPHA", "2:UBETA"} {
		u, err := database.GetUserByID(id)
		require.NoError(t, err)
		assert.NotNil(t, u, "user %s synced under its own account", id)
	}
}

func TestSyncUsersOnly_AccountFlagPicksOneAccount(t *testing.T) {
	fake := stubUsersOnlySlack(t)
	configPath, ids := usersOnlyWorkspace(t, "alpha", "beta")

	_, _, err := runRootCmd(t, []*cobra.Command{syncCmd},
		"sync", "--users-only", "--account", "2", "--progress-json", "--config", configPath)
	require.NoError(t, err)
	assert.Equal(t, 1, fake.count("/users.list"))

	database := usersOnlyDB(t, configPath)
	beta, err := database.GetUserByID("2:UBETA")
	require.NoError(t, err)
	assert.NotNil(t, beta)
	alpha, err := database.GetUserByID("1:UALPHA")
	require.NoError(t, err)
	assert.Nil(t, alpha, "account 1 was not asked for")
	stamp, err := database.SlackRosterSyncedAt(ids[0])
	require.NoError(t, err)
	assert.True(t, stamp.IsZero(), "account 1's marker is untouched")
}

func TestSyncUsersOnly_UnknownAccountIsAnError(t *testing.T) {
	fake := stubUsersOnlySlack(t)
	configPath, _ := usersOnlyWorkspace(t, "alpha")

	_, _, err := runRootCmd(t, []*cobra.Command{syncCmd},
		"sync", "--users-only", "--account", "7", "--config", configPath)
	require.ErrorContains(t, err, "slack account 7 is not connected")
	assert.Zero(t, fake.total())
}

func TestSyncUsersOnly_NoSlackAccountIsAnError(t *testing.T) {
	configPath, _ := usersOnlyWorkspace(t)

	_, _, err := runRootCmd(t, []*cobra.Command{syncCmd},
		"sync", "--users-only", "--config", configPath)
	require.ErrorContains(t, err, "slack is not connected")
}

func TestSyncUsersOnly_RejectsIncompatibleFlags(t *testing.T) {
	configPath, _ := usersOnlyWorkspace(t)
	for _, args := range [][]string{
		{"--users-only", "--daemon"},
		{"--users-only", "--full"},
		{"--users-only", "--channels", "general"},
		{"--account", "1"},
	} {
		_, _, err := runRootCmd(t, []*cobra.Command{syncCmd},
			append(append([]string{"sync"}, args...), "--config", configPath)...)
		require.Error(t, err, "%v", args)
		assert.Contains(t, err.Error(), "--", "%v", args)
	}
}
