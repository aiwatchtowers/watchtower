package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
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
	"watchtower/internal/feed"
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
	syncFlagChannels     []string
	syncFlagWorkers      int
	syncFlagSkipDMs      bool
	syncFlagDays         int
	syncFlagProgressJSON bool
	syncFlagNoPipelines  bool
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
	syncCmd.Flags().BoolVar(&syncFlagFull, "full", false, "re-fetch all history within the initial history window")
	syncCmd.Flags().BoolVar(&syncFlagDaemon, "daemon", false, "run in daemon mode with periodic syncing")
	syncCmd.Flags().BoolVar(&syncFlagDetach, "detach", false, "start daemon in the background (requires --daemon)")
	syncCmd.Flags().BoolVar(&syncFlagStop, "stop", false, "stop a running detached daemon")
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
	return runSyncStop(cfg)
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

func runSyncStop(cfg *config.Config) error {
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
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		return fmt.Errorf("sending SIGTERM: %w", err)
	}

	// Poll until process exits (10s timeout).
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, 0); err == nil {
			// Process still alive, keep waiting
			time.Sleep(200 * time.Millisecond)
			continue
		}
		daemon.RemovePID(pidPath)
		fmt.Println("Daemon stopped.")
		return nil
	}
	return fmt.Errorf("daemon (PID %d) did not exit within 10 seconds", pid)
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

	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return fmt.Errorf("opening log file: %w", err)
	}
	defer logFile.Close()

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
		return runSyncStop(cfg)
	}

	// Slack is optional: without a token the daemon still runs (Calendar,
	// Gmail, Jira keep syncing) and only the Slack phase is skipped.
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}
	ws, err := cfg.GetActiveWorkspace()
	if err != nil {
		return err
	}
	if ws.SlackToken != "" {
		if err := cfg.Validate(); err != nil {
			return fmt.Errorf("invalid config: %w", err)
		}
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

	// Always write logs to watchtower.log; also to stderr when verbose or detached.
	syncLog := syncLogFilePath(cfg)
	if err := os.MkdirAll(filepath.Dir(syncLog), 0o755); err != nil {
		return fmt.Errorf("creating log directory: %w", err)
	}
	logFile, err := os.OpenFile(syncLog, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return fmt.Errorf("opening log file: %w", err)
	}
	defer logFile.Close()

	var logWriter io.Writer = logFile
	isDetachedChild := os.Getenv(daemon.DetachEnvKey) == "1"
	if flagVerbose || isDetachedChild {
		logWriter = io.MultiWriter(logFile, os.Stderr)
	}
	logger := log.New(logWriter, "", log.LstdFlags)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
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
		d := daemon.New(cfg)
		d.SetOrchestrators(orchestrators)
		d.SetLogger(logger)
		d.SetDB(database)
		d.SetPIDPath(pidFilePath(cfg))
		if cfg.Digest.Enabled {
			gen, cleanupPool := cliPooledGenerator(cfg, logger)
			defer cleanupPool()
			tracksPipe := tracks.New(database, cfg, gen, logger)
			pipe := digest.New(database, cfg, gen, logger)
			pipe.TrackLinker = tracksPipe
			d.SetDigestPipeline(pipe)
			d.SetTracksPipeline(tracksPipe)
			d.SetPeoplePipeline(guide.New(database, cfg, gen, logger))
			if cfg.Briefing.Enabled {
				d.SetBriefingPipeline(briefing.New(database, cfg, gen, logger))
			}
			if cfg.Inbox.Enabled {
				inboxPipe := inbox.New(database, cfg, gen, logger)
				inboxPipe.SetPromptStore(prompts.New(database, nil))
				d.SetInboxPipeline(inboxPipe)
			}
			wireIdeasPipeline(d, database, cfg, gen, logger)
			wireMemoryPipeline(d, database, cfg, logger)
			d.SetNextStepPipeline(targets.New(database, &cfg.Targets, gen, nil, cfg.Digest.Language, logger))
			customTracksPipe := customtracks.New(database, gen, cfg.Digest.Language, logger)
			d.SetCustomTracksPipeline(customTracksPipe)
			if cfg.DayPlan.Enabled {
				dayPlanPipe := dayplan.New(database, cfg, gen, logger)
				dayPlanPipe.SetPromptStore(prompts.New(database, nil))
				d.SetDayPlanPipeline(dayPlanPipe)
			}
			if cfg.Feed.Enabled {
				d.SetFeedPipeline(feed.New(database, cfg, logger))
			}
		}
		// Seed jira_accounts from a pre-multi-account legacy token file
		// before wiring, so a single-account install keeps syncing without
		// a re-login.
		if _, err := ensureLegacyJiraAccount(cfg, database, logger); err != nil {
			logger.Printf("jira: failed to seed legacy account: %v", err)
		}
		// Wire one Jira syncer per connected, enabled jira_accounts row.
		wireJiraSyncers(d, cfg, database, logger)
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
		return d.Run(ctx)
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

// wireJiraSyncers wires one Jira syncer per connected, enabled jira_accounts
// row whose token file exists. A broken account records its own auth-state
// error rather than aborting the wiring step for the others — the
// wireGoogleSyncers fan-out pattern. The global cfg.Jira.Enabled toggle gates
// the whole phase, matching every other daemon phase's on/off switch. Zero
// accounts is a clean no-op.
func wireJiraSyncers(d *daemon.Daemon, cfg *config.Config, database *db.DB, logger *log.Logger) {
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
		mapper := jira.NewUserMapper(client, database)
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
		syncer.SetLogger(logger)
		// Bounded comment sync feeds the Ideas registry's Jira pre-digest; it
		// stays off (0 = disabled) unless the registry itself is on.
		if cfg.Ideas.Enabled {
			syncer.SetCommentSyncLimit(cfg.Ideas.MaxCommentIssuesPerSync)
		}
		// Wire board analyzer for auto-refresh of changed configs.
		if cfg.Digest.Enabled {
			aiProvider := newAIClient(cfg, cfg.DBPath())
			analyzer := jira.NewBoardAnalyzer(client, database, aiProvider, acct.ID)
			analyzer.SetLanguage(cfg.Digest.Language)
			syncer.SetBoardAnalyzer(analyzer)
			syncer.SetAutoRefresh(true)
		}
		syncers = append(syncers, syncer)
	}
	d.SetJiraSyncers(syncers)
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
	tracksPipe := tracks.New(database, cfg, gen, logger)
	pipe.TrackLinker = tracksPipe
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
