package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime/debug"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"encoding/json"
	"watchtower/internal/briefing"
	"watchtower/internal/caldav"
	"watchtower/internal/calendar"
	"watchtower/internal/config"
	"watchtower/internal/customtracks"
	"watchtower/internal/daemon"
	"watchtower/internal/dayplan"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/gmail"
	"watchtower/internal/guide"
	"watchtower/internal/imap"
	"watchtower/internal/inbox"
	"watchtower/internal/jira"
	"watchtower/internal/prompts"
	watchtowerslack "watchtower/internal/slack"
	"watchtower/internal/sync"
	"watchtower/internal/targets"
	"watchtower/internal/tracks"
	"watchtower/internal/ui"

	"github.com/spf13/cobra"
	"golang.org/x/term"
)

var (
	syncFlagFull         bool
	syncFlagDaemon       bool
	syncFlagDetach       bool
	syncFlagStop         bool
	syncFlagNow          bool
	syncFlagChannels     []string
	syncFlagWorkers      int
	syncFlagSkipDMs      bool
	syncFlagDays         int
	syncFlagProgressJSON bool
	syncFlagNoPipelines  bool
	syncStopFlagForce    bool
)

var syncCmd = &cobra.Command{
	Use:   "sync",
	Short: "Sync Slack workspace data to local database",
	Long:  "Fetches workspace metadata, messages, and threads from Slack and stores them in the local SQLite database.",
	RunE:  runSync,
}

var syncStopCmd = &cobra.Command{
	Use:   "stop",
	Short: "Stop a running detached daemon",
	RunE:  runSyncStopCmd,
}

func init() {
	rootCmd.AddCommand(syncCmd)
	syncCmd.AddCommand(syncStopCmd)
	syncStopCmd.Flags().BoolVar(&syncStopFlagForce, "force", false, "if the daemon does not stop within the grace period, escalate to SIGKILL")
	syncCmd.Flags().BoolVar(&syncFlagFull, "full", false, "re-fetch all history within the initial history window")
	syncCmd.Flags().BoolVar(&syncFlagDaemon, "daemon", false, "run in daemon mode with periodic syncing")
	syncCmd.Flags().BoolVar(&syncFlagDetach, "detach", false, "start daemon in the background (requires --daemon)")
	syncCmd.Flags().BoolVar(&syncFlagStop, "stop", false, "stop a running detached daemon")
	syncCmd.Flags().BoolVar(&syncFlagNow, "now", false, "ask the running daemon to sync immediately instead of waiting for its next poll")
	syncCmd.Flags().StringSliceVar(&syncFlagChannels, "channels", nil, "limit sync to specific channel names or IDs")
	syncCmd.Flags().IntVar(&syncFlagWorkers, "workers", 0, "number of concurrent sync workers (0 = use config default)")
	syncCmd.Flags().BoolVar(&syncFlagSkipDMs, "skip-dms", false, "skip syncing DMs and group DMs")
	syncCmd.Flags().BoolVar(&syncFlagProgressJSON, "progress-json", false, "output progress as JSON lines to stdout")
	syncCmd.Flags().IntVar(&syncFlagDays, "days", 0, "override initial_history_days for this run")
	syncCmd.Flags().BoolVar(&syncFlagNoPipelines, "no-pipelines", false, "sync messages only, skip digest/tracks/people/briefing pipelines")
}

func runSyncStopCmd(cmd *cobra.Command, args []string) error {
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
	return runSyncStop(cfg, syncStopFlagForce)
}

func pidFilePath(cfg *config.Config) string {
	return filepath.Join(cfg.WorkspaceDir(), "daemon.pid")
}

func logFilePath(cfg *config.Config) string {
	return filepath.Join(cfg.WorkspaceDir(), "daemon.log")
}

func syncLogFilePath(cfg *config.Config) string {
	return filepath.Join(cfg.WorkspaceDir(), "watchtower.log")
}

func syncResultPath(cfg *config.Config) string {
	return filepath.Join(cfg.WorkspaceDir(), "last_sync.json")
}

// maxLogSize is the size past which a log file is rotated: the current file
// is renamed to "<name>.1" (replacing the previous generation) and a fresh
// file is started. daemon.log is checked at open (runSyncDetach); the
// daemon's own stream, watchtower.log, is additionally kept under the cap
// while the process runs, by the rotatingFile writer in logfile.go.
const maxLogSize = 20 * 1024 * 1024

// rotateLogIfOversized renames path to path+".1" when the file exceeds
// maxLogSize, so the next open starts fresh. The returned error is for
// logging only — rotation must never block a sync, so the caller proceeds
// and appends to the existing file on failure.
func rotateLogIfOversized(path string) error {
	return rotateLogIfLargerThan(path, maxLogSize)
}

// rotateLogIfLargerThan is rotateLogIfOversized with the cap supplied by the
// caller, so rotatingFile can share exactly these rename semantics under the
// small cap its tests inject.
func rotateLogIfLargerThan(path string, maxSize int64) error {
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("stat %s: %w", path, err)
	}
	if info.Size() <= maxSize {
		return nil
	}
	// os.Rename replaces an existing ".1" atomically on POSIX.
	if err := os.Rename(path, path+".1"); err != nil {
		return fmt.Errorf("rename %s: %w", path, err)
	}
	return nil
}

// syncStopGracePeriod is how long a plain "sync stop" waits for the daemon
// to exit after SIGTERM before giving up and printing the --force hint.
// A package var, not a config key, so tests can shrink it instead of
// waiting out the real 10s (see the daemon-shutdown-hang RCA §6c).
var syncStopGracePeriod = 10 * time.Second

// syncStopForceGracePeriod is how long "sync stop --force" waits after
// escalating to a second SIGTERM — which, after cmd/shutdown.go's
// notifyShutdownContext fix, terminates outright any command built on it —
// before resorting to SIGKILL, and again after SIGKILL before giving up.
// A package var for the same reason as syncStopGracePeriod.
var syncStopForceGracePeriod = 5 * time.Second

// syncStopPollInterval is the liveness-poll tick used while waiting out
// either grace period above. A package var so tests using a shrunk grace
// period can shrink this too and still get several polls in the window.
var syncStopPollInterval = 200 * time.Millisecond

// errProcessGone marks a signal delivery that failed only because the
// target process had already exited between our last liveness check and
// the kill(2) call — not a real error.
var errProcessGone = errors.New("process already exited")

