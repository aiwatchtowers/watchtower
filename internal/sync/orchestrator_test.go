package sync

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
	"time"

	goslack "github.com/slack-go/slack"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"
)

// testSetup creates an in-memory DB, mock Slack server, and orchestrator for testing.
// A slack_accounts row is always seeded first and its id (accountID, "1" in a
// fresh :memory: DB) is threaded into NewOrchestrator — Orchestrator is
// per-account (Task 4).
type testSetup struct {
	db        *db.DB
	orch      *Orchestrator
	srv       *httptest.Server
	accountID int64
}

func newTestSetup(t *testing.T, mux *http.ServeMux) *testSetup {
	t.Helper()

	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	accountID, err := database.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)

	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	api := goslack.New("xoxp-test-token", goslack.OptionAPIURL(srv.URL+"/"))
	slackClient := watchtowerslack.NewClientWithAPIUnlimited(api)

	cfg := &config.Config{
		ActiveWorkspace: "test-workspace",
		Workspaces: map[string]*config.WorkspaceConfig{
			"test-workspace": {SlackToken: "xoxp-test-token"},
		},
		Sync: config.SyncConfig{
			Workers:            2,
			InitialHistoryDays: 30,
			SyncThreads:        true,
		},
	}

	orch := NewOrchestrator(database, slackClient, cfg, accountID)
	orch.SetLogger(log.New(os.Stderr, "[test] ", 0))

	return &testSetup{db: database, orch: orch, srv: srv, accountID: accountID}
}

// ns namespaces a raw Slack id (e.g. "C001") with this testSetup's account,
// matching what the DB actually stores at the sync boundary.
func (ts *testSetup) ns(rawID string) string {
	return watchtowerslack.Namespace(ts.accountID, rawID)
}

// baseMux creates a mock Slack API server with metadata endpoints
// (team.info, users.list, conversations.list) but no conversations.history.
// Use defaultMux() for a fully functional mock, or call baseMux() and add
// your own conversations.history handler.
func baseMux() *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("/team.info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"team": map[string]any{
				"id":     "T024BE7LD",
				"name":   "my-company",
				"domain": "my-company",
			},
		})
	})

	mux.HandleFunc("/users.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"members": []map[string]any{
				{
					"id": "U001", "name": "alice", "real_name": "Alice Smith",
					"is_bot": false, "deleted": false,
					"profile": map[string]any{"display_name": "alice", "email": "alice@example.com"},
				},
				{
					"id": "U002", "name": "bob", "real_name": "Bob Jones",
					"is_bot": false, "deleted": false,
					"profile": map[string]any{"display_name": "bob", "email": "bob@example.com"},
				},
				{
					"id": "U003", "name": "slackbot", "real_name": "Slackbot",
					"is_bot": true, "deleted": false,
					"profile": map[string]any{"display_name": "Slackbot"},
				},
			},
			"response_metadata": map[string]any{"next_cursor": ""},
		})
	})

	mux.HandleFunc("/conversations.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"channels": []map[string]any{
				{
					"id": "C001", "name": "general", "is_channel": true, "is_member": true,
					"num_members": 50, "is_archived": false,
					"topic":   map[string]any{"value": "General chat"},
					"purpose": map[string]any{"value": "Company-wide announcements"},
				},
				{
					"id": "C002", "name": "engineering", "is_channel": true, "is_member": true,
					"num_members": 20, "is_archived": false,
					"topic":   map[string]any{"value": "Engineering discussion"},
					"purpose": map[string]any{"value": ""},
				},
				{
					"id": "C003", "name": "old-project", "is_channel": true, "is_member": false,
					"num_members": 5, "is_archived": true,
					"topic":   map[string]any{"value": ""},
					"purpose": map[string]any{"value": ""},
				},
			},
			"response_metadata": map[string]any{"next_cursor": ""},
		})
	})

	mux.HandleFunc("/search.messages", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"messages": map[string]any{
				"matches": []map[string]any{
					{
						"user": "U001", "username": "alice", "ts": "1740567600.000100",
						"text": "test message",
						"channel": map[string]any{
							"id": "C001", "name": "general",
						},
					},
					{
						"user": "U002", "username": "bob", "ts": "1740567600.000200",
						"text": "another message",
						"channel": map[string]any{
							"id": "C002", "name": "engineering",
						},
					},
				},
				"paging": map[string]any{
					"count": 100,
					"total": 2,
					"page":  1,
					"pages": 1,
				},
				"total": 2,
			},
		})
	})

	mux.HandleFunc("/users.info", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		userID := r.FormValue("user")
		w.Header().Set("Content-Type", "application/json")

		users := map[string]map[string]any{
			"U001": {"id": "U001", "name": "alice", "real_name": "Alice Smith", "is_bot": false, "deleted": false, "profile": map[string]any{"display_name": "alice", "email": "alice@example.com"}},
			"U002": {"id": "U002", "name": "bob", "real_name": "Bob Jones", "is_bot": false, "deleted": false, "profile": map[string]any{"display_name": "bob", "email": "bob@example.com"}},
			"U003": {"id": "U003", "name": "slackbot", "real_name": "Slackbot", "is_bot": true, "deleted": false, "profile": map[string]any{"display_name": "Slackbot"}},
		}

		if user, ok := users[userID]; ok {
			json.NewEncoder(w).Encode(map[string]any{"ok": true, "user": user})
		} else {
			json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": "user_not_found"})
		}
	})

	return mux
}

// defaultMux creates a mock Slack API server with standard responses,
// including an empty conversations.history and conversations.replies handler.
func defaultMux() *http.ServeMux {
	mux := baseMux()

	mux.HandleFunc("/conversations.history", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":                true,
			"messages":          []any{},
			"has_more":          false,
			"response_metadata": map[string]any{"next_cursor": ""},
		})
	})

	mux.HandleFunc("/conversations.replies", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":                true,
			"messages":          []any{},
			"has_more":          false,
			"response_metadata": map[string]any{"next_cursor": ""},
		})
	})

	return mux
}

func TestNewOrchestrator(t *testing.T) {
	ts := newTestSetup(t, defaultMux())
	assert.NotNil(t, ts.orch)
	assert.NotNil(t, ts.orch.db)
	assert.NotNil(t, ts.orch.slackClient)
	assert.NotNil(t, ts.orch.config)
	assert.NotNil(t, ts.orch.logger)
}

