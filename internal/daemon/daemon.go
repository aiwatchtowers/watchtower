// Package daemon provides background daemon and service management capabilities.
package daemon

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	gosync "sync"
	"watchtower/internal/briefing"
	"watchtower/internal/caldav"
	"watchtower/internal/calendar"
	"watchtower/internal/config"
	"watchtower/internal/dayplan"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/feed"
	"watchtower/internal/gmail"
	"watchtower/internal/guide"
	"watchtower/internal/ideas"
	"watchtower/internal/imap"
	"watchtower/internal/inbox"
	"watchtower/internal/jira"
	"watchtower/internal/memory"

	"watchtower/internal/customtracks"
	"watchtower/internal/sync"
	"watchtower/internal/targets"
	"watchtower/internal/tracks"
)

// DayPlanRunner is the interface the daemon uses to generate day plans and
// keep calendar items / conflicts in sync every cycle. *dayplan.Pipeline
// satisfies this interface.
type DayPlanRunner interface {
	Run(ctx context.Context, opts dayplan.RunOptions) (*db.DayPlan, error)
	DetectConflicts(ctx context.Context, userID, date string) error
	SyncCalendarItemsForDate(ctx context.Context, userID, date string) error
	AccumulatedUsage() (int, int, float64, int)
}

// jiraAccountSyncer is the slice of *jira.Syncer behaviour phaseJiraSync uses.
// The phase keeps it as an interface (the DayPlanRunner precedent) because the
// branch that matters — a revoked grant reaching the account row — is only
// produced by a live 401 from Atlassian, which no offline test can stage
// through the concrete Syncer.
type jiraAccountSyncer interface {
	Sync(ctx context.Context) (int, error)
	AccountID() int64
	BoardAnalyzerUsage() (inputTokens, outputTokens, totalAPITokens int)
}

// minPollInterval is the minimum allowed poll interval. Values below this
// (e.g. nanosecond-scale durations from misconfigured integer values) are
// replaced with DefaultPollInterval. Tests may lower this for fast execution.
var minPollInterval = 1 * time.Second

// Daemon runs periodic incremental syncs on a timer and after wake-from-sleep events.
type Daemon struct {
	orchestrators       []*sync.Orchestrator
	config              *config.Config
	logger              *log.Logger
	wakeCh              <-chan struct{}
	pidPath             string
	db                  *db.DB
	digestPipe          *digest.Pipeline
	tracksPipe          *tracks.Pipeline
	peoplePipe          *guide.Pipeline
	briefingPipe        *briefing.Pipeline
	inboxPipe           *inbox.Pipeline
	ideasPipe           *ideas.Pipeline
	memoryPipe          *memory.Pipeline
	feedPipe            *feed.Pipeline
	nextStepPipe        *targets.Pipeline
	customTracksPipe    *customtracks.Pipeline
	calendarSyncers     []*calendar.Syncer
	calDAVSyncers       []*caldav.Syncer
	gmailSyncers        []*gmail.Syncer
	imapSyncers         []*imap.Syncer
	jiraSyncers         []jiraAccountSyncer
	dayPlanPipeline     DayPlanRunner
	lastJira            time.Time
	lastPeople          time.Time // when people cards last ran (once per day)
	lastBriefing        time.Time // when briefing last ran (once per day)
	lastIdeas           time.Time // when the ideas registry last ran (throttled by ideas.mine_interval_hours)
	lastIdeasLockSkip   time.Time // when phaseIdeas last LOGGED a lock-held skip (GB7 — throttles the log line, not the skip itself)
	lastStreams         time.Time // when the stage-1 stream digests last ran (throttled by streams.interval_hours, decoupled from ideas.enabled)
	lastStreamsLockSkip time.Time // when phaseStreamDigests last LOGGED a lock-held skip (the lastIdeasLockSkip precedent)
	lastDayPlanDate     string    // YYYY-MM-DD of last generation, for dedup
}

// New creates a Daemon. Slack orchestrators are attached separately via
// SetOrchestrators — an empty (or nil) set means Slack is not connected, in
// which case the Slack sync phase is skipped while the other source syncers
// and pipelines still run.
func New(cfg *config.Config) *Daemon {
	return &Daemon{
		config: cfg,
		logger: log.New(os.Stderr, "[daemon] ", log.LstdFlags),
	}
}

// SetOrchestrators attaches one Slack sync orchestrator per connected account.
// An empty or nil slice disables the Slack sync phase.
func (d *Daemon) SetOrchestrators(o []*sync.Orchestrator) {
	d.orchestrators = o
}

// SetLogger replaces the daemon's logger.
func (d *Daemon) SetLogger(l *log.Logger) {
	d.logger = l
}

// SetDB sets the database for post-pipeline operations like auto-marking read status.
func (d *Daemon) SetDB(database *db.DB) {
	d.db = database
}

// SetDigestPipeline sets the digest pipeline for post-sync digest generation.
func (d *Daemon) SetDigestPipeline(p *digest.Pipeline) {
	d.digestPipe = p
}

// SetTracksPipeline sets the tracks pipeline for post-digest extraction.
func (d *Daemon) SetTracksPipeline(p *tracks.Pipeline) {
	d.tracksPipe = p
}

// SetBriefingPipeline sets the daily briefing pipeline.
func (d *Daemon) SetBriefingPipeline(p *briefing.Pipeline) {
	d.briefingPipe = p
}

// SetInboxPipeline sets the inbox detection pipeline.
func (d *Daemon) SetInboxPipeline(p *inbox.Pipeline) {
	d.inboxPipe = p
}

// SetIdeasPipeline sets the ideas & decisions registry pipeline (also used
// by the independently-gated stage-1 stream digests phase, phaseStreamDigests).
func (d *Daemon) SetIdeasPipeline(p *ideas.Pipeline) {
	d.ideasPipe = p
}

// HasIdeasPipeline reports whether an ideas.Pipeline is wired — cmd/sync.go's
// wireIdeasPipeline attaches one when either the registry consolidator
// (ideas.enabled) or the stream digests phase (streams.enabled) needs it, so
// callers can't infer "wired" from ideas.enabled alone.
func (d *Daemon) HasIdeasPipeline() bool {
	return d.ideasPipe != nil
}

// SetMemoryPipeline sets the memory consolidation pipeline (internal/memory).
// The daemon owns the run context, so the pipeline's pipeline_runs rows are
// stamped source="daemon" here regardless of how the caller constructed it.
func (d *Daemon) SetMemoryPipeline(p *memory.Pipeline) {
	if p != nil {
		p.Source = "daemon"
	}
	d.memoryPipe = p
}