// verifyDaemonAlive re-confirms, immediately before forceStopSync escalates
// to a further signal, that pid still refers to the same watchtower daemon
// FindProcess resolved earlier in runSyncStop — never assumed to still hold
// after a multi-second grace-period wait. It re-runs daemon.FindProcess
// against pidPath rather than a bare liveness check: FindProcess applies
// the same identity check (isReusedPID, via `ps`'s process name) FindProcess
// used to resolve pid in the first place, and — as a side effect — removes
// the pid file itself once it decides the process is gone or reused, so a
// false return here has already cleaned up the stale file. A false return
// also covers the case where the pid file now names a *different* pid (a
// fresh daemon started in the meantime): forceStopSync must not touch that
// process either, and must not remove its still-valid pid file.
//
// A package var, not a plain function, so tests can simulate "gone/reused"
// deterministically (real PID reuse is not something a test can force) —
// the daemon-shutdown-hang RCA's package-var-seam precedent
// (syncStopGracePeriod et al.).
var verifyDaemonAlive = func(pidPath string, pid int) bool {
	current, err := daemon.FindProcess(pidPath)
	if err != nil {
		// Unable to determine identity — conservatively assume it is still
		// the daemon rather than silently abandoning an in-progress forced
		// stop.
		return true
	}
	return current == pid
}

func runSyncStop(cfg *config.Config, force bool) error {
	pidPath := pidFilePath(cfg)
	pid, err := daemon.FindProcess(pidPath)
	if err != nil {
		return fmt.Errorf("reading pid file: %w", err)
	}
	if pid == 0 {
		fmt.Println("No daemon is running.")
		return nil
	}

	fmt.Printf("Stopping daemon (PID %d)...\n", pid)
	if err := signalStop(pid, syscall.SIGTERM); err != nil {
		if err == errProcessGone {
			daemon.RemovePID(pidPath)
			fmt.Println("Daemon stopped.")
			return nil
		}
		return fmt.Errorf("sending SIGTERM: %w", err)
	}

	if waitForProcessExit(pid, syncStopGracePeriod) {
		daemon.RemovePID(pidPath)
		fmt.Println("Daemon stopped.")
		return nil
	}

	if !force {
		fmt.Printf("Daemon (PID %d) is still shutting down; run 'watchtower sync stop --force' to kill it\n", pid)
		return fmt.Errorf("daemon (PID %d) did not exit within %s", pid, syncStopGracePeriod)
	}
	return forceStopSync(pidPath, pid)
}

// forceStopSync escalates against a daemon that ignored the initial
// SIGTERM: a second SIGTERM — which notifyShutdownContext's second-signal
// fix turns into an immediate kill for any command built on it (RCA §6b) —
// and, failing that, SIGKILL. SIGKILL is never the default stop path
// (global constraint #7); it only runs here, after --force was explicitly
// requested and a plain SIGTERM already timed out.
//
// pid was resolved once, up to syncStopGracePeriod (10s) ago, by the
// FindProcess call in runSyncStop. Each grace-period wait below is another
// window in which the daemon can exit and the OS can hand pid to an
// unrelated process — so immediately before EVERY signal after the first
// (the second SIGTERM, and SIGKILL), verifyDaemonAlive re-confirms pid is
// still the same watchtower daemon before escalating. Skipping that
// re-check risks SIGKILLing a process we never meant to touch.
func forceStopSync(pidPath string, pid int) error {
	if !verifyDaemonAlive(pidPath, pid) {
		fmt.Printf("Daemon (PID %d) already exited; nothing more to stop.\n", pid)
		return nil
	}
	fmt.Printf("Daemon (PID %d) still running; sending a second SIGTERM...\n", pid)
	if err := signalStop(pid, syscall.SIGTERM); err != nil {
		if err == errProcessGone {
			daemon.RemovePID(pidPath)
			fmt.Printf("Daemon (PID %d) stopped (SIGTERM).\n", pid)
			return nil
		}
		return fmt.Errorf("sending second SIGTERM: %w", err)
	}
	if waitForProcessExit(pid, syncStopForceGracePeriod) {
		daemon.RemovePID(pidPath)
		fmt.Printf("Daemon (PID %d) stopped (SIGTERM).\n", pid)
		return nil
	}

	if !verifyDaemonAlive(pidPath, pid) {
		fmt.Printf("Daemon (PID %d) already exited; nothing more to stop.\n", pid)
		return nil
	}
	fmt.Printf("Daemon (PID %d) still running; sending SIGKILL...\n", pid)
	if err := signalStop(pid, syscall.SIGKILL); err != nil {
		if err == errProcessGone {
			daemon.RemovePID(pidPath)
			fmt.Printf("Daemon (PID %d) stopped (SIGKILL).\n", pid)
			return nil
		}
		return fmt.Errorf("sending SIGKILL: %w", err)
	}
	if !waitForProcessExit(pid, syncStopForceGracePeriod) {
		return fmt.Errorf("daemon (PID %d) did not exit even after SIGKILL", pid)
	}
	daemon.RemovePID(pidPath)
	fmt.Printf("Daemon (PID %d) stopped (SIGKILL).\n", pid)
	return nil
}

// signalStop sends sig to pid, treating "no such process" as success (the
// process exited in the gap between our last liveness poll and this
// signal) rather than an error.
func signalStop(pid int, sig syscall.Signal) error {
	if err := syscall.Kill(pid, sig); err != nil {
		if errors.Is(err, syscall.ESRCH) {
			return errProcessGone
		}
		return err
	}
	return nil
}

// waitForProcessExit polls pid's liveness until it is gone or grace
// elapses, returning whether it exited within the window.
func waitForProcessExit(pid int, grace time.Duration) bool {
	deadline := time.Now().Add(grace)
	for {
		if syscall.Kill(pid, 0) != nil {
			return true
		}
		if !time.Now().Before(deadline) {
			return false
		}
		time.Sleep(syncStopPollInterval)
	}
}

// runSyncNow asks a running daemon to start a sync now. It deliberately does
// not fall back to syncing in this process: the daemon holds an exclusive
// flock on sync.lock, so a local sync would fail on the lock anyway, and a
// second syncer racing the daemon is exactly what that lock exists to prevent.
func runSyncNow(cfg *config.Config) error {
	pidPath := pidFilePath(cfg)
	pid, err := daemon.FindProcess(pidPath)
	if err != nil {
		return fmt.Errorf("reading pid file: %w", err)
	}
	if pid == 0 {
		return errors.New("no daemon is running (start one with: watchtower sync --daemon --detach)")
	}
	if err := syscall.Kill(pid, daemon.TriggerSignal); err != nil {
		return fmt.Errorf("signalling daemon (PID %d): %w", pid, err)
	}
	fmt.Printf("Sync requested (daemon PID %d).\n", pid)
	return nil
}