func TestRunFullSync(t *testing.T) {
	ts := newTestSetup(t, defaultMux())
	err := ts.orch.Run(context.Background(), SyncOptions{Full: true})
	require.NoError(t, err)

	// Verify the connected account's team info was resolved
	acct, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, "T024BE7LD", acct.TeamID)
	assert.Equal(t, "my-company", acct.TeamName)
	assert.Equal(t, "my-company", acct.TeamDomain)

	// Verify users were synced
	users, err := ts.db.GetUsers(db.UserFilter{})
	require.NoError(t, err)
	assert.Len(t, users, 3)

	alice, err := ts.db.GetUserByName("alice")
	require.NoError(t, err)
	require.NotNil(t, alice)
	assert.Equal(t, "Alice Smith", alice.RealName)
	assert.False(t, alice.IsBot)

	bot, err := ts.db.GetUserByName("slackbot")
	require.NoError(t, err)
	require.NotNil(t, bot)
	assert.True(t, bot.IsBot)

	// Verify channels were synced
	channels, err := ts.db.GetChannels(db.ChannelFilter{})
	require.NoError(t, err)
	assert.Len(t, channels, 3)

	general, err := ts.db.GetChannelByName("general")
	require.NoError(t, err)
	require.NotNil(t, general)
	assert.Equal(t, "public", general.Type)
	assert.True(t, general.IsMember)
	assert.Equal(t, 50, general.NumMembers)
	assert.Equal(t, "General chat", general.Topic)

	archived, err := ts.db.GetChannelByName("old-project")
	require.NoError(t, err)
	require.NotNil(t, archived)
	assert.True(t, archived.IsArchived)
	assert.False(t, archived.IsMember)
}

func TestRunSearchSync(t *testing.T) {
	ts := newTestSetup(t, defaultMux())

	// Pre-populate the account's team info so ensureWorkspace takes the cached path.
	err := ts.db.UpdateSlackAccountConnection(ts.accountID, "T024BE7LD", "my-company", "my-company", "")
	require.NoError(t, err)

	err = ts.orch.Run(context.Background(), SyncOptions{})
	require.NoError(t, err)

	// Verify the account's team info
	acct, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, "T024BE7LD", acct.TeamID)

	// Verify channels discovered via search
	channels, err := ts.db.GetChannels(db.ChannelFilter{})
	require.NoError(t, err)
	assert.GreaterOrEqual(t, len(channels), 2, "should discover at least 2 channels from search")

	general, err := ts.db.GetChannelByName("general")
	require.NoError(t, err)
	require.NotNil(t, general)
	assert.Equal(t, watchtowerslack.Namespace(ts.accountID, "C001"), general.ID)
	assert.True(t, general.IsMember)

	// Verify messages were saved directly from search results
	msgs, err := ts.db.GetMessagesByChannel(watchtowerslack.Namespace(ts.accountID, "C001"), 100)
	require.NoError(t, err)
	assert.GreaterOrEqual(t, len(msgs), 1, "search sync should save messages")

	// Verify search_last_date was saved
	lastDate, err := ts.db.GetSlackAccountSearchWatermark(ts.accountID)
	require.NoError(t, err)
	assert.NotEmpty(t, lastDate, "search_last_date should be set after search sync")
}

func TestSyncMetadataWorkspaceUpsert(t *testing.T) {
	ts := newTestSetup(t, defaultMux())
	err := ts.orch.syncMetadata(context.Background(), SyncOptions{})
	require.NoError(t, err)

	acct, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, "T024BE7LD", acct.TeamID)

	// Run again — should update, not fail
	err = ts.orch.syncMetadata(context.Background(), SyncOptions{})
	require.NoError(t, err)

	acct2, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, acct.TeamID, acct2.TeamID)
}

func TestSyncSkipsDeletedUsers(t *testing.T) {
	// Create a mux where users.list includes a deleted user
	mux := http.NewServeMux()

	mux.HandleFunc("/team.info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":   true,
			"team": map[string]any{"id": "T001", "name": "test", "domain": "test"},
		})
	})

	mux.HandleFunc("/users.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"members": []map[string]any{
				{
					"id": "U001", "name": "alice", "real_name": "Alice",
					"deleted": false, "is_bot": false,
					"profile": map[string]any{"display_name": "alice"},
				},
				{
					"id": "U999", "name": "departed", "real_name": "Gone User",
					"deleted": true, "is_bot": false,
					"profile": map[string]any{"display_name": "departed"},
				},
			},
			"response_metadata": map[string]any{"next_cursor": ""},
		})
	})

	mux.HandleFunc("/conversations.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":                true,
			"channels":          []map[string]any{},
			"response_metadata": map[string]any{"next_cursor": ""},
		})
	})

	ts := newTestSetup(t, mux)
	err := ts.orch.syncMetadata(context.Background(), SyncOptions{})
	require.NoError(t, err)

	// Active user should be saved
	alice, err := ts.db.GetUserByID(watchtowerslack.Namespace(ts.accountID, "U001"))
	require.NoError(t, err)
	require.NotNil(t, alice)
	assert.Equal(t, "Alice", alice.RealName)

	// Deleted user should NOT be saved
	users, err := ts.db.GetUsers(db.UserFilter{})
	require.NoError(t, err)
	assert.Len(t, users, 1, "deleted user should not be saved to DB")
}

func TestSyncChannelTypes(t *testing.T) {
	mux := http.NewServeMux()

	mux.HandleFunc("/team.info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":   true,
			"team": map[string]any{"id": "T001", "name": "test", "domain": "test"},
		})
	})

	mux.HandleFunc("/users.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":                true,
			"members":           []map[string]any{},
			"response_metadata": map[string]any{"next_cursor": ""},
		})
	})

	mux.HandleFunc("/conversations.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"channels": []map[string]any{
				{
					"id": "C001", "name": "general", "is_channel": true,
					"topic": map[string]any{"value": ""}, "purpose": map[string]any{"value": ""},
				},
				{
					"id": "G001", "name": "secret", "is_channel": false, "is_group": true, "is_private": true,
					"topic": map[string]any{"value": ""}, "purpose": map[string]any{"value": ""},
				},
				{
					"id": "D001", "name": "", "is_im": true, "user": "U001",
					"topic": map[string]any{"value": ""}, "purpose": map[string]any{"value": ""},
				},
				{
					"id": "G002", "name": "group-dm", "is_mpim": true,
					"topic": map[string]any{"value": ""}, "purpose": map[string]any{"value": ""},
				},
			},
			"response_metadata": map[string]any{"next_cursor": ""},
		})
	})

	ts := newTestSetup(t, mux)
	err := ts.orch.syncMetadata(context.Background(), SyncOptions{})
	require.NoError(t, err)

	ch, err := ts.db.GetChannelByID(watchtowerslack.Namespace(ts.accountID, "C001"))
	require.NoError(t, err)
	assert.Equal(t, "public", ch.Type)

	ch, err = ts.db.GetChannelByID(watchtowerslack.Namespace(ts.accountID, "G001"))
	require.NoError(t, err)
	assert.Equal(t, "private", ch.Type)

	ch, err = ts.db.GetChannelByID(watchtowerslack.Namespace(ts.accountID, "D001"))
	require.NoError(t, err)
	assert.Equal(t, "dm", ch.Type)
	assert.Equal(t, watchtowerslack.Namespace(ts.accountID, "U001"), ch.DMUserID.String)

	ch, err = ts.db.GetChannelByID(watchtowerslack.Namespace(ts.accountID, "G002"))
	require.NoError(t, err)
	assert.Equal(t, "group_dm", ch.Type)
}

