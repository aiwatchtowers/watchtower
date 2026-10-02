package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"watchtower/internal/config"
	"watchtower/internal/db"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

// defaultWorkspaceName names the workspace `workspace init` creates when the
// config has none yet.
const defaultWorkspaceName = "default"

var workspaceCmd = &cobra.Command{
	Use:   "workspace",
	Short: "Manage the local workspace (data directory and database)",
}

var workspaceInitCmd = &cobra.Command{
	Use:   "init",
	Short: "Create the workspace and its database without connecting Slack",
	Long: `Creates the workspace directory, opens (and migrates) its watchtower.db, and
writes active_workspace to config.yaml, so Google, Jira, the daemon and every
other command work before (or without) a Slack connection.

Idempotent: when the config already has a workspace (set explicitly, or the
single workspace holding a database), that workspace is kept and only its
directory and database are ensured; --name is ignored. The global
--workspace flag selects the workspace the same way, for this run; it is
recorded in config.yaml only when the file names no workspace yet. A Slack login made
afterwards writes into this same workspace instead of creating a second one.

Flags:
  --name  workspace name to create when none exists (default "default")
  --json  print {"workspace", "db_path", "created"} as one JSON object`,
	Args: cobra.NoArgs,
	RunE: runWorkspaceInit,
}

func init() {
	rootCmd.AddCommand(workspaceCmd)
	workspaceCmd.AddCommand(workspaceInitCmd)
	workspaceInitCmd.Flags().String("name", defaultWorkspaceName, "workspace name to create when none exists")
	workspaceInitCmd.Flags().Bool("json", false, "print the result as one JSON object")
}

// workspaceInitResult is `workspace init --json`'s output.
type workspaceInitResult struct {
	Workspace string `json:"workspace"`
	DBPath    string `json:"db_path"`
	Created   bool   `json:"created"`
}

func runWorkspaceInit(cmd *cobra.Command, _ []string) error {
	name, _ := cmd.Flags().GetString("name")
	asJSON, _ := cmd.Flags().GetBool("json")

	res, err := initWorkspace(flagConfig, flagWorkspace, name)
	if err != nil {
		return err
	}

	out := cmd.OutOrStdout()
	if asJSON {
		return json.NewEncoder(out).Encode(res)
	}
	if res.Created {
		fmt.Fprintf(out, "Workspace %q created: %s\n", res.Workspace, res.DBPath)
	} else {
		fmt.Fprintf(out, "Workspace %q already set up: %s\n", res.Workspace, res.DBPath)
	}
	return nil
}

// initWorkspace ensures a workspace exists: override (the --workspace flag)
// when set, else the config's own workspace when it resolves to one, else
// name. It creates the directory and the migrated database and records
// active_workspace in the config file when the file names no workspace yet. Several workspaces holding a database with none
// selected is refused, like every other command (a guess could split data
// across two databases).
func initWorkspace(configPath, override, name string) (*workspaceInitResult, error) {
	cfg, err := config.Load(configPath)
	if err != nil {
		return nil, fmt.Errorf("loading config: %w", err)
	}
	if override != "" {
		cfg.ActiveWorkspace = override
	}
	if cfg.ActiveWorkspace == "" {
		if err := cfg.ValidateWorkspace(); !errors.Is(err, config.ErrNoWorkspace) {
			return nil, err
		}
		cfg.ActiveWorkspace = name
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, err
	}

	dbPath := cfg.DBPath()
	_, statErr := os.Stat(dbPath)
	if statErr != nil && !errors.Is(statErr, fs.ErrNotExist) {
		return nil, fmt.Errorf("checking database: %w", statErr)
	}
	created := statErr != nil

	if err := os.MkdirAll(cfg.WorkspaceDir(), 0o700); err != nil {
		return nil, fmt.Errorf("creating workspace directory: %w", err)
	}
	database, err := db.Open(dbPath)
	if err != nil {
		return nil, fmt.Errorf("opening database: %w", err)
	}
	if err := database.Close(); err != nil {
		return nil, fmt.Errorf("closing database: %w", err)
	}

	if err := writeWorkspaceScaffold(configPath, cfg.ActiveWorkspace, false); err != nil {
		return nil, err
	}
	return &workspaceInitResult{Workspace: cfg.ActiveWorkspace, DBPath: dbPath, Created: created}, nil
}

// writeWorkspaceScaffold records workspace as active_workspace in the config
// file and fills in the sync/digest defaults a fresh install needs, leaving
// every key the file already sets alone. With force=false a file that already
// names a workspace is not rewritten at all (an idempotent re-run must not
// churn the owner's file, and a --workspace override is for that run only);
// force=true always writes, which the Slack login path needs to switch to a
// team-named workspace. A missing file starts empty; any other read failure
// is returned, so an unreadable file is never overwritten with defaults.
func writeWorkspaceScaffold(configPath, workspace string, force bool) error {
	if err := os.MkdirAll(filepath.Dir(configPath), 0o700); err != nil {
		return fmt.Errorf("creating config directory: %w", err)
	}

	v := viper.New()
	v.SetConfigFile(configPath)
	if err := v.ReadInConfig(); err != nil {
		var notFound viper.ConfigFileNotFoundError
		if !errors.As(err, &notFound) && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("reading config: %w", err)
		}
	}

	if !force && v.GetString("active_workspace") != "" {
		return nil
	}
	v.Set("active_workspace", workspace)

	defaults := map[string]any{
		"ai.context_budget":         config.DefaultAIContextBudget,
		"sync.workers":              config.DefaultSyncWorkers,
		"sync.initial_history_days": config.DefaultInitialHistDays,
		"sync.poll_interval":        config.DefaultPollInterval.String(),
		"sync.sync_threads":         config.DefaultSyncThreads,
		"sync.sync_on_wake":         config.DefaultSyncOnWake,
		"digest.enabled":            config.DefaultDigestEnabled,
		"digest.min_messages":       config.DefaultDigestMinMsgs,
	}
	for key, val := range defaults {
		if !v.IsSet(key) {
			v.Set(key, val)
		}
	}

	return writeConfigAtomic(v, configPath)
}
