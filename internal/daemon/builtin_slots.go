package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	gosync "sync"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/ideas"
	"watchtower/internal/policy"
	"watchtower/internal/reactioncmd"
)

// The C3 built-ins' ids, and the builtin_migrations id of the custom-track
// move (the watch recipes: no built-in of its own).
const (
	trackMyThreadsID = "track-my-threads"
	ideaFinderID     = "idea-finder"
	customTracksID   = "custom-tracks"
	reactionsID      = "reactions"
	waitingForMeID   = "waiting-for-me"
	slackTodayID     = builtin.SlackTodayID
)

// TrackMyThreadsPrimitives is tracks.extract over the daemon's tracks
// pipeline, tracked as pipeline_runs "tracks" with the run's window.
func (d *Daemon) TrackMyThreadsPrimitives() map[string]automations.PrimitiveFunc {
	var p builtin.TracksRunner
	if d.tracksPipe != nil {
		p = d.tracksPipe
	}
	return builtin.TrackMyThreadsPrimitives(p, builtin.ThreadsHooks{Track: d.runTracksTracked})
}

// IdeaFinderPrimitives is ideas.consolidate over the daemon's ideas
// pipeline: the backfill lock taken as "daemon", the run tracked as
// pipeline_runs "ideas" and the lastIdeas throttle stamped whenever it ran.
func (d *Daemon) IdeaFinderPrimitives() map[string]automations.PrimitiveFunc {
	var p builtin.IdeasRunner
	if d.ideasPipe != nil {
		p = d.ideasPipe
	}
	return builtin.IdeaFinderPrimitives(p, builtin.IdeaHooks{
		Lock:  func() (func(), error) { return ideas.AcquireBackfillLock(d.config.WorkspaceDir(), "daemon") },
		Track: d.runIdeasTracked,
	})
}

// ReactionPrimitives is reaction.compose over the daemon's reaction-commands
// pipeline and its reaction slot.
func (d *Daemon) ReactionPrimitives() map[string]automations.PrimitiveFunc {
	var p builtin.ReactionDispatcher
	if d.reactionCmdPipe != nil {
		p = d.reactionCmdPipe
	}
	return builtin.ReactionPrimitives(p, d.reactionSlot)
}

// WatchPrimitives is track.scan over the daemon's custom-track pipeline.
func (d *Daemon) WatchPrimitives() map[string]automations.PrimitiveFunc {
	var s builtin.WatchScanner
	if d.customTracksPipe != nil {
		s = d.customTracksPipe
	}
	return builtin.WatchPrimitives(d.db, s, d.planOwner, nil)
}

// WaitingForMePrimitives is attention.waiting over the daemon's database.
func (d *Daemon) WaitingForMePrimitives() map[string]automations.PrimitiveFunc {
	return builtin.WaitingPrimitives(d.db, time.Now)
}

// WaitingForMeGate is Waiting for me's sync gate: due when what it would
// show differs from what its last succeeded run showed — the open items as
// their rows read by the shipped recipe (builtin.WaitingFingerprint) with
// the recipe's hashes. A quiet cycle writes no run. An owner's copy runs
// every cycle: it may show what the fingerprint does not cover. A failed read is
// due (the run reports it); a daemon start knows no fingerprint, so its
// first cycle runs. Attention detection off skips the built-in before the
// gate is asked (its feature, FEAT-01), and a queued Run Now runs without
// asking it.
func (d *Daemon) WaitingForMeGate() builtin.Gate { return waitingForMeGate{d: d} }

type waitingForMeGate struct{ d *Daemon }

func (g waitingForMeGate) Due(ctx context.Context, _ builtin.Entry, now time.Time) bool {
	d := g.d
	d.waitingSeen = ""
	a, err := d.db.GetBuiltinAutomation(waitingForMeID)
	if err != nil {
		d.logger.Printf("waiting-for-me: reading its row: %v", err)
		return true
	}
	if a.Overridden {
		// The owner's copy may show what the fingerprint does not cover
		// (other reads, other fields): it runs every cycle.
		return true
	}
	fp, err := builtin.WaitingFingerprint(ctx, d.db, now)
	if err != nil {
		d.logger.Printf("waiting-for-me: reading the open items: %v", err)
		return true
	}
	d.waitingSeen = fp + "/" + a.ContentHash + "/" + a.ConfirmedHash
	return d.waitingSeen != d.waitingShown
}