func TestSyncContextCancellation(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/team.info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":   true,
			"team": map[string]any{"id": "T001", "name": "test", "domain": "test"},
		})
	})
	mux.HandleFunc("/users.list", func(w http.ResponseWriter, r *http.Request) {
		// Don't respond — the context should already be canceled
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":                true,
			"members":           []map[string]any{},
			"response_metadata": map[string]any{"next_cursor": ""},
		})
	})

	ts := newTestSetup(t, mux)
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancel immediately

	err := ts.orch.Run(ctx, SyncOptions{})
	assert.Error(t, err)
}

func TestSyncTeamInfoError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/team.info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":    false,
			"error": "invalid_auth",
		})
	})

	ts := newTestSetup(t, mux)
	err := ts.orch.Run(context.Background(), SyncOptions{})
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "workspace sync")

	// Run must record the failure on the account row (recordAuthResult) — a
	// revoked/broken token must surface in Desktop, not stay "ok" forever.
	// invalid_auth is specifically a dead-token signal, so status="revoked"
	// (Desktop's more urgent red indicator), not the softer "error".
	acct, dbErr := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, dbErr)
	assert.Equal(t, "revoked", acct.Status)
	assert.Contains(t, acct.Error, "workspace sync")
}

// TestSyncTeamInfoError_GenericErrorNotClassifiedAsRevoked proves
// isRevokedAuthError actually discriminates: a non-auth failure (unlike
// TestSyncTeamInfoError's invalid_auth) must record plain "error", not
// "revoked" — a classifier that always says "revoked" would pass the other
// test too, so this is the branch that actually pins the distinction.
func TestSyncTeamInfoError_GenericErrorNotClassifiedAsRevoked(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/team.info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": "internal_error"})
	})

	ts := newTestSetup(t, mux)
	require.Error(t, ts.orch.Run(context.Background(), SyncOptions{}))

	acct, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, "error", acct.Status, "a non-auth Slack error must not be classified as revoked")
}

// TestRunRecordsAuthStateRecoversOnSuccess: after a failed Run flips the
// account's status to "error", a subsequent successful Run must clear it back
// to "ok" — mirroring calendar.Syncer/gmail.Syncer's recordAuthResult.
func TestRunRecordsAuthStateRecoversOnSuccess(t *testing.T) {
	errorMux := http.NewServeMux()
	errorMux.HandleFunc("/team.info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": "invalid_auth"})
	})
	ts := newTestSetup(t, errorMux)
	require.Error(t, ts.orch.Run(context.Background(), SyncOptions{}))
	acct, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	require.Equal(t, "revoked", acct.Status) // invalid_auth classifies as revoked

	// Re-point the client at a healthy server (same orchestrator, same
	// account row) and re-run — status must clear.
	healthySrv := httptest.NewServer(defaultMux())
	t.Cleanup(healthySrv.Close)
	healthyAPI := goslack.New("xoxp-test-token", goslack.OptionAPIURL(healthySrv.URL+"/"))
	ts.orch.slackClient = watchtowerslack.NewClientWithAPIUnlimited(healthyAPI)
	ts.orch.slackClient.SetLogger(ts.orch.logger)

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	acct, err = ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, "ok", acct.Status)
	assert.Empty(t, acct.Error)
}

// TestRecordAuthResultSkipsCancelledContext is calendar.Syncer's
// TestRecordAuthResultSkipsCancelledContext precedent applied to Orchestrator:
// a cancelled ctx means daemon shutdown, not an auth problem, so a real error
// that happens to coincide with shutdown must not flip the account's status
// (a regression that made this guard fire unconditionally, masking a genuine
// auth failure, would pass every other auth-state test in this file — none
// of them cancel the context before calling recordAuthResult).
func TestRecordAuthResultSkipsCancelledContext(t *testing.T) {
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	accountID, err := database.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)

	orch := NewOrchestrator(database, nil, &config.Config{}, accountID)
	orch.logger = log.New(os.Stderr, "[test] ", 0) // avoid SetLogger's nil slackClient touch

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	orch.recordAuthResult(ctx, errors.New("sync: terminated signal received"))

	acct, err := database.GetSlackAccount(accountID)
	require.NoError(t, err)
	assert.Equal(t, "ok", acct.Status, "cancelled ctx must not flip auth state")
	assert.Empty(t, acct.Error)
}

func TestSyncOptionsDefaults(t *testing.T) {
	opts := SyncOptions{}
	assert.False(t, opts.Full)
	assert.Empty(t, opts.Channels)
	assert.Equal(t, 0, opts.Workers)
}

func TestIsNonFatalError(t *testing.T) {
	tests := []struct {
		err      string
		expected bool
	}{
		{"channel_not_found", true},
		{"account_inactive", true},
		{"is_archived", true},
		{"not_in_channel", true},
		{"missing_scope", true},
		{"access_denied", true},
		{"some random db error", false},
		{"", false},
	}

	for _, tt := range tests {
		t.Run(tt.err, func(t *testing.T) {
			if tt.err == "" {
				assert.False(t, isNonFatalError(nil))
			} else {
				assert.Equal(t, tt.expected, isNonFatalError(errFromString(tt.err)))
			}
		})
	}
}

func TestSlackChannelType(t *testing.T) {
	tests := []struct {
		name     string
		channel  goslack.Channel
		expected string
	}{
		{
			name:     "public channel",
			channel:  goslack.Channel{},
			expected: "public",
		},
		{
			name: "private channel",
			channel: goslack.Channel{
				GroupConversation: goslack.GroupConversation{
					Conversation: goslack.Conversation{IsPrivate: true},
				},
			},
			expected: "private",
		},
		{
			name: "DM",
			channel: goslack.Channel{
				GroupConversation: goslack.GroupConversation{
					Conversation: goslack.Conversation{IsIM: true},
				},
			},
			expected: "dm",
		},
		{
			name: "group DM",
			channel: goslack.Channel{
				GroupConversation: goslack.GroupConversation{
					Conversation: goslack.Conversation{IsMpIM: true},
				},
			},
			expected: "group_dm",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			assert.Equal(t, tt.expected, slackChannelType(tt.channel))
		})
	}
}

