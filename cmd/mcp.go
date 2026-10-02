package cmd

import (
	"errors"
	"fmt"

	"github.com/spf13/cobra"

	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/db"
	internalmcp "watchtower/internal/mcp"
	"watchtower/internal/skills"
	"watchtower/internal/tools"
)

var mcpCmd = &cobra.Command{
	Use:   "mcp",
	Short: "Run a read-only MCP server exposing Watchtower data over stdio",
	Long: `Run a Model Context Protocol (MCP) server over stdio.

The server exposes Watchtower's product data (targets, briefings, digests,
people, tracks, calendar, Jira) as read-only tools so any MCP client
(Claude Code, Cursor, Codex, ...) can use it for work context.

Add it to Claude Code with:
  claude mcp add watchtower -- watchtower mcp

With --project N the server is bound to one Watchtower project: its project
tools (board, documents, comments) apply directly to that project only, and
nothing else becomes writable. 'watchtower integrate claude-code --project N'
registers this mode in the project folder; never register it by hand for an
unrelated client.`,
	RunE: runMCP,
}

var (
	mcpFlagDBPath       string
	mcpFlagChat         bool
	mcpFlagSurface      string
	mcpFlagConversation int64
	mcpFlagTurn         string
	mcpFlagTurnFile     string
	mcpFlagContextType  string
	mcpFlagContextID    string
	mcpFlagProject      int64
)

func init() {
	rootCmd.AddCommand(mcpCmd)
	mcpCmd.Flags().StringVar(&mcpFlagDBPath, "db-path", "", "SQLite database path (overrides the workspace default)")
	mcpCmd.Flags().BoolVar(&mcpFlagChat, "chat", false, "assistant chat mode: mount write tools as proposals (never for external clients)")
	mcpCmd.Flags().StringVar(&mcpFlagSurface, "surface", "main", "chat surface for --chat: main|target")
	mcpCmd.Flags().Int64Var(&mcpFlagConversation, "conversation", 0, "chat conversation id for --chat")
	mcpCmd.Flags().StringVar(&mcpFlagTurn, "turn", "", "turn id for --chat (proposals attach to it)")
	mcpCmd.Flags().StringVar(&mcpFlagTurnFile, "turn-file", "", "file holding the running turn id for --chat (a warm ai session); mutually exclusive with --turn")
	mcpCmd.Flags().StringVar(&mcpFlagContextType, "context-type", "", "chat context type for --chat (e.g. target)")
	mcpCmd.Flags().StringVar(&mcpFlagContextID, "context-id", "", "chat context id for --chat")
	mcpCmd.Flags().Int64Var(&mcpFlagProject, "project", 0, "project mode: bind to project N and apply its project tools directly (installed by 'integrate claude-code --project N')")
}

// mcpTurnBinding resolves the turn a chat-mode proposal attaches to: a fixed
// --turn (one-shot `ai query`) or a --turn-file read at propose time (a warm
// `ai session`). Exactly one may be given, and only in chat mode.
func mcpTurnBinding(chatMode bool, turn, turnFile string) (string, func() string, error) {
	if turnFile == "" {
		return turn, nil, nil
	}
	if !chatMode {
		return "", nil, errors.New("--turn-file requires --chat")
	}
	if turn != "" {
		return "", nil, errors.New("--turn and --turn-file are mutually exclusive")
	}
	return "", chat.TurnFileReader(turnFile), nil
}

// mcpModeOptions sets up project mode, chat mode (the write-tool registry) or
// dev mode (the read-only fence) on the opened database.
func mcpModeOptions(cfg *config.Config, database *db.DB, turn string, turnFunc func() string) ([]internalmcp.ServerOption, error) {
	if mcpFlagProject == 0 && !mcpFlagChat {
		// The MCP surface is read-only; enforce it at the connection level so even
		// a buggy handler cannot write. Must run after Open (migrations need writes).
		if err := database.SetReadOnly(); err != nil {
			return nil, fmt.Errorf("enforcing read-only: %w", err)
		}
		return nil, nil
	}
	// Both writable modes record owner-facing rows (a proposal, a board
	// write); give them the owner-click lock budget.
	if err := database.SetBusyTimeout(ownerWriteBusyTimeout); err != nil {
		return nil, err
	}
	if mcpFlagProject != 0 {
		return mcpProjectOptions(cfg, database, mcpFlagProject)
	}
	// Chat mode: the connection stays writable ONLY so the registry can
	// record proposals (agent_actions) — the tools themselves still never
	// write domain data on propose (AGENT-01). Dev mode above keeps the
	// query_only fence (AGENT-02 / DEV-01).
	if mcpFlagSurface != "main" && mcpFlagSurface != "target" {
		return nil, fmt.Errorf("--surface must be main or target")
	}
	return []internalmcp.ServerOption{internalmcp.WithRegistry(buildToolRegistry(cfg, database), tools.Binding{
		Surface: mcpFlagSurface, ConversationID: mcpFlagConversation, TurnID: turn, TurnIDFunc: turnFunc,
		ContextType: mcpFlagContextType, ContextID: mcpFlagContextID,
	})}, nil
}

// mcpProjectOptions is `watchtower mcp --project N` (DEV-06): the connection
// stays writable, the registry is bound to project N on the "project" surface,
// and its tools apply directly (DirectApply) with an agent_actions audit row —
// never an External tool inline: the one propose-only External tool
// (send_slack_message) is recorded pending for the owner's Approve (DEV-06). The project must exist when the server starts; if
// it is deleted later, every tool answers "project N no longer exists".
func mcpProjectOptions(cfg *config.Config, database *db.DB, projectID int64) ([]internalmcp.ServerOption, error) {
	if mcpFlagChat {
		return nil, errors.New("--project and --chat are mutually exclusive")
	}
	if projectID < 0 {
		return nil, fmt.Errorf("--project must be a project id, got %d", projectID)
	}
	if _, err := database.GetProject(projectID); err != nil {
		return nil, fmt.Errorf("project %d: %w", projectID, err)
	}
	return []internalmcp.ServerOption{internalmcp.WithRegistry(buildToolRegistry(cfg, database), tools.Binding{
		Surface: "project", ProjectID: projectID, DirectApply: true,
	})}, nil
}

func runMCP(cmd *cobra.Command, args []string) error {
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

	turn, turnFunc, err := mcpTurnBinding(mcpFlagChat, mcpFlagTurn, mcpFlagTurnFile)
	if err != nil {
		return err
	}

	dbPath := cfg.DBPath()
	if mcpFlagDBPath != "" {
		dbPath = mcpFlagDBPath
	}
	database, err := db.Open(dbPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	opts := []internalmcp.ServerOption{
		internalmcp.WithSkillsDir(skills.Dir(cfg.WorkspaceDir())),
	}
	modeOpts, err := mcpModeOptions(cfg, database, turn, turnFunc)
	if err != nil {
		return err
	}
	opts = append(opts, modeOpts...)
	if cfg.Memory.Enabled {
		opts = append(opts, internalmcp.WithMemoryVault(memoryVaultPath(cfg)))
		if cfg.Memory.Retrieve.RecallCompare {
			shadowDB, err := db.Open(dbPath)
			if err != nil {
				return fmt.Errorf("opening retrieve-compare shadow handle: %w", err)
			}
			defer shadowDB.Close()
			opts = append(opts, internalmcp.WithMemoryRetrieveCompare(shadowDB))
		}
	}
	return internalmcp.NewServer(database, opts...).ServeStdio(cmd.Context())
}
