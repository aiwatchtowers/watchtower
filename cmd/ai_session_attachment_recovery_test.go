package cmd

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
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

func TestAISessionAttachmentNewTurnRecoveryChecksAvailableCandidate(t *testing.T) {
	for _, kind := range []string{"image", "pdf"} {
		for _, scenario := range []string{"recovered", "healthy-sticky", "both-wait", "preferred-forbidden"} {
			t.Run(kind+"/"+scenario, func(t *testing.T) {
				cleanup := setupWatchTestEnv(t)
				t.Cleanup(cleanup)
				resetAISessionFlags(t)
				policytest.Set(t, nil)
				// Explicit API mode keeps native claude.ai tools off; ask 971 is separate.
				t.Setenv("ANTHROPIC_API_KEY", "test-key")
				cfg, err := config.Load(flagConfig)
				require.NoError(t, err)
				cfg.AI.Provider = "claude"
				cfg.AI.ConfiguredProvider = "claude"
				cfg.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: "codex"}
				cfg.AI.Providers = map[string]config.AIProviderConfig{"claude": {Models: config.AIModels{Strong: "preferred-model"}}, "codex": {Models: config.AIModels{Strong: "reserve-model"}}}
				dir := t.TempDir()
				claudeMarker, codexMarker := filepath.Join(dir, "claude-starts"), filepath.Join(dir, "codex-starts")
				t.Setenv("TASK8_CLAUDE_MARKER", claudeMarker)
				t.Setenv("TASK8_CODEX_MARKER", codexMarker)
				cfg.ClaudePath = filepath.Join(dir, "claude")
				cfg.CodexPath = filepath.Join(dir, "codex")
				claudeScript := strings.Replace(fakeSessionClaude, "#!/bin/sh\n", "#!/bin/sh\nprintf 'spawn\\n' >> \"$TASK8_CLAUDE_MARKER\"\n", 1)
				require.NoError(t, os.WriteFile(cfg.ClaudePath, []byte(claudeScript), 0o755))
				require.NoError(t, os.WriteFile(cfg.CodexPath, []byte("#!/bin/sh\nprintf 'spawn\\n' >> \"$TASK8_CODEX_MARKER\"\nexit 88\n"), 0o755))
				database := db.OpenTestDB(t)
				_, err = database.Exec(`INSERT INTO chat_conversations(id,created_at,updated_at,actual_provider,actual_model) VALUES(1,1,1,'codex','reserve-model')`)
				require.NoError(t, err)
				_, err = database.Exec(`INSERT INTO chat_messages(conversation_id,role,text,turn_id,created_at) VALUES(1,'user','new attachment question','new-turn',1),(1,'assistant','','new-turn',2)`)
				require.NoError(t, err)
				conv, err := database.GetChatConversation(1)
				require.NoError(t, err)
				health, err := providerhealth.Installation()
				require.NoError(t, err)
				if scenario != "healthy-sticky" {
					require.NoError(t, health.RecordQuota(context.Background(), providerhealth.AccountScope("codex", ""), &providers.Failure{Provider: "codex", Category: providers.Quota}))
				}
				if scenario == "both-wait" {
					require.NoError(t, health.RecordQuota(context.Background(), providerhealth.AccountScope("claude", ""), &providers.Failure{Provider: "claude", Category: providers.Quota}))
				}
				if scenario == "preferred-forbidden" {
					policytest.Set(t, map[string]any{"AllowedAIProviders": []any{"codex"}})
				}
				before, err := health.Read(context.Background(), providerhealth.AccountScope("codex", ""))
				require.NoError(t, err)
				cmd := &cobra.Command{}
				cmd.SetErr(io.Discard)
				cmd.Flags().String("model", "", "")
				backend, err := routedSessionBackend(cmd, cfg, database, filepath.Join(dir, "chat.db"), conv, "", nil, 0, nil, func() {})
				require.NoError(t, err)
				t.Cleanup(func() { _ = backend.Close() })
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				_, err = backend.Start(ctx)
				require.NoError(t, err)
				mime := "image/png"
				content := []byte("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR")
				if kind == "pdf" {
					mime = "application/pdf"
					content = []byte("%PDF-1.4\nsynthetic")
				}
				path := filepath.Join(dir, "attachment")
				require.NoError(t, os.WriteFile(path, content, 0o600))
				var events []chat.Event
				err = backend.Turn(ctx, chat.Command{TurnID: "new-turn", Text: "new attachment question", Attachments: []chat.Attachment{{Path: path, Mime: mime, Name: "synthetic attachment"}}}, func(e chat.Event) { events = append(events, e) })
				actual, getErr := database.GetChatConversation(1)
				require.NoError(t, getErr)
				// Codex takes images since G4 (L6): the sticky healthy
				// codex runs the image turn (the fake exits 88); a PDF is
				// still refused by capability before anything starts.
				codexRuns := kind == "image" && scenario == "healthy-sticky"
				if codexRuns {
					require.Error(t, err)
					require.Equal(t, "codex", actual.ActualProvider)
					require.NoFileExists(t, claudeMarker)
					require.FileExists(t, codexMarker)
					require.NoError(t, backend.Close())
					return
				}
				if scenario == "recovered" {
					require.NoError(t, err)
					require.Equal(t, "claude", actual.ActualProvider)
					require.Equal(t, "preferred-model", actual.ActualModel)
					terminals := 0
					for _, e := range events {
						require.Equal(t, "claude", e.Provider)
						require.Equal(t, "preferred-model", e.Model)
						if e.Type == chat.EventTurnDone {
							terminals++
						}
						require.NotEqual(t, chat.EventError, e.Type)
					}
					require.Equal(t, 1, terminals)
					data, err := os.ReadFile(claudeMarker)
					require.NoError(t, err)
					require.Equal(t, "spawn\n", string(data))
				} else {
					require.Error(t, err)
					require.Equal(t, "codex", actual.ActualProvider)
					require.NoFileExists(t, claudeMarker)
					if scenario == "both-wait" {
						require.ErrorIs(t, err, providerrouting.ErrDeferred)
					} else {
						var failure *providers.Failure
						require.ErrorAs(t, err, &failure)
						expected := providers.Capability
						if scenario == "preferred-forbidden" {
							expected = providers.Policy
						}
						require.Equal(t, expected, failure.Category)
					}
					require.False(t, errors.Is(err, context.DeadlineExceeded))
				}
				require.NoFileExists(t, codexMarker)
				require.NoError(t, backend.Close())
				after, err := health.Read(context.Background(), providerhealth.AccountScope("codex", ""))
				require.NoError(t, err)
				require.Equal(t, before.QuotaCount, after.QuotaCount)
				require.True(t, before.NextProbeAt.Equal(after.NextProbeAt))
			})
		}
	}
}
