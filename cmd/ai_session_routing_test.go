package cmd

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
)

func TestAISessionRoutingPersistsStickyAcrossRestartAndManualPin(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	t.Cleanup(cleanup)
	resetAISessionFlags(t)
	policytest.Set(t, nil)
	t.Setenv("ANTHROPIC_API_KEY", "test-key")
	oldProvider := flagProvider
	flagProvider = ""
	t.Cleanup(func() { flagProvider = oldProvider })
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	cfg.AI.Provider = "codex"
	cfg.AI.ConfiguredProvider = "codex"
	cfg.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: "claude"}
	cfg.AI.Providers = map[string]config.AIProviderConfig{"codex": {Models: config.AIModels{Strong: "preferred-model"}}, "claude": {Models: config.AIModels{Strong: "reserve-model"}}}
	cfg.ClaudePath = filepath.Join(t.TempDir(), "claude")
	require.NoError(t, os.WriteFile(cfg.ClaudePath, []byte(fakeSessionClaude), 0o755))
	marker := filepath.Join(t.TempDir(), "preferred-started")
	t.Setenv("TASK8_PREFERRED_MARKER", marker)
	cfg.CodexPath = filepath.Join(t.TempDir(), "must-not-spawn")
	require.NoError(t, os.WriteFile(cfg.CodexPath, []byte("#!/bin/sh\nprintf started > \"$TASK8_PREFERRED_MARKER\"\nexit 88\n"), 0o755))
	dbPath := filepath.Join(t.TempDir(), "chat.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	_, err = database.Exec(`INSERT INTO chat_conversations(id,created_at,updated_at) VALUES(1,1,1)`)
	require.NoError(t, err)
	health, err := providerhealth.Installation()
	require.NoError(t, err)
	require.NoError(t, health.RecordQuota(context.Background(), providerhealth.AccountScope("codex", ""), &providers.Failure{Provider: "codex", Category: providers.Quota}))
	cmd := &cobra.Command{}
	cmd.SetOut(io.Discard)
	cmd.SetErr(io.Discard)
	cmd.Flags().String("model", "", "")
	makeBackend := func() chat.Backend {
		conv, err := database.GetChatConversation(1)
		require.NoError(t, err)
		backend, err := routedSessionBackend(cmd, cfg, database, dbPath, conv, "", nil, 0, nil, func() {})
		require.NoError(t, err)
		t.Cleanup(func() { _ = backend.Close() })
		_, err = backend.Start(context.Background())
		require.NoError(t, err)
		return backend
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	first := makeBackend()
	require.NoError(t, first.Turn(ctx, chat.Command{TurnID: "one", Text: "question"}, func(e chat.Event) {
		if e.Type == chat.EventSessionReady {
			require.Equal(t, "claude", e.Provider)
			require.Equal(t, "reserve-model", e.Model)
		}
	}))
	require.NoError(t, first.Close())
	conv, err := database.GetChatConversation(1)
	require.NoError(t, err)
	require.Equal(t, "preferred_reserve", conv.RoutingMode)
	require.Equal(t, "claude", conv.ActualProvider)
	require.NoFileExists(t, marker)
	require.Empty(t, conv.Provider)
	// Simulate primary recovery by replacing only the private health store's
	// directory; the persisted conversation must remain on its actual reserve.
	root, err := config.AppSupportDir()
	require.NoError(t, err)
	require.NoError(t, os.Rename(filepath.Join(root, "provider-health"), filepath.Join(root, "provider-health-prior-test")))
	require.NoError(t, database.Close())
	database, err = db.Open(dbPath)
	require.NoError(t, err)
	second := makeBackend()
	require.NoError(t, second.Turn(ctx, chat.Command{TurnID: "two", Text: "new question"}, func(e chat.Event) {
		if e.Type == chat.EventSessionReady {
			require.Equal(t, "claude", e.Provider)
		}
	}))
	require.NoError(t, second.Close())
	require.NoError(t, health.RecordQuota(ctx, providerhealth.AccountScope("claude", ""), &providers.Failure{Provider: "claude", Category: providers.Quota}))
	require.NoError(t, health.RecordQuota(ctx, providerhealth.AccountScope("codex", ""), &providers.Failure{Provider: "codex", Category: providers.Quota}))
	blocked := makeBackend()
	require.ErrorIs(t, blocked.Turn(ctx, chat.Command{TurnID: "blocked", Text: "keep question"}, func(e chat.Event) { require.NotEqual(t, chat.EventTextDelta, e.Type) }), providerrouting.ErrDeferred)
	require.NoError(t, blocked.Close())
	require.NoError(t, database.SetChatRouting(1, "pinned", "claude", "explicit-model"))
	third := makeBackend()
	ready := third.(interface{ RoutingEvent() chat.Event }).RoutingEvent()
	require.Equal(t, "pinned", ready.RoutingMode)
	require.Equal(t, "explicit-model", ready.Model)
	require.Equal(t, "claude", ready.Provider)
	require.NoError(t, third.Close())
}
func TestAISessionRoutingExplicitDefaultModelPinsBeforeStart(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	t.Cleanup(cleanup)
	resetAISessionFlags(t)
	policytest.Set(t, nil)
	t.Setenv("ANTHROPIC_API_KEY", "test-key")
	oldProvider := flagProvider
	flagProvider = ""
	t.Cleanup(func() { flagProvider = oldProvider })
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	cfg.AI.Provider = "claude"
	cfg.AI.ConfiguredProvider = "codex"
	cfg.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: "codex"}
	dbPath := filepath.Join(t.TempDir(), "chat.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	_, err = database.Exec(`INSERT INTO chat_conversations(id,created_at,updated_at) VALUES(1,1,1)`)
	require.NoError(t, err)
	_, aiSessionFlagModel = providers.ResolveModelsFor(cfg, "claude")
	cmd := &cobra.Command{}
	cmd.SetErr(io.Discard)
	cmd.Flags().String("model", "", "")
	require.NoError(t, cmd.Flags().Set("model", aiSessionFlagModel))
	conv, err := database.GetChatConversation(1)
	require.NoError(t, err)
	backend, err := routedSessionBackend(cmd, cfg, database, dbPath, conv, "", nil, 0, nil, func() {})
	require.NoError(t, err)
	t.Cleanup(func() { _ = backend.Close() })
	ready := backend.(interface{ RoutingEvent() chat.Event }).RoutingEvent()
	require.Equal(t, "codex", ready.PreferredProvider)
	require.Equal(t, "claude", ready.Provider)
	conv, err = database.GetChatConversation(1)
	require.NoError(t, err)
	require.Equal(t, "pinned", conv.RoutingMode)
	require.Equal(t, aiSessionFlagModel, conv.Model)
}

func TestAISessionRoutingBinaryAttachmentRejectsReserveBeforeSelection(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	t.Cleanup(cleanup)
	resetAISessionFlags(t)
	policytest.Set(t, nil)
	t.Setenv("ANTHROPIC_API_KEY", "test-key")
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	cfg.AI.Provider = "claude"
	cfg.AI.ConfiguredProvider = "claude"
	cfg.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: "codex"}
	database := db.OpenTestDB(t)
	_, err = database.Exec(`INSERT INTO chat_conversations(id,created_at,updated_at) VALUES(1,1,1)`)
	require.NoError(t, err)
	conv, err := database.GetChatConversation(1)
	require.NoError(t, err)
	health, err := providerhealth.Installation()
	require.NoError(t, err)
	require.NoError(t, health.RecordQuota(context.Background(), providerhealth.AccountScope("claude", ""), &providers.Failure{Provider: "claude", Category: providers.Quota}))
	cmd := &cobra.Command{}
	cmd.SetErr(io.Discard)
	cmd.Flags().String("model", "", "")
	backend, err := routedSessionBackend(cmd, cfg, database, filepath.Join(t.TempDir(), "chat.db"), conv, "", nil, 0, nil, func() {})
	require.NoError(t, err)
	t.Cleanup(func() { _ = backend.Close() })
	_, err = backend.Start(context.Background())
	require.NoError(t, err)
	// Content sniffing wins over a misleading text MIME label.
	attachment := filepath.Join(t.TempDir(), "file.txt")
	require.NoError(t, os.WriteFile(attachment, []byte("%PDF-1.4\nsynthetic"), 0o600))
	err = backend.Turn(context.Background(), chat.Command{TurnID: "one", Text: "question", Attachments: []chat.Attachment{{Path: attachment, Mime: "text/plain", Name: "file.txt"}}}, func(e chat.Event) { require.Equal(t, "required_capability_missing", e.Reason) })
	var failure *providers.Failure
	require.ErrorAs(t, err, &failure)
	require.Equal(t, providers.Capability, failure.Category)
	conv, err = database.GetChatConversation(1)
	require.NoError(t, err)
	require.Empty(t, conv.ActualProvider)
}