func runSyncDetach(cfg *config.Config) error {
	pidPath := pidFilePath(cfg)
	pid, err := daemon.FindProcess(pidPath)
	if err != nil {
		return fmt.Errorf("checking existing daemon: %w", err)
	}
	if pid != 0 {
		return fmt.Errorf("daemon already running (PID %d)", pid)
	}

	logPath := logFilePath(cfg)
	if err := os.MkdirAll(filepath.Dir(logPath), 0o755); err != nil {
		return fmt.Errorf("creating log directory: %w", err)
	}

	rotationErr := rotateLogIfOversized(logPath)
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return fmt.Errorf("opening log file: %w", err)
	}
	defer logFile.Close()
	if rotationErr != nil {
		fmt.Fprintf(logFile, "%s log rotation: %v (continuing without rotation)\n",
			time.Now().Format("2006/01/02 15:04:05"), rotationErr)
	}

	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("finding executable: %w", err)
	}

	// Re-exec ourselves with the detach env var set.
	child := exec.Command(exe, os.Args[1:]...)
	child.Env = append(os.Environ(), daemon.DetachEnvKey+"=1")
	child.Stdout = logFile
	child.Stderr = logFile
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}

	if err := child.Start(); err != nil {
		return fmt.Errorf("starting daemon: %w", err)
	}

	fmt.Printf("Daemon started (PID %d)\n", child.Process.Pid)
	fmt.Printf("Log: %s\n", logPath)
	return nil
}

// validateSyncConfig checks what a sync needs from config.yaml: a usable
// active_workspace. Slack is optional — without a token the daemon still runs
// (Calendar, Gmail, Jira keep syncing) and only the Slack phase is skipped.
// A missing `workspaces.<name>` block is fine too: since Slack multi-account
// the token lives in slack_token_<id>.json and `auth login` no longer writes
// that block, so a fresh install has none. Only a legacy config-embedded
// token, when present, is still validated for shape. Deliberately dropped
// with it: the old side effect of rejecting an active_workspace absent from
// a non-empty legacy block — that block is a migration remnant, not a
// registry of valid workspaces, and no other command ever consulted it.
func validateSyncConfig(cfg *config.Config) error {
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}
	if legacySlackConfigToken(cfg) != "" {
		if err := cfg.Validate(); err != nil {
			return fmt.Errorf("invalid config: %w", err)
		}
	}
	return nil
}

func runSync(cmd *cobra.Command, args []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)

	// --stop only needs workspace validation (no Slack token).
	if syncFlagStop {
		if err := cfg.ValidateWorkspace(); err != nil {
			return fmt.Errorf("invalid config: %w", err)
		}
		return runSyncStop(cfg, false)
	}

	// --now signals the running daemon; like --stop it never syncs in this
	// process, so it needs no Slack token either.
	if syncFlagNow {
		if err := cfg.ValidateWorkspace(); err != nil {
			return fmt.Errorf("invalid config: %w", err)
		}
		return runSyncNow(cfg)
	}

	if err := validateSyncConfig(cfg); err != nil {
		return err
	}

	// --detach re-execs the process in the background.
	// Skip if we're already the detached child (env key is set).
	if syncFlagDetach && os.Getenv(daemon.DetachEnvKey) != "1" {
		if !syncFlagDaemon {
			return fmt.Errorf("--detach requires --daemon")
		}
		return runSyncDetach(cfg)
	}

	// Acquire exclusive lock to prevent concurrent syncs.
	lockPath := filepath.Join(cfg.WorkspaceDir(), "sync.lock")
	if err := os.MkdirAll(filepath.Dir(lockPath), 0o755); err != nil {
		return fmt.Errorf("creating workspace directory: %w", err)
	}
	lockFile, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return fmt.Errorf("opening lock file: %w", err)
	}
	defer lockFile.Close()
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return fmt.Errorf("another sync is already running (lock: %s)", lockPath)
	}
	defer func() { _ = syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN) }()

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	// Every log line goes to watchtower.log, which the rotating writer keeps
	// under maxLogSize while the daemon runs; stderr is added only under
	// --verbose (see logWriterFor for why a detached child must not get it).
	logFile, err := newSyncLogWriter(cfg)
	if err != nil {
		return err
	}
	defer func() { _ = logFile.Close() }()

	isDetachedChild := os.Getenv(daemon.DetachEnvKey) == "1"
	logger := log.New(logWriterFor(logFile, flagVerbose, isDetachedChild), "", log.LstdFlags)
	if syncFlagDaemon {
		defer routeStdLog(logger)()
	}

	ctx, cancel := notifyShutdownContext(context.Background(), logger.Printf)
	defer cancel()

	// Seed slack_accounts from a pre-multi-account legacy token (config.yaml)
	// before wiring, so a single-account install keeps syncing without a
	// re-login: the migration seeds row #1 but only Go can move the token out
	// of config into slack_token_<id>.json, which wireSlackSyncers requires.
	if _, err := ensureLegacySlackAccount(ctx, cfg, database, logger); err != nil {
		logger.Printf("slack: failed to seed legacy account: %v", err)
	}
	// Wire one Slack sync orchestrator per connected, enabled slack_accounts row.
	orchestrators := wireSlackSyncers(database, cfg, logger)

	// Daemon mode: run periodic syncs until interrupted
	if syncFlagDaemon {
		return runSyncDaemon(ctx, cfg, database, logger, orchestrators)
	}

	// One-shot sync is a Slack sync — nothing to do without a connected account.
	if len(orchestrators) == 0 {
		return fmt.Errorf("slack is not connected for workspace %q; run 'watchtower auth login' first", cfg.ActiveWorkspace)
	}

	// Override initial_history_days if --days specified
	if syncFlagDays > 0 {
		cfg.Sync.InitialHistoryDays = syncFlagDays
	}

	opts := sync.SyncOptions{
		Full:     syncFlagFull,
		Channels: syncFlagChannels,
		Workers:  syncFlagWorkers,
		SkipDMs:  syncFlagSkipDMs,
	}

	out := cmd.OutOrStdout()

	// In verbose mode: just run sync, logs go to stderr. Each connected
	// account's orchestrator runs in turn; one account's failure is recorded
	// but does not block the others (the fan-out pattern), and a single
	// aggregated result is written.
	if flagVerbose {
		var snaps []sync.Snapshot
		var firstErr error
		for _, o := range orchestrators {
			syncErr := o.Run(ctx, opts)
			snap := o.Progress().Snapshot()
			snaps = append(snaps, snap)
			if syncErr != nil && firstErr == nil {
				firstErr = syncErr
			}
			elapsed := time.Since(snap.StartTime).Round(time.Second)
			fmt.Fprintf(out, "Sync complete in %s: %d messages synced.\n",
				elapsed, snap.MessagesFetched)
		}
		if err := sync.WriteSyncResult(syncResultPath(cfg), sync.ResultFromSnapshots(snaps, firstErr)); err != nil {
			logger.Printf("warning: failed to write sync result: %v", err)
		}
		if firstErr != nil {
			return fmt.Errorf("sync failed: %w", firstErr)
		}
		if !syncFlagNoPipelines {
			runPostSyncPipelines(ctx, database, cfg, logger)
		}
		return nil
	}

	// Normal mode: progress display in background. Each connected account's
	// orchestrator runs in turn with its own progress display; failures are
	// recorded but do not block the remaining accounts (the fan-out pattern),
	// and a single aggregated result is written after all accounts finish.
	snaps, firstErr := runOrchestratorsWithProgress(ctx, orchestrators, opts, out, cfg)

	if wErr := sync.WriteSyncResult(syncResultPath(cfg), sync.ResultFromSnapshots(snaps, firstErr)); wErr != nil {
		logger.Printf("warning: failed to write sync result: %v", wErr)
	}
	if firstErr != nil {
		return fmt.Errorf("sync failed: %w", firstErr)
	}
	// Skip post-sync pipelines in --progress-json mode: the desktop app
	// runs them independently via BackgroundTaskManager after onboarding.
	if !syncFlagProgressJSON && !syncFlagNoPipelines {
		runPostSyncPipelines(ctx, database, cfg, logger)
	}
	return nil
}

