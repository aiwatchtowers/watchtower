// Package cmd contains the command-line interface for Watchtower.
package cmd

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"time"

	"watchtower/internal/auditlog"
	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
	"watchtower/internal/db/lockmetrics"
	"watchtower/internal/fsutil"
	"watchtower/internal/llmusage"
	"watchtower/internal/logredact"
	"watchtower/internal/repl"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var (
	flagWorkspace string
	flagConfig    string
	flagVerbose   bool
	flagProvider  string
)

var rootCmd = &cobra.Command{
	Use:               "watchtower",
	Short:             "Slack workspace intelligence tool",
	Long:              "Watchtower syncs a Slack workspace into a local SQLite database and provides an AI-powered interface for analysis via the Claude API.",
	PersistentPreRunE: ensureSchemaFormat,
	RunE:              runREPL,
}

// ensureSchemaFormat runs once before every command. When the on-disk
// db.schema_format flag is below db.CurrentSchemaFormat, it invokes the
// one-shot RunSchemaUpgrade against the live DB (idempotent) and bumps
// the flag in config. Skips silently when no config / no DB exists. It
// also points the LLM call records at their spool first (wireLLMUsage).
func ensureSchemaFormat(_ *cobra.Command, _ []string) error {
	if _, err := os.Stat(flagConfig); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			wireLLMUsage(nil)
			return nil
		}
		return fmt.Errorf("checking config file: %w", err)
	}

	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	wireLLMUsage(cfg)
	if cfg.DB.SchemaFormat >= db.CurrentSchemaFormat {
		return nil
	}

	dbPath := cfg.DBPath()
	if _, statErr := os.Stat(dbPath); statErr == nil {
		if err := db.RunSchemaUpgrade(dbPath); err != nil {
			return fmt.Errorf("schema upgrade: %w", err)
		}
	}

	v := viper.New()
	v.SetConfigFile(flagConfig)
	if err := v.ReadInConfig(); err != nil {
		return fmt.Errorf("re-reading config for schema_format bump: %w", err)
	}
	v.Set("db.schema_format", db.CurrentSchemaFormat)
	if err := writeConfigAtomic(v, flagConfig); err != nil {
		return fmt.Errorf("persisting schema_format: %w", err)
	}
	return nil
}

// Execute runs the root command and returns the exit code.
func Execute() int {
	role := roleFor(os.Args[1:])
	lockmetrics.SetProcessRole(role)
	llmusage.SetProcess(role, surfaceFor(role, os.Args[1:]))
	auditlog.SetProcess(auditPath(role))
	// Calls land in the setup spool until the root pre-run resolves the
	// workspace; a command with its own no-op PersistentPreRunE keeps it.
	wireLLMUsage(nil)
	go sweepStaleTemp()
	wrapContentCommands()
	contentRan.Store(nil)
	err := rootCmd.Execute()
	auditCLIRun(os.Getenv, err)
	if err != nil {
		// The final error is for the owner (a terminal, or the Desktop that
		// shows a failed command's stderr), so CLI stderr and HTTP bodies
		// show in full (logredact.Full) — except in the detached daemon,
		// whose stderr is watchtower.log.
		switch {
		case err.Error() == "": // errQuietExit: the exit code says it all
		case os.Getenv(daemon.DetachEnvKey) == "1":
			fmt.Fprintln(os.Stderr, err)
		default:
			fmt.Fprintln(os.Stderr, logredact.Full(err))
		}
		var ec *exitCodeError
		if errors.As(err, &ec) {
			return ec.code
		}
		return 1
	}
	return 0
}

// staleTempAge matches the daemon's sweep: a live call never keeps a prompt
// temp file this long.
const staleTempAge = 10 * time.Minute

// sweepStaleTemp removes the prompt and MCP-config temp files a killed
// process left (fsutil.StaleTempPatterns). Every process start runs it in
// the background: best effort, it never delays a command or a hook, and a
// short-lived process may exit before it finishes; errors are dropped (the
// daemon's own startup sweep logs them).
func sweepStaleTemp() {
	_, _ = fsutil.SweepStaleTemp(staleTempAge, time.Now())
}

func init() {
	rootCmd.SilenceErrors = true
	rootCmd.SilenceUsage = true
	rootCmd.PersistentFlags().StringVar(&flagWorkspace, "workspace", "", "workspace name to use")
	rootCmd.PersistentFlags().StringVar(&flagConfig, "config", defaultConfigPath(), "path to config file")
	rootCmd.PersistentFlags().BoolVarP(&flagVerbose, "verbose", "v", false, "enable verbose output")
	rootCmd.PersistentFlags().StringVar(&flagProvider, "provider", "", "AI provider to use (claude|codex|ollama)")
}

// defaultConfigPath honors WATCHTOWER_CONFIG_PATH when set, so a dev/verification
// run (and any subprocess it spawns, e.g. the Desktop app's `sync --daemon`
// child) can be pointed at an isolated config without an explicit --config flag
// at every call site. Mirrors the Desktop app's Constants.configPath override —
// same env var name, same fallback-to-real-path behavior when unset.
func defaultConfigPath() string {
	if p := os.Getenv("WATCHTOWER_CONFIG_PATH"); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "watchtower", "config.yaml")
}

func runREPL(cmd *cobra.Command, args []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	accounts, err := database.ListSlackAccounts()
	if err != nil {
		return fmt.Errorf("listing slack accounts: %w", err)
	}

	domain := ""
	teamID := ""
	workspace := cfg.ActiveWorkspace
	if len(accounts) > 0 {
		// The first account is the representative for illustrative deep-link
		// examples; per-message permalinks resolve per account downstream.
		domain = accounts[0].TeamDomain
		teamID = accounts[0].TeamID
		workspace = db.FormatConnectedWorkspaces(accounts)
	}

	deps := repl.Deps{
		Config:     cfg,
		DB:         database,
		DBPath:     cfg.DBPath(),
		Domain:     domain,
		TeamID:     teamID,
		Workspace:  workspace,
		AIProvider: newAIClient(cfg, cfg.DBPath()),
	}

	return repl.Run(deps)
}