// SetFeedPipeline installs the dashboard feed publisher (internal/feed).
func (d *Daemon) SetFeedPipeline(p *feed.Pipeline) {
	d.feedPipe = p
}

// SetNextStepPipeline sets the targets pipeline used to refresh AI next-step
// suggestions for active targets each cycle.
func (d *Daemon) SetNextStepPipeline(p *targets.Pipeline) {
	d.nextStepPipe = p
}

// SetCustomTracksPipeline sets the pipeline that scans user-authored custom
// tracks over recent cross-source activity, producing their event timelines.
// It runs BEFORE auto-track extraction so custom narratives/fingerprints are
// current when the auto splitter dedups against them.
func (d *Daemon) SetCustomTracksPipeline(p *customtracks.Pipeline) {
	d.customTracksPipe = p
}

// SetCalendarSyncers sets the per-account Google Calendar syncers — one per
// connected google_accounts row with calendar enabled and a live token
// (mirrors SetCalDAVSyncers/SetImapSyncers).
func (d *Daemon) SetCalendarSyncers(s []*calendar.Syncer) {
	d.calendarSyncers = s
}

// SetCalDAVSyncers sets the per-account CalDAV/ICS calendar syncers — one
// per connected calendar_accounts row, unlike Google Calendar's single
// syncer, since a workspace can have any number of connected calendar
// sources (mirrors SetImapSyncers).
func (d *Daemon) SetCalDAVSyncers(s []*caldav.Syncer) {
	d.calDAVSyncers = s
}

// SetGmailSyncers sets the per-account Gmail syncers — one per connected
// google_accounts row with gmail enabled and a live token (mirrors
// SetCalendarSyncers/SetImapSyncers).
func (d *Daemon) SetGmailSyncers(s []*gmail.Syncer) {
	d.gmailSyncers = s
}

// SetImapSyncers sets the per-account IMAP/Outlook syncers for post-sync mail
// fetch — one per connected email_accounts row, unlike Gmail's single syncer,
// since a workspace can have any number of connected mailboxes.
func (d *Daemon) SetImapSyncers(s []*imap.Syncer) {
	d.imapSyncers = s
}

// SetJiraSyncers sets the per-account Jira syncers — one per connected,
// enabled jira_accounts row with a live token (mirrors SetCalendarSyncers/
// SetGmailSyncers). An empty or nil slice disables the Jira sync phase.
func (d *Daemon) SetJiraSyncers(s []*jira.Syncer) {
	d.jiraSyncers = make([]jiraAccountSyncer, len(s))
	for i, syncer := range s {
		d.jiraSyncers[i] = syncer
	}
}

// SetPeoplePipeline sets the people card pipeline (REDUCE phase).
func (d *Daemon) SetPeoplePipeline(p *guide.Pipeline) {
	d.peoplePipe = p
}

// SetDayPlanPipeline sets the day-plan pipeline for post-briefing generation
// and per-cycle calendar sync + conflict detection.
func (d *Daemon) SetDayPlanPipeline(p DayPlanRunner) {
	d.dayPlanPipeline = p
}

// SetPIDPath sets the path where the daemon will write its PID file.
func (d *Daemon) SetPIDPath(path string) {
	d.pidPath = path
}

// Run starts the daemon poll loop. It blocks until ctx is cancelled.
// The caller is responsible for wiring signal handling into the context.
// Each tick or wake event triggers an incremental sync.
func (d *Daemon) Run(ctx context.Context) error {
	if d.pidPath != "" {
		if err := WritePID(d.pidPath); err != nil {
			return fmt.Errorf("writing pid file: %w", err)
		}
		defer RemovePID(d.pidPath)
	}

	pollInterval := d.config.Sync.PollInterval
	if pollInterval < minPollInterval {
		pollInterval = config.DefaultPollInterval
	}

	if d.config.Sync.SyncOnWake {
		d.wakeCh = WatchWake(ctx, pollInterval)
	}

	// Restore last pipeline times from disk so throttle guards survive restarts.
	d.loadLastPeople()
	d.loadLastBriefing()
	d.loadLastIdeas()
	d.loadLastStreams()

	d.logger.Printf("daemon started, polling every %s", pollInterval)

	// Run an initial sync immediately on startup.
	d.runSync(ctx)

	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			d.logger.Println("shutting down")
			return nil
		case <-ticker.C:
			d.runSync(ctx)
		case <-d.wakeChannel():
			d.logger.Println("wake event detected, syncing")
			d.runSync(ctx)
			// Reset the ticker so the next poll is a full interval from now.
			ticker.Reset(pollInterval)
		}
	}
}

// wakeChannel returns the wake channel or a nil channel (blocks forever) when
// wake detection is disabled.
func (d *Daemon) wakeChannel() <-chan struct{} {
	if d.wakeCh != nil {
		return d.wakeCh
	}
	return nil
}

func (d *Daemon) runSync(ctx context.Context) {
	syncErr := d.phaseSlackSync(ctx)
	d.phaseCalendarSync(ctx)
	d.phaseCalDAVSync(ctx)
	d.phaseGmailSync(ctx)
	d.phaseImapSync(ctx)
	d.phaseJiraSync(ctx)

	// Run pipelines even if sync had a non-fatal error (e.g. rate-limited,
	// partial fetch). The DB still has messages that need processing.
	// Only skip pipelines if the context itself was cancelled (shutdown).
	if ctx.Err() != nil {
		d.logger.Printf("context cancelled, skipping pipelines")
		return
	}
	if syncErr != nil {
		d.logger.Printf("sync had errors, but running pipelines on existing data")
	}

	d.phaseFastInbox(ctx)
	d.phaseChannelDigests(ctx)
	d.phaseUnsnooze()
	d.phaseTranscriptAudioCleanup()

	d.phaseCustomTrackScan(ctx) // before auto extraction so folds land

	// Phases 2-4 run in parallel where possible:
	//   Group A: Tracks → inject track context → Rollups
	//   Group B: People Cards (only depends on Phase 1 channel digests)
	var phasesWg gosync.WaitGroup
	phasesWg.Add(2)
	go func() {
		defer phasesWg.Done()
		d.phaseTracksAndRollups(ctx)
	}()
	go func() {
		defer phasesWg.Done()
		d.phasePeopleCards(ctx)
	}()
	phasesWg.Wait()

	// Auto-mark digests and tracks as read based on Slack read cursors.
	// Runs once after all analysis phases so channel digests, rollups, and tracks
	// are all available for marking.
	d.autoMarkRead()

	d.phaseInbox(ctx)
	d.phaseStreamDigests(ctx)
	d.phaseIdeas(ctx)
	d.phaseMemory(ctx)
	d.phaseNextStep(ctx)
	d.phaseBriefing(ctx)

	now := time.Now()
	d.runDayPlanPhase(ctx, now)
	d.runDayPlanConflictPhase(ctx, now)
	d.phaseFeed()
}

