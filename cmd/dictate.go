package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

var (
	dictateCleanFlagMode string
	dictateCleanFlagFile string
)

// dictateGeneratorFactory is the seam tests override to inject a mock
// generator (the transcriptGeneratorFactory pattern).
var dictateGeneratorFactory = func(cfg *config.Config) digest.Generator {
	return cliGenerator(cfg)
}

var dictateCmd = &cobra.Command{
	Use:   "dictate",
	Short: "Voice-dictation helpers for the Desktop app",
}

var dictateCleanCmd = &cobra.Command{
	Use:   "clean",
	Short: "Clean a raw dictation transcript into destination-shaped text",
	Long: "Cleans a raw voice-dictation transcript via a light-tier AI pass. " +
		"Pure transform: reads the transcript file, prints a JSON envelope on stdout, " +
		"persists nothing. Exits 1 on any failure.",
	RunE: runDictateClean,
}

func init() {
	rootCmd.AddCommand(dictateCmd)
	dictateCmd.AddCommand(dictateCleanCmd)
	dictateCleanCmd.Flags().StringVar(&dictateCleanFlagMode, "mode", "", "cleanup destination: idea, note, or chat (required)")
	dictateCleanCmd.Flags().StringVar(&dictateCleanFlagFile, "transcript-file", "", "path to the raw transcript text file (required)")
}

// dictateEnv loads config and opens the workspace DB (the transcriptEnv
// pattern), also applying the --provider override before any generator is
// built. The DB is opened only to read the tunable dictation.clean prompt —
// nothing is ever written.
func dictateEnv() (*config.Config, *db.DB, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, nil, fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, nil, err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, nil, fmt.Errorf("opening database: %w", err)
	}
	return cfg, database, nil
}

func runDictateClean(cmd *cobra.Command, _ []string) error {
	instructions, ok := prompts.DictationModeInstructions(dictateCleanFlagMode)
	if !ok {
		return fmt.Errorf("invalid --mode %q (valid: idea, note, chat)", dictateCleanFlagMode)
	}
	if dictateCleanFlagFile == "" {
		return fmt.Errorf("--transcript-file is required")
	}
	raw, err := os.ReadFile(dictateCleanFlagFile)
	if err != nil {
		return fmt.Errorf("reading transcript file: %w", err)
	}
	transcript := strings.TrimSpace(string(raw))
	if transcript == "" {
		return fmt.Errorf("transcript file is empty")
	}

	cfg, database, err := dictateEnv()
	if err != nil {
		return err
	}
	defer database.Close()

	store := prompts.New(database, nil)
	tmpl, _, _ := store.Get(prompts.DictationClean)
	if tmpl == "" {
		tmpl = prompts.Defaults[prompts.DictationClean]
	}
	system := fmt.Sprintf(tmpl, instructions, prompts.Directive(cfg.Digest.Language))
	// The transcript rides the USER message so the >32 KB stdin path stays
	// reachable and a leading "-" can never be parsed as a CLI flag.
	user := "=== RAW DICTATION TRANSCRIPT ===\n" + transcript

	ctx := cmd.Context()
	if ctx == nil { // RunE invoked directly (tests) — cobra sets ctx only via Execute
		ctx = context.Background()
	}
	gen := dictateGeneratorFactory(cfg)
	reply, _, _, err := gen.Generate(digest.WithSource(ctx, "dictation.clean"), system, user, "")
	if err != nil {
		return fmt.Errorf("cleaning dictation: %w", err)
	}

	envelope, err := dictateCleanEnvelope(dictateCleanFlagMode, reply)
	if err != nil {
		return err
	}

	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(envelope)
}

// dictateCleanEnvelope parses the AI reply and builds the per-mode stdout
// envelope, rejecting a reply whose mode-required field is missing or empty.
func dictateCleanEnvelope(mode, reply string) (map[string]any, error) {
	obj, err := prompts.ExtractJSONObject(reply)
	if err != nil {
		return nil, fmt.Errorf("extracting cleanup JSON: %w (raw: %.300s)", err, reply)
	}
	var parsed struct {
		Title    string `json:"title"`
		Body     string `json:"body"`
		Markdown string `json:"markdown"`
		Text     string `json:"text"`
	}
	if err := json.Unmarshal([]byte(obj), &parsed); err != nil {
		return nil, fmt.Errorf("parsing cleanup JSON: %w (raw: %.300s)", err, reply)
	}

	envelope := map[string]any{"mode": mode}
	switch mode {
	case "idea":
		if strings.TrimSpace(parsed.Title) == "" || strings.TrimSpace(parsed.Body) == "" {
			return nil, fmt.Errorf("cleanup reply missing title/body (raw: %.300s)", reply)
		}
		envelope["title"], envelope["body"] = parsed.Title, parsed.Body
	case "note":
		if strings.TrimSpace(parsed.Markdown) == "" {
			return nil, fmt.Errorf("cleanup reply missing markdown (raw: %.300s)", reply)
		}
		envelope["markdown"] = parsed.Markdown
	case "chat":
		if strings.TrimSpace(parsed.Text) == "" {
			return nil, fmt.Errorf("cleanup reply missing text (raw: %.300s)", reply)
		}
		envelope["text"] = parsed.Text
	}
	return envelope, nil
}