// runOrchestratorsWithProgress runs each orchestrator in turn against opts,
// rendering a live progress display to out while it syncs (a ticker repaints
// the display every 500ms; a panic inside Run is recovered and reported as
// that orchestrator's error rather than crashing the process). One account's
// failure is recorded but does not block the remaining accounts — the
// fan-out pattern used throughout this file — so the returned snapshots
// always cover every orchestrator passed in, and the returned error is only
// the first one encountered.
func runOrchestratorsWithProgress(ctx context.Context, orchestrators []*sync.Orchestrator, opts sync.SyncOptions, out io.Writer, cfg *config.Config) ([]sync.Snapshot, error) {
	progressLines.Store(0)
	var snaps []sync.Snapshot
	var firstErr error
	for _, o := range orchestrators {
		done := make(chan error, 1)
		go func() {
			defer func() {
				if r := recover(); r != nil {
					done <- fmt.Errorf("sync panicked: %v\n%s", r, debug.Stack())
				}
			}()
			done <- o.Run(ctx, opts)
		}()

		ticker := time.NewTicker(500 * time.Millisecond)
	accountLoop:
		for {
			select {
			case syncErr := <-done:
				snap := o.Progress().Snapshot()
				snaps = append(snaps, snap)
				if syncFlagProgressJSON {
					printProgressJSON(out, snap, syncErr)
				} else {
					printProgress(out, o.Progress(), cfg.ActiveWorkspace)
				}
				if syncErr != nil && firstErr == nil {
					firstErr = syncErr
				}
				ticker.Stop()
				break accountLoop
			case <-ticker.C:
				snap := o.Progress().Snapshot()
				if syncFlagProgressJSON {
					printProgressJSON(out, snap, nil)
				} else {
					printProgress(out, o.Progress(), cfg.ActiveWorkspace)
				}
			}
		}
	}
	return snaps, firstErr
}

// migrateJiraFeatureKeys runs the one-time jira.features key repair and
// returns the config the daemon should run with: the reloaded one when the
// repair actually moved a value, otherwise cfg untouched. Log-only on
// failure — an unrepaired file reads exactly as it did before, which is the
// pre-repair status quo rather than a fail-open, and the next start retries.
//
// Daemon start is the ONLY caller that reaches an install which never opens
// `jira features`, i.e. every Desktop-only owner, so the call site in
// runSyncDaemon is load-bearing and pinned by
// TestRunSyncDaemon_CallsTheJiraFeatureKeyMigration.
func migrateJiraFeatureKeys(cfg *config.Config, logger *log.Logger) *config.Config {
	repaired, err := config.MigrateJiraFeatureKeys(flagConfig)
	if err != nil {
		logger.Printf("jira feature-key migration error: %v (continuing with current config)", err)
		return cfg
	}
	if !repaired {
		return cfg
	}
	freshCfg, err := config.Load(flagConfig)
	if err != nil {
		logger.Printf("failed to reload config after jira feature-key migration: %v (continuing with current config)", err)
		return cfg
	}
	logger.Printf("jira feature-key migration applied; config reloaded")
	return freshCfg
}