// pipelineRunStats are the bookkeeping metrics recorded for a daemon-managed
// pipeline run. Period bounds (pFrom/pTo) are only set by tracks.
type pipelineRunStats struct {
	items    int
	inTok    int
	outTok   int
	cost     float64
	totalAPI int
	pFrom    *float64
	pTo      *float64
	err      error
}

// trackedPipelineRun creates a pipeline_runs row, runs the work closure, then
// records the completion. fn always runs (even when DB is unavailable) so the
// caller sees consistent semantics. Idempotent on CreatePipelineRun failure.
func (d *Daemon) trackedPipelineRun(name string, fn func() pipelineRunStats) {
	if d.db == nil {
		fn()
		return
	}
	runID, _ := d.db.CreatePipelineRun(name, "daemon", "auto")
	stats := fn()
	if runID <= 0 {
		return
	}
	errMsg := ""
	if stats.err != nil {
		errMsg = stats.err.Error()
	}
	_ = d.db.CompletePipelineRun(runID, stats.items, stats.inTok, stats.outTok, stats.cost, stats.totalAPI, stats.pFrom, stats.pTo, errMsg)
}

// phaseSlackSync runs every connected account's orchestrator and persists one
// aggregated last_sync.json. One account's error is logged and does not block
// the others (the wireImapSyncers/wireGoogleSyncers fan-out pattern) — each
// orchestrator advances its own account's sync_state independently, so a
// failed account never freezes a healthy one's watermark. The returned error
// is the first account's error (non-nil for non-fatal sync issues); pipelines
// still run. An empty orchestrator set means Slack is not connected — the
// phase is skipped and the other sources still sync.
func (d *Daemon) phaseSlackSync(ctx context.Context) error {
	if len(d.orchestrators) == 0 {
		return nil
	}
	var firstErr error
	snaps := make([]sync.Snapshot, 0, len(d.orchestrators))
	for _, o := range d.orchestrators {
		if err := o.Run(ctx, sync.SyncOptions{}); err != nil {
			d.logger.Printf("sync error: %v", err)
			if firstErr == nil {
				firstErr = err
			}
		}
		snaps = append(snaps, o.Progress().Snapshot())
	}
	resultPath := filepath.Join(d.config.WorkspaceDir(), "last_sync.json")
	if err := sync.WriteSyncResult(resultPath, sync.ResultFromSnapshots(snaps, firstErr)); err != nil {
		d.logger.Printf("failed to write sync result: %v", err)
	}
	return firstErr
}

// phaseCalendarSync pulls Google Calendar events for every connected
// google_accounts row with calendar enabled. Lightweight, runs every cycle.
// Like phaseCalDAVSync/phaseImapSync, this loops over one syncer per
// account — a per-account failure is logged and skipped rather than
// aborting the rest of the accounts.
func (d *Daemon) phaseCalendarSync(ctx context.Context) {
	for _, s := range d.calendarSyncers {
		n, err := s.Sync(ctx)
		if err != nil {
			d.logger.Printf("calendar sync error: %v", err)
		} else if n > 0 {
			d.logger.Printf("calendar: %d events synced", n)
		}
	}
}

// phaseCalDAVSync pulls calendar events for every connected CalDAV/ICS
// account. Lightweight, runs every cycle. Like phaseImapSync, this loops
// over one syncer per account — a per-account failure is logged and skipped
// rather than aborting the rest of the accounts.
func (d *Daemon) phaseCalDAVSync(ctx context.Context) {
	for _, s := range d.calDAVSyncers {
		n, err := s.Sync(ctx)
		if err != nil {
			d.logger.Printf("caldav sync error: %v", err)
		} else if n > 0 {
			d.logger.Printf("caldav: %d events synced", n)
		}
	}
}

// phaseGmailSync pulls Gmail inbox messages for every connected
// google_accounts row with gmail enabled. Lightweight, runs every cycle.
// Like phaseCalDAVSync/phaseImapSync, this loops over one syncer per
// account — a per-account failure is logged and skipped rather than
// aborting the rest of the accounts.
func (d *Daemon) phaseGmailSync(ctx context.Context) {
	for _, s := range d.gmailSyncers {
		n, err := s.Sync(ctx)
		if err != nil {
			d.logger.Printf("gmail sync error: %v", err)
		} else if n > 0 {
			d.logger.Printf("gmail: %d messages synced", n)
		}
	}
}

// phaseImapSync pulls new mail for every connected IMAP/Outlook account.
// Lightweight, runs every cycle. Unlike phaseGmailSync's single nil-check,
// this loops over one syncer per account — a per-account failure is logged
// and skipped rather than aborting the rest of the accounts.
func (d *Daemon) phaseImapSync(ctx context.Context) {
	for _, s := range d.imapSyncers {
		n, err := s.Sync(ctx)
		if err != nil {
			d.logger.Printf("imap sync error: %v", err)
		} else if n > 0 {
			d.logger.Printf("imap: %d messages synced", n)
		}
	}
}

