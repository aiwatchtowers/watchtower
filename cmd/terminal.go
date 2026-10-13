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

	"watchtower/internal/agentkind"
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
// config directory, under which transcripts live in projects/*/<id>.jsonl
// and the session registry the staleness probe reads (`workbench
// session-probe`, board #411) in sessions/<pid>.json.
var terminalClaudeDir = defaultTerminalClaudeDir

// defaultTerminalClaudeDir is always `~/.claude`, never `CLAUDE_CONFIG_DIR`:
// the same rule as the Desktop's `ClaudeTranscript.defaultConfigDir` (a dual
// path: move both at once), and the dir the session probe's registry read
// uses. An env override could point Watchtower at a
// TCC-protected folder, and the app's environment need not match the login
// shell the embedded claude runs in.
func defaultTerminalClaudeDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".claude")
}

// terminalCodexHome is the seam tests point at a temp dir: Codex's home,
// under which rollouts live in sessions/YYYY/MM/DD/rollout-*-<id>.jsonl.
var terminalCodexHome = defaultTerminalCodexHome

// defaultTerminalCodexHome is `$CODEX_HOME` when it is set to an absolute
// path, else `~/.codex` (Codex's own rule).
func defaultTerminalCodexHome() string {
	if dir := os.Getenv("CODEX_HOME"); filepath.IsAbs(dir) {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".codex")
}

// terminalAgentHome is the home dir under which kind's transcripts live.
func terminalAgentHome(kind agentkind.Kind) string {
	if kind == agentkind.Codex {
		return terminalCodexHome()
	}
	return terminalClaudeDir()
}

const terminalTitleOwnerChars = 2000

var terminalTitleFlagDBPath string

var terminalCmd = &cobra.Command{
	Use:   "terminal",
	Short: "Embedded terminal session helpers (used by the desktop app)",
}

var terminalTitleCmd = &cobra.Command{
	Use:   "title <session-id>",
	Short: "Name an embedded coding-agent session from the owner's first messages",
	Long: `Generates a short name for a Claude Code or Codex terminal session from the
owner's first messages in its transcript and stores it with title_source='ai'.
A shell session, an owner-chosen title or an earlier AI title is left alone,
and a session with no owner message yet (or a transcript in a format this
reader does not parse) makes no AI call: the command prints
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
	kind, isAgent := agentkind.Parse(sess.Kind)
	if !isAgent || sess.TitleSource != "auto" || !sess.ClaudeSessionID.Valid {
		return enc.Encode(terminalTitleResult{Title: sess.Title, Written: false})
	}

	owner, err := terminalOwnerText(cmd, kind, sess.ClaudeSessionID.String, sess.TranscriptPath.String)
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
	tmpl, _, err := prompts.Resolve(prompts.New(database, nil), prompts.TerminalTitle, "")
	if err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "terminal title: using the default prompt: %v\n", err)
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
// transcript. A transcript the agent has not written yet, or one in a format
// the reader does not parse (a compressed Codex rollout), reads as empty: no
// title change.
func terminalOwnerText(cmd *cobra.Command, kind agentkind.Kind, sessionID, storedPath string) (string, error) {
	owner, err := readTerminalOwnerText(kind, sessionID, storedPath)
	switch {
	case errors.Is(err, terminal.ErrNoTranscript):
		return "", nil
	case errors.Is(err, terminal.ErrUnsupportedTranscript):
		fmt.Fprintf(cmd.ErrOrStderr(), "terminal title: %v\n", err)
		return "", nil
	}
	return owner, err
}

func readTerminalOwnerText(kind agentkind.Kind, sessionID, storedPath string) (string, error) {
	tr, err := terminal.OpenTranscript(kind, sessionID, storedPath, terminalAgentHome(kind))
	if err != nil {
		return "", err
	}
	return tr.OwnerText(terminalTitleOwnerChars)
}