func TestUserProfileJSONStored(t *testing.T) {
	ts := newTestSetup(t, defaultMux())
	err := ts.orch.syncMetadata(context.Background(), SyncOptions{})
	require.NoError(t, err)

	alice, err := ts.db.GetUserByName("alice")
	require.NoError(t, err)
	require.NotNil(t, alice)

	// Verify profile JSON was stored and is valid JSON
	assert.NotEmpty(t, alice.ProfileJSON)
	var profile map[string]any
	err = json.Unmarshal([]byte(alice.ProfileJSON), &profile)
	assert.NoError(t, err, "profile_json should be valid JSON")
	assert.Equal(t, "alice@example.com", profile["email"])
}

// integrationMux creates a mock Slack API server where conversations.history returns
// different messages per channel, and conversations.replies returns thread replies.
func integrationMux(channelMessages map[string][]map[string]any, threadReplies map[string][]map[string]any) *http.ServeMux {
	mux := baseMux()

	mux.HandleFunc("/conversations.history", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		channelID := r.FormValue("channel")
		msgs, ok := channelMessages[channelID]
		if !ok {
			msgs = []map[string]any{}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":                true,
			"messages":          msgs,
			"has_more":          false,
			"response_metadata": map[string]any{"next_cursor": ""},
		})
	})

	mux.HandleFunc("/conversations.replies", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		channelID := r.FormValue("channel")
		threadTS := r.FormValue("ts")
		key := channelID + "|" + threadTS
		replies, ok := threadReplies[key]
		if !ok {
			replies = []map[string]any{}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":                true,
			"messages":          replies,
			"has_more":          false,
			"response_metadata": map[string]any{"next_cursor": ""},
		})
	})

	return mux
}

// TestIntegrationSyncFlow runs a full sync with canned Slack API responses
// (workspace info, users, channels, messages, thread replies) and verifies
// that the database contains the expected data after sync completes.
func TestIntegrationSyncFlow(t *testing.T) {
	// Define messages per channel
	channelMessages := map[string][]map[string]any{
		"C001": {
			{
				"type": "message", "user": "U001",
				"text":        "Deploying v2.3 to production",
				"ts":          "1740567600.000100",
				"reply_count": 2, "thread_ts": "1740567600.000100",
			},
			{
				"type": "message", "user": "U002",
				"text": "Monitoring dashboards now",
				"ts":   "1740567600.000200",
			},
		},
		"C002": {
			{
				"type": "message", "user": "U001",
				"text": "New design mockups ready for review",
				"ts":   "1740567600.000300",
			},
		},
		// C003 (old-project) is archived and won't be synced by default
	}

	// Define thread replies: parent message + 2 replies
	threadReplies := map[string][]map[string]any{
		"C001|1740567600.000100": {
			{
				"type": "message", "user": "U001",
				"text":        "Deploying v2.3 to production",
				"ts":          "1740567600.000100",
				"thread_ts":   "1740567600.000100",
				"reply_count": 2,
			},
			{
				"type": "message", "user": "U002",
				"text":      "Looks good, I'll keep an eye on metrics",
				"ts":        "1740567600.000150",
				"thread_ts": "1740567600.000100",
			},
			{
				"type": "message", "user": "U003",
				"text":      "No breaking changes in my service",
				"ts":        "1740567600.000160",
				"thread_ts": "1740567600.000100",
			},
		},
	}

	mux := integrationMux(channelMessages, threadReplies)
	ts := newTestSetup(t, mux)

	err := ts.orch.Run(context.Background(), SyncOptions{Full: true})
	require.NoError(t, err)

	// --- Verify the connected account's team info ---
	acct, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, "T024BE7LD", acct.TeamID)
	assert.Equal(t, "my-company", acct.TeamName)
	assert.Equal(t, "my-company", acct.TeamDomain)

	// --- Verify users ---
	users, err := ts.db.GetUsers(db.UserFilter{})
	require.NoError(t, err)
	assert.Len(t, users, 3)

	alice, err := ts.db.GetUserByName("alice")
	require.NoError(t, err)
	require.NotNil(t, alice)
	assert.Equal(t, watchtowerslack.Namespace(ts.accountID, "U001"), alice.ID)
	assert.Equal(t, "Alice Smith", alice.RealName)

	// --- Verify channels ---
	channels, err := ts.db.GetChannels(db.ChannelFilter{})
	require.NoError(t, err)
	assert.Len(t, channels, 3)

	general, err := ts.db.GetChannelByName("general")
	require.NoError(t, err)
	require.NotNil(t, general)
	assert.Equal(t, watchtowerslack.Namespace(ts.accountID, "C001"), general.ID)
	assert.True(t, general.IsMember)

	engineering, err := ts.db.GetChannelByName("engineering")
	require.NoError(t, err)
	require.NotNil(t, engineering)
	assert.Equal(t, watchtowerslack.Namespace(ts.accountID, "C002"), engineering.ID)

	// --- Verify messages in #general (C001) ---
	c001ID := watchtowerslack.Namespace(ts.accountID, "C001")
	c001Msgs, err := ts.db.GetMessagesByChannel(c001ID, 100)
	require.NoError(t, err)
	assert.Len(t, c001Msgs, 4) // 2 history messages + 2 thread replies

	// Verify a specific message
	found := false
	for _, m := range c001Msgs {
		if m.TS == "1740567600.000100" {
			found = true
			assert.Equal(t, watchtowerslack.Namespace(ts.accountID, "U001"), m.UserID)
			assert.Equal(t, "Deploying v2.3 to production", m.Text)
		}
	}
	assert.True(t, found, "expected to find the deployment message")

	// --- Verify messages in #engineering (C002) ---
	c002Msgs, err := ts.db.GetMessagesByChannel(watchtowerslack.Namespace(ts.accountID, "C002"), 100)
	require.NoError(t, err)
	assert.Len(t, c002Msgs, 1)
	assert.Equal(t, "New design mockups ready for review", c002Msgs[0].Text)

	// --- Verify thread replies were synced ---
	threadMsgs, err := ts.db.GetThreadReplies(c001ID, "1740567600.000100")
	require.NoError(t, err)
	assert.GreaterOrEqual(t, len(threadMsgs), 2, "thread should have at least 2 replies")

	replyFound := false
	for _, m := range threadMsgs {
		if m.TS == "1740567600.000150" {
			replyFound = true
			assert.Equal(t, watchtowerslack.Namespace(ts.accountID, "U002"), m.UserID)
			assert.Equal(t, "Looks good, I'll keep an eye on metrics", m.Text)
		}
	}
	assert.True(t, replyFound, "expected to find thread reply from bob")

	// --- Verify sync state ---
	syncState, err := ts.db.GetSyncState(c001ID)
	require.NoError(t, err)
	require.NotNil(t, syncState)
	assert.True(t, syncState.IsInitialSyncComplete)
	assert.Greater(t, syncState.MessagesSynced, 0)

	// --- Verify archived channel (C003) was NOT synced for messages ---
	c003Msgs, err := ts.db.GetMessagesByChannel(watchtowerslack.Namespace(ts.accountID, "C003"), 100)
	require.NoError(t, err)
	assert.Len(t, c003Msgs, 0, "archived channel should not have messages synced")
}