// phaseJiraSync pulls Jira issues for every connected account respecting the
// configured interval, then records board-analyzer LLM usage and reflects
// target statuses. One account's sync error is logged and confined to that
// account — it never blocks the other accounts, nor their target reflection
// (the phaseCalendarSync/phaseGmailSync fan-out pattern).
//
// A pass never writes a blanket "ok" back. Syncer.Sync deliberately keeps going
// across ordinary per-project failures (those are logged and skipped), so a nil
// error is not proof the account is healthy — flipping the row to "ok" on it
// would paint a half-broken account green in Settings and hide its Re-login
// button. Only the OAuth connect (connectJiraAccount), which has just proven
// access, clears the state to "ok".
//
// The one failure a pass DOES persist is jira.ErrAuthRevoked: the grant itself
// is gone, Sync aborts on it, and the row needs status "revoked" for the
// Settings Re-login button to appear. Every other Sync error is logged and
// left off the row entirely — a rate limit, a dropped connection or a failing
// local read says nothing about the grant, and stamping it would strand a red
// badge that only a re-login could clear. A cancelled context is daemon
// shutdown, checked first for the same reason. Errors still accumulate into
// firstErr, which is what the jira-boards pipeline_runs row records.
func (d *Daemon) phaseJiraSync(ctx context.Context) {
	if len(d.jiraSyncers) == 0 {
		return
	}
	interval := time.Duration(d.config.Jira.SyncIntervalMins) * time.Minute
	if interval <= 0 {
		interval = time.Duration(config.DefaultJiraSyncIntervalMins) * time.Minute
	}
	if !d.lastJira.IsZero() && time.Since(d.lastJira) < interval {
		return
	}
	d.lastJira = time.Now()

	var firstErr error
	anyClean := false
	for _, s := range d.jiraSyncers {
		n, err := s.Sync(ctx)
		if err != nil {
			d.logger.Printf("jira: account %d: sync error: %v", s.AccountID(), err)
			if firstErr == nil {
				firstErr = err
			}
			switch {
			case ctx.Err() != nil:
				// Shutdown, not an auth problem — leave the account's state
				// alone rather than stamping "context canceled" on it, which
				// nothing but a re-login could clear.
				d.logger.Printf("jira: account %d: sync cancelled, leaving auth state untouched", s.AccountID())
			case errors.Is(err, jira.ErrAuthRevoked):
				if d.db != nil {
					if dbErr := d.db.SetJiraAccountAuthState(s.AccountID(), "revoked", err.Error()); dbErr != nil {
						d.logger.Printf("jira: account %d: record auth state: %v", s.AccountID(), dbErr)
					}
				}
			}
			continue
		}
		anyClean = true
		if n > 0 {
			d.logger.Printf("jira: account %d: %d issues synced", s.AccountID(), n)
		}
	}

	// Record board analyzer LLM usage if any boards were re-analyzed.
	if d.db != nil {
		var inTok, outTok, totalAPI int
		for _, s := range d.jiraSyncers {
			in, out, api := s.BoardAnalyzerUsage()
			inTok += in
			outTok += out
			totalAPI += api
		}
		if inTok > 0 || outTok > 0 {
			d.trackedPipelineRun("jira-boards", func() pipelineRunStats {
				return pipelineRunStats{inTok: inTok, outTok: outTok, totalAPI: totalAPI, err: firstErr}
			})
		}
	}

	// Reflect Jira issue statuses onto targets as soon as ANY account's pass
	// came back clean. Gating on "no account failed" would let one broken
	// account freeze every other account's targets in their stale status
	// indefinitely — the same fan-out isolation the auth-state write follows.
	// Zero syncers never reaches here (the early return above).
	if anyClean && d.db != nil {
		if synced, serr := d.db.SyncJiraTargetStatuses(); serr != nil {
			d.logger.Printf("jira target status sync warning: %v", serr)
		} else if synced > 0 {
			d.logger.Printf("jira-targets: synced %d target status(es)", synced)
		}
	}
}

// phaseFastInbox surfaces Slack/Jira/Calendar mentions in the UI immediately,
// before the LLM-heavy digest pipeline. Phase 5 (phaseInbox) still runs later
// to detect decision_made/briefing_ready from fresh digests.
func (d *Daemon) phaseFastInbox(ctx context.Context) {
	if d.inboxPipe == nil {
		return
	}
	d.applyInboxCurrentUser()
	if err := d.inboxPipe.RunFastDetection(ctx); err != nil {
		d.logger.Printf("inbox fast detect error: %v", err)
	}
}

// phaseChannelDigests generates per-channel digests (MAP phase that produces
// people_signals consumed later by phasePeopleCards).
func (d *Daemon) phaseChannelDigests(ctx context.Context) {
	if d.digestPipe == nil {
		return
	}
	d.trackedPipelineRun("digests", func() pipelineRunStats {
		n, usage, err := d.digestPipe.RunChannelDigestsOnly(ctx)
		switch {
		case err != nil:
			d.logger.Printf("digest error: %v", err)
		case n > 0 && usage != nil && (usage.InputTokens > 0 || usage.OutputTokens > 0):
			d.logger.Printf("generated %d digest(s) (%d+%d tokens)", n, usage.InputTokens, usage.OutputTokens)
		case n > 0:
			d.logger.Printf("generated %d digest(s)", n)
		}
		stats := pipelineRunStats{items: n, err: err}
		if usage != nil {
			stats.inTok = usage.InputTokens
			stats.outTok = usage.OutputTokens
			stats.totalAPI = usage.TotalAPITokens
		}
		return stats
	})
}

// phaseUnsnooze releases snoozed targets and inbox items whose snooze_until
// has passed, then surfaces any newly-overdue targets to the inbox so they
// reach the user through the same channel as Slack/Jira/Calendar reminders.
func (d *Daemon) phaseUnsnooze() {
	if d.db == nil {
		return
	}
	if n, err := d.db.UnsnoozeExpiredTargets(); err != nil {
		d.logger.Printf("unsnooze targets error: %v", err)
	} else if n > 0 {
		d.logger.Printf("unsnoozed %d target(s)", n)
	}
	if n, err := d.db.UnsnoozeExpiredInboxItems(); err != nil {
		d.logger.Printf("unsnooze inbox error: %v", err)
	} else if n > 0 {
		d.logger.Printf("unsnoozed %d inbox item(s)", n)
	}
	if n, err := d.db.NotifyDueTargets(time.Now().UTC()); err != nil {
		d.logger.Printf("notify due targets error: %v", err)
	} else if n > 0 {
		d.logger.Printf("surfaced %d due target(s) to inbox", n)
	}
}

// phaseTranscriptAudioCleanup deletes meeting-recording audio files past the
// retention window and NULLs audio_path. Transcript text is never touched.
// Missing files are fine (idempotent re-runs). It then sweeps the recordings
// directory for orphaned rec_* files no transcript row references.
func (d *Daemon) phaseTranscriptAudioCleanup() {
	if d.db == nil {
		return
	}
	days := d.config.Transcripts.AudioRetentionDays
	if days <= 0 {
		return // retention disabled
	}
	cutoff := time.Now().UTC().AddDate(0, 0, -days)
	rows, err := d.db.ExpiredTranscriptAudio(cutoff.Format(time.RFC3339))
	if err != nil {
		d.logger.Printf("transcript cleanup query error: %v", err)
		return
	}
	for _, tr := range rows {
		if err := os.Remove(tr.AudioPath.String); err != nil && !os.IsNotExist(err) {
			d.logger.Printf("transcript cleanup: removing %s: %v", tr.AudioPath.String, err)
			continue // keep audio_path so a later run retries
		}
		if err := d.db.ClearMeetingTranscriptAudio(tr.ID); err != nil {
			d.logger.Printf("transcript cleanup: clearing row %d: %v", tr.ID, err)
		}
	}
	if len(rows) > 0 {
		d.logger.Printf("transcript cleanup: processed %d expired recording(s)", len(rows))
	}

	d.cleanupOrphanRecordings(cutoff)
}

