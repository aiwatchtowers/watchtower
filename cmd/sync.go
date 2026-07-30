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

	var orch *sync.Orchestrator
	if ws.SlackToken != "" {
		slackClient := watchtowerslack.NewClient(ws.SlackToken)
		orch = sync.NewOrchestrator(database, slackClient, cfg)
	}

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
	if orch != nil {
		orch.SetLogger(logger)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	// Daemon mode: run periodic syncs until interrupted
	if syncFlagDaemon {
		d := daemon.New(orch, cfg)
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
		// Wire Jira syncer if configured and token exists.
		wireJiraSyncer(d, cfg, database, logger)
		// Wire calendar syncer if token exists.
		wireCalendarSyncer(ctx, d, cfg, database, logger)
		// Wire gmail syncer if token exists.
		wireGmailSyncer(ctx, d, cfg, database, logger)
		// Wire one IMAP/Outlook syncer per connected email_accounts row.
		wireImapSyncers(ctx, d, cfg, database, logger)
		// Wire one CalDAV/ICS syncer per connected calendar_accounts row.
		wireCalDAVSyncers(d, cfg, database, logger)
		return d.Run(ctx)
	}

	// One-shot sync is a Slack sync — nothing to do without a token.
	if orch == nil {
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

	// In verbose mode: just run sync, logs go to stderr
	if flagVerbose {
		syncErr := orch.Run(ctx, opts)
		snap := orch.Progress().Snapshot()
		if err := sync.WriteSyncResult(syncResultPath(cfg), sync.ResultFromSnapshot(snap, syncErr)); err != nil {
			logger.Printf("warning: failed to write sync result: %v", err)
		}
		if syncErr != nil {
			return fmt.Errorf("sync failed: %w", syncErr)
		}
		elapsed := time.Since(snap.StartTime).Round(time.Second)
		fmt.Fprintf(out, "Sync complete in %s: %d messages synced.\n",
			elapsed, snap.MessagesFetched)
		if !syncFlagNoPipelines {
			runPostSyncPipelines(ctx, database, cfg, logger)
		}
		return nil
	}

	// Normal mode: progress display in background
	progressLines.Store(0)
	done := make(chan error, 1)
	go func() {
		defer func() {
			if r := recover(); r != nil {
				done <- fmt.Errorf("sync panicked: %v\n%s", r, debug.Stack())
			}
		}()
		done <- orch.Run(ctx, opts)
	}()

	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case syncErr := <-done:
			snap := orch.Progress().Snapshot()
			if syncFlagProgressJSON {
				printProgressJSON(out, snap, syncErr)
			} else {
				printProgress(out, orch.Progress(), cfg.ActiveWorkspace)
			}
			if wErr := sync.WriteSyncResult(syncResultPath(cfg), sync.ResultFromSnapshot(snap, syncErr)); wErr != nil {
				logger.Printf("warning: failed to write sync result: %v", wErr)
			}
			if syncErr != nil {
				return fmt.Errorf("sync failed: %w", syncErr)
			}
			// Skip post-sync pipelines in --progress-json mode: the desktop app
			// runs them independently via BackgroundTaskManager after onboarding.
			if !syncFlagProgressJSON && !syncFlagNoPipelines {
				runPostSyncPipelines(ctx, database, cfg, logger)
			}
			return nil
		case <-ticker.C:
			snap := orch.Progress().Snapshot()
			if syncFlagProgressJSON {
				printProgressJSON(out, snap, nil)
			} else {
				printProgress(out, orch.Progress(), cfg.ActiveWorkspace)
			}
		}
	}
}

