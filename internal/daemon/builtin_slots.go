package daemon

import (
	"context"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/ideas"
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
	mailWaitingID    = builtin.MailWaitingID
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
// show differs from what its last succeeded run showed — the open people
// items as the shipped recipe reads them (builtin.WaitingFingerprint over
// db.WaitingPeople; mail is Mail waiting's) with the recipe's hashes. A
// quiet cycle writes no run. An owner's copy runs
// every cycle: it may show what the fingerprint does not cover. A failed read is
// due (the run reports it); a daemon start knows no fingerprint, so its
// first cycle runs. Attention detection off skips the built-in before the
// gate is asked (its feature, FEAT-01), and a queued Run Now runs without
// asking it. A built-in that is not active is never due.
func (d *Daemon) WaitingForMeGate() builtin.Gate {
	return waitingGate{d: d, id: waitingForMeID, kind: db.WaitingPeople}
}

// MailWaitingGate is Mail waiting's sync gate: Waiting for me's rules over
// the mail senders and counts (builtin.WaitingFingerprint over
// db.WaitingMail), so a new sender, a changed count or a mute runs it, and
// a new people item does not. It keeps its own seen/shown marks.
func (d *Daemon) MailWaitingGate() builtin.Gate {
	return waitingGate{d: d, id: mailWaitingID, kind: db.WaitingMail}
}

// waitingGate is the gate of the built-in id at the Waiting for me slot,
// over its fingerprint kind.
type waitingGate struct {
	d    *Daemon
	id   string
	kind db.WaitingKind
}

func (g waitingGate) Due(ctx context.Context, _ builtin.Entry, now time.Time) bool {
	d := g.d
	seen, shown, ok := d.waitingMarks(g.id)
	if !ok {
		// No marks to compare: run, and say so.
		d.logger.Printf("%s: no Waiting for me marks for this built-in; it runs every cycle", g.id)
		return true
	}
	*seen = ""
	if !d.builtinOn(g.id) {
		return false
	}
	a, err := d.db.GetBuiltinAutomation(g.id)
	if err != nil {
		d.logger.Printf("%s: reading its row: %v", g.id, err)
		return true
	}
	if a.Overridden {
		// The owner's copy may show what the fingerprint does not cover
		// (other reads, other fields): it runs every cycle.
		return true
	}
	fp, err := builtin.WaitingFingerprint(ctx, d.db, now, g.kind)
	if err != nil {
		d.logger.Printf("%s: reading the open items: %v", g.id, err)
		return true
	}
	*seen = fp + "/" + a.ContentHash + "/" + a.ConfirmedHash
	return *seen != *shown
}

// waitingMarks is the seen/shown marks of the Waiting for me slot's
// built-in id; ok false for any other id.
func (d *Daemon) waitingMarks(id string) (seen, shown *string, ok bool) {
	switch id {
	case waitingForMeID:
		return &d.waitingSeen, &d.waitingShown, true
	case mailWaitingID:
		return &d.mailSeen, &d.mailShown, true
	}
	return nil, nil, false
}

// phaseWaitingForMe is the Waiting for me slot, right after phaseInbox:
// Waiting for me, then Mail waiting, each rewrites its one living artifact
// from the open attention items when its gate finds a change. A succeeded
// slot run records what its gate read as shown; any failed run (a Run Now
// included) forgets what was shown, so the next cycle runs it again. Neither
// has a legacy phase: until one is active its queued Run Now is cancelled
// (only the slot would take it) and its gate is never due; the slot is
// skipped while neither is active.
func (d *Daemon) phaseWaitingForMe(ctx context.Context) {
	now := time.Now()
	active := false
	for _, id := range []string{waitingForMeID, mailWaitingID} {
		if d.builtinOn(id) {
			active = true
		} else {
			d.cancelQueuedBuiltinRuns(id, now, cancelInactive)
		}
	}
	if !active {
		return
	}
	d.ensureBuiltinsSwept()
	d.waitingSeen, d.mailSeen = "", ""
	for _, o := range d.builtins.RunSlot(ctx, builtin.SlotWaitingForMe) {
		seen, shown, ok := d.waitingMarks(o.BuiltinID)
		switch {
		case !ok:
		case slotRunFailed(o):
			// Any failed run — a Run Now too, which the gate never saw —
			// leaves the artifact behind: the next cycle runs again.
			*shown = ""
		case o.RunID != 0 && o.Status == db.RunSucceeded && *seen != "":
			*shown = *seen
		}
	}
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
		d.cancelQueuedBuiltinRuns(trackMyThreadsID, now, cancelLegacy)
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
		d.cancelQueuedBuiltinRuns(ideaFinderID, time.Now(), cancelLegacy)
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