// cleanupOrphanRecordings deletes rec_* files in the recordings directory that
// are older than the retention window (by modification time) and not
// referenced by any meeting_transcripts.audio_path. Recordings whose Center
// run failed never get a DB row, so the row-driven pass above would leave them
// on disk forever.
func (d *Daemon) cleanupOrphanRecordings(cutoff time.Time) {
	dir := d.config.RecordingsDir()
	if dir == "" {
		return
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		if !os.IsNotExist(err) {
			d.logger.Printf("transcript cleanup: reading recordings dir %s: %v", dir, err)
		}
		return
	}
	referenced, err := d.db.TranscriptAudioPaths()
	if err != nil {
		d.logger.Printf("transcript cleanup: listing referenced audio paths: %v", err)
		return
	}
	refSet := make(map[string]bool, len(referenced))
	for _, p := range referenced {
		refSet[p] = true
	}
	removed := 0
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasPrefix(entry.Name(), "rec_") {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		if refSet[path] {
			continue
		}
		info, err := entry.Info()
		if err != nil || !info.ModTime().Before(cutoff) {
			continue // young orphans get a full retention window before deletion
		}
		if err := os.Remove(path); err != nil {
			d.logger.Printf("transcript cleanup: removing orphan %s: %v", path, err)
			continue
		}
		removed++
	}
	if removed > 0 {
		d.logger.Printf("transcript cleanup: removed %d orphaned recording(s)", removed)
	}
}

// phaseTracksAndRollups (group A) runs the tracks pipeline, injects active
// track context into the digest pipeline, then runs daily/weekly rollups.
func (d *Daemon) phaseTracksAndRollups(ctx context.Context) {
	if d.tracksPipe != nil {
		d.trackedPipelineRun("tracks", func() pipelineRunStats {
			n, updated, err := d.tracksPipe.Run(ctx)
			if err != nil {
				d.logger.Printf("tracks error: %v", err)
			} else if n > 0 || updated > 0 {
				d.logger.Printf("tracks: created %d, updated %d", n, updated)
			}
			inTok, outTok, cost, totalAPI := d.tracksPipe.AccumulatedUsage()
			stats := pipelineRunStats{
				items: n + updated, inTok: inTok, outTok: outTok,
				cost: cost, totalAPI: totalAPI, err: err,
			}
			if d.tracksPipe.LastFrom > 0 {
				stats.pFrom = &d.tracksPipe.LastFrom
			}
			if d.tracksPipe.LastTo > 0 {
				stats.pTo = &d.tracksPipe.LastTo
			}
			return stats
		})

		// Inject track context into digest pipeline for track-aware rollups.
		if trackCtx, err := d.tracksPipe.FormatActiveTracksForPrompt(); err == nil && trackCtx != "" {
			if d.digestPipe != nil {
				d.digestPipe.TrackContext = trackCtx
			}
		}
	}

	// Phase 3: Daily/weekly rollups (track-aware).
	if d.digestPipe != nil {
		if err := d.digestPipe.RunRollups(ctx); err != nil {
			d.logger.Printf("rollup error: %v", err)
		}
	}
}

// phasePeopleCards (group B) generates per-user people cards from people_signals
// produced by phaseChannelDigests. Throttled to once per 24h.
func (d *Daemon) phasePeopleCards(ctx context.Context) {
	if d.peoplePipe == nil {
		return
	}
	now := time.Now()
	if !d.lastPeople.IsZero() && now.Sub(d.lastPeople) < 24*time.Hour {
		return
	}

	d.trackedPipelineRun("people", func() pipelineRunStats {
		n, err := d.peoplePipe.Run(ctx)
		if err != nil {
			d.logger.Printf("people cards error: %v", err)
		} else {
			if n > 0 {
				d.logger.Printf("generated %d people card(s)", n)
			}
			d.lastPeople = now
			d.saveLastPeople()
		}
		inTok, outTok, cost, totalAPI := d.peoplePipe.AccumulatedUsage()
		return pipelineRunStats{items: n, inTok: inTok, outTok: outTok, cost: cost, totalAPI: totalAPI, err: err}
	})
}

// phaseInbox runs the full inbox pipeline (decision_made/briefing_ready from
// fresh digests, AI triage, secretary card generation). Runs after digest/tracks/
// people so detectors see fresh data.
func (d *Daemon) phaseInbox(ctx context.Context) {
	if d.inboxPipe == nil {
		return
	}
	d.applyInboxCurrentUser()

	d.trackedPipelineRun("inbox", func() pipelineRunStats {
		created, resolved, err := d.inboxPipe.Run(ctx)
		if err != nil {
			d.logger.Printf("inbox error: %v", err)
		} else if created > 0 || resolved > 0 {
			d.logger.Printf("inbox: %d new, %d resolved", created, resolved)
		}
		inTok, outTok, cost, totalAPI := d.inboxPipe.AccumulatedUsage()
		if inTok > 0 || outTok > 0 {
			d.logger.Printf("inbox: %d+%d tokens", inTok, outTok)
		}
		return pipelineRunStats{
			items: created + resolved, inTok: inTok, outTok: outTok,
			cost: cost, totalAPI: totalAPI, err: err,
		}
	})
}

// ideasLockSkipLogThrottle bounds how often phaseIdeas LOGS a lock-held skip
// (GB7): the phase is polled every daemon tick, so a long-running CLI
// backfill would otherwise flood the log with an identical skip line on
// every single tick for its entire duration. The skip itself is never
// throttled — only the log line.
const ideasLockSkipLogThrottle = 10 * time.Minute

