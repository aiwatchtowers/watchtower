// Package cmd contains the command-line interface for Watchtower.
package cmd

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"time"

	"watchtower/internal/ai"
	"watchtower/internal/aiconsent"
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

	return config.WithWriteLock(flagConfig, func(lk *config.WriteLock) error {
		v := viper.New()
		v.SetConfigFile(flagConfig)
		v.SetConfigType("yaml")
		if err := v.ReadInConfig(); err != nil {
			return fmt.Errorf("re-reading config for schema_format bump: %w", err)
		}
		v.Set("db.schema_format", db.CurrentSchemaFormat)
		if err := writeConfigAtomic(lk, v, flagConfig); err != nil {
			return fmt.Errorf("persisting schema_format: %w", err)
		}
		return nil
	})
}

// Execute runs the root command and returns the exit code.
func Execute() int {
	role := initProcessOrigin(os.Args[1:], os.Getenv)
	lockmetrics.SetProcessRole(role)
	llmusage.SetProcess(role, surfaceFor(role, os.Args[1:]))
	auditlog.SetProcess(auditPath(role))
	// Calls land in the setup spool until the root pre-run resolves the
	// workspace; a command with its own no-op PersistentPreRunE keeps it.
	wireLLMUsage(nil)
	if shouldSweepTemp(role) {
		startTempSweep()
	}
	wrapContentCommands()
	contentRan.Store(nil)
	err := rootCmd.Execute()
	auditCLIRun(os.Getenv, err)
	if err != nil {
		printFinalError(os.Stderr, err, os.Getenv(daemon.DetachEnvKey) == "1")
		var ec *exitCodeError
		if errors.As(err, &ec) {
			return ec.code
		}
		return 1
	}
	return 0
}

// initProcessOrigin names this process from its arguments and sets its
// default AI origin from that role and the environment: the daemon is
// background, a child a background unit started inherits background through
// the environment, everything else is the owner's (aiconsent.InitProcess).
//
// It also points the consent reader at the default config path (the
// --config flag is not parsed yet); wireAIConsent re-points it at the
// resolved path once cobra has parsed the flags.
func initProcessOrigin(args []string, getenv func(string) string) string {
	aiconsent.SetConfigPath(flagConfig)
	role := roleFor(args)
	aiconsent.InitProcess(role, getenv)
	return role
}

// wireAIConsent points the consent reader at the resolved config file and
// tells a process started under an automation run marker how to read its
// run's trigger. It runs for every command (cobra.OnInitialize), including
// the ones whose own PersistentPreRunE replaces the root's — so the daemon
// (sync --daemon) and the hub and chat engine it hosts read the same file.
// main.go -> Execute is the only process entry.
func wireAIConsent() {
	aiconsent.SetConfigPath(flagConfig)
	aiconsent.SetRunTriggerLookup(lookupRunTrigger)
}

// lookupRunTrigger reads automation_runs.trigger for runID through a
// read-only handle opened on first use (aiconsent resolves the marker once).
func lookupRunTrigger(runID int64) (string, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return "", fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	database, err := db.OpenExisting(cfg.DBPath(), runTriggerBusy)
	if err != nil {
		return "", fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()
	var trigger string
	if err := database.QueryRow(`SELECT trigger FROM automation_runs WHERE id = ?`, runID).Scan(&trigger); err != nil {
		return "", fmt.Errorf("reading run %d: %w", runID, err)
	}
	return trigger, nil
}

// runTriggerBusy bounds the wait for another process's lock on the one
// trigger read.
const runTriggerBusy = 2 * time.Second

// printFinalError prints the command's final error. It is for the owner (a
// terminal, or the Desktop that shows a failed command's stderr), so CLI
// stderr and HTTP bodies show in full (logredact.Full) — except in the
// detached daemon, whose stderr is watchtower.log. errQuietExit prints
// nothing: its exit code says it all.
func printFinalError(w io.Writer, err error, detached bool) {
	switch {
	case errors.Is(err, errQuietExit):
	case detached:
		_, _ = fmt.Fprintln(w, err)
	default:
		_, _ = fmt.Fprintln(w, logredact.Full(err))
	}
}

// staleTempAge matches the daemon's sweep: a live call never keeps an unheld
// prompt temp file this long (a held one is skipped, fsutil.HoldTempFile).
const staleTempAge = 10 * time.Minute

// sweepStaleTemp removes the prompt and MCP-config temp files a killed
// process left (fsutil.StaleTempPatterns). Every process start runs it in
// the background: best effort, it never delays a command or a hook, and a
// short-lived process may exit before it finishes; errors are dropped (the
// daemon's own startup sweep logs them).
func sweepStaleTemp() {
	_, _ = fsutil.SweepStaleTemp(staleTempAge, time.Now())
}

// startTempSweep starts sweepStaleTemp in the background; a seam so a test
// can run the sweep synchronously and see whether a command skipped it.
var startTempSweep = func() { go sweepStaleTemp() }

// shouldSweepTemp is false for `diagnostics`, which removes nothing — not
// even another process's stale temp files (spec "What it writes").
func shouldSweepTemp(role string) bool { return role != "cli:diagnostics" }

func init() {
	cobra.OnInitialize(wireAIConsent)
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
		AIProvider: replAIProvider(cfg),
		// The REPL discards sync logs; the daemon logs a damaged company file.
		DenyHosts: linkDenySource(cfg, log.New(io.Discard, "", 0)),
	}

	return repl.Run(deps)
}

// replAIProvider is the REPL's client. It lives for the whole session, so
// nothing is refused once at build time: every call asks consent (BGAI-01)
// and the configured provider's policy first — also ahead of the reserve
// routing, which on a resumed turn checks only the session's provider — then
// the long-lived checkedAIClient routes it. The call's ctx and the current
// state decide (spec §4.3).
func replAIProvider(cfg *config.Config) ai.Provider {
	return policyCheckedProvider{inner: checkedAIClient(cfg, cfg.DBPath()), provider: cfg.AI.Provider}
}