// phaseWaitingForMe is Waiting for me's slot, right after phaseInbox: the
// built-in rewrites its one living artifact from the open attention items
// when its gate finds a change. A succeeded slot run records what the gate
// read as shown; any failed run (a Run Now included) forgets what was
// shown, so the next cycle runs again. It
// has no legacy phase: until it is active its queued Run Now is cancelled
// (only the slot would take it).
func (d *Daemon) phaseWaitingForMe(ctx context.Context) {
	if !d.builtinOn(waitingForMeID) {
		d.cancelQueuedBuiltinRuns(waitingForMeID, time.Now())
		return
	}
	d.ensureBuiltinsSwept()
	d.waitingSeen = ""
	for _, o := range d.builtins.RunSlot(ctx, builtin.SlotWaitingForMe) {
		switch {
		case o.BuiltinID != waitingForMeID:
		case slotRunFailed(o):
			// Any failed run — a Run Now too, which the gate never saw —
			// leaves the artifact behind: the next cycle runs again.
			d.waitingShown = ""
		case o.RunID != 0 && o.Status == db.RunSucceeded && d.waitingSeen != "":
			d.waitingShown = d.waitingSeen
		}
	}
}

// Slack today's gate timings: a succeeded sync run is followed by the next
// one an hour later at the earliest; a failed one is retried 15 minutes
// after it.
const (
	slackTodayInterval   = 60 * time.Minute
	slackTodayRetryAfter = 15 * time.Minute
)

// SlackTodayPrimitives is slack.window over the daemon's database.
func (d *Daemon) SlackTodayPrimitives() map[string]automations.PrimitiveFunc {
	return builtin.SlackWindowPrimitives(d.db, time.Now)
}

// SlackTodayGate is Slack today's sync gate. Not due with no enabled Slack
// account (removed and purged ones left out) or with Slack off by policy,
// nor within 15 minutes of a failed sync run newer than the last succeeded
// one, whatever the day or the cursor says (a failing run is not retried
// every cycle). Then due without waiting for the hour when the committed
// state's day is not today's local date (the card resets after midnight,
// new messages or not) — only when the state has a "today" value, or when
// the last succeeded sync run was queued before local midnight (none counts
// as before), so a recipe that writes no "today" is not run every cycle —
// or when its window cursor is behind (the last window was cut by a cap).
// Otherwise due when that failure is 15 minutes old, else when the last
// succeeded sync run is an hour old (none = due) — and only with material:
// an in-scope message past the cursor since local midnight. A failed read is
// logged and counts as due (the run reports it); a failed read before the
// failed-run hold (the accounts, the row, the state, the run times) counts
// as due at most once per slackTodayRetryAfter, as the hold would not see a
// run that never started. An owner's edited copy is read with the shipped
// state shape (a bad shape logs and counts as due). Slack today off skips
// the built-in before the gate is asked (FEAT-01), and a queued Run Now
// runs without asking it.
func (d *Daemon) SlackTodayGate() builtin.Gate { return &slackTodayGate{d: d} }

type slackTodayGate struct {
	d *Daemon
	// mu guards lastErrDue: when a failed read before the hold last
	// counted as due (in memory: a restart may count once more).
	mu         gosync.Mutex
	lastErrDue time.Time
}

// errDue logs a failed read before the hold and reports whether it counts
// as due: once per slackTodayRetryAfter.
func (g *slackTodayGate) errDue(now time.Time, format string, args ...any) bool {
	g.d.logger.Printf("slack-today: "+format, args...)
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.lastErrDue.IsZero() && now.Sub(g.lastErrDue) < slackTodayRetryAfter {
		return false
	}
	g.lastErrDue = now
	return true
}