// wireJiraSyncer wires the Jira syncer onto the daemon if Jira is configured
// and a token exists, logging failures instead of failing sync startup.
func wireJiraSyncer(d *daemon.Daemon, cfg *config.Config, database *db.DB, logger *log.Logger) {
	if !cfg.Jira.Enabled || cfg.Jira.CloudID == "" {
		return
	}
	jiraStore := jira.NewTokenStore(cfg.WorkspaceDir())
	if !jiraStore.Exists() {
		return
	}
	jiraCfg := resolveJiraOAuthConfig()
	jiraClient := jira.NewClient(cfg.Jira.CloudID, jiraCfg, jiraStore)
	jiraMapper := jira.NewUserMapper(jiraClient, database)
	boards, err := database.GetJiraSelectedBoards()
	if err != nil {
		logger.Printf("jira: failed to load selected boards: %v", err)
		return
	}
	boardIDs := make([]int, len(boards))
	for i, b := range boards {
		boardIDs[i] = b.ID
	}
	jiraSyncer := jira.NewSyncer(jiraClient, database, jiraMapper, boardIDs)
	jiraSyncer.SetLogger(logger)
	// Wire board analyzer for auto-refresh of changed configs.
	if cfg.Digest.Enabled {
		aiProvider := newAIClient(cfg, cfg.DBPath())
		analyzer := jira.NewBoardAnalyzer(jiraClient, database, aiProvider)
		analyzer.SetLanguage(cfg.Digest.Language)
		jiraSyncer.SetBoardAnalyzer(analyzer)
		jiraSyncer.SetAutoRefresh(true)
	}
	d.SetJiraSyncer(jiraSyncer)
}

// wireCalendarSyncer wires the Calendar syncer onto the daemon if a token exists,
// recording auth-state errors (e.g. revoked grants) instead of failing sync startup.
func wireCalendarSyncer(ctx context.Context, d *daemon.Daemon, cfg *config.Config, database *db.DB, logger *log.Logger) {
	calendarStore := calendar.NewTokenStore(cfg.WorkspaceDir())
	if !calendarStore.Exists() {
		return
	}
	googleCfg := resolveGoogleOAuthConfig()
	calToken, err := calendarStore.Load()
	if err != nil {
		logger.Printf("calendar: failed to load token: %v", err)
		return
	}
	calClient, err := calendar.NewClient(ctx, calToken.RefreshToken, googleCfg)
	if err != nil {
		logger.Printf("calendar: failed to create client: %v", err)
		status := "error"
		if errors.Is(err, calendar.ErrAuthRevoked) {
			status = "revoked"
		}
		if dbErr := database.SetGoogleAccountAuthState(stubGoogleAccountID, status, err.Error()); dbErr != nil {
			logger.Printf("calendar: failed to record auth state: %v", dbErr)
		}
		return
	}
	d.SetCalendarSyncer(calendar.NewSyncer(calClient, database, cfg, logger))
}

// wireGmailSyncer wires the Gmail syncer onto the daemon if a token exists,
// recording auth-state errors (e.g. revoked grants) instead of failing sync startup.
func wireGmailSyncer(ctx context.Context, d *daemon.Daemon, cfg *config.Config, database *db.DB, logger *log.Logger) {
	gmailStore := gmail.NewTokenStore(cfg.WorkspaceDir())
	if !gmailStore.Exists() {
		return
	}
	gc := resolveGoogleOAuthConfig() // calendar.GoogleOAuthConfig
	gmailToken, err := gmailStore.Load()
	if err != nil {
		logger.Printf("gmail: failed to load token: %v", err)
		return
	}
	gmClient, err := gmail.NewClient(ctx, gmailToken.RefreshToken,
		gmail.GoogleOAuthConfig{ClientID: gc.ClientID, ClientSecret: gc.ClientSecret})
	if err != nil {
		logger.Printf("gmail: failed to create client: %v", err)
		status := "error"
		if errors.Is(err, gmail.ErrAuthRevoked) {
			status = "revoked"
		}
		if dbErr := database.SetGoogleAccountAuthState(stubGoogleAccountID, status, err.Error()); dbErr != nil {
			logger.Printf("gmail: failed to record auth state: %v", dbErr)
		}
		return
	}
	d.SetGmailSyncer(gmail.NewSyncer(gmClient, database, cfg, logger, stubGoogleAccountID))
}

// wireImapSyncers wires one imap.Syncer per connected email_accounts row.
// Unlike wireGmailSyncer's single token check, this iterates every account;
// a broken mailbox records its own auth-state error (imap.Syncer.Sync) rather
// than aborting the wiring step for the others.
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