// phaseIdeas runs the ideas & decisions registry pipeline (Gmail/Jira
// pre-digests, then the stage-2 consolidator). Runs after inbox so the
// registry sees fresh digests/transcripts. Throttled to once per
// ideas.mine_interval_hours (default 6 when unset/non-positive, the
// DefaultIdeasMineIntervalHours precedent) — the phasePeopleCards pattern.
// When the throttle says it's time to run, phaseIdeas ACQUIRES the same
// cross-process backfill lock a CLI `ideas mine --from` backfill takes
// (spec §5, GB7) for the duration of its run, released on return — mutual
// exclusion now runs both ways: the daemon steps aside for an in-progress
// CLI backfill exactly as the CLI steps aside for an in-progress daemon
// cycle, instead of only ever checking freshness read-only. The throttle
// check runs BEFORE the lock acquire so an idle poll tick (nothing due to
// run yet) never touches the lock file at all.
func (d *Daemon) phaseIdeas(ctx context.Context) {
	if d.ideasPipe == nil {
		return
	}
	interval := time.Duration(d.config.Ideas.MineIntervalHours) * time.Hour
	if d.config.Ideas.MineIntervalHours <= 0 {
		interval = time.Duration(config.DefaultIdeasMineIntervalHours) * time.Hour
	}
	now := time.Now()
	if !d.lastIdeas.IsZero() && now.Sub(d.lastIdeas) < interval {
		return
	}

	release, err := ideas.AcquireBackfillLock(d.config.WorkspaceDir(), "daemon")
	if err != nil {
		if d.lastIdeasLockSkip.IsZero() || now.Sub(d.lastIdeasLockSkip) >= ideasLockSkipLogThrottle {
			d.logger.Printf("ideas: skipping cycle — %v", err)
			d.lastIdeasLockSkip = now
		}
		return
	}
	defer release()

	d.trackedPipelineRun("ideas", func() pipelineRunStats {
		// The pipeline instance outlives this cycle — and is shared with
		// phaseStreamDigests — so both its drop counters and its usage
		// counters are lifetime totals across BOTH phases: log/report this
		// run's delta, never the running sum, or phaseStreamDigests' stage-1
		// tokens double-count into this phase's reported usage too.
		dropped0, rejected0 := d.ideasPipe.AccumulatedDrops()
		inTok0, outTok0, cost0, totalAPI0 := d.ideasPipe.AccumulatedUsage()
		proposed, err := d.ideasPipe.Run(ctx)
		if err != nil {
			d.logger.Printf("ideas error: %v", err)
		} else if proposed > 0 {
			d.logger.Printf("ideas: proposed %d", proposed)
		}
		if dropped, rejected := d.ideasPipe.AccumulatedDrops(); dropped > dropped0 || rejected > rejected0 {
			d.logger.Printf("ideas: slack_refs_dropped=%d refs_rejected=%d", dropped-dropped0, rejected-rejected0)
		}
		// The throttle advances whenever the pipeline RAN, error or not.
		// ideas.Run's partial-failure contract already carries the state:
		// every floor is honest about what was actually consumed, so
		// unconsumed material simply waits. Retrying an erroring pipeline on
		// the very next cycle buys nothing but repeated AI cost — and one
		// stuck account would otherwise pin the whole phase to every cycle.
		d.lastIdeas = now
		d.saveLastIdeas()
		inTok, outTok, cost, totalAPI := d.ideasPipe.AccumulatedUsage()
		return pipelineRunStats{items: proposed, inTok: inTok - inTok0, outTok: outTok - outTok0, cost: cost - cost0, totalAPI: totalAPI - totalAPI0, err: err}
	})
}

// streamsLockSkipLogThrottle is the ideasLockSkipLogThrottle precedent
// applied to phaseStreamDigests' own lock-skip log line.
const streamsLockSkipLogThrottle = 10 * time.Minute

// phaseStreamDigests runs the ideas registry's stage-1 Gmail/Jira stream
// pre-digests (ideas.Pipeline.RunStreamDigests) on its own schedule and gate
// (streams.enabled), independent of the stage-2 consolidator's phaseIdeas —
// the stream digests feed the Desktop Digests tab on their own. Runs right
// before phaseIdeas so both stages see the freshest inbox/digest state, and
// shares the same ideas.Pipeline instance (and its AI-usage accumulation)
// since both stages belong to the same package. Throttled to once per
// streams.interval_hours (default DefaultStreamsIntervalHours when
// unset/non-positive), and takes the same cross-process backfill lock
// phaseIdeas does — the two never interleave consumption of the same
// account floors — with the same log-throttle-not-skip-throttle shape (GB7).
func (d *Daemon) phaseStreamDigests(ctx context.Context) {
	if d.ideasPipe == nil {
		return
	}
	if !d.config.Streams.Enabled {
		return
	}
	interval := time.Duration(d.config.Streams.IntervalHours) * time.Hour
	if d.config.Streams.IntervalHours <= 0 {
		interval = time.Duration(config.DefaultStreamsIntervalHours) * time.Hour
	}
	now := time.Now()
	if !d.lastStreams.IsZero() && now.Sub(d.lastStreams) < interval {
		return
	}

	release, err := ideas.AcquireBackfillLock(d.config.WorkspaceDir(), "daemon")
	if err != nil {
		if d.lastStreamsLockSkip.IsZero() || now.Sub(d.lastStreamsLockSkip) >= streamsLockSkipLogThrottle {
			d.logger.Printf("stream-digests: skipping cycle — %v", err)
			d.lastStreamsLockSkip = now
		}
		return
	}
	defer release()

	d.trackedPipelineRun("stream-digests", func() pipelineRunStats {
		// The pipeline instance is shared with phaseIdeas, so AccumulatedUsage
		// is a lifetime total across BOTH phases — snapshot before the run and
		// report only this phase's own delta (the phaseIdeas precedent),
		// otherwise phaseIdeas' stage-2 tokens (from an earlier or later cycle
		// sharing the same instance) would double-count into this phase too.
		inTok0, outTok0, cost0, totalAPI0 := d.ideasPipe.AccumulatedUsage()
		err := d.ideasPipe.RunStreamDigests(ctx)
		if err != nil {
			d.logger.Printf("stream-digests error: %v", err)
		}
		// The throttle advances whenever the phase RAN, error or not — the
		// lastIdeas precedent: unconsumed material simply waits for the next
		// cycle rather than retrying immediately at repeated AI cost.
		d.lastStreams = now
		d.saveLastStreams()
		inTok, outTok, cost, totalAPI := d.ideasPipe.AccumulatedUsage()
		return pipelineRunStats{inTok: inTok - inTok0, outTok: outTok - outTok0, cost: cost - cost0, totalAPI: totalAPI - totalAPI0, err: err}
	})
}