func (g *slackTodayGate) Due(ctx context.Context, e builtin.Entry, now time.Time) bool {
	d := g.d
	if !policy.SourceAllowed("slack") {
		return false
	}
	switch on, err := d.slackAccountEnabled(); {
	case err != nil:
		return g.errDue(now, "listing the Slack accounts: %v", err)
	case !on:
		return false
	}
	a, err := d.db.GetBuiltinAutomation(slackTodayID)
	if err != nil {
		return g.errDue(now, "reading its row: %v", err)
	}
	state, err := d.db.GetAutomationState(a.ID)
	if err != nil {
		return g.errDue(now, "reading automation %d's state: %v", a.ID, err)
	}
	t, err := d.slackTodayTiming(ctx, a.ID, now)
	if err != nil {
		return g.errDue(now, "automation %d's last runs: %v", a.ID, err)
	}
	if t.hold {
		return false
	}
	local := now.In(time.Local)
	midnight := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, time.Local)
	day, hasDay, err := slackTodayDay(state)
	if err != nil {
		d.logger.Printf("slack-today: automation %d's state: %v", a.ID, err)
		return true
	}
	if day != local.Format("2006-01-02") && (hasDay || !t.hasOK || t.lastOK.Before(midnight)) {
		return true
	}
	after, behind, err := automations.WindowCursorOf(state, automations.SlackWindowStateKey)
	if err != nil {
		d.logger.Printf("slack-today: automation %d's state: %v", a.ID, err)
		return true
	}
	if behind {
		return true
	}
	if !t.timeDue {
		return false
	}
	has, err := d.db.SlackWindowHasMaterial(ctx, db.SlackWindowQuery{
		Scope:      e.WindowScope,
		AfterRowID: after,
		Floor:      midnight,
		Now:        local,
	})
	if err != nil {
		d.logger.Printf("slack-today: checking automation %d's window for new messages: %v", a.ID, err)
		return true
	}
	return has
}

// slackTodayTimes is the gate's timing rule over the built-in's sync runs.
// hold: a failed run newer than the last succeeded one (or with none) is
// less than slackTodayRetryAfter old — not due, whatever the day or the
// cursor says. timeDue: that failure is old enough, or else the last
// succeeded run is slackTodayInterval old (none = due). lastOK is when the
// last succeeded run was queued (hasOK false: none).
type slackTodayTimes struct {
	hold, timeDue, hasOK bool
	lastOK               time.Time
}

func (d *Daemon) slackTodayTiming(ctx context.Context, id int64, now time.Time) (slackTodayTimes, error) {
	ok, hasOK, err := d.db.LastAutomationRunQueuedAt(ctx, id, db.TriggerSync, []string{db.RunSucceeded})
	if err != nil {
		return slackTodayTimes{}, err
	}
	failed, hasFailed, err := d.db.LastAutomationRunQueuedAt(ctx, id, db.TriggerSync,
		[]string{db.RunFailed, db.RunBudgetExceeded, db.RunTimedOut})
	if err != nil {
		return slackTodayTimes{}, err
	}
	t := slackTodayTimes{hasOK: hasOK, lastOK: ok}
	if hasFailed && (!hasOK || failed.After(ok)) {
		retry := now.Sub(failed) >= slackTodayRetryAfter
		t.hold, t.timeDue = !retry, retry
		return t, nil
	}
	t.timeDue = !hasOK || now.Sub(ok) >= slackTodayInterval
	return t, nil
}

// slackAccountEnabled reports whether a Slack account is enabled and
// neither removed nor purged.
func (d *Daemon) slackAccountEnabled() (bool, error) {
	accts, err := d.db.ListSlackAccounts()
	if err != nil {
		return false, err
	}
	for _, a := range accts {
		if a.Enabled && a.Status != "removed" && a.Status != "purged" {
			return true, nil
		}
	}
	return false, nil
}

