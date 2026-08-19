package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	internalmcp "watchtower/internal/mcp"
	"watchtower/internal/skills"
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

var mcpFlagDBPath string

func init() {
	rootCmd.AddCommand(mcpCmd)
	mcpCmd.Flags().StringVar(&mcpFlagDBPath, "db-path", "", "SQLite database path (overrides the workspace default)")
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

	// The MCP surface is read-only; enforce it at the connection level so even
	// a buggy handler cannot write. Must run after Open (migrations need writes).
	if err := database.SetReadOnly(); err != nil {
		return fmt.Errorf("enforcing read-only: %w", err)
	}

	opts := []internalmcp.ServerOption{
		internalmcp.WithSkillsDir(skills.Dir(cfg.WorkspaceDir())),
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
