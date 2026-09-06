package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

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
  claude mcp add watchtower -- watchtower mcp`,
	RunE: runMCP,
}

var (
	mcpFlagDBPath       string
	mcpFlagChat         bool
	mcpFlagSurface      string
	mcpFlagConversation int64
	mcpFlagTurn         string
	mcpFlagContextType  string
	mcpFlagContextID    string
)

func init() {
	rootCmd.AddCommand(mcpCmd)
	mcpCmd.Flags().StringVar(&mcpFlagDBPath, "db-path", "", "SQLite database path (overrides the workspace default)")
	mcpCmd.Flags().BoolVar(&mcpFlagChat, "chat", false, "assistant chat mode: mount write tools as proposals (never for external clients)")
	mcpCmd.Flags().StringVar(&mcpFlagSurface, "surface", "main", "chat surface for --chat: main|target")
	mcpCmd.Flags().Int64Var(&mcpFlagConversation, "conversation", 0, "chat conversation id for --chat")
	mcpCmd.Flags().StringVar(&mcpFlagTurn, "turn", "", "turn id for --chat (proposals attach to it)")
	mcpCmd.Flags().StringVar(&mcpFlagContextType, "context-type", "", "chat context type for --chat (e.g. target)")
	mcpCmd.Flags().StringVar(&mcpFlagContextID, "context-id", "", "chat context id for --chat")
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
	if mcpFlagChat {
		// Chat mode: the connection stays writable ONLY so the registry can
		// record proposals (agent_actions) — the tools themselves still never
		// write domain data on propose (AGENT-01). Dev mode below keeps the
		// query_only fence (AGENT-02 / DEV-01).
		if mcpFlagSurface != "main" && mcpFlagSurface != "target" {
			return fmt.Errorf("--surface must be main or target")
		}
		opts = append(opts, internalmcp.WithRegistry(buildToolRegistry(cfg, database), tools.Binding{
			Surface: mcpFlagSurface, ConversationID: mcpFlagConversation, TurnID: mcpFlagTurn,
			ContextType: mcpFlagContextType, ContextID: mcpFlagContextID,
		}))
	} else {
		// The MCP surface is read-only; enforce it at the connection level so even
		// a buggy handler cannot write. Must run after Open (migrations need writes).
		if err := database.SetReadOnly(); err != nil {
			return fmt.Errorf("enforcing read-only: %w", err)
		}
	}
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