// TestIntegrationSyncWithChannelFilter verifies that passing --channels
// limits the sync to only the specified channels.
func TestIntegrationSyncWithChannelFilter(t *testing.T) {
	channelMessages := map[string][]map[string]any{
		"C001": {
			{"type": "message", "user": "U001", "text": "General msg", "ts": "1740567600.000100"},
		},
		"C002": {
			{"type": "message", "user": "U002", "text": "Engineering msg", "ts": "1740567600.000200"},
		},
	}

	mux := integrationMux(channelMessages, nil)
	ts := newTestSetup(t, mux)

	// Sync only "general" channel
	err := ts.orch.Run(context.Background(), SyncOptions{
		Channels: []string{"general"},
	})
	require.NoError(t, err)

	// General should have messages
	c001Msgs, err := ts.db.GetMessagesByChannel(watchtowerslack.Namespace(ts.accountID, "C001"), 100)
	require.NoError(t, err)
	assert.Len(t, c001Msgs, 1)

	// Engineering should NOT have messages (wasn't requested)
	c002Msgs, err := ts.db.GetMessagesByChannel(watchtowerslack.Namespace(ts.accountID, "C002"), 100)
	require.NoError(t, err)
	assert.Len(t, c002Msgs, 0)
}

// errFromString creates an error with the given string.
type stringError string

func (e stringError) Error() string { return string(e) }

func errFromString(s string) error { return stringError(s) }

// TestSyncTwoAccountsNoCollision reproduces the exact scenario namespacing
// exists to defend against: two connected Slack accounts (different orgs)
// whose Slack channel ids happen to collide on the raw wire id "C001". Each
// account gets its own Orchestrator + mock Slack server, sharing one DB, and
// the resulting "channels"/"messages" rows must stay distinct — no
// cross-account contamination of names, message text, or counts.
func TestSyncTwoAccountsNoCollision(t *testing.T) {
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	account1ID, err := database.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)
	account2ID, err := database.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)
	require.NotEqual(t, account1ID, account2ID)

	// Both mocks use baseMux()'s fixed conversations.list, which always
	// returns a channel with raw id "C001" ("general") — the same raw id
	// for both "orgs" — but each org's conversations.history returns
	// different message content so cross-contamination is detectable.
	mux1 := integrationMux(map[string][]map[string]any{
		"C001": {{"type": "message", "user": "U001", "text": "org1 message", "ts": "1700000001.000000"}},
	}, nil)
	mux2 := integrationMux(map[string][]map[string]any{
		"C001": {{"type": "message", "user": "U001", "text": "org2 message", "ts": "1700000002.000000"}},
	}, nil)

	srv1 := httptest.NewServer(mux1)
	t.Cleanup(srv1.Close)
	srv2 := httptest.NewServer(mux2)
	t.Cleanup(srv2.Close)

	cfg := &config.Config{Sync: config.SyncConfig{Workers: 2, InitialHistoryDays: 30}}

	api1 := goslack.New("xoxp-test-token-1", goslack.OptionAPIURL(srv1.URL+"/"))
	orch1 := NewOrchestrator(database, watchtowerslack.NewClientWithAPIUnlimited(api1), cfg, account1ID)
	orch1.SetLogger(log.New(os.Stderr, "[test-1] ", 0))

	api2 := goslack.New("xoxp-test-token-2", goslack.OptionAPIURL(srv2.URL+"/"))
	orch2 := NewOrchestrator(database, watchtowerslack.NewClientWithAPIUnlimited(api2), cfg, account2ID)
	orch2.SetLogger(log.New(os.Stderr, "[test-2] ", 0))

	require.NoError(t, orch1.Run(context.Background(), SyncOptions{Full: true}))
	require.NoError(t, orch2.Run(context.Background(), SyncOptions{Full: true}))

	ch1ID := watchtowerslack.Namespace(account1ID, "C001")
	ch2ID := watchtowerslack.Namespace(account2ID, "C001")
	require.NotEqual(t, ch1ID, ch2ID)

	ch1, err := database.GetChannelByID(ch1ID)
	require.NoError(t, err)
	require.NotNil(t, ch1, "account 1's C001 channel should exist under its namespaced id")

	ch2, err := database.GetChannelByID(ch2ID)
	require.NoError(t, err)
	require.NotNil(t, ch2, "account 2's C001 channel should exist under its namespaced id, distinct from account 1's")

	msgs1, err := database.GetMessagesByChannel(ch1ID, 100)
	require.NoError(t, err)
	require.Len(t, msgs1, 1)
	assert.Equal(t, "org1 message", msgs1[0].Text)
	assert.Equal(t, watchtowerslack.Namespace(account1ID, "U001"), msgs1[0].UserID)

	msgs2, err := database.GetMessagesByChannel(ch2ID, 100)
	require.NoError(t, err)
	require.Len(t, msgs2, 1)
	assert.Equal(t, "org2 message", msgs2[0].Text)
	assert.Equal(t, watchtowerslack.Namespace(account2ID, "U001"), msgs2[0].UserID)

	// The two channel rows must never mix — account 1's message set must
	// not contain account 2's text (and vice versa).
	assert.NotEqual(t, msgs1[0].Text, msgs2[0].Text)
}

