package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"strings"

	"watchtower/internal/config"
	"watchtower/internal/ollama"
	"watchtower/internal/providers"

	"github.com/spf13/cobra"
)

var (
	aiFlagModel        string
	aiFlagSessionID    string
	aiFlagSystemPrompt string
	aiFlagDBPath       string
	aiFlagAllowedTools string
)

var aiCmd = &cobra.Command{
	Use:   "ai",
	Short: "AI provider interface (used by desktop app)",
}

var aiQueryCmd = &cobra.Command{
	Use:   "query",
	Short: "Stream an AI query through the configured provider",
	Long:  "Sends a prompt to the configured AI provider (Claude or Codex) and streams the response as JSON lines. Intended for programmatic use by the desktop app.",
	Args:  cobra.ExactArgs(1),
	RunE:  runAIQuery,
}

var aiModelsFlagJSON bool

var aiModelsCmd = &cobra.Command{
	Use:   "models",
	Short: "List AI providers and their models",
	Long:  "Prints the provider registry: default per-tier models, the resolved light/strong models per provider under the current config, and — for OpenAI-compatible providers — the live model list. The Desktop app consumes this via --json.",
	RunE:  runAIModels,
}

var aiTestCmd = &cobra.Command{
	Use:   "test",
	Short: "Test AI provider connectivity",
	Long:  "Verifies that the configured AI provider is available and responds. Outputs JSON with status.",
	RunE:  runAITest,
}

// aiStreamEvent is a JSON line emitted by `watchtower ai query`.
// Maps 1:1 to Swift StreamEvent enum.
type aiStreamEvent struct {
	Type      string `json:"type"`
	Text      string `json:"text,omitempty"`
	SessionID string `json:"session_id,omitempty"`
	Error     string `json:"error,omitempty"`
}

func init() {
	rootCmd.AddCommand(aiCmd)
	aiCmd.AddCommand(aiQueryCmd)
	aiCmd.AddCommand(aiTestCmd)
	aiCmd.AddCommand(aiModelsCmd)

	aiModelsCmd.Flags().BoolVar(&aiModelsFlagJSON, "json", false, "output JSON")
	aiTestCmd.Flags().StringVar(&aiFlagModel, "model", "", "override AI model")

	aiQueryCmd.Flags().StringVar(&aiFlagModel, "model", "", "override AI model")
	aiQueryCmd.Flags().StringVar(&aiFlagSessionID, "session-id", "", "resume session (Claude only)")
	aiQueryCmd.Flags().StringVar(&aiFlagSystemPrompt, "system-prompt", "", "system prompt")
	aiQueryCmd.Flags().StringVar(&aiFlagDBPath, "db-path", "", "SQLite database path for MCP (overrides default)")
	aiQueryCmd.Flags().StringVar(&aiFlagAllowedTools, "allowed-tools", "", "additional allowed tools (comma-separated)")
}

func runAIQuery(_ *cobra.Command, args []string) error {
	prompt := args[0]
	enc := json.NewEncoder(os.Stdout)

	cfg, err := config.Load(flagConfig)
	if err != nil {
		return emitError(enc, fmt.Sprintf("loading config: %v", err))
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return emitError(enc, fmt.Sprintf("invalid config: %v", err))
	}

	// Determine database path
	dbPath := aiFlagDBPath
	if dbPath == "" {
		dbPath = cfg.DBPath()
	}

	aiClient := newAIClientWithModel(cfg, dbPath, aiFlagModel)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	systemPrompt := aiFlagSystemPrompt
	textCh, errCh, sidCh := aiClient.Query(ctx, systemPrompt, prompt, aiFlagSessionID)

	// Drain text channel (main stream)
	for text := range textCh {
		_ = enc.Encode(aiStreamEvent{Type: "text", Text: text})
	}

	// Drain session ID (at most one value)
	for sid := range sidCh {
		if sid != "" {
			_ = enc.Encode(aiStreamEvent{Type: "session_id", SessionID: sid})
		}
	}

	// Check for errors
	for err := range errCh {
		if err != nil {
			_ = enc.Encode(aiStreamEvent{Type: "error", Error: err.Error()})
		}
	}

	_ = enc.Encode(aiStreamEvent{Type: "done"})
	return nil
}

