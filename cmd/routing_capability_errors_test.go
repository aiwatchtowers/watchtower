package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
	"watchtower/internal/providers/transport"
	"watchtower/internal/sqlcipher"
)

func capabilityFailureBinaries(t *testing.T, cfg *config.Config) string {
	t.Helper()
	marker := filepath.Join(t.TempDir(), "unexpected-child")
	bin := filepath.Join(t.TempDir(), "fake-provider")
	require.NoError(t, os.WriteFile(bin, []byte(fmt.Sprintf("#!/bin/sh\nprintf started >> %q\nexit 88\n", marker)), 0o755))
	cfg.ClaudePath, cfg.CodexPath = bin, bin
	return marker
}

func breakConnectionCapabilityDB(t *testing.T, d *db.DB, mode string) {
	t.Helper()
	switch mode {
	case "closed":
		require.NoError(t, d.Close())
	case "list":
		_, err := d.Exec(`DROP TABLE external_connection_tools`)
		require.NoError(t, err)
	case "scan":
		_, err := d.Exec(`INSERT INTO external_connections(name,enabled,args_json) VALUES('synthetic',1,'{')`)
		require.NoError(t, err)
	default:
		t.Fatal("unknown failure case")
	}
}
func requireOperationalCapabilityError(t *testing.T, err error, mode string) {
	t.Helper()
	require.Error(t, err)
	var failure *providers.Failure
	require.False(t, errors.As(err, &failure))
	require.NotErrorIs(t, err, providerrouting.ErrDeferred)
	switch mode {
	case "closed":
		require.Contains(t, err.Error(), "database is closed")
	case "list":
		var cause sqlcipher.Error
		require.ErrorAs(t, err, &cause)
	case "scan":
		var cause *json.SyntaxError
		require.ErrorAs(t, err, &cause)
	default:
		t.Fatal("unknown failure case")
	}
}
func TestRoutingConnectionCapabilityStorageErrorsPreserveCauseBeforeChild(t *testing.T) {
	for _, surface := range []string{"chat", "generic"} {
		for _, mode := range []string{"closed", "list", "scan"} {
			t.Run(surface+"/"+mode, func(t *testing.T) {
				cleanup := setupWatchTestEnv(t)
				t.Cleanup(cleanup)
				resetAISessionFlags(t)
				policytest.Set(t, nil)
				t.Setenv("ANTHROPIC_API_KEY", "test-key")
				cfg := &config.Config{AI: config.AIConfig{Provider: "claude", Fallback: config.AIFallbackConfig{Enabled: true, Provider: "codex"}}}
				marker := capabilityFailureBinaries(t, cfg)
				database := db.OpenTestDB(t)
				_, err := database.Exec(`INSERT INTO chat_conversations(id,created_at,updated_at) VALUES(1,1,1)`)
				require.NoError(t, err)
				conv, err := database.GetChatConversation(1)
				require.NoError(t, err)
				health, err := providerhealth.Installation()
				require.NoError(t, err)
				scope := providerhealth.AccountScope("claude", "")
				require.NoError(t, health.RecordQuota(context.Background(), scope, &providers.Failure{Provider: "claude", Category: providers.Quota}))
				before, err := health.Read(context.Background(), scope)
				require.NoError(t, err)
				if surface == "chat" {
					cmd := &cobra.Command{}
					cmd.SetErr(io.Discard)
					cmd.Flags().String("model", "", "")
					backend, err := routedSessionBackend(cmd, cfg, database, filepath.Join(t.TempDir(), "chat.db"), conv, "", nil, 0, nil, func() {})
					require.NoError(t, err)
					t.Cleanup(func() { _ = backend.Close() })
					_, err = backend.Start(context.Background())
					require.NoError(t, err)
					breakConnectionCapabilityDB(t, database, mode)
					_, original := database.ListEnabledExternalConnections()
					require.Error(t, original)
					got := backend.Turn(context.Background(), chat.Command{TurnID: "one", Text: "owner text"}, func(e chat.Event) {
						require.Equal(t, chat.EventError, e.Type)
						require.Empty(t, e.Reason)
						require.False(t, e.Retryable)
					})
					requireOperationalCapabilityError(t, got, mode)
					for errors.Unwrap(original) != nil {
						original = errors.Unwrap(original)
					}
					if mode == "closed" {
						require.ErrorIs(t, got, original)
					}
				} else {
					builds := 0
					p := newToolRouteProvider(cfg, func(*config.Config) (ai.Provider, func(), error) {
						builds++
						return &toolRouteTestLeaf{}, func() {}, nil
					})
					p.router = &providerrouting.Router{Health: health}
					var original error
					p.capable = func(provider string) (bool, error) {
						if provider == "claude" {
							return true, nil
						}
						supported, err := reserveConnectionsCapable(cfg, database, provider)
						original = err
						return supported, err
					}
					breakConnectionCapabilityDB(t, database, mode)
					_, _, got := p.QuerySync(context.Background(), "system", "owner", "")
					requireOperationalCapabilityError(t, got, mode)
					require.ErrorIs(t, got, original)
					require.Zero(t, builds)
				}
				require.NoFileExists(t, marker)
				after, err := health.Read(context.Background(), scope)
				require.NoError(t, err)
				require.Equal(t, before.QuotaCount, after.QuotaCount)
				require.True(t, before.NextProbeAt.Equal(after.NextProbeAt))
				reserve, err := health.Read(context.Background(), providerhealth.AccountScope("codex", ""))
				require.NoError(t, err)
				require.Equal(t, providerhealth.Available, reserve.State)
			})
		}
	}
}
func TestQueryReserveCapabilityOpenErrorPreservesPathCause(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	t.Cleanup(cleanup)
	policytest.Set(t, nil)
	oldTools, oldModel, oldProvider := aiFlagTools, aiFlagModel, flagProvider
	aiFlagTools, aiFlagModel, flagProvider = "chat", "", ""
	t.Cleanup(func() { aiFlagTools, aiFlagModel, flagProvider = oldTools, oldModel, oldProvider })
	cfg := &config.Config{AI: config.AIConfig{Provider: "claude", Fallback: config.AIFallbackConfig{Enabled: true, Provider: "codex"}}}
	parent := filepath.Join(t.TempDir(), "not-a-directory")
	require.NoError(t, os.WriteFile(parent, []byte("synthetic"), 0o600))
	leaf, cleanupClient, err := newQueryClient(cfg, filepath.Join(parent, "chat.db"), transport.Options{})
	require.NoError(t, err)
	defer cleanupClient()
	routed := leaf.(*toolRouteProvider)
	health := providerhealth.New(t.TempDir(), nil)
	require.NoError(t, health.RecordQuota(context.Background(), providerhealth.AccountScope("claude", ""), &providers.Failure{Provider: "claude", Category: providers.Quota}))
	routed.router = &providerrouting.Router{Health: health}
	builds := 0
	routed.build = func(*config.Config) (ai.Provider, func(), error) {
		builds++
		return &toolRouteTestLeaf{}, func() {}, nil
	}
	_, _, err = routed.QuerySync(context.Background(), "system", "owner", "")
	require.ErrorContains(t, err, "opening reserve capability database")
	var cause *os.PathError
	require.ErrorAs(t, err, &cause)
	var failure *providers.Failure
	require.False(t, errors.As(err, &failure))
	require.Zero(t, builds)
	state, err := health.Read(context.Background(), providerhealth.AccountScope("codex", ""))
	require.NoError(t, err)
	require.Equal(t, providerhealth.Available, state.State)
}
