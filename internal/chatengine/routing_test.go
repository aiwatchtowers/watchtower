package chatengine

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/chatstore"
	"watchtower/internal/config"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
)

// routingRow is a conversation's routing columns, compared whole.
type routingRow struct {
	Mode, Provider, Model, ActualProvider, ActualModel, Reason string
	ProviderNull, ModelNull                                    bool
}

func readRouting(t *testing.T, g *rig, conv int64) routingRow {
	t.Helper()
	var r routingRow
	var provider, model *string
	require.NoError(t, g.d.QueryRow(`SELECT routing_mode, provider, model, actual_provider, actual_model, routing_reason
		FROM chat_conversations WHERE id = ?`, conv).Scan(&r.Mode, &provider, &model, &r.ActualProvider, &r.ActualModel, &r.Reason))
	r.ProviderNull, r.ModelNull = provider == nil, model == nil
	if provider != nil {
		r.Provider = *provider
	}
	if model != nil {
		r.Model = *model
	}
	return r
}

// stickOnReserve writes what `ai session` leaves on an automatic chat that
// fell back to the reserve on quota.
func stickOnReserve(t *testing.T, g *rig, conv int64) {
	t.Helper()
	_, err := g.d.Exec(`UPDATE chat_conversations SET actual_provider = 'codex', actual_model = 'gpt-x',
		routing_reason = 'quota_exhausted' WHERE id = ?`, conv)
	require.NoError(t, err)
}

// TestChatengine_FeedCarriesRoutingReason: the feed's conversation carries
// the row's routing_reason, and a live session_ready's reason overlays it
// (the reason of the session that answers now).
func TestChatengine_FeedCarriesRoutingReason(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		c := newConversation(t, g.d)
		stickOnReserve(t, g, c)
		feed, err := g.r.Feed(context.Background(), c, 0)
		require.NoError(t, err)
		assert.Equal(t, "quota_exhausted", feed.Conversation.RoutingReason)
		raw, err := json.Marshal(feed.Conversation)
		require.NoError(t, err)
		assert.Contains(t, string(raw), `"routing_reason":"quota_exhausted"`)

		g.send(t, c, "go", nil)
		synctest.Wait()
		g.f.all()[0].emit(chat.Event{Type: chat.EventSessionReady, Provider: "codex", Model: "gpt-x",
			RoutingMode: "preferred_reserve", Reason: "required_capability_missing"})
		time.Sleep(time.Second)
		synctest.Wait()
		// The row lags the session (`ai session` writes its own columns):
		// the live reason is the feed's.
		_, err = g.d.Exec(`UPDATE chat_conversations SET routing_reason = 'quota_exhausted' WHERE id = ?`, c)
		require.NoError(t, err)
		feed, err = g.r.Feed(context.Background(), c, 0)
		require.NoError(t, err)
		assert.Equal(t, "required_capability_missing", feed.Conversation.RoutingReason)
		g.f.all()[0].finish()
		synctest.Wait()
	})
}

// TestChatengine_UsePreferredClearsStickyAndRetiresIdleSession: Use
// preferred on an automatic chat sticky on the reserve writes preferred +
// reserve with the actual pair and reason cleared, retires the idle
// session, and tells a subscriber once. A pinned chat turns automatic the
// same way.
func TestChatengine_UsePreferredClearsStickyAndRetiresIdleSession(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		c := newConversation(t, g.d)
		g.send(t, c, "one", nil)
		synctest.Wait()
		stickOnReserve(t, g, c)
		idle := procOf(t, g, c)
		require.Len(t, idle, 1)
		require.False(t, idle[0].isExited(), "the idle session is warm")
		sub := g.r.Subscribe(Target{Conversation: c}, Client{Kind: "mac"})
		defer sub.Close()
		synctest.Wait()
		drain(sub)

		require.NoError(t, g.r.Manage(context.Background(), ManageRequest{Conversation: c, Op: ManageUsePreferred}))
		time.Sleep(time.Second)
		synctest.Wait()
		assert.Equal(t, routingRow{Mode: "preferred_reserve", ProviderNull: true, ModelNull: true}, readRouting(t, g, c))
		assert.True(t, idle[0].isExited(), "the idle session is retired")
		updates := 0
		for _, ev := range drain(sub) {
			if ev.Type == EventConversationUpdate {
				updates++
				assert.Empty(t, ev.ConversationUpdate.RoutingReason)
				assert.Empty(t, ev.ConversationUpdate.ActualProvider)
				assert.Equal(t, "auto", ev.ConversationUpdate.Routing.Mode)
			}
		}
		assert.Equal(t, 1, updates, "one conversation_update")

		pinned := newConversation(t, g.d)
		g.send(t, pinned, "one", &chatstore.Routing{Provider: "codex", Model: "gpt-x"})
		synctest.Wait()
		_, err := g.d.Exec(`UPDATE chat_conversations SET actual_provider = 'codex', actual_model = 'gpt-x' WHERE id = ?`, pinned)
		require.NoError(t, err)
		require.Equal(t, "pinned", readRouting(t, g, pinned).Mode)
		require.NoError(t, g.r.Manage(context.Background(), ManageRequest{Conversation: pinned, Op: ManageUsePreferred}))
		synctest.Wait()
		assert.Equal(t, routingRow{Mode: "preferred_reserve", ProviderNull: true, ModelNull: true}, readRouting(t, g, pinned))
		assert.True(t, procOf(t, g, pinned)[0].isExited())
	})
}