// slackTodayDay is the day of the recipe's committed "today" state; has is
// false when the state has no "today" value yet.
func slackTodayDay(state json.RawMessage) (day string, has bool, err error) {
	if len(state) == 0 {
		return "", false, nil
	}
	var all map[string]json.RawMessage
	if err := json.Unmarshal(state, &all); err != nil {
		return "", false, fmt.Errorf("decoding the state: %w", err)
	}
	raw, ok := all["today"]
	if !ok || string(raw) == "null" {
		return "", false, nil
	}
	var today struct {
		Day string `json:"day"`
	}
	if err := json.Unmarshal(raw, &today); err != nil {
		return "", false, fmt.Errorf("decoding its today key: %w", err)
	}
	return today.Day, true, nil
}

// phaseSlackToday is Slack today's slot, right after phaseWaitingForMe: the
// built-in labels today's new channel messages into its one living artifact
// when its gate says so. It has no legacy phase: until it is active its
// queued Run Now is cancelled (only the slot would take it). Slack today off
// is skipped by the runner before any read (FEAT-01).
func (d *Daemon) phaseSlackToday(ctx context.Context) {
	if !d.builtinOn(slackTodayID) {
		d.cancelQueuedBuiltinRuns(slackTodayID, time.Now())
		return
	}
	d.ensureBuiltinsSwept()
	d.builtins.RunSlot(ctx, builtin.SlotSlackToday)
}

// TrackMyThreadsGate is Track my threads' sync gate: tracks and digests on, a
// tracks pipeline, an owner, and material (tracks.Pipeline.HasMaterial: new
// digests since the last tracks run, or owed retry digests). A quiet cycle
// therefore writes neither an automation run nor a pipeline_runs row.
func (d *Daemon) TrackMyThreadsGate() builtin.Gate { return trackMyThreadsGate{d: d} }

type trackMyThreadsGate struct{ d *Daemon }

func (g trackMyThreadsGate) Due(_ context.Context, _ builtin.Entry, now time.Time) bool {
	d := g.d
	if !d.config.Tracks.Enabled || !d.config.Digest.Enabled || d.tracksPipe == nil || d.db == nil {
		return false
	}
	switch owner, err := d.db.ResolveOwner(); {
	case err != nil:
		d.logger.Printf("tracks: resolving the owner: %v", err)
		return false
	case !owner.Known():
		d.logNoOwnerOnce(now, "tracks")
		return false
	}
	if failed := d.tracksFailedAttempt(); !failed.IsZero() {
		// A run failed before tracks.extract ran (the owner's copy threw):
		// only digests newer than that attempt make the next one due.
		// created_at has whole seconds and the compare is strict, so the
		// bound steps back one second: a digest from the attempt's own
		// second counts (at most one extra attempt, never hidden material).
		fresh, err := d.db.GetDigestsCreatedAfter("channel", failed.Add(-time.Second).UTC().Format(time.RFC3339))
		if err != nil {
			d.logger.Printf("tracks: checking for new digests: %v", err)
			return true
		}
		return len(fresh) > 0
	}
	has, err := d.tracksPipe.HasMaterial()
	if err != nil {
		// The briefing precedent: a failed read counts as material, so the
		// run reports the error.
		d.logger.Printf("tracks: checking for new digests: %v", err)
		return true
	}
	return has
}

// IdeaFinderGate is the Idea finder's sync gate: ideas on, an ideas
// pipeline, ideas.mine_interval_hours elapsed since lastIdeas, and no fresh
// backfill lock (a probe: ideas.consolidate takes the lock itself, and a run
// that loses that race is skipped). A held lock's skip is logged at most
// once per ideasLockSkipLogThrottle.
func (d *Daemon) IdeaFinderGate() builtin.Gate { return ideaFinderGate{d: d} }

type ideaFinderGate struct{ d *Daemon }