// TestSyncChannelUsesRawIDForSlackAPI proves the de-namespacing boundary is
// correctly placed: syncChannel is given a namespaced channel id, but the
// Slack API request it issues must carry only the raw id.
func TestSyncChannelUsesRawIDForSlackAPI(t *testing.T) {
	var gotChannelParam string
	mux := baseMux()
	mux.HandleFunc("/conversations.history", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		gotChannelParam = r.Form.Get("channel")
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"messages": []map[string]any{
				{"ts": "1700000001.000000", "user": "U001", "text": "hi", "type": "message"},
			},
			"has_more":          false,
			"response_metadata": map[string]any{"next_cursor": ""},
		})
	})

	ts := newTestSetup(t, mux)

	namespacedChannelID := watchtowerslack.Namespace(ts.accountID, "C001")
	err := ts.orch.syncChannel(context.Background(), namespacedChannelID, false)
	require.NoError(t, err)

	assert.Equal(t, "C001", gotChannelParam,
		"the Slack API request must carry the raw channel id, not the namespaced %q", namespacedChannelID)

	// The DB-side sync_state row and the upserted message must both be
	// keyed by the namespaced id, never the raw wire id.
	state, err := ts.db.GetSyncState(namespacedChannelID)
	require.NoError(t, err)
	require.NotNil(t, state)

	msgs, err := ts.db.GetMessagesByChannel(namespacedChannelID, 10)
	require.NoError(t, err)
	require.Len(t, msgs, 1)
	assert.Equal(t, ts.ns("U001"), msgs[0].UserID)
}

// reactionsListItem renders one reactions.list message item the way Slack
// does (reactions nested under "message"; slack-go lifts them onto
// ReactedItem.Reactions).
func reactionsListItem(channel, ts string, reactions ...map[string]any) map[string]any {
	return map[string]any{
		"type": "message", "channel": channel,
		"message": map[string]any{"type": "message", "ts": ts, "reactions": reactions},
	}
}

// TestSyncInboxReactionsUsesOneOwnerListing pins the API-budget shape of
// syncInboxReactions: the only reaction auto-resolve ever reads is the
// OWNER's (CheckUserReplied filters on the owner's user id), and
// reactions.list under the owner's token enumerates exactly those in a
// handful of pages — so the phase makes ONE listing call, never one
// reactions.get per pending item. On a real install 196 pending items were
// costing 196 Tier-3 calls (~5 of every 10 sync minutes) each cycle to learn
// what a single listing says. The listing carries every reaction on a
// message the owner touched, so other reactors on that message still land
// in the table as before; a pending message the owner never reacted to is
// simply left alone.
func TestSyncInboxReactionsUsesOneOwnerListing(t *testing.T) {
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	accountID, err := database.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)
	owner := watchtowerslack.Namespace(accountID, "UOWNER")
	require.NoError(t, database.UpdateSlackAccountConnection(accountID, "T024BE7LD", "my-company", "my-company", owner))

	ch := watchtowerslack.Namespace(accountID, "C001")
	for _, ts := range []string{"1700000001.000000", "1700000002.000000"} {
		_, err = database.CreateInboxItem(db.InboxItem{
			ChannelID: ch, MessageTS: ts,
			SenderUserID: watchtowerslack.Namespace(accountID, "U001"), TriggerType: "mention",
		})
		require.NoError(t, err)
	}

	var listUsers []string
	mux := baseMux()
	mux.HandleFunc("/reactions.get", func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("reactions.get must not be called per pending item; got %s", r.URL.RawQuery)
	})
	mux.HandleFunc("/reactions.list", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		listUsers = append(listUsers, r.Form.Get("user"))
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"items": []map[string]any{
				// The owner reacted to pending message #1 (a colleague did too) …
				reactionsListItem("C001", "1700000001.000000",
					map[string]any{"name": "eyes", "count": 2, "users": []string{"UOWNER", "U002"}}),
				// … and to a message that is not pending at all.
				reactionsListItem("C009", "1700000009.000000",
					map[string]any{"name": "thumbsup", "count": 1, "users": []string{"UOWNER"}}),
			},
			"paging": map[string]any{"count": 100, "total": 2, "page": 1, "pages": 1},
		})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	api := goslack.New("xoxp-test-token-1", goslack.OptionAPIURL(srv.URL+"/"))
	orch := NewOrchestrator(database, watchtowerslack.NewClientWithAPIUnlimited(api), &config.Config{}, accountID)
	orch.SetLogger(log.New(os.Stderr, "[test] ", 0))
	require.NoError(t, orch.ensureWorkspace(context.Background()))

	orch.syncInboxReactions(context.Background())

	assert.Equal(t, []string{"UOWNER"}, listUsers, "exactly one reactions.list call, under the owner's own id")

	replied, err := database.CheckUserReplied(owner, ch, "1700000001.000000", "")
	require.NoError(t, err)
	assert.True(t, replied, "the owner's reaction on pending message #1 must be visible to auto-resolve")

	summaries, err := database.GetReactionsForMessages(ch, []string{"1700000001.000000", "1700000002.000000"})
	require.NoError(t, err)
	require.Len(t, summaries["1700000001.000000"], 1, "one emoji on message #1")
	assert.Equal(t, 2, summaries["1700000001.000000"][0].Count, "the colleague's reaction on the same message is kept too")
	assert.Empty(t, summaries["1700000002.000000"], "a pending message the owner never reacted to is left alone")

	summaries, err = database.GetReactionsForMessages(watchtowerslack.Namespace(accountID, "C009"), []string{"1700000009.000000"})
	require.NoError(t, err)
	assert.Empty(t, summaries, "a non-pending message in the listing is not written — this phase serves the inbox only")
}