// TestChatengine_UsePreferredRefusedWhileTurnRuns: while a turn runs, Use
// preferred is refused busy; the row is unchanged and the session lives.
func TestChatengine_UsePreferredRefusedWhileTurnRuns(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		c := newConversation(t, g.d)
		stickOnReserve(t, g, c)
		g.send(t, c, "go", nil)
		synctest.Wait()
		before := readRouting(t, g, c)
		err := g.r.Manage(context.Background(), ManageRequest{Conversation: c, Op: ManageUsePreferred})
		require.ErrorIs(t, err, chatstore.ErrBusy)
		assert.Equal(t, "busy", ErrorCode(err))
		assert.Equal(t, before, readRouting(t, g, c), "the row is unchanged")
		p := procOf(t, g, c)[0]
		assert.False(t, p.isExited())
		assert.NotContains(t, p.log(), "close")
		p.finish()
		synctest.Wait()
	})
}

// TestChatengine_UsePreferredOnGoneConversation: a deleted id and an
// embedded chat (context_type set) are gone; the embedded row is unchanged.
func TestChatengine_UsePreferredOnGoneConversation(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		err := g.r.Manage(context.Background(), ManageRequest{Conversation: 999_999, Op: ManageUsePreferred})
		require.ErrorIs(t, err, chatstore.ErrConversationGone)

		res, err := g.d.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at,
			routing_mode, provider, actual_provider, routing_reason) VALUES ('t', 'target', '7', 1, 1, 'pinned', 'codex', 'codex', 'quota_exhausted')`)
		require.NoError(t, err)
		embedded, err := res.LastInsertId()
		require.NoError(t, err)
		before := readRouting(t, g, embedded)
		err = g.r.Manage(context.Background(), ManageRequest{Conversation: embedded, Op: ManageUsePreferred})
		require.ErrorIs(t, err, chatstore.ErrConversationGone)
		assert.Equal(t, before, readRouting(t, g, embedded))
	})
}

// catalogConfig is a config with claude preferred and codex as the reserve.
func catalogConfig() *config.Config {
	cfg := &config.Config{}
	cfg.AI.Provider = "claude"
	cfg.AI.Fallback.Enabled = true
	cfg.AI.Fallback.Provider = "codex"
	return cfg
}

// quotaRouter is a router over a fresh health store where claude waits for
// its quota.
func quotaRouter(t *testing.T) *providerrouting.Router {
	t.Helper()
	now := time.Date(2026, 1, 2, 10, 0, 0, 0, time.UTC)
	health := providerhealth.New(t.TempDir(), func() time.Time { return now })
	require.NoError(t, health.RecordQuota(context.Background(), providerhealth.AccountScope("claude", ""),
		&providers.Failure{Provider: "claude", Category: providers.Quota}))
	return &providerrouting.Router{Health: health, Allowed: func(string) error { return nil }}
}

func catalogRow(c *RoutingCatalog, id string) *RoutingProvider {
	for i := range c.Providers {
		if c.Providers[i].ID == id {
			return &c.Providers[i]
		}
	}
	return nil
}

// TestChatengine_RoutingCatalogCarriesPairCapsAndStatus: the catalog names
// each allowed provider with its peer and capability row, and carries the
// routing status without the command's application fields.
func TestChatengine_RoutingCatalogCarriesPairCapsAndStatus(t *testing.T) {
	c := ReadRoutingCatalog(context.Background(), catalogConfig(), quotaRouter(t))
	claude, codex := catalogRow(c, "claude"), catalogRow(c, "codex")
	require.NotNil(t, claude)
	require.NotNil(t, codex)
	assert.Equal(t, RoutingProvider{ID: "claude", DisplayName: "Claude", ReservePeer: "codex", Images: true, PDFs: true,
		ReadFolder: true, ClaudeAI: true}, *claude)
	assert.Equal(t, RoutingProvider{ID: "codex", DisplayName: "Codex", ReservePeer: "claude", Images: true,
		ReadFolder: true}, *codex)
	if ollama := catalogRow(c, "ollama"); ollama != nil {
		assert.Empty(t, ollama.ReservePeer, "a provider with no peer has none")
	}
	require.NotNil(t, c.Status)
	assert.Empty(t, c.Error)
	assert.Equal(t, "claude", c.Status.PreferredProvider)
	assert.True(t, c.Status.Enabled)
	require.NotEmpty(t, c.Status.Providers)
	assert.Equal(t, "claude", c.Status.Providers[0].Provider)
	assert.Equal(t, providerhealth.QuotaWait, c.Status.Providers[0].State)
	raw, err := json.Marshal(c)
	require.NoError(t, err)
	assert.NotContains(t, string(raw), `"application`)
	assert.NotContains(t, string(raw), `"saved_version"`)
}

