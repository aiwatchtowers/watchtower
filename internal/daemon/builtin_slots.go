package daemon

import (
	"context"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/config"
	"watchtower/internal/ideas"
)

// The C3 built-ins' ids, and the builtin_migrations id of the custom-track
// move (the watch recipes: no built-in of its own).
const (
	trackMyThreadsID = "track-my-threads"
	ideaFinderID     = "idea-finder"
	customTracksID   = "custom-tracks"
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
		d.builtins.RunSlot(ctx, builtin.SlotTracks)
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
	d.builtins.RunSlot(ctx, builtin.SlotIdeas)
}