// runSyncDaemon builds a daemon.Daemon around the already-wired Slack
// orchestrators, attaches every pipeline stage (unconditionally — each
// pipeline's own daemon phase gates its execution on that feature's own
// config flag, see internal/daemon/daemon.go) plus one syncer per connected
// Jira/Google/IMAP/CalDAV account (seeding each source's legacy
// single-account config into its accounts table first, so an existing install
// keeps syncing without a re-login), and runs it until ctx is cancelled. A
// source that fails to seed or wire records its own error and is skipped —
// the fan-out pattern shared by wireJiraSyncers/wireGoogleSyncers/
// wireImapSyncers/wireCalDAVSyncers — so one broken account never blocks the
// rest of the daemon from starting.
func runSyncDaemon(ctx context.Context, cfg *config.Config, database *db.DB, logger *log.Logger, orchestrators []*sync.Orchestrator) error {
	// Perform the one-time feature-gate migration (and its first-contact
	// marker stamp) for digest.enabled=false installs. On a real migration,
	// reload the config so this daemon process uses the migrated values.
	legacyDigestOff, err := config.MigrateFeatureGates(flagConfig)
	switch {
	case err != nil && legacyDigestOff:
		// The mapping could not be persisted on an install that still needs
		// it. Honoring the raw config here would turn nine AI features ON
		// for an owner who believes everything is off — and spend tokens
		// proving it. Fail closed for this process; the next start retries
		// the on-disk write.
		logger.Printf("feature-gate migration failed: %v — running FAIL-CLOSED with all AI features off this session; fix the config file and restart", err)
		config.ApplyLegacyDigestOff(cfg)
	case err != nil:
		logger.Printf("feature-gate migration error: %v (continuing with current config)", err)
	case legacyDigestOff:
		freshCfg, err := config.Load(flagConfig)
		if err != nil {
			logger.Printf("failed to reload config after feature-gate migration: %v (applying it in memory instead)", err)
			config.ApplyLegacyDigestOff(cfg)
		} else {
			cfg = freshCfg
			logger.Printf("feature-gate migration applied; config reloaded")
		}
	}

	cfg = migrateJiraFeatureKeys(cfg, logger)

	d := daemon.New(cfg)
	d.SetOrchestrators(orchestrators)
	d.SetLogger(logger)
	d.SetDB(database)
	d.SetPIDPath(pidFilePath(cfg))
	// Every pipeline is constructed unconditionally now (Task 3 demoted
	// digest.enabled from a master switch to a per-phase gate) — each is a
	// cheap struct, and the daemon's own phase methods gate execution on
	// their own feature's config flag (internal/daemon/daemon.go), not on
	// whether it was wired here.
	gen, cleanupPool := cliPooledGenerator(cfg, logger)
	defer cleanupPool()
	tracksPipe := tracks.New(database, cfg, gen, logger)
	tracksPipe.SetPromptStore(prompts.New(database, nil))
	pipe := digest.New(database, cfg, gen, logger)
	pipe.SetPromptStore(prompts.New(database, nil))
	pipe.TrackLinker = tracksPipe
	// One shared detector across both pipelines, so the known-project-key set
	// is loaded once rather than once per pipeline.
	if det := newJiraKeyDetector(cfg, database, logger); det != nil {
		pipe.SetJiraKeyDetector(det)
		tracksPipe.SetJiraKeyDetector(det)
	}
	d.SetDigestPipeline(pipe)
	d.SetTracksPipeline(tracksPipe)
	peoplePipe := guide.New(database, cfg, gen, logger)
	peoplePipe.SetPromptStore(prompts.New(database, nil))
	d.SetPeoplePipeline(peoplePipe)
	briefingPipe := briefing.New(database, cfg, gen, logger)
	briefingPipe.SetPromptStore(prompts.New(database, nil))
	d.SetBriefingPipeline(briefingPipe)
	d.SetInboxPipeline(inbox.New(database, cfg, gen, logger))
	wireIdeasPipeline(d, database, cfg, gen, logger)
	wireReactionCommandsPipeline(d, database, cfg, gen, logger)
	wireMemoryPipeline(d, database, cfg, logger)
	nextStepPipe := targets.New(database, &cfg.Targets, gen, nil, cfg.Digest.Language, logger)
	nextStepPipe.SetPromptStore(prompts.New(database, nil))
	d.SetNextStepPipeline(nextStepPipe)
	customTracksPipe := customtracks.New(database, gen, cfg.Digest.Language, logger)
	d.SetCustomTracksPipeline(customTracksPipe)
	dayPlanPipe := dayplan.New(database, cfg, gen, logger)
	dayPlanPipe.SetPromptStore(prompts.New(database, nil))
	d.SetDayPlanPipeline(dayPlanPipe)
	// Seed jira_accounts from a pre-multi-account legacy token file
	// before wiring, so a single-account install keeps syncing without
	// a re-login.
	if _, err := ensureLegacyJiraAccount(cfg, database, logger); err != nil {
		logger.Printf("jira: failed to seed legacy account: %v", err)
	}
	// Wire one Jira syncer per connected, enabled jira_accounts row.
	wireJiraSyncers(ctx, d, cfg, database, logger)
	// Seed google_accounts from a pre-multi-account legacy token file
	// before wiring, so a single-account install keeps syncing without
	// a re-login.
	if _, err := ensureLegacyGoogleAccount(ctx, cfg, database, logger); err != nil {
		logger.Printf("google: failed to seed legacy account: %v", err)
	}
	// Wire one calendar/gmail syncer per connected google_accounts row.
	wireGoogleSyncers(ctx, d, cfg, database, logger)
	// Wire one IMAP/Outlook syncer per connected email_accounts row.
	wireImapSyncers(ctx, d, cfg, database, logger)
	// Wire one CalDAV/ICS syncer per connected calendar_accounts row.
	wireCalDAVSyncers(d, cfg, database, logger)
	// Refresh the shipped assistant skills in the workspace. Log-only: a skills
	// directory we cannot write is not a reason to refuse to run the daemon.
	deployShippedSkills(cfg, logger)
	return d.Run(ctx)
}

// wireSlackSyncers builds one sync.Orchestrator per connected, enabled Slack
// account (slack_accounts row) whose per-account token file exists. An account
// with a missing or unreadable token is skipped and logged rather than
// aborting the rest — the wireImapSyncers/wireGoogleSyncers fan-out pattern.
// Returns an empty slice when no account is connected (Slack simply doesn't
// sync; the other sources still run).
func wireSlackSyncers(database *db.DB, cfg *config.Config, logger *log.Logger) []*sync.Orchestrator {
	accounts, err := database.ListEnabledSlackAccounts()
	if err != nil {
		logger.Printf("slack: failed to list accounts: %v", err)
		return nil
	}
	// One detector shared by every account's orchestrator: its known-key cache
	// is workspace-wide (jira_slack_links is deliberately not account-scoped)
	// and its only mutable state is behind a mutex.
	keyDetector := newJiraKeyDetector(cfg, database, logger)
	var orchestrators []*sync.Orchestrator
	for _, acct := range accounts {
		store := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), acct.ID)
		token, err := store.Load()
		if err != nil {
			logger.Printf("slack: account %d: failed to load token: %v", acct.ID, err)
			recordSlackWireError(database, logger, acct.ID, acct.Status, err)
			continue
		}
		if token == nil {
			logger.Printf("slack: account %d: no token file, skipping", acct.ID)
			recordSlackWireError(database, logger, acct.ID, acct.Status, fmt.Errorf("no token file — re-login required"))
			continue
		}
		client := watchtowerslack.NewClient(token.AccessToken)
		client.SetLogger(logger)
		orch := sync.NewOrchestrator(database, client, cfg, acct.ID)
		orch.SetLogger(logger)
		if keyDetector != nil {
			orch.SetJiraKeyDetector(keyDetector)
		}
		orchestrators = append(orchestrators, orch)
	}
	return orchestrators
}

