package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// chatTitleGeneratorFactory is the seam tests override to inject a mock
// generator (the dictateGeneratorFactory pattern).
//
// The title call's user message is the owner's first exchange, so CHAT-04
// forbids it on argv at any size: the CLI generators always pass it on
// stdin (the HTTP ollama generator has no argv to protect).
var chatTitleGeneratorFactory = func(cfg *config.Config) digest.Generator {
	return cliGenerator(cfg)
}

var chatTitleFlagDBPath string

var chatCmd = &cobra.Command{
	Use:   "chat",
	Short: "Chat helpers (used by the desktop app)",
}

var chatTitleCmd = &cobra.Command{
	Use:   "title <conversation-id>",
	Short: "Name a chat conversation from its first exchange",
	Long: `Generates a title of at most 60 characters for a chat conversation from its
first owner message and assistant reply, and stores it with title_source='ai'.
A title the owner set (title_source='user') is never overwritten: the command
then prints it with "written": false and makes no AI call.`,
	Args: cobra.ExactArgs(1),
	RunE: runChatTitle,
}

var chatShutdownFlagSocketTimeout time.Duration

var chatShutdownCmd = &cobra.Command{
	Use:   "shutdown",
	Short: "End every chat turn and close the chat sessions (used by the desktop app)",
	Long: `Ends the main chat: every running turn stops (its text so far kept) and every
chat session process is closed. Asks the daemon's chat engine on chat.sock;
when no daemon answers, sends each session socket cancel and close and reaps
the sessions' process groups directly (close, then SIGTERM after 2 s, then
SIGKILL after 3 s more); the replies are then marked by the next daemon
start. The app runs it when it quits with the daemon already down and
before it compacts the database.

--socket-timeout bounds the chat.sock step (default 15 s); the app passes a
short one, having already asked the engine itself, so the direct reap
always runs within its own wait.`,
	Args: cobra.NoArgs,
	RunE: runChatShutdown,
}

func init() {
	rootCmd.AddCommand(chatCmd)
	chatCmd.AddCommand(chatTitleCmd)
	chatCmd.AddCommand(chatShutdownCmd)
	chatShutdownCmd.Flags().DurationVar(&chatShutdownFlagSocketTimeout, "socket-timeout", chatShutdownBudget, "how long to wait for the daemon's chat engine on chat.sock before reaping the sessions directly")
	chatTitleCmd.Flags().StringVar(&chatTitleFlagDBPath, "db-path", "", "SQLite database path (overrides the workspace default)")
}

type chatTitleResult struct {
	Title   string `json:"title"`
	Written bool   `json:"written"`
}

// openChatTitleDB loads the config (workspace/provider overrides applied) and
// opens the database `chat title` works on.
func openChatTitleDB() (*config.Config, *db.DB, error) {
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
	dbPath := chatTitleFlagDBPath
	if dbPath == "" {
		dbPath = cfg.DBPath()
	}
	database, err := db.Open(dbPath)
	if err != nil {
		return nil, nil, fmt.Errorf("opening database: %w", err)
	}
	return cfg, database, nil
}

func runChatTitle(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil || id <= 0 {
		return fmt.Errorf("invalid conversation id %q", args[0])
	}
	cfg, database, err := openChatTitleDB()
	if err != nil {
		return err
	}
	defer database.Close()

	ctx := cmd.Context()
	if ctx == nil { // RunE invoked directly (tests)
		ctx = context.Background()
	}
	res, err := chat.GenerateTitle(ctx, database, cfg, chatTitleGeneratorFactory(cfg), id)
	if res.PromptFallback != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "chat title: using the default prompt: %v\n", res.PromptFallback)
	}
	if err != nil {
		return err
	}
	return json.NewEncoder(cmd.OutOrStdout()).Encode(chatTitleResult{Title: res.Title, Written: res.Written})
}

func runChatShutdown(cmd *cobra.Command, _ []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}
	if chatShutdownFlagSocketTimeout <= 0 {
		return errors.New("--socket-timeout must be positive")
	}
	if err := shutdownChatWithin(cfg, chatShutdownFlagSocketTimeout); err != nil {
		return fmt.Errorf("chat shutdown: %w", err)
	}
	fmt.Fprintln(cmd.OutOrStdout(), "Chat sessions closed.")
	return nil
}
