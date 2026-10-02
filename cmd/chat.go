package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// chatTitleGeneratorFactory is the seam tests override to inject a mock
// generator (the dictateGeneratorFactory pattern).
//
// The title call's user message is the owner's first exchange, so CHAT-04
// forbids it on argv at any size: the CLI generators are switched to their
// stdin-only mode (the HTTP ollama generator has no argv to protect).
var chatTitleGeneratorFactory = func(cfg *config.Config) digest.Generator {
	gen := cliGenerator(cfg)
	if s, ok := gen.(interface{ SetStdinOnly(bool) }); ok {
		s.SetStdinOnly(true)
	}
	return gen
}

const (
	chatTitleMaxRunes     = 60
	chatTitleExcerptRunes = 4000
)

var chatTitleFlagDBPath string

var chatCmd = &cobra.Command{
	Use:   "chat",
	Short: "AI Chat helpers (used by the desktop app)",
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

func init() {
	rootCmd.AddCommand(chatCmd)
	chatCmd.AddCommand(chatTitleCmd)
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

// chatTitlePrompt renders the chat.title system prompt (the tunable DB row,
// else the compiled default) and the first-exchange user message.
func chatTitlePrompt(database *db.DB, cfg *config.Config, owner, assistant string) (system, user string) {
	// A store read error falls back to the default silently, as before: stderr
	// stays clean for the Desktop that runs this command.
	tmpl, _, _ := prompts.Resolve(prompts.New(database, nil), prompts.ChatTitle, "")
	system = fmt.Sprintf(tmpl, prompts.Directive(cfg.Digest.Language))
	user = "=== FIRST EXCHANGE ===\nOwner: " + excerptRunes(owner, chatTitleExcerptRunes) +
		"\n\nAssistant: " + excerptRunes(assistant, chatTitleExcerptRunes)
	return system, user
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

	conv, err := database.GetChatConversation(id)
	if err != nil {
		return err
	}
	if conv == nil {
		return fmt.Errorf("conversation %d not found", id)
	}
	enc := json.NewEncoder(cmd.OutOrStdout())
	if conv.TitleSource == "user" {
		return enc.Encode(chatTitleResult{Title: conv.Title, Written: false})
	}

	path, err := database.ActiveChatPath(id)
	if err != nil {
		return err
	}
	owner, assistant := firstChatExchange(path)
	if owner == "" {
		return fmt.Errorf("conversation %d has no owner message yet", id)
	}

	system, user := chatTitlePrompt(database, cfg, owner, assistant)
	ctx := cmd.Context()
	if ctx == nil { // RunE invoked directly (tests)
		ctx = context.Background()
	}
	reply, _, _, err := chatTitleGeneratorFactory(cfg).Generate(digest.WithSource(ctx, "chat.title"), system, user, "")
	if err != nil {
		return fmt.Errorf("generating the title: %w", err)
	}
	title := cleanChatTitle(reply)
	if title == "" {
		return fmt.Errorf("the model returned an empty title")
	}
	written, err := database.SetChatTitle(id, title, "ai")
	if err != nil {
		return err
	}
	return enc.Encode(chatTitleResult{Title: title, Written: written})
}

// firstChatExchange returns the first owner message and the first assistant
// reply after it on the active path.
func firstChatExchange(path []db.ChatMessage) (owner, assistant string) {
	for _, m := range path {
		switch {
		case m.Role == "user" && owner == "":
			owner = strings.TrimSpace(m.Text)
		case m.Role == "assistant" && owner != "" && assistant == "":
			assistant = strings.TrimSpace(m.Text)
		}
	}
	return owner, assistant
}

// cleanChatTitle takes the first non-empty line of the reply and strips the
// decoration models add anyway: heading/list markers, a "Title:" label,
// quotes of any script, emphasis and a trailing period; then caps it at
// chatTitleMaxRunes runes.
func cleanChatTitle(reply string) string {
	for _, line := range strings.Split(reply, "\n") {
		s := strings.TrimSpace(line)
		s = strings.TrimLeft(s, "#>-* ")
		if strings.HasPrefix(strings.ToLower(s), "title:") {
			s = strings.TrimSpace(s[len("title:"):])
		}
		s = strings.Trim(s, "\"'`“”«»*_ ")
		s = strings.TrimSpace(strings.TrimSuffix(s, "."))
		if s == "" {
			continue
		}
		if r := []rune(s); len(r) > chatTitleMaxRunes {
			s = strings.TrimSpace(string(r[:chatTitleMaxRunes-1])) + "…"
		}
		return s
	}
	return ""
}

// excerptRunes caps s at n runes (the first exchange can be a pasted document).
func excerptRunes(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n]) + "…"
	}
	return s
}