// recordSlackWireError records a per-account wiring failure (missing/unreadable
// token — before an Orchestrator ever exists to self-report via
// Orchestrator.recordAuthResult) so the Desktop UI shows the account needs
// re-login instead of staying silently "ok" forever. Only flips a currently-
// "ok" account to "error" — one already flagged error/revoked stays as-is,
// so this doesn't churn the status/updated_at on every daemon cycle (the
// wireGoogleSyncers precedent).
func recordSlackWireError(database *db.DB, logger *log.Logger, accountID int64, currentStatus string, err error) {
	if currentStatus != "ok" {
		return
	}
	if dbErr := database.SetSlackAccountAuthState(accountID, "error", err.Error()); dbErr != nil {
		logger.Printf("slack: account %d: record auth state: %v", accountID, dbErr)
	}
}

// jiraCommentSyncEnabled reports whether wireJiraSyncers should turn on
// bounded Jira comment sync — gated on streams.enabled now that the stream
// digests (internal/ideas stage 1), not the ideas registry consolidator
// (stage 2), own the comment feed.
func jiraCommentSyncEnabled(cfg *config.Config) bool {
	return cfg.Streams.Enabled
}

// wireJiraSyncers wires one Jira syncer per connected, enabled jira_accounts
// row whose token file exists. A broken account records its own auth-state
// error rather than aborting the wiring step for the others — the
// wireGoogleSyncers fan-out pattern. The global cfg.Jira.Enabled toggle gates
// the whole phase, matching every other daemon phase's on/off switch. Zero
// accounts is a clean no-op.
//
// It also lazily fills the Jira rung of the owner ladder (Task 2): an
// account wired here that has never recorded its /myself identity gets one
// attempt per daemon start via maybeRecordJiraOwner, so an install that
// connected before this feature shipped catches up without a re-login.
func wireJiraSyncers(ctx context.Context, d *daemon.Daemon, cfg *config.Config, database *db.DB, logger *log.Logger) {
	if !cfg.Jira.Enabled {
		return
	}
	accounts, err := database.ListEnabledJiraAccounts()
	if err != nil {
		logger.Printf("jira: failed to list accounts: %v", err)
		return
	}
	jiraCfg := resolveJiraOAuthConfig()
	var syncers []*jira.Syncer
	for _, acct := range accounts {
		store := jira.NewTokenStore(cfg.WorkspaceDir(), acct.ID)
		if acct.CloudID == "" || !store.Exists() {
			// Only flip a currently-"ok" account to "error" — an account
			// already flagged error/revoked stays as-is, so this doesn't
			// churn the status on every daemon cycle.
			if acct.Status == "ok" {
				if err := database.SetJiraAccountAuthState(acct.ID, "error", "no token or site — re-login required"); err != nil {
					logger.Printf("jira: account %d: record auth state: %v", acct.ID, err)
				}
			}
			continue
		}
		client := jira.NewClient(acct.CloudID, jiraCfg, store)
		client.SetLogger(subLogger(logger, "[jira] "))
		maybeRecordJiraOwner(ctx, logger.Writer(), database, acct, client)
		mapper := jira.NewUserMapper(client, database)
		mapper.SetLogger(subLogger(logger, "[jira-users] "))
		boards, err := database.GetJiraSelectedBoards(acct.ID)
		if err != nil {
			logger.Printf("jira: account %d: failed to load selected boards: %v", acct.ID, err)
			continue
		}
		boardIDs := make([]int, len(boards))
		for i, b := range boards {
			boardIDs[i] = b.ID
		}
		syncer := jira.NewSyncer(client, database, mapper, boardIDs, acct.ID)
		syncer.SetLogger(subLogger(logger, "[jira-sync] "))
		// Bounded comment sync feeds the stream digests' Jira pre-digest
		// (internal/ideas stage 1); it stays off (0 = disabled) unless the
		// stream digests phase itself is on — decoupled from ideas.enabled
		// since the registry consolidator (stage 2) no longer owns the
		// comment feed.
		if jiraCommentSyncEnabled(cfg) {
			syncer.SetCommentSyncLimit(cfg.Ideas.MaxCommentIssuesPerSync)
		}
		// Wire board analyzer for auto-refresh of changed configs. This
		// serves Boards, not digests, so it attaches whenever the account
		// itself is wired — no longer behind cfg.Digest.Enabled (Task 3).
		aiProvider := newAIClient(cfg, cfg.DBPath())
		analyzer := jira.NewBoardAnalyzer(client, database, aiProvider, acct.ID)
		analyzer.SetLogger(subLogger(logger, "[jira-analyzer] "))
		analyzer.SetLanguage(cfg.Digest.Language)
		syncer.SetBoardAnalyzer(analyzer)
		syncer.SetAutoRefresh(true)
		syncers = append(syncers, syncer)
	}
	d.SetJiraSyncers(syncers)
}

// newJiraKeyDetector is jira.NewKeyDetectorIfEnabled with the detector's
// logger moved onto the sync command's stream (its default is os.Stderr, which
// is daemon.log for a detached child). Returns a nil *jira.KeyDetector when
// Jira is off, so callers keep their nil check.
func newJiraKeyDetector(cfg *config.Config, database *db.DB, logger *log.Logger) *jira.KeyDetector {
	det := jira.NewKeyDetectorIfEnabled(cfg, database)
	if det != nil {
		det.SetLogger(subLogger(logger, "[jira-keys] "))
	}
	return det
}

