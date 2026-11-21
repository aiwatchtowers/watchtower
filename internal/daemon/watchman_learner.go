package daemon

import (
	"context"

	"watchtower/internal/aiconsent"
	"watchtower/internal/prompts"
	"watchtower/internal/watchman"
)

// startWatchmanLearner runs the learner beside the sync loop (spec
// 2026-11-21-watchman-tuning §3): a pass at start, then on every Watchman
// wake (forwardWakes: `watchman learn --start` and the first hand-over send
// one) and every cycle's nudge. A pass learns each workbench Watchman is on
// for and still learning (db.WatchmanLearningSQL) to the end, with no time
// budget. The returned stop cancels it and waits for the pass to end (the
// cursors keep every batch written; the next start resumes).
func (d *Daemon) startWatchmanLearner(ctx context.Context) (stop func()) {
	if d.db == nil {
		return func() {}
	}
	if d.watchmanLearnWake == nil {
		d.watchmanLearnWake = make(chan struct{}, 1)
	}
	d.watchmanLearnCycle = make(chan struct{}, 1)
	runCtx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		cycle := true // the start counts as a cycle
		for {
			d.runWatchmanLearner(runCtx, cycle)
			select {
			case <-runCtx.Done():
				return
			case <-d.watchmanLearnWake:
				cycle = false
			case <-d.watchmanLearnCycle:
				cycle = true
			}
		}
	}()
	return func() {
		cancel()
		<-done
	}
}

// nudgeWatchmanLearner asks the learner for a pass this cycle (no-op before
// it starts; a pass already asked for absorbs it).
func (d *Daemon) nudgeWatchmanLearner() {
	select {
	case d.watchmanLearnCycle <- struct{}{}:
	default:
	}
}

// runWatchmanLearner is one learner pass; cycle is whether a cycle (or the
// start) asked for it rather than a wake. Background AI paused (BGAI-01),
// read before each workbench and between its batches, ends the pass; the
// next wake or cycle resumes from the cursors. A workbench whose learn lock
// is held (`watchman learn --start` learning it) is skipped. One whose pass
// failed is logged by id and counts and retried on the next cycle only — a
// wake skips it — while the others go on. Logs carry ids and counts, never
// text. Only the learner's goroutine calls it.
func (d *Daemon) runWatchmanLearner(ctx context.Context, cycle bool) {
	if ctx.Err() != nil {
		return
	}
	if cycle || d.watchmanLearnFailed == nil {
		d.watchmanLearnFailed = map[int64]bool{}
	}
	ids, err := d.db.WatchmanWorkbenches()
	if err != nil {
		d.logger.Printf("watchman learner: %v", err)
		return
	}
	// Read directly (not consentNow, whose log state belongs to the cycle
	// goroutine), as the twin's pass does.
	read := d.consent
	if read == nil {
		read = aiconsent.Current
	}
	allowed := func() bool { return read().Allowed() }
	for _, wb := range ids {
		if ctx.Err() != nil || !allowed() {
			return
		}
		if d.watchmanLearnFailed[wb] {
			continue
		}
		learning, err := d.db.WatchmanStillLearning(wb)
		if err != nil {
			d.logger.Printf("watchman learner: workbench %d: %v", wb, err)
			continue
		}
		if learning && !d.learnWorkbench(ctx, wb, allowed) {
			d.watchmanLearnFailed[wb] = true
		}
	}
}

// learnWorkbench learns one workbench to the end under its learn lock:
// every source batch after batch, then the relabel pass, checking ctx and
// allowed between batches. Its labels run outside the cycle's AI worker
// pool (watchmanTwinGenerator, one call at a time), so a busy cycle never
// times a batch out waiting for a slot. Done, the twin is nudged: the
// questions that waited for the learning are leased now. ok is false when
// the pass failed (not on a shutdown, a pause or a held lock).
func (d *Daemon) learnWorkbench(ctx context.Context, wb int64, allowed func() bool) (ok bool) {
	unlock, locked, err := watchman.TryLearnLock(d.config.WorkspaceDir(), wb)
	if err != nil {
		d.logger.Printf("watchman learner: workbench %d: %v", wb, err)
		return false
	}
	if !locked {
		return true // `watchman learn --start` has it
	}
	defer unlock()
	if d.routingJob != nil {
		ctx, _ = d.routingJob(ctx, ctx)
	}
	ctx = aiconsent.WithAdmitted(ctx, "phase:watchman-learn")
	ok = true
	d.trackedPipelineRun("watchman-learn", func() pipelineRunStats {
		labeler := watchman.NewLLMLabeler(d.watchmanTwinGenerator(ctx), prompts.New(d.db, nil))
		st, err := watchman.Learn(ctx, d.db, wb, watchman.LearnOptions{Sources: watchmanSources(ctx, d, wb), Labeler: labeler, Proceed: allowed})
		d.logWatchmanLearn(wb, st)
		switch {
		case err != nil && isBenignShutdownErr(ctx, err):
			d.logger.Printf("watchman learner: workbench %d: stopped by shutdown", wb)
			err = nil
		case err != nil:
			d.logger.Printf("watchman learner: workbench %d: %v, retried next cycle", wb, err) // source errors are fingerprinted (FILES-01)
			ok = false
		}
		return pipelineRunStats{items: st.Written + st.Relabelled, err: err}
	})
	learning, err := d.db.WatchmanStillLearning(wb)
	if err != nil {
		d.logger.Printf("watchman learner: workbench %d: %v", wb, err)
		return ok
	}
	if !learning {
		d.logger.Printf("watchman learner: workbench %d learned", wb)
		d.nudgeWatchmanTwin()
	}
	return ok
}