// phaseMemory runs the memory consolidation pipeline (vault reconcile, entity
// seeding, situation ingest, episode extraction). Runs after inbox so freshly
// composed situations are visible, before next-step. The pipeline records its
// own pipeline_runs row (source="daemon", see SetMemoryPipeline), so there is
// no trackedPipelineRun wrapper here. Errors are logged and never abort the
// cycle; watermark freeze on failure is the pipeline's own business (MEM-04).
func (d *Daemon) phaseMemory(ctx context.Context) {
	if d.memoryPipe == nil {
		return
	}
	if !d.config.Memory.Enabled {
		d.logger.Printf("memory: disabled, skipping")
		return
	}
	stats, err := d.memoryPipe.Run(ctx)
	if errors.Is(err, memory.ErrLocked) {
		// A CLI consolidate/seed/reindex holds the memory lock — skip this
		// cycle, the next one picks up where the other run left off.
		d.logger.Printf("memory: skipping cycle — %v", err)
		return
	}
	if err != nil {
		d.logger.Printf("memory error: %v", err)
		return
	}
	situations := stats.Ingested.Created + stats.Ingested.Updated + stats.Ingested.Finalized
	if stats.Seeded > 0 || situations > 0 || stats.Episodes > 0 || stats.WindowsFailed > 0 {
		d.logger.Printf("memory: %d seeded, %d situation node(s), %d episode(s) from %d window(s) (%d failed, %d refs rejected)",
			stats.Seeded, situations, stats.Episodes, stats.Windows, stats.WindowsFailed, stats.RefsRejected)
	}
}

// phaseFeed mirrors source tables into the dashboard feed index. Runs last so
// it sees everything this cycle produced (situations, briefings, recaps, day
// plans). AI-free and best-effort: errors are logged, never propagated, and
// never affect the inbox pipeline or its watermarks (DASH-06).
func (d *Daemon) phaseFeed() {
	if d.feedPipe == nil {
		return
	}
	n, err := d.feedPipe.Publish(time.Now())
	if err != nil {
		d.logger.Printf("feed error: %v", err)
	}
	if n > 0 {
		d.logger.Printf("feed: published %d items", n)
	}
}

// phaseNextStep refreshes AI next-step suggestions for active targets whose
// suggestion is missing or stale (regenerated after a user edit). Runs after
// inbox so any targets just surfaced/created are included.
func (d *Daemon) phaseNextStep(ctx context.Context) {
	if d.nextStepPipe == nil {
		return
	}
	d.trackedPipelineRun("next_step", func() pipelineRunStats {
		n, err := d.nextStepPipe.GenerateAllNextSteps(ctx)
		if err != nil {
			d.logger.Printf("next-step error: %v", err)
		} else if n > 0 {
			d.logger.Printf("next-step: refreshed %d target(s)", n)
		}
		return pipelineRunStats{items: n, err: err}
	})
}

// phaseCustomTrackScan runs enabled custom tracks over recent activity,
// appending timeline events. Runs before auto-track extraction so folds land.
func (d *Daemon) phaseCustomTrackScan(ctx context.Context) {
	if d.customTracksPipe == nil {
		return
	}
	d.trackedPipelineRun("custom_tracks", func() pipelineRunStats {
		n, err := d.customTracksPipe.Run(ctx)
		if err != nil {
			d.logger.Printf("custom tracks error: %v", err)
		} else if n > 0 {
			d.logger.Printf("custom tracks: created %d event(s)", n)
		}
		return pipelineRunStats{items: n, err: err}
	})
}

// phaseBriefing generates the daily briefing once per scheduled day.
func (d *Daemon) phaseBriefing(ctx context.Context) {
	if d.briefingPipe == nil || !d.shouldRunBriefing() {
		return
	}
	d.trackedPipelineRun("briefing", func() pipelineRunStats {
		id, err := d.briefingPipe.Run(ctx)
		if err != nil {
			d.logger.Printf("briefing error: %v", err)
		} else if id > 0 {
			d.logger.Printf("generated briefing (id=%d)", id)
			d.lastBriefing = time.Now()
			d.saveLastBriefing()
		}
		items := 0
		if id > 0 {
			items = 1
		}
		inTok, outTok, cost, totalAPI := d.briefingPipe.AccumulatedUsage()
		return pipelineRunStats{
			items: items, inTok: inTok, outTok: outTok,
			cost: cost, totalAPI: totalAPI, err: err,
		}
	})
}

// applyInboxCurrentUser populates the inbox pipeline with the current user's
// id+email so it can filter mentions/DMs. The email falls back to the first
// connected google_accounts row with a resolved email when there is no Slack
// identity (no users row) — otherwise the Gmail/Calendar detectors can't
// match To/Cc/attendees. No-op when DB is unavailable.
func (d *Daemon) applyInboxCurrentUser() {
	if d.db == nil || d.inboxPipe == nil {
		return
	}
	uid, err := d.db.GetCurrentUserID()
	if err != nil {
		uid = ""
	}
	email := ""
	if uid != "" {
		if u, uerr := d.db.GetUserByID(uid); uerr == nil && u != nil {
			email = u.Email
		}
	}
	if email == "" {
		if accounts, aerr := d.db.ListGoogleAccounts(); aerr == nil {
			for _, a := range accounts {
				if a.Email != "" {
					email = a.Email
					break
				}
			}
		}
	}
	if uid == "" && email == "" {
		return
	}
	d.inboxPipe.SetCurrentUser(uid, email)
}

// autoMarkRead marks digests as read based on Slack read cursors.
// Safe to call when db is nil (no-op).
func (d *Daemon) autoMarkRead() {
	if d.db == nil {
		return
	}
	digestsMarked, tracksMarked, err := d.db.AutoMarkReadFromSlack()
	if err != nil {
		d.logger.Printf("auto-mark read error: %v", err)
	} else if digestsMarked > 0 || tracksMarked > 0 {
		d.logger.Printf("auto-marked %d digest(s), %d track(s) as read", digestsMarked, tracksMarked)
	}
}

func (d *Daemon) lastPeoplePath() string {
	return filepath.Join(d.config.WorkspaceDir(), "last_people.txt")
}

func (d *Daemon) loadLastPeople() {
	data, err := os.ReadFile(d.lastPeoplePath())
	if err != nil {
		return
	}
	unix, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return
	}
	d.lastPeople = time.Unix(unix, 0)
	d.logger.Printf("restored last people time: %s", d.lastPeople.Format(time.RFC3339))
}