func TestAISessionRoutingPolicyRefusalDoesNotPersistPin(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	t.Cleanup(cleanup)
	resetAISessionFlags(t)
	policytest.Set(t, map[string]any{"AllowedAIProviders": []any{"claude"}})
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	cfg.AI.Provider = "codex"
	database := db.OpenTestDB(t)
	_, err = database.Exec(`INSERT INTO chat_conversations(id,created_at,updated_at) VALUES(1,1,1)`)
	require.NoError(t, err)
	conv, err := database.GetChatConversation(1)
	require.NoError(t, err)
	cmd := &cobra.Command{}
	cmd.SetErr(io.Discard)
	cmd.Flags().String("model", "", "")
	require.NoError(t, cmd.Flags().Set("model", "gpt-5.4"))
	_, err = routedSessionBackend(cmd, cfg, database, "", conv, "", nil, 0, nil, func() {})
	require.Error(t, err)
	conv, err = database.GetChatConversation(1)
	require.NoError(t, err)
	require.Equal(t, "preferred_reserve", conv.RoutingMode)
	require.Empty(t, conv.Provider)
	require.Empty(t, conv.ActualProvider)
}

func TestAISessionRoutingExhaustedReserveReturnsToRecoveredPreferredBeforeNewTurn(t *testing.T) {
	for _, preferred := range []string{"claude", "codex"} {
		t.Run(preferred, func(t *testing.T) {
			cleanup := setupWatchTestEnv(t)
			t.Cleanup(cleanup)
			resetAISessionFlags(t)
			policytest.Set(t, nil)
			t.Setenv("ANTHROPIC_API_KEY", "test-key")
			reserve := "codex"
			if preferred == reserve {
				reserve = "claude"
			}
			cfg, err := config.Load(flagConfig)
			require.NoError(t, err)
			cfg.AI.Provider = preferred
			cfg.AI.ConfiguredProvider = preferred
			cfg.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: reserve}
			cfg.AI.Providers = map[string]config.AIProviderConfig{preferred: {Models: config.AIModels{Strong: "preferred-model"}}, reserve: {Models: config.AIModels{Strong: "reserve-model"}}}
			cfg.ClaudePath = filepath.Join(t.TempDir(), "claude")
			require.NoError(t, os.WriteFile(cfg.ClaudePath, []byte(fakeSessionClaude), 0o755))
			cfg.CodexPath = routingCLI(t, "codex", false)
			path := filepath.Join(t.TempDir(), "chat.db")
			database, err := db.Open(path)
			require.NoError(t, err)
			t.Cleanup(func() { _ = database.Close() })
			_, err = database.Exec(`INSERT INTO chat_conversations(id,created_at,updated_at,actual_provider,actual_model) VALUES(1,1,1,?,'reserve-model')`, reserve)
			require.NoError(t, err)
			health, err := providerhealth.Installation()
			require.NoError(t, err)
			require.NoError(t, health.RecordQuota(context.Background(), providerhealth.AccountScope(reserve, ""), &providers.Failure{Provider: reserve, Category: providers.Quota}))
			conv, err := database.GetChatConversation(1)
			require.NoError(t, err)
			cmd := &cobra.Command{}
			cmd.SetErr(io.Discard)
			cmd.Flags().String("model", "", "")
			backend, err := routedSessionBackend(cmd, cfg, database, path, conv, "", nil, 0, nil, func() {})
			require.NoError(t, err)
			t.Cleanup(func() { _ = backend.Close() })
			_, err = backend.Start(context.Background())
			require.NoError(t, err)
			turn := func(id string) {
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				terminals := 0
				require.NoError(t, backend.Turn(ctx, chat.Command{TurnID: id, Text: "new owner turn"}, func(e chat.Event) {
					require.Equal(t, preferred, e.Provider)
					require.Equal(t, "preferred-model", e.Model)
					if e.Type == chat.EventTurnDone {
						terminals++
					}
					require.NotEqual(t, chat.EventError, e.Type)
				}))
				require.Equal(t, 1, terminals)
				actual, err := database.GetChatConversation(1)
				require.NoError(t, err)
				require.Equal(t, preferred, actual.ActualProvider)
				require.Equal(t, "preferred-model", actual.ActualModel)
			}
			turn("recovered")
			// Once reserve is healthy too, the same backend must remember that its
			// actual moved to preferred, rather than returning to the old sticky reserve.
			root, err := config.AppSupportDir()
			require.NoError(t, err)
			require.NoError(t, os.Rename(filepath.Join(root, "provider-health"), filepath.Join(root, "prior-health")))
			turn("stay-on-recovered")
			require.NoError(t, backend.Close())
			require.NoError(t, database.Close())
			database, err = db.Open(path)
			require.NoError(t, err)
			actual, err := database.GetChatConversation(1)
			require.NoError(t, err)
			require.Equal(t, preferred, actual.ActualProvider)
		})
	}
}