func (g ideaFinderGate) Due(_ context.Context, _ builtin.Entry, now time.Time) bool {
	d := g.d
	if !d.config.Ideas.Enabled || d.ideasPipe == nil || !d.ideasThrottleElapsed(now) {
		return false
	}
	if !ideas.BackfillLockFresh(d.config.WorkspaceDir()) {
		return true
	}
	d.ideasMu.Lock()
	defer d.ideasMu.Unlock()
	if d.lastIdeasLockSkip.IsZero() || now.Sub(d.lastIdeasLockSkip) >= ideasLockSkipLogThrottle {
		d.logger.Printf("ideas: skipping cycle — an ideas backfill is mining right now")
		d.lastIdeasLockSkip = now
	}
	return false
}

// ideasThrottleElapsed reports whether ideas.mine_interval_hours (default
// config.DefaultIdeasMineIntervalHours when unset or non-positive) has passed
// since the ideas registry last ran.
func (d *Daemon) ideasThrottleElapsed(now time.Time) bool {
	interval := time.Duration(d.config.Ideas.MineIntervalHours) * time.Hour
	if d.config.Ideas.MineIntervalHours <= 0 {
		interval = time.Duration(config.DefaultIdeasMineIntervalHours) * time.Hour
	}
	d.ideasMu.Lock()
	defer d.ideasMu.Unlock()
	return d.lastIdeas.IsZero() || now.Sub(d.lastIdeas) >= interval
}

// builtinOn reports whether built-in id runs at its slot (wired and moved);
// otherwise its producers run as legacy phases.
func (d *Daemon) builtinOn(id string) bool {
	return d.builtins != nil && d.builtinActive[id]
}

// ensureBuiltinsSwept retries the start's sweep of the runs a previous
// daemon left (sweepBuiltinRuns) before a slot, until it has succeeded.
func (d *Daemon) ensureBuiltinsSwept() {
	if !d.builtinsSwept {
		d.sweepBuiltinRuns()
	}
}

// phaseWatchSlot is the custom-track slot, where phaseCustomTrackScan ran.
// It runs only while tracks and digests are on (FEAT-01: the watches stop
// with Track my threads). Until the custom-tracks move is done it first
// runs the legacy scan, which scans only the tracks bound to no recipe;
// then the watch recipes run (builtin.Runner.RunWatchSlot), each due one an
// automation run of its own. A watch run writes no pipeline_runs row.
func (d *Daemon) phaseWatchSlot(ctx context.Context) {
	if !d.config.Tracks.Enabled || !d.config.Digest.Enabled {
		if d.builtins != nil { // a queued Run Now or Scan from would wait forever
			d.builtins.CancelQueuedWatchRuns()
		}
		return
	}
	if !d.builtinOn(customTracksID) {
		d.phaseCustomTrackScan(ctx)
	}
	if d.builtins == nil || d.customTracksPipe == nil {
		return
	}
	d.ensureBuiltinsSwept()
	d.builtins.RunWatchSlot(ctx, builtin.NewWatchGate(d.db, d.customTracksPipe, d.logger))
}

// phaseTrackMyThreads (group A, beside people cards) is the Track my threads
// slot, where phaseTracksAndRollups ran: with the built-in not active the
// legacy tracks phase (and its queued Run Now cancelled: only the slot would
// take it), otherwise the built-in's slot run. Then, whether or not
// extraction was due, the active tracks go to the digest pipeline and the
// rollups run, as before. now is the rollup budget's date.
func (d *Daemon) phaseTrackMyThreads(ctx context.Context, now time.Time) {
	if d.builtinOn(trackMyThreadsID) {
		d.ensureBuiltinsSwept()
		start := time.Now()
		for _, o := range d.builtins.RunSlot(ctx, builtin.SlotTracks) {
			if o.BuiltinID == trackMyThreadsID && slotRunFailed(o) {
				d.noteTracksFailedAttempt(start)
			}
		}
	} else {
		d.cancelQueuedBuiltinRuns(trackMyThreadsID, now)
		d.phaseTracks(ctx)
	}
	d.injectTrackContext()
	d.runRollupPhase(ctx, now)
}