func runAITest(_ *cobra.Command, _ []string) error {
	enc := json.NewEncoder(os.Stdout)

	cfg, err := config.Load(flagConfig)
	if err != nil {
		return enc.Encode(map[string]any{
			"ok":    false,
			"error": fmt.Sprintf("loading config: %v", err),
		})
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)

	_, model := providers.ResolveModelsFor(cfg, cfg.AI.Provider)
	if aiFlagModel != "" {
		model = aiFlagModel
	}

	// Quick connectivity check — ask for a minimal response
	aiClient := newAIClientWithModel(cfg, "", model)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	_, _, err = aiClient.QuerySync(ctx, "", "respond with exactly: OK", "")
	if err != nil {
		return enc.Encode(map[string]any{
			"ok":       false,
			"error":    err.Error(),
			"provider": cfg.AI.Provider,
			"model":    model,
		})
	}

	return enc.Encode(map[string]any{
		"ok":       true,
		"provider": cfg.AI.Provider,
		"model":    model,
	})
}

// aiModelsProvider is one provider entry in the `ai models` output.
type aiModelsProvider struct {
	providers.Provider
	ResolvedLight  string   `json:"resolved_light"`
	ResolvedStrong string   `json:"resolved_strong"`
	Models         []string `json:"models,omitempty"`
	Error          string   `json:"error,omitempty"`
}

// aiModelsOutput is the JSON envelope of `ai models --json`.
type aiModelsOutput struct {
	ActiveProvider string             `json:"active_provider"`
	Providers      []aiModelsProvider `json:"providers"`
}

func runAIModels(cmd *cobra.Command, _ []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	out := aiModelsOutput{ActiveProvider: providers.ByID(cfg.AI.Provider).ID}
	for _, p := range providers.All() {
		entry := aiModelsProvider{Provider: p}
		entry.ResolvedLight, entry.ResolvedStrong = providers.ResolveModelsFor(cfg, p.ID)
		entry.Models = p.KnownModels
		if p.LiveModels {
			// Best-effort: an unreachable server yields an empty list plus an
			// error string, never a failing command.
			models, err := ollama.ListModels(ctx, cfg.AI.OllamaURL)
			if err != nil {
				entry.Error = err.Error()
			} else {
				entry.Models = models
			}
		}
		out.Providers = append(out.Providers, entry)
	}

	w := cmd.OutOrStdout()
	if aiModelsFlagJSON {
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(out)
	}

	for _, p := range out.Providers {
		active := " "
		if p.ID == out.ActiveProvider {
			active = "*"
		}
		fmt.Fprintf(w, "%s %s (%s)\n", active, p.DisplayName, p.ID)
		fmt.Fprintf(w, "    light:  %s\n", orPickHint(p.ResolvedLight))
		fmt.Fprintf(w, "    strong: %s\n", orPickHint(p.ResolvedStrong))
		if p.LiveModels {
			switch {
			case p.Error != "":
				fmt.Fprintf(w, "    models: unavailable (%s)\n", p.Error)
			case len(p.Models) == 0:
				fmt.Fprintf(w, "    models: none installed\n")
			default:
				fmt.Fprintf(w, "    models: %s\n", strings.Join(p.Models, ", "))
			}
		}
	}
	return nil
}

// orPickHint renders an unresolved (empty) model as an instruction instead
// of a blank — only ollama can resolve empty, since it ships no default.
func orPickHint(model string) string {
	if model == "" {
		return "(not set — pick a model, e.g. via ai.models.strong)"
	}
	return model
}

func emitError(enc *json.Encoder, msg string) error {
	_ = enc.Encode(aiStreamEvent{Type: "error", Error: msg})
	_ = enc.Encode(aiStreamEvent{Type: "done"})
	return nil
}