// TestSyncInboxReactionsScopedToOwnAccount reproduces the exact collision
// syncInboxReactions must not touch: two connected accounts share a colliding
// raw channel id ("C001"), each with its own pending inbox item. Before the
// account-scoping fix, account 1's orchestrator would strip the namespace off
// EVERY pending item — including account 2's. The listing is made under
// account 1's own token and id, so an item it returns for the colliding raw
// channel is account 1's message — account 2's pending item at the other ts
// must never be written under account 1's namespace.
func TestSyncInboxReactionsScopedToOwnAccount(t *testing.T) {
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	account1ID, err := database.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)
	account2ID, err := database.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)
	owner1 := watchtowerslack.Namespace(account1ID, "UOWNER")
	require.NoError(t, database.UpdateSlackAccountConnection(account1ID, "T1", "one", "one", owner1))

	// Both accounts have a pending inbox item on the same colliding raw
	// channel id "C001", at different message timestamps.
	_, err = database.CreateInboxItem(db.InboxItem{
		ChannelID: watchtowerslack.Namespace(account1ID, "C001"), MessageTS: "1700000001.000000",
		SenderUserID: watchtowerslack.Namespace(account1ID, "U001"), TriggerType: "mention",
	})
	require.NoError(t, err)
	_, err = database.CreateInboxItem(db.InboxItem{
		ChannelID: watchtowerslack.Namespace(account2ID, "C001"), MessageTS: "1700000002.000000",
		SenderUserID: watchtowerslack.Namespace(account2ID, "U001"), TriggerType: "mention",
	})
	require.NoError(t, err)

	mux := baseMux()
	mux.HandleFunc("/reactions.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		// Account 1's token lists a reaction at BOTH timestamps on raw C001:
		// only the first is account 1's pending item.
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"items": []map[string]any{
				reactionsListItem("C001", "1700000001.000000", map[string]any{"name": "eyes", "count": 1, "users": []string{"UOWNER"}}),
				reactionsListItem("C001", "1700000002.000000", map[string]any{"name": "eyes", "count": 1, "users": []string{"UOWNER"}}),
			},
			"paging": map[string]any{"count": 100, "total": 2, "page": 1, "pages": 1},
		})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	api := goslack.New("xoxp-test-token-1", goslack.OptionAPIURL(srv.URL+"/"))
	orch1 := NewOrchestrator(database, watchtowerslack.NewClientWithAPIUnlimited(api), &config.Config{}, account1ID)
	orch1.SetLogger(log.New(os.Stderr, "[test-1] ", 0))
	require.NoError(t, orch1.ensureWorkspace(context.Background()))

	orch1.syncInboxReactions(context.Background())

	got, err := database.GetReactionsForMessages(watchtowerslack.Namespace(account1ID, "C001"), []string{"1700000001.000000", "1700000002.000000"})
	require.NoError(t, err)
	assert.Len(t, got["1700000001.000000"], 1, "account 1's own pending item gets its reaction")
	assert.Empty(t, got["1700000002.000000"], "account 2's pending item must never be written under account 1's namespace")
	got, err = database.GetReactionsForMessages(watchtowerslack.Namespace(account2ID, "C001"), []string{"1700000002.000000"})
	require.NoError(t, err)
	assert.Empty(t, got, "account 1's listing says nothing about account 2's message")
}

// TestSearchSyncThrottlesReadStateAndRoster pins the cadence of the two
// auxiliary refreshes the search path runs after the messages themselves:
// the per-channel read cursor (conversations.info per channel with an unread
// digest) and the full workspace roster (users.list, every page). Neither is
// message sync — a read cursor moves at human pace and the roster at hiring
// pace — yet both ran on every 15-minute cycle: on a real install 158
// channels with an unread digest back to March cost 158 Tier-3 calls
// (~4 minutes) and the roster 17 pages, every cycle. The read state is now
// refreshed at most once an hour and the roster once a day (per daemon
// process; a restart refreshes both on its first run), while search.messages
// still runs every cycle.
func TestSearchSyncThrottlesReadStateAndRoster(t *testing.T) {
	var infoCalls, listCalls, searchCalls atomic.Int32
	mux := defaultMux()
	mux.HandleFunc("/conversations.info", func(w http.ResponseWriter, r *http.Request) {
		infoCalls.Add(1)
		_ = r.ParseForm()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "channel": map[string]any{"id": r.Form.Get("channel"), "last_read": "1700000001.000000"}})
	})
	counting := http.NewServeMux()
	counting.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/users.list":
			listCalls.Add(1)
		case "/search.messages":
			searchCalls.Add(1)
		}
		mux.ServeHTTP(w, r)
	})
	ts := newTestSetup(t, counting)
	require.NoError(t, ts.db.UpdateSlackAccountConnection(ts.accountID, "T024BE7LD", "my-company", "my-company", ""))
	// An unread channel digest keeps C001 on the read-state list on every
	// run (the first-run "channels without last_read" path empties itself
	// after one pass, so it cannot show the throttle). Its period ends AFTER
	// the stubbed last_read (epoch 1700000001), or finishSync's
	// AutoMarkReadFromSlack would mark it read on the first run and the
	// later runs would measure the first-run path for C002 instead.
	require.NoError(t, ts.db.UpsertChannel(db.Channel{ID: watchtowerslack.Namespace(ts.accountID, "C001"), Name: "general", Type: "public", IsMember: true}))
	_, err := ts.db.UpsertDigest(db.Digest{ChannelID: watchtowerslack.Namespace(ts.accountID, "C001"), Type: "channel", Summary: "s", PeriodFrom: 1700000100, PeriodTo: 1700000200, MessageCount: 1})
	require.NoError(t, err)

	start := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	now := start
	ts.orch.now = func() time.Time { return now }

	run := func(at time.Duration) {
		t.Helper()
		now = start.Add(at)
		require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	}

	run(0)
	assert.Equal(t, int32(1), searchCalls.Load())
	firstInfo, firstList := infoCalls.Load(), listCalls.Load()
	require.Greater(t, firstInfo, int32(0), "the first run refreshes the read cursor")
	require.Greater(t, firstList, int32(0), "the first run fetches the roster")

	run(30 * time.Minute)
	assert.Equal(t, int32(2), searchCalls.Load(), "messages sync every cycle")
	assert.Equal(t, firstInfo, infoCalls.Load(), "read state is not refreshed again within the hour")
	assert.Equal(t, firstList, listCalls.Load(), "the roster is not refetched within the day")

	run(2 * time.Hour)
	assert.Equal(t, 2*firstInfo, infoCalls.Load(), "an hour later the read state is refreshed")
	assert.Equal(t, firstList, listCalls.Load(), "the roster still waits for its day")

	run(25 * time.Hour)
	assert.Equal(t, 2*firstList, listCalls.Load(), "a day later the roster is refetched")
}

// TestSearchSyncRosterFailureRetriesNextCycle pins that the roster throttle
// stamps on success only: a users.list failure fails the run (as before) and
// the very next cycle fetches the roster again instead of waiting out the day
// on a fetch that never happened.
func TestSearchSyncRosterFailureRetriesNextCycle(t *testing.T) {
	var listCalls atomic.Int32
	failFirst := true
	mux := defaultMux()
	counting := http.NewServeMux()
	counting.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/users.list" {
			listCalls.Add(1)
			if failFirst {
				failFirst = false
				w.Header().Set("Content-Type", "application/json")
				json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": "internal_error"})
				return
			}
		}
		mux.ServeHTTP(w, r)
	})
	ts := newTestSetup(t, counting)
	require.NoError(t, ts.db.UpdateSlackAccountConnection(ts.accountID, "T024BE7LD", "my-company", "my-company", ""))

	now := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	ts.orch.now = func() time.Time { return now }

	err := ts.orch.Run(context.Background(), SyncOptions{})
	require.ErrorContains(t, err, "user roster sync")
	require.Equal(t, int32(1), listCalls.Load())

	now = now.Add(15 * time.Minute)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, int32(2), listCalls.Load(), "a failed roster fetch is retried on the next cycle, not after the day")
}