// wireGoogleSyncers wires one calendar.Syncer and/or gmail.Syncer per
// connected google_accounts row whose token store exists, using each
// account's own OAuth client credentials when it brought one. A broken
// account records its own auth-state error (e.g. revoked grants) rather than
// aborting the wiring step for the others — the calendar/gmail analog of
// wireImapSyncers/wireCalDAVSyncers. The global cfg.Calendar.Enabled /
// cfg.Gmail.Enabled toggles gate the corresponding syncer kind across every
// account, matching every other daemon phase's global on/off switch.
func wireGoogleSyncers(ctx context.Context, d *daemon.Daemon, cfg *config.Config, database *db.DB, logger *log.Logger) {
	accounts, err := database.ListGoogleAccounts()
	if err != nil {
		logger.Printf("google: failed to list accounts: %v", err)
		return
	}
	var calSyncers []*calendar.Syncer
	var gmSyncers []*gmail.Syncer
	for _, acct := range accounts {
		store := calendar.NewAccountTokenStore(cfg.WorkspaceDir(), acct.ID)
		if !store.Exists() {
			// Only flip a currently-"ok" account to "error" — an account
			// already flagged error/revoked stays as-is, so this doesn't
			// churn the status/updated_at on every daemon cycle.
			if acct.Status == "ok" {
				if err := database.SetGoogleAccountAuthState(acct.ID, "error", "no token file — re-login required"); err != nil {
					logger.Printf("google: account %d: record auth state: %v", acct.ID, err)
				}
			}
			continue
		}
		token, err := store.Load()
		if err != nil {
			logger.Printf("google: account %d: failed to load token: %v", acct.ID, err)
			continue
		}
		googleCfg := resolveGoogleOAuthConfigForAccount(cfg.WorkspaceDir(), acct.ID)
		if cfg.Calendar.Enabled && acct.CalendarEnabled {
			calClient, err := calendar.NewClient(ctx, token.RefreshToken, googleCfg)
			if err != nil {
				recordGoogleWireError(database, logger, acct.ID, "calendar", err, errors.Is(err, calendar.ErrAuthRevoked))
			} else {
				calSyncers = append(calSyncers, calendar.NewSyncer(calClient, database, cfg, logger, acct.ID))
			}
		}
		if cfg.Gmail.Enabled && acct.GmailEnabled {
			gmClient, err := gmail.NewClient(ctx, token.RefreshToken,
				gmail.GoogleOAuthConfig{ClientID: googleCfg.ClientID, ClientSecret: googleCfg.ClientSecret})
			if err != nil {
				recordGoogleWireError(database, logger, acct.ID, "gmail", err, errors.Is(err, gmail.ErrAuthRevoked))
			} else {
				gmSyncers = append(gmSyncers, gmail.NewSyncer(gmClient, database, cfg, logger, acct.ID))
			}
		}
	}
	d.SetCalendarSyncers(calSyncers)
	d.SetGmailSyncers(gmSyncers)
}

// recordGoogleWireError logs a per-account client-creation failure and
// records its auth-state (revoked vs plain error) so the Desktop UI shows
// the problem instead of a silently-dead account.
func recordGoogleWireError(database *db.DB, logger *log.Logger, accountID int64, svc string, err error, revoked bool) {
	logger.Printf("%s: account %d: failed to create client: %v", svc, accountID, err)
	status := "error"
	if revoked {
		status = "revoked"
	}
	if dbErr := database.SetGoogleAccountAuthState(accountID, status, err.Error()); dbErr != nil {
		logger.Printf("%s: account %d: record auth state: %v", svc, accountID, dbErr)
	}
}

// wireImapSyncers wires one imap.Syncer per connected email_accounts row —
// the non-Google mail analog of wireGoogleSyncers. A broken mailbox records
// its own auth-state error (imap.Syncer.Sync) rather than aborting the
// wiring step for the others.
func wireImapSyncers(ctx context.Context, d *daemon.Daemon, cfg *config.Config, database *db.DB, logger *log.Logger) {
	accounts, err := database.ListEmailAccounts()
	if err != nil {
		logger.Printf("imap: failed to list accounts: %v", err)
		return
	}
	var syncers []*imap.Syncer
	for _, acct := range accounts {
		accountCfg := imap.AccountConfig{
			Host: acct.Host, Port: acct.Port,
			Security: imap.Security(acct.Security), Folder: acct.Folder,
		}

		var auth imap.Authenticator
		switch acct.Provider {
		case "imap":
			store := imap.NewCredentialStore(cfg.WorkspaceDir(), acct.ID)
			creds, err := store.Load()
			if err != nil {
				logger.Printf("imap: account %d: failed to load credentials: %v", acct.ID, err)
				if dbErr := database.SetEmailAccountAuthState(acct.ID, "error", err.Error()); dbErr != nil {
					logger.Printf("imap: account %d: record auth state: %v", acct.ID, dbErr)
				}
				continue
			}
			auth = imap.PasswordAuth{Username: acct.EmailAddress, Password: creds.Password}
		case "outlook":
			auth = outlookAuthenticator(ctx, cfg, database, acct, logger)
			if auth == nil {
				continue
			}
		default:
			logger.Printf("imap: account %d: unknown provider %q, skipping", acct.ID, acct.Provider)
			continue
		}

		syncers = append(syncers, imap.NewSyncer(acct, accountCfg, auth, database, cfg, logger))
	}
	d.SetImapSyncers(syncers)
}

// wireCalDAVSyncers wires one caldav.Syncer per connected calendar_accounts
// row — the exact calendar analog of wireImapSyncers. A broken account
// records its own auth-state error rather than aborting the wiring step for
// the others; an account whose credential file can't be loaded is marked
// status='error' immediately so the Desktop UI shows the problem instead of
// a silently-dead account.
func wireCalDAVSyncers(d *daemon.Daemon, cfg *config.Config, database *db.DB, logger *log.Logger) {
	accounts, err := database.ListCalendarAccounts()
	if err != nil {
		logger.Printf("caldav: failed to list accounts: %v", err)
		return
	}
	var syncers []*caldav.Syncer
	for _, acct := range accounts {
		store := caldav.NewCredentialStore(cfg.WorkspaceDir(), acct.ID)
		creds, err := store.Load()
		if err != nil {
			logger.Printf("caldav: account %d: failed to load credentials: %v", acct.ID, err)
			if dbErr := database.SetCalendarAccountAuthState(acct.ID, "error", err.Error()); dbErr != nil {
				logger.Printf("caldav: account %d: record auth state: %v", acct.ID, dbErr)
			}
			continue
		}
		syncers = append(syncers, caldav.NewSyncer(acct, creds, database, cfg, logger))
	}
	d.SetCalDAVSyncers(syncers)
}

// outlookAuthenticator builds a RefreshingXOAUTH2Auth for one Outlook
// account: RefreshFunc loads the stored refresh token, exchanges it for a
// fresh access token on every Authenticate() call (i.e. every Dial(), i.e.
// every Sync() cycle — see imap.RefreshingXOAUTH2Auth), and re-persists the
// credential store whenever Microsoft rotates the refresh token. Returns nil
// if the account's credentials can't be loaded, in which case the caller
// skips wiring a syncer for it (mirroring the imap-provider branch above).
func outlookAuthenticator(_ context.Context, cfg *config.Config, database *db.DB, acct db.EmailAccount, logger *log.Logger) imap.Authenticator {
	store := imap.NewCredentialStore(cfg.WorkspaceDir(), acct.ID)
	if _, err := store.Load(); err != nil {
		logger.Printf("imap: account %d: failed to load credentials: %v", acct.ID, err)
		if dbErr := database.SetEmailAccountAuthState(acct.ID, "error", err.Error()); dbErr != nil {
			logger.Printf("imap: account %d: record auth state: %v", acct.ID, dbErr)
		}
		return nil
	}

	msCfg := resolveMicrosoftOAuthConfig()
	return imap.RefreshingXOAUTH2Auth{
		Username: acct.EmailAddress,
		RefreshFunc: func(ctx context.Context) (string, error) {
			creds, err := store.Load()
			if err != nil {
				return "", fmt.Errorf("loading outlook credentials for account %d: %w", acct.ID, err)
			}
			accessToken, newRefreshToken, err := imap.RefreshAccessToken(ctx, msCfg, creds.RefreshToken)
			if err != nil {
				if dbErr := database.SetEmailAccountAuthState(acct.ID, "error", err.Error()); dbErr != nil {
					logger.Printf("imap: account %d: record auth state: %v", acct.ID, dbErr)
				}
				return "", fmt.Errorf("refreshing outlook token for account %d: %w", acct.ID, err)
			}
			if newRefreshToken != "" && newRefreshToken != creds.RefreshToken {
				creds.RefreshToken = newRefreshToken
				if err := store.Save(creds); err != nil {
					logger.Printf("imap: account %d: failed to persist rotated refresh token: %v", acct.ID, err)
				}
			}
			return accessToken, nil
		},
	}
}

