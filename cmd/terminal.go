package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
	"watchtower/internal/terminal"
)

// terminalTitleGeneratorFactory is the seam tests override to inject a mock
// generator. The user message is the owner's own typed text, so the CLI
// generators are switched to their stdin-only mode (CHAT-04: owner text is
// never on argv).
var terminalTitleGeneratorFactory = func(cfg *config.Config) digest.Generator {
	gen := cliGenerator(cfg)
	if s, ok := gen.(interface{ SetStdinOnly(bool) }); ok {
		s.SetStdinOnly(true)
	}
	return gen
}

// terminalClaudeDir is the seam tests point at a temp dir: Claude Code's
// config directory, under which transcripts live in projects/*/<id>.jsonl.
var terminalClaudeDir = defaultTerminalClaudeDir

// defaultTerminalClaudeDir is always `~/.claude`, never `CLAUDE_CONFIG_DIR`:
// the same rule as the Desktop's `ClaudeTranscript.defaultConfigDir` (a dual
// path: move both at once). An env override could point Watchtower at a
// TCC-protected folder, and the app's environment need not match the login
// shell the embedded claude runs in.
func defaultTerminalClaudeDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".claude")
}

const terminalTitleOwnerChars = 2000

var terminalTitleFlagDBPath string

var terminalCmd = &cobra.Command{
	Use:   "terminal",
	Short: "Embedded terminal session helpers (used by the desktop app)",
}

var terminalTitleCmd = &cobra.Command{
	Use:   "title <session-id>",
	Short: "Name an embedded Claude Code session from the owner's first messages",
	Long: `Generates a short name for a Claude Code terminal session from the owner's
first messages in its transcript and stores it with title_source='ai'. A shell
session, an owner-chosen title or an earlier AI title is left alone, and a
session with no owner message yet makes no AI call: the command prints
{"title":"","written":false} and exits 0.`,
	Args: cobra.ExactArgs(1),
	RunE: runTerminalTitle,
}

func init() {
	rootCmd.AddCommand(terminalCmd)
	terminalCmd.AddCommand(terminalTitleCmd)
	terminalTitleCmd.Flags().StringVar(&terminalTitleFlagDBPath, "db-path", "", "SQLite database path (overrides the workspace default)")
	terminalTitleCmd.Flags().Bool("json", true, "Print the JSON envelope (always on; accepted for symmetry)")
}

type terminalTitleResult struct {
	Title   string `json:"title"`
	Written bool   `json:"written"`
}

func runTerminalTitle(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil || id <= 0 {
		return fmt.Errorf("invalid terminal session id %q", args[0])
	}
	cfg, database, err := openTerminalTitleDB()
	if err != nil {
		return err
	}
	defer database.Close()

	sess, err := database.GetTerminalSession(id)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(cmd.OutOrStdout())
	if sess.Kind != "claude" || sess.TitleSource != "auto" || !sess.ClaudeSessionID.Valid {
		return enc.Encode(terminalTitleResult{Title: sess.Title, Written: false})
	}

	owner, err := terminalOwnerText(sess.ClaudeSessionID.String)
	if err != nil {
		return err
	}
	if owner == "" {
		return enc.Encode(terminalTitleResult{})
	}
	title, err := generateTerminalTitle(cmd, cfg, database, owner)
	if err != nil {
		return err
	}
	written, err := database.SetTerminalSessionAITitle(id, title)
	if err != nil {
		return err
	}
	return enc.Encode(terminalTitleResult{Title: title, Written: written})
}

// openTerminalTitleDB loads the config and opens the workspace database (or
// --db-path).
func openTerminalTitleDB() (*config.Config, *db.DB, error) {
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
	dbPath := terminalTitleFlagDBPath
	if dbPath == "" {
		dbPath = cfg.DBPath()
	}
	database, err := db.Open(dbPath)
	if err != nil {
		return nil, nil, fmt.Errorf("opening database: %w", err)
	}
	return cfg, database, nil
}

// generateTerminalTitle asks the light-tier model for a title of the owner's
// messages; an empty answer is an error.
func generateTerminalTitle(cmd *cobra.Command, cfg *config.Config, database *db.DB, owner string) (string, error) {
	tmpl, _, err := prompts.New(database, nil).Get(prompts.TerminalTitle)
	if err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "terminal title: using the default prompt: %v\n", err)
	}
	if tmpl == "" {
		tmpl = prompts.Defaults[prompts.TerminalTitle]
	}
	ctx := cmd.Context()
	if ctx == nil { // RunE invoked directly (tests)
		ctx = context.Background()
	}
	reply, _, _, err := terminalTitleGeneratorFactory(cfg).Generate(digest.WithSource(ctx, "terminal.title"), tmpl, owner, "")
	if err != nil {
		return "", fmt.Errorf("generating the title: %w", err)
	}
	title := cleanChatTitle(reply)
	if title == "" {
		return "", fmt.Errorf("the model returned an empty title")
	}
	return title, nil
}

// terminalOwnerText reads the owner's typed messages from the session's
// transcript; a transcript Claude Code has not written yet reads as empty.
func terminalOwnerText(sessionID string) (string, error) {
	path, err := terminal.FindTranscript(terminalClaudeDir(), sessionID)
	if errors.Is(err, terminal.ErrNoTranscript) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	f, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("opening transcript: %w", err)
	}
	defer f.Close()
	return terminal.OwnerMessages(f, terminalTitleOwnerChars)
}
