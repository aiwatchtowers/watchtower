package cmd

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/llmusage"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providers"
)

// Ask971: the main chat's automatic native offering is optional on quota
// fallback. Real attachment requirements, explicit pins and policy remain gates.
func TestAISessionAutomaticNativeOfferingMayFallBackBeforeTurn(t *testing.T) {
	for _, scenario := range []string{"automatic", "pdf", "pinned", "off", "policy"} {
		t.Run(scenario, func(t *testing.T) {
			cleanup := setupWatchTestEnv(t)
			t.Cleanup(cleanup)
			resetAISessionFlags(t)
			previousProvider := flagProvider
			flagProvider = ""
			t.Cleanup(func() { flagProvider = previousProvider })
			policytest.Set(t, nil)
			sink := &ledgerSink{}
			llmusage.SetSink(sink)
			t.Cleanup(func() { llmusage.SetSink(nil) })
			claudeAILoginEnv(t) // fake sandbox/environment only; no auth-status or account read
			cfg, err := config.Load(flagConfig)
			require.NoError(t, err)
			cfg.AI.Provider, cfg.AI.ConfiguredProvider = "claude", "claude"
			cfg.AI.Fallback = config.AIFallbackConfig{Enabled: scenario != "off", Provider: "codex"}
			cfg.ClaudePath = filepath.Join(t.TempDir(), "claude")
			require.NoError(t, os.WriteFile(cfg.ClaudePath, []byte(fakeSessionClaude), 0700))
			cfg.CodexPath = routingCLI(t, "codex", false)
			capture := t.TempDir()
			marker := filepath.Join(capture, "codex-started")
			promptPath := filepath.Join(capture, "system-prompt")
			argsPath := filepath.Join(capture, "arguments")
			script, err := os.ReadFile(cfg.CodexPath)
			require.NoError(t, err)
			// Count inference starts, excluding the adapter's version compatibility check.
			captureScript := "printf started >> '" + marker + "'\nprintf '%s\\n' \"$@\" > '" + argsPath + "'\n" +
				`for a in "$@"; do case "$a" in model_instructions_file=*) file=${a#model_instructions_file=}; file=${file#\"}; file=${file%\"}; cat "$file" > '` + promptPath + `' ;; esac; done
cat >/dev/null`
			script = []byte(strings.Replace(string(script), "cat >/dev/null", captureScript, 1))
			require.NoError(t, os.WriteFile(cfg.CodexPath, script, 0700))
			path := filepath.Join(t.TempDir(), "chat.db")
			database, err := db.Open(path)
			require.NoError(t, err)
			defer database.Close()
			_, err = database.Exec(`INSERT INTO chat_conversations(id,created_at,updated_at) VALUES(1,1,1)`)
			require.NoError(t, err)
			if scenario == "pinned" {
				require.NoError(t, database.SetChatRouting(1, "pinned", "claude", ""))
			}
			require.True(t, resolveClaudeAI(cfg, "main", 1, os.Environ(), io.Discard).mode.On)
			health, err := providerhealth.Installation()
			require.NoError(t, err)
			require.NoError(t, health.RecordQuota(context.Background(), providerhealth.AccountScope("claude", ""), &providers.Failure{Provider: "claude", Category: providers.Quota}))
			if scenario == "policy" {
				policytest.Set(t, map[string]any{"AllowedAIProviders": []string{"claude"}})
			}
			command := &cobra.Command{}
			command.Flags().String("model", "", "")
			command.SetErr(io.Discard)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			makeBackend := func() chat.Backend {
				conv, getErr := database.GetChatConversation(1)
				require.NoError(t, getErr)
				backend, buildErr := routedSessionBackend(command, cfg, database, path, conv, "", nil, 0, nil, func() {})
				require.NoError(t, buildErr)
				t.Cleanup(func() { _ = backend.Close() })
				_, startErr := backend.Start(ctx)
				require.NoError(t, startErr)
				return backend
			}
			turn := chat.Command{TurnID: "first", Text: "ordinary text question"}
			if scenario == "pdf" {
				file := filepath.Join(t.TempDir(), "document.pdf")
				require.NoError(t, os.WriteFile(file, []byte("%PDF-1.4\nfixture"), 0600))
				turn.Attachments = []chat.Attachment{{Path: file, Mime: "application/pdf", Name: "document.pdf"}}
			}
			backend := makeBackend()
			var ready chat.Event
			err = backend.Turn(ctx, turn, func(e chat.Event) {
				if e.Type == chat.EventSessionReady {
					ready = e
				}
			})
			if scenario == "pdf" || scenario == "policy" {
				require.Error(t, err)
				require.NoFileExists(t, marker)
				return
			}
			require.NoError(t, err)
			if scenario != "automatic" {
				selected, readErr := database.GetChatConversation(1)
				require.NoError(t, readErr)
				require.Equal(t, "claude", selected.ActualProvider)
				require.NoFileExists(t, marker)
				return
			}
			require.Equal(t, "codex", ready.Provider)
			require.Equal(t, "quota_exhausted", ready.Reason)
			prompt, readErr := os.ReadFile(promptPath)
			require.NoError(t, readErr)
			require.Contains(t, string(prompt), "Publishing to claude.ai and claude.ai connectors need the Claude provider")
			require.NotContains(t, string(prompt), "Artifact tool")
			require.NotContains(t, string(prompt), "The outside resources are the claude.ai tools")
			arguments, readErr := os.ReadFile(argsPath)
			require.NoError(t, readErr)
			require.Contains(t, string(arguments), "mcp_servers=")
			require.Contains(t, string(arguments), "watchtower")
			require.NotContains(t, string(arguments), "claude_ai")
			require.NoError(t, backend.Close())
			require.NoError(t, database.Close())
			database, err = db.Open(path)
			require.NoError(t, err)
			defer database.Close()
			persisted, err := database.GetChatConversation(1)
			require.NoError(t, err)
			require.Equal(t, "codex", persisted.ActualProvider)
			require.Equal(t, "quota_exhausted", persisted.RoutingReason)
			// Reopen with actual metadata: a new turn remains sticky, never resends
			// the first tool-bearing turn or transfers Claude native session ids.
			second := makeBackend()
			require.NoError(t, second.Turn(ctx, chat.Command{TurnID: "second", Text: "new owner text"}, func(e chat.Event) {
				if e.Type == chat.EventSessionReady {
					require.Equal(t, "codex", e.Provider)
					require.Equal(t, "quota_exhausted", e.Reason)
				}
			}))
			starts, err := os.ReadFile(marker)
			require.NoError(t, err)
			require.Equal(t, "startedstarted", string(starts))
			require.Len(t, sink.calls, 2)
			for _, call := range sink.calls {
				require.Equal(t, "codex", call.Provider)
			}
		})
	}
}