// TestSearchSyncReadStateFailureRetriesNextCycle is the read-state twin of
// the roster pin above: a pass in which every conversations.info call failed
// (a 429 storm, a dead network) updated nothing, so it must not be stamped as
// done — the next cycle refreshes again instead of logging "refreshed within
// the hour" over a refresh that never happened. Unlike the roster, the read
// cursor is best-effort and never fails the run.
func TestSearchSyncReadStateFailureRetriesNextCycle(t *testing.T) {
	var infoCalls atomic.Int32
	failing := true
	mux := defaultMux()
	mux.HandleFunc("/conversations.info", func(w http.ResponseWriter, r *http.Request) {
		infoCalls.Add(1)
		_ = r.ParseForm()
		w.Header().Set("Content-Type", "application/json")
		if failing {
			json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": "internal_error"})
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "channel": map[string]any{"id": r.Form.Get("channel"), "last_read": "1700000001.000000"}})
	})
	ts := newTestSetup(t, mux)
	require.NoError(t, ts.db.UpdateSlackAccountConnection(ts.accountID, "T024BE7LD", "my-company", "my-company", ""))
	require.NoError(t, ts.db.UpsertChannel(db.Channel{ID: watchtowerslack.Namespace(ts.accountID, "C001"), Name: "general", Type: "public", IsMember: true}))
	_, err := ts.db.UpsertDigest(db.Digest{ChannelID: watchtowerslack.Namespace(ts.accountID, "C001"), Type: "channel", Summary: "s", PeriodFrom: 1700000100, PeriodTo: 1700000200, MessageCount: 1})
	require.NoError(t, err)

	now := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	ts.orch.now = func() time.Time { return now }

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}), "a failed read-cursor refresh never fails the run")
	first := infoCalls.Load()
	require.Greater(t, first, int32(0))

	failing = false
	now = now.Add(15 * time.Minute)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Greater(t, infoCalls.Load(), first, "a pass that updated nothing is retried on the next cycle, not after the hour")

	now = now.Add(15 * time.Minute)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, 2*first, infoCalls.Load(), "once a pass succeeded the hourly throttle holds")
}

// TestSyncInboxReactionsDegenerateInputs pins the clean-exit branches of the
// listing shape: no owner id yet → no Slack call at all (reactions.list with
// an empty user would list the token's own reactions anyway — a phantom
// write); a listing error → nothing written, no error surfaced (best-effort,
// retried next cycle); an empty listing → nothing written.
func TestSyncInboxReactionsDegenerateInputs(t *testing.T) {
	type fixture struct {
		ownerID string
		list    func(w http.ResponseWriter)
	}
	empty := func(w http.ResponseWriter) {
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "items": []any{}, "paging": map[string]any{"count": 100, "total": 0, "page": 1, "pages": 1}})
	}
	for _, tc := range []struct {
		name      string
		fx        fixture
		wantCalls int32
	}{
		{"no owner id", fixture{"", empty}, 0},
		{"listing error", fixture{"UOWNER", func(w http.ResponseWriter) {
			json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": "internal_error"})
		}}, 1},
		{"empty listing", fixture{"UOWNER", empty}, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, err := db.Open(":memory:")
			require.NoError(t, err)
			t.Cleanup(func() { database.Close() })
			accountID, err := database.CreateSlackAccount(db.SlackAccount{})
			require.NoError(t, err)
			owner := ""
			if tc.fx.ownerID != "" {
				owner = watchtowerslack.Namespace(accountID, tc.fx.ownerID)
			}
			require.NoError(t, database.UpdateSlackAccountConnection(accountID, "T1", "one", "one", owner))
			ch := watchtowerslack.Namespace(accountID, "C001")
			_, err = database.CreateInboxItem(db.InboxItem{ChannelID: ch, MessageTS: "1700000001.000000", SenderUserID: watchtowerslack.Namespace(accountID, "U001"), TriggerType: "mention"})
			require.NoError(t, err)

			var listCalls atomic.Int32
			mux := baseMux()
			mux.HandleFunc("/reactions.list", func(w http.ResponseWriter, r *http.Request) {
				listCalls.Add(1)
				w.Header().Set("Content-Type", "application/json")
				tc.fx.list(w)
			})
			srv := httptest.NewServer(mux)
			t.Cleanup(srv.Close)
			api := goslack.New("xoxp-test-token-1", goslack.OptionAPIURL(srv.URL+"/"))
			orch := NewOrchestrator(database, watchtowerslack.NewClientWithAPIUnlimited(api), &config.Config{}, accountID)
			orch.SetLogger(log.New(os.Stderr, "[test] ", 0))
			require.NoError(t, orch.ensureWorkspace(context.Background()))

			orch.syncInboxReactions(context.Background())

			assert.Equal(t, tc.wantCalls, listCalls.Load())
			got, err := database.GetReactionsForMessages(ch, []string{"1700000001.000000"})
			require.NoError(t, err)
			assert.Empty(t, got, "nothing is written")
		})
	}
}

// TestSyncChannelReadStateScopedToOwnAccount is syncChannelReadState's analog
// of TestSyncInboxReactionsScopedToOwnAccount: two accounts share a colliding
// raw channel id, both lacking a last_read cursor. Account 1's orchestrator
// must only ever call conversations.info for its own channel.
func TestSyncChannelReadStateScopedToOwnAccount(t *testing.T) {
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })

	account1ID, err := database.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)
	account2ID, err := database.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)

	for _, acctID := range []int64{account1ID, account2ID} {
		require.NoError(t, database.UpsertChannel(db.Channel{
			ID: watchtowerslack.Namespace(acctID, "C001"), Name: "general", Type: "public", IsMember: true,
		}))
	}

	var gotChannels []string
	mux := baseMux()
	mux.HandleFunc("/conversations.info", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		gotChannels = append(gotChannels, r.Form.Get("channel"))
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "channel": map[string]any{"id": "C001", "last_read": "1700000001.000000"}})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	api := goslack.New("xoxp-test-token-1", goslack.OptionAPIURL(srv.URL+"/"))
	orch1 := NewOrchestrator(database, watchtowerslack.NewClientWithAPIUnlimited(api), &config.Config{}, account1ID)
	orch1.SetLogger(log.New(os.Stderr, "[test-1] ", 0))

	require.NoError(t, orch1.syncChannelReadState(context.Background()))

	require.Len(t, gotChannels, 1, "account 1's orchestrator must only query its own channel, never account 2's")
	assert.Equal(t, "C001", gotChannels[0])
}