// TestChatengine_RoutingCatalogPolicyDropsProvider: a provider the policy
// forbids is not listed, and no row names it as its peer.
func TestChatengine_RoutingCatalogPolicyDropsProvider(t *testing.T) {
	policytest.Set(t, map[string]any{"AllowedAIProviders": []any{"claude"}})
	c := ReadRoutingCatalog(context.Background(), catalogConfig(), quotaRouter(t))
	assert.Nil(t, catalogRow(c, "codex"))
	require.NotNil(t, catalogRow(c, "claude"))
	assert.Empty(t, catalogRow(c, "claude").ReservePeer)
	assert.Len(t, c.Providers, 1)
}

// TestChatengine_RoutingCatalogStatusErrorIsSanitized: a failed status read
// sets the fixed copy, never the cause's text, and still lists the
// providers.
func TestChatengine_RoutingCatalogStatusErrorIsSanitized(t *testing.T) {
	r := &providerrouting.Router{Allowed: func(string) error {
		return errors.New("open /Users/someone/Library/provider-health/health.json: permission denied") // leak-check:allow
	}}
	c := ReadRoutingCatalog(context.Background(), catalogConfig(), r)
	assert.Equal(t, "Couldn't read provider availability", c.Error)
	assert.NotContains(t, c.Error, "/")
	assert.Nil(t, c.Status)
	assert.NotEmpty(t, c.Providers)
}

// TestChatengine_RoutingCatalogFixture pins the catalog's wire shape in
// testdata/routing_catalog.json, which the Swift ChatRoutingCatalogTests
// decode (-update, the package's flag, rewrites it).
func TestChatengine_RoutingCatalogFixture(t *testing.T) {
	c := ReadRoutingCatalog(context.Background(), catalogConfig(), quotaRouter(t))
	// Only the pair's rows: a new provider in the registry does not change
	// the fixture.
	var pair []RoutingProvider
	for _, p := range c.Providers {
		if p.ID == "claude" || p.ID == "codex" {
			pair = append(pair, p)
		}
	}
	c.Providers = pair
	got, err := json.MarshalIndent(c, "", "  ")
	require.NoError(t, err)
	got = append(got, '\n')
	path := filepath.Join("testdata", "routing_catalog.json")
	if *updateParts {
		require.NoError(t, os.WriteFile(path, got, 0o600))
	}
	want, err := os.ReadFile(path)
	require.NoError(t, err, "run with -update to write it")
	assert.Equal(t, strings.TrimSpace(string(want)), strings.TrimSpace(string(got)))
}