// phaseIdeaFinder is the Idea finder slot, where phaseIdeas ran: with the
// built-in not active the legacy phase (and its queued Run Now cancelled),
// otherwise the built-in's slot run.
func (d *Daemon) phaseIdeaFinder(ctx context.Context) {
	if !d.builtinOn(ideaFinderID) {
		d.cancelQueuedBuiltinRuns(ideaFinderID, time.Now())
		d.phaseIdeas(ctx)
		return
	}
	d.ensureBuiltinsSwept()
	start := time.Now()
	for _, o := range d.builtins.RunSlot(ctx, builtin.SlotIdeas) {
		if o.BuiltinID == ideaFinderID && slotRunFailed(o) {
			d.stampIdeasIfNotRan(start)
		}
	}
}

// slotRunFailed reports whether o is a run that ended in a failure.
func slotRunFailed(o builtin.SlotOutcome) bool {
	if o.RunID == 0 {
		return false
	}
	switch o.Status {
	case db.RunFailed, db.RunBudgetExceeded, db.RunTimedOut, builtin.StatusError:
		return true
	}
	return false
}

// stampIdeasIfNotRan stamps the lastIdeas throttle at start when the Idea
// finder's run failed before ideas.consolidate ran (which stamps it
// itself): an owner's copy that throws is then tried once per
// ideas.mine_interval_hours, as an erroring pipeline is, not every cycle.
func (d *Daemon) stampIdeasIfNotRan(start time.Time) {
	d.ideasMu.Lock()
	defer d.ideasMu.Unlock()
	if d.lastIdeas.Before(start) {
		d.lastIdeas = start
		d.saveLastIdeas()
	}
}

// noteTracksFailedAttempt records start as a failed Track my threads
// attempt when tracks.extract did not run since (no pipeline_runs row moved
// the gate's watermark): the gate then waits for digests newer than it.
func (d *Daemon) noteTracksFailedAttempt(start time.Time) {
	d.tracksMu.Lock()
	defer d.tracksMu.Unlock()
	if d.tracksRanAt.Before(start) {
		d.tracksFailedAt = start
	}
}

// tracksFailedAttempt is the failed attempt noteTracksFailedAttempt
// recorded, zero when none is pending (tracks.extract ran since).
func (d *Daemon) tracksFailedAttempt() time.Time {
	d.tracksMu.Lock()
	defer d.tracksMu.Unlock()
	return d.tracksFailedAt
}

// setReactionDispatch points the reaction pass at its dispatcher before a
// poll. With the Reactions built-in not active the pass composes in Go
// (the legacy dispatcher) and claims as before. Active and confirmed, each
// claimed command is composed by the built-in's recipe (reactionDispatcher).
// Active but not confirmed, or stopped by the daemon (AUTO-08), or with its
// row unreadable, the pass still seeds and publishes reaction events but
// claims nothing, so those reactions dispatch once it can run again.
func (d *Daemon) setReactionDispatch() {
	p := d.reactionCmdPipe
	if !d.builtinOn(reactionsID) {
		p.SetDispatcher(nil)
		p.SetDispatchPaused(false)
		return
	}
	d.ensureBuiltinsSwept()
	a, err := d.db.GetBuiltinAutomation(reactionsID)
	if err != nil {
		d.logger.Printf("reaction-commands: reading the Reactions automation, claiming nothing this poll: %v", err)
	} else if a.DisabledReason == "" && a.Confirmed() {
		p.SetDispatcher(d.reactionDispatcher())
		p.SetDispatchPaused(false)
		return
	}
	// Not confirmed or stopped: silent here, as a slot skip is (the start
	// logs the owner copy's state).
	p.SetDispatcher(nil)
	p.SetDispatchPaused(true)
}

// reactionDispatcher composes each claimed command through one sync run of
// the Reactions built-in (builtin.ReactionDispatch over the daemon's runner
// and reaction slot).
func (d *Daemon) reactionDispatcher() reactioncmd.Dispatcher {
	return builtin.ReactionDispatch(d.builtins, d.reactionSlot, d.logger)
}