func (d *Daemon) saveLastPeople() {
	data := strconv.FormatInt(d.lastPeople.Unix(), 10)
	if err := os.WriteFile(d.lastPeoplePath(), []byte(data), 0o600); err != nil {
		d.logger.Printf("failed to save last people time: %v", err)
	}
}

func (d *Daemon) lastIdeasPath() string {
	return filepath.Join(d.config.WorkspaceDir(), "last_ideas.txt")
}

func (d *Daemon) loadLastIdeas() {
	data, err := os.ReadFile(d.lastIdeasPath())
	if err != nil {
		return
	}
	unix, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return
	}
	d.lastIdeas = time.Unix(unix, 0)
	d.logger.Printf("restored last ideas time: %s", d.lastIdeas.Format(time.RFC3339))
}

func (d *Daemon) saveLastIdeas() {
	data := strconv.FormatInt(d.lastIdeas.Unix(), 10)
	if err := os.WriteFile(d.lastIdeasPath(), []byte(data), 0o600); err != nil {
		d.logger.Printf("failed to save last ideas time: %v", err)
	}
}

func (d *Daemon) lastStreamsPath() string {
	return filepath.Join(d.config.WorkspaceDir(), "last_streams.txt")
}

func (d *Daemon) loadLastStreams() {
	data, err := os.ReadFile(d.lastStreamsPath())
	if err != nil {
		return
	}
	unix, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return
	}
	d.lastStreams = time.Unix(unix, 0)
	d.logger.Printf("restored last streams time: %s", d.lastStreams.Format(time.RFC3339))
}

func (d *Daemon) saveLastStreams() {
	data := strconv.FormatInt(d.lastStreams.Unix(), 10)
	if err := os.WriteFile(d.lastStreamsPath(), []byte(data), 0o600); err != nil {
		d.logger.Printf("failed to save last streams time: %v", err)
	}
}

// shouldRunBriefing checks if the daily briefing should run.
// Runs at most once per calendar day, after the configured briefing.hour.
func (d *Daemon) shouldRunBriefing() bool {
	now := time.Now()

	if !d.lastBriefing.IsZero() && sameCalendarDay(d.lastBriefing, now) {
		return false
	}

	targetHour := d.config.Briefing.Hour
	if targetHour <= 0 {
		targetHour = config.DefaultBriefingHour
	}

	return now.Hour() >= targetHour
}

func sameCalendarDay(a, b time.Time) bool {
	ay, am, ad := a.Date()
	by, bm, bd := b.Date()
	return ay == by && am == bm && ad == bd
}

func (d *Daemon) lastBriefingPath() string {
	return filepath.Join(d.config.WorkspaceDir(), "last_briefing.txt")
}

func (d *Daemon) loadLastBriefing() {
	data, err := os.ReadFile(d.lastBriefingPath())
	if err != nil {
		return
	}
	unix, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return
	}
	d.lastBriefing = time.Unix(unix, 0)
	d.logger.Printf("restored last briefing time: %s", d.lastBriefing.Format(time.RFC3339))
}

func (d *Daemon) saveLastBriefing() {
	data := strconv.FormatInt(d.lastBriefing.Unix(), 10)
	if err := os.WriteFile(d.lastBriefingPath(), []byte(data), 0o600); err != nil {
		d.logger.Printf("failed to save last briefing time: %v", err)
	}
}

// shouldRunDayPlan returns true when the day-plan pipeline should generate a
// plan: enabled, hour gate passed, no plan yet for today.
func (d *Daemon) shouldRunDayPlan(now time.Time) bool {
	if d.dayPlanPipeline == nil {
		return false
	}
	cfg := d.config.DayPlan
	if !cfg.Enabled {
		return false
	}
	targetHour := cfg.Hour
	if targetHour <= 0 {
		targetHour = config.DefaultDayPlanHour
	}
	if now.Hour() < targetHour {
		return false
	}
	date := now.Format("2006-01-02")
	if d.lastDayPlanDate == date {
		return false
	}
	if d.db == nil {
		return true
	}
	userID, _ := d.db.GetCurrentUserID()
	if userID == "" {
		return false
	}
	existing, _ := d.db.GetDayPlan(userID, date)
	return existing == nil
}

// runDayPlanPhase is Phase 7: generate today's day plan once per day after
// the configured hour, immediately after the briefing phase.
func (d *Daemon) runDayPlanPhase(ctx context.Context, now time.Time) {
	if !d.shouldRunDayPlan(now) {
		return
	}
	if d.db == nil {
		return
	}
	userID, _ := d.db.GetCurrentUserID()
	if userID == "" {
		return
	}
	date := now.Format("2006-01-02")
	d.trackedPipelineRun("day_plan", func() pipelineRunStats {
		plan, err := d.dayPlanPipeline.Run(ctx, dayplan.RunOptions{UserID: userID, Date: date})
		items := 0
		if plan != nil {
			items = 1
		}
		inTok, outTok, cost, totalAPI := d.dayPlanPipeline.AccumulatedUsage()
		if err != nil {
			d.logger.Printf("dayplan: generation failed: %v", err)
		} else {
			d.lastDayPlanDate = date
			d.logger.Printf("dayplan: generated plan for %s", date)
		}
		return pipelineRunStats{items: items, inTok: inTok, outTok: outTok, cost: cost, totalAPI: totalAPI, err: err}
	})
}

// runDayPlanConflictPhase is Phase 8: every cycle, sync calendar items and
// re-detect conflicts on today's plan. Fires a log notice on false→true flip.
func (d *Daemon) runDayPlanConflictPhase(ctx context.Context, now time.Time) {
	if d.dayPlanPipeline == nil || d.db == nil {
		return
	}
	userID, _ := d.db.GetCurrentUserID()
	if userID == "" {
		return
	}
	date := now.Format("2006-01-02")

	prev, _ := d.db.GetDayPlan(userID, date)
	if prev == nil {
		return
	}
	prevHad := prev.HasConflicts

	if err := d.dayPlanPipeline.SyncCalendarItemsForDate(ctx, userID, date); err != nil {
		d.logger.Printf("dayplan: sync calendar items: %v", err)
	}
	if err := d.dayPlanPipeline.DetectConflicts(ctx, userID, date); err != nil {
		d.logger.Printf("dayplan: detect conflicts: %v", err)
	}

	updated, _ := d.db.GetDayPlan(userID, date)
	if updated != nil && !prevHad && updated.HasConflicts {
		summary := ""
		if updated.ConflictSummary.Valid {
			summary = updated.ConflictSummary.String
		}
		d.logger.Printf("dayplan: conflicts detected: %s", summary)
	}
}