var progressLines atomic.Int32

func printProgress(w io.Writer, p *sync.Progress, workspace string) {
	if !flagVerbose {
		if f, ok := w.(*os.File); ok && isTerminal(f) {
			// Move cursor up to overwrite previous output
			if lines := progressLines.Load(); lines > 0 {
				fmt.Fprintf(w, "\033[%dA\033[J", lines)
			}
		}
	}
	output := p.Render(workspace)
	fmt.Fprintln(w, output)
	progressLines.Store(int32(strings.Count(output, "\n") + 1))
}

func isTerminal(f *os.File) bool {
	return term.IsTerminal(int(f.Fd()))
}

type progressJSON struct {
	Phase               string  `json:"phase"`
	ElapsedSec          float64 `json:"elapsed_sec"`
	UsersTotal          int     `json:"users_total"`
	UsersDone           int     `json:"users_done"`
	ChannelsTotal       int     `json:"channels_total"`
	ChannelsDone        int     `json:"channels_done"`
	DiscoveryPages      int     `json:"discovery_pages"`
	DiscoveryTotalPages int     `json:"discovery_total_pages"`
	DiscoveryChannels   int     `json:"discovery_channels"`
	DiscoveryUsers      int     `json:"discovery_users"`
	SearchAfter         string  `json:"search_after,omitempty"`
	UserProfilesTotal   int     `json:"user_profiles_total"`
	UserProfilesDone    int     `json:"user_profiles_done"`
	MsgChannelsTotal    int     `json:"msg_channels_total"`
	MsgChannelsDone     int     `json:"msg_channels_done"`
	MessagesFetched     int     `json:"messages_fetched"`
	Error               string  `json:"error,omitempty"`
}

func runPostSyncPipelines(ctx context.Context, database *db.DB, cfg *config.Config, logger *log.Logger) {
	if !cfg.Digest.Enabled {
		return
	}

	out := os.Stdout
	gen, cleanup := cliPooledGenerator(cfg, logger)
	defer cleanup()

	// Digests (with tracks linked between channel digests and rollups)
	fmt.Fprintln(out)
	digestSpinner := ui.NewSpinner(out, "Generating digests...")
	pipe := digest.New(database, cfg, gen, logger)
	pipe.SetPromptStore(prompts.New(database, nil))
	tracksPipe := tracks.New(database, cfg, gen, logger)
	tracksPipe.SetPromptStore(prompts.New(database, nil))
	pipe.TrackLinker = tracksPipe
	if det := newJiraKeyDetector(cfg, database, logger); det != nil {
		pipe.SetJiraKeyDetector(det)
		tracksPipe.SetJiraKeyDetector(det)
	}
	pipe.OnProgress = func(done, total int, status string) {
		digestSpinner.UpdateProgress(done, total, status)
	}
	n, usage, err := pipe.Run(ctx)
	if err != nil {
		digestSpinner.Stop(fmt.Sprintf("Digest error: %v", err))
	} else if n > 0 {
		if usage != nil && (usage.InputTokens > 0 || usage.OutputTokens > 0) {
			digestSpinner.Stop(fmt.Sprintf("Generated %d digest(s) (%d+%d tokens)",
				n, usage.InputTokens, usage.OutputTokens))
		} else {
			digestSpinner.Stop(fmt.Sprintf("Generated %d digest(s)", n))
		}
	} else {
		digestSpinner.Stop("No new digests needed")
	}

	// People cards (REDUCE phase: reads signals from channel digests)
	{
		peopleSpinner := ui.NewSpinner(out, "Generating people cards...")
		peoplePipe := guide.New(database, cfg, gen, logger)
		peoplePipe.SetPromptStore(prompts.New(database, nil))
		peoplePipe.OnProgress = func(done, total int, status string) {
			peopleSpinner.UpdateProgress(done, total, status)
		}
		pn, err := peoplePipe.Run(ctx)
		if err != nil {
			peopleSpinner.Stop(fmt.Sprintf("People cards error: %v", err))
		} else if pn > 0 {
			peopleSpinner.Stop(fmt.Sprintf("Generated %d people card(s)", pn))
		} else {
			peopleSpinner.Stop("No new people cards needed")
		}
	}
}

func printProgressJSON(w io.Writer, snap sync.Snapshot, syncErr error) {
	p := progressJSON{
		Phase:               snap.Phase.String(),
		ElapsedSec:          time.Since(snap.StartTime).Seconds(),
		UsersTotal:          snap.UsersTotal,
		UsersDone:           snap.UsersDone,
		ChannelsTotal:       snap.ChannelsTotal,
		ChannelsDone:        snap.ChannelsDone,
		DiscoveryPages:      snap.DiscoveryPages,
		DiscoveryTotalPages: snap.DiscoveryTotalPages,
		DiscoveryChannels:   snap.DiscoveryChannels,
		DiscoveryUsers:      snap.DiscoveryUsers,
		SearchAfter:         snap.SearchAfter,
		UserProfilesTotal:   snap.UserProfilesTotal,
		UserProfilesDone:    snap.UserProfilesDone,
		MsgChannelsTotal:    snap.MsgChannelsTotal,
		MsgChannelsDone:     snap.MsgChannelsDone,
		MessagesFetched:     snap.MessagesFetched,
	}
	if syncErr != nil {
		p.Error = syncErr.Error()
	}
	data, _ := json.Marshal(p)
	fmt.Fprintln(w, string(data))
}