// Reopening after a preference change does not turn the historical actual
// provider into evidence of quota. A genuine sticky quota cause stays intact.
func TestAISessionStickyReasonSurvivesReopenWithoutInventingQuota(t *testing.T) {
	for _, preferred := range []string{"claude", "codex"} {
		for _, reason := range []string{"", "preferred", "fallback_disabled", "quota_exhausted"} {
			t.Run(preferred+"/"+reason, func(t *testing.T) {
				cleanup := setupWatchTestEnv(t)
				t.Cleanup(cleanup)
				resetAISessionFlags(t)
				policytest.Set(t, nil)
				t.Setenv("ANTHROPIC_API_KEY", "test-key")
				reserve := "claude"
				if preferred == "claude" {
					reserve = "codex"
				}
				cfg, err := config.Load(flagConfig)
				require.NoError(t, err)
				cfg.AI.Provider, cfg.AI.ConfiguredProvider = preferred, preferred
				cfg.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: reserve}
				cfg.AI.Providers = map[string]config.AIProviderConfig{
					preferred: {Models: config.AIModels{Strong: "preferred-model"}},
					reserve:   {Models: config.AIModels{Strong: "reserve-model"}},
				}
				cfg.ClaudePath = filepath.Join(t.TempDir(), "claude")
				require.NoError(t, os.WriteFile(cfg.ClaudePath, []byte(fakeSessionClaude), 0o755))
				cfg.CodexPath = routingCLI(t, "codex", false)
				path := filepath.Join(t.TempDir(), "chat.db")
				database, err := db.Open(path)
				require.NoError(t, err)
				t.Cleanup(func() { _ = database.Close() })
				_, err = database.Exec(`INSERT INTO chat_conversations(id,created_at,updated_at,actual_provider,actual_model,routing_reason) VALUES(1,1,1,?,'old-model',?)`, reserve, reason)
				require.NoError(t, err)
				for reopen := 0; reopen < 2; reopen++ {
					conv, err := database.GetChatConversation(1)
					require.NoError(t, err)
					command := &cobra.Command{}
					command.SetErr(io.Discard)
					command.Flags().String("model", "", "")
					backend, err := routedSessionBackend(command, cfg, database, path, conv, "", nil, 0, nil, func() {})
					require.NoError(t, err)
					t.Cleanup(func() { _ = backend.Close() })
					_, err = backend.Start(context.Background())
					require.NoError(t, err)
					for _, turn := range []string{"first", "next"} {
						ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
						var reasons []string
						err := backend.Turn(ctx, chat.Command{TurnID: turn, Text: "new owner message"}, func(event chat.Event) {
							if event.Type == chat.EventSessionReady {
								reasons = append(reasons, event.Reason)
								require.Equal(t, reserve, event.Provider)
								require.Equal(t, "reserve-model", event.Model)
							}
						})
						cancel()
						require.NoError(t, err)
						require.Equal(t, []string{reason}, reasons)
						actual, err := database.GetChatConversation(1)
						require.NoError(t, err)
						require.Equal(t, reserve, actual.ActualProvider)
						require.Equal(t, reason, actual.RoutingReason)
						require.Equal(t, "preferred_reserve", actual.RoutingMode)
						require.Empty(t, actual.Provider)
						require.Empty(t, actual.Model)
					}
					require.NoError(t, backend.Close())
				}
			})
		}
	}
}

// A fallback route may pick codex for an image turn (--image, L6), never
// ollama; a PDF needs Claude on either.
func TestSessionAttachmentCapability_CodexTakesImagesNotPDFs(t *testing.T) {
	dir := t.TempDir()
	png := filepath.Join(dir, "shot.png")
	require.NoError(t, os.WriteFile(png, []byte("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"), 0o600))
	pdf := filepath.Join(dir, "doc.pdf")
	require.NoError(t, os.WriteFile(pdf, []byte("%PDF-1.4\nsynthetic"), 0o600))
	img := []chat.Attachment{{Path: png, Mime: "image/png", Name: "shot.png"}}
	doc := []chat.Attachment{{Path: pdf, Mime: "application/pdf", Name: "doc.pdf"}}
	for _, tc := range []struct {
		provider string
		atts     []chat.Attachment
		want     bool
	}{{"codex", img, true}, {"ollama", img, false}, {"codex", doc, false}, {"ollama", doc, false}} {
		caps, _ := providers.CapsFor(tc.provider)
		got, err := sessionAttachmentCapability(caps, tc.atts)
		require.NoError(t, err)
		require.Equal(t, tc.want, got, "%s %s", tc.provider, tc.atts[0].Name)
	}
}

// Routing and the turn decide image support the same way: a provider the
// routing says takes images builds a chat client the turn backend hands
// them to (chat's imageQuerier), so a routed image turn is never refused.
func TestSessionAttachmentCapability_MatchesTheCodexClient(t *testing.T) {
	caps, _ := providers.CapsFor("codex")
	require.True(t, caps.Images)
	cfg := &config.Config{}
	cfg.AI.Provider = "codex"
	var q chat.Querier = codexSessionClient(sessionWiring{cfg: cfg, database: db.OpenTestDB(t), dbPath: ":memory:",
		conv: &db.ChatConversation{ID: 1}, model: "m"})
	_, ok := q.(interface{ SetImages([]string) })
	require.True(t, ok, "the codex chat client takes images")
}
