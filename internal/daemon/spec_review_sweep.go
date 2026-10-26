package daemon

import (
	"context"
	"errors"
	"syscall"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/specreview"
)

const (
	// specReviewMaxRelaunch bounds the queued reviews one cycle starts again.
	specReviewMaxRelaunch = 3
	// specReviewMaxAttempts is how many launches a queued review gets before
	// it is failed as "could not start".
	specReviewMaxAttempts = 3
	// specReviewGrace is added to the reviewer's own run timeout before a
	// running row counts as abandoned.
	specReviewGrace = 2 * time.Minute

	specReviewDeadReason = "reviewer process ended without a result"
)

// SetSpecReviewLaunch wires the launcher of the independent spec reviewer
// (cmd.LaunchSpecReview with the binary and log dir); nil = no sweep.
func (d *Daemon) SetSpecReviewLaunch(f func(askID int64) error) {
	d.specReviewLaunch = f
}

// specReviewOverdueAfter is how long after its start a running review counts
// as abandoned even while its pid lives; a var so a test can shorten it.
var specReviewOverdueAfter = specreview.RunTimeout + specReviewGrace

// specReviewBeforeRelaunch is a test hook between the sweep's listing and its
// re-queue of one row (the window a slow reviewer's claim can land in).
var specReviewBeforeRelaunch func(askID int64)

// phaseSpecReviewSweep repairs spec reviews the process that queued them never
// finished (docs/features/spec-review.md): a queued row older than a minute is
// launched again (three per cycle; a row launched three times is failed with
// "could not start"), and a running row whose process is gone, or that started
// longer ago than the reviewer's timeout plus a grace, is failed — an overdue
// reviewer that still runs is stopped first (SIGTERM to its process group).
func (d *Daemon) phaseSpecReviewSweep(ctx context.Context) {
	if d.db == nil || ctx.Err() != nil {
		return
	}
	now := time.Now()
	d.sweepSpecLoops(now)
	if d.specReviewLaunch == nil {
		return
	}
	queued, running, err := d.db.SpecReviewsToSweep(now)
	if err != nil {
		d.logger.Printf("spec review sweep: %v", err)
		return
	}
	for _, r := range running {
		alive := specReviewPIDAlive(r.PID)
		started, perr := db.ParseSpecReviewTime(r.StartedAt)
		overdue := alive && perr == nil && now.Sub(started) > specReviewOverdueAfter
		if alive && !overdue {
			continue
		}
		if overdue {
			d.stopSpecReviewer(r.AskID, r.PID, started)
		}
		if err := d.db.FailSpecReview(r.AskID, r.PID, specReviewDeadReason, now); err != nil {
			d.logger.Printf("spec review sweep: failing ask %d: %v", r.AskID, err)
		}
		d.revealSpecLoop(r.AskID, specreview.EndReviewerFailed, now)
	}
	launched := 0
	for _, id := range queued {
		if ctx.Err() != nil || launched >= specReviewMaxRelaunch {
			return
		}
		if specReviewBeforeRelaunch != nil {
			specReviewBeforeRelaunch(id)
		}
		// Re-queued only while still queued with launches left, so a row a
		// slow reviewer has just claimed is never reset under it.
		ok, err := d.db.RelaunchQueuedSpecReview(id, specReviewMaxAttempts, now)
		if err != nil {
			d.logger.Printf("spec review sweep: requeueing ask %d: %v", id, err)
			continue
		}
		if ok {
			launched++
			if err := d.specReviewLaunch(id); err != nil {
				d.logger.Printf("spec review sweep: launching ask %d: %v", id, err)
			}
			continue
		}
		// Not re-queued: claimed meanwhile, or out of launches. Failing
		// needs a running row: claim it under pid 0 first (a lost claim
		// means a reviewer owns it now).
		claimed, err := d.db.ClaimSpecReview(id, 0, now)
		if err != nil {
			d.logger.Printf("spec review sweep: ask %d: %v", id, err)
			continue
		}
		if !claimed {
			continue
		}
		if err := d.db.FailSpecReview(id, 0, "could not start", now); err != nil {
			d.logger.Printf("spec review sweep: failing ask %d: %v", id, err)
		}
		d.revealSpecLoop(id, specreview.EndReviewerFailed, now)
	}
}

// sweepSpecLoops ends the author loops that cannot go on: the asking session
// is gone, or the author left a delivered round unanswered for AuthorTimeout.
// It needs no launcher.
func (d *Daemon) sweepSpecLoops(now time.Time) {
	rows, err := d.db.SpecLoopsToSweep()
	if err != nil {
		d.logger.Printf("spec review sweep: %v", err)
		return
	}
	for _, r := range rows {
		switch {
		case !r.SessionBound:
			d.revealSpecLoop(r.AskID, specreview.EndSessionGone, now)
		case r.Status == "done":
			fin, perr := db.ParseSpecReviewTime(r.FinishedAt)
			if perr == nil && fin.Add(specreview.AuthorTimeout).Before(now) {
				d.revealSpecLoop(r.AskID, specreview.EndTimeout, now)
			}
		}
	}
}

// revealSpecLoop reveals ask id's loop (a no-op on a row not in the loop).
func (d *Daemon) revealSpecLoop(id int64, end string, now time.Time) {
	if err := specreview.Reveal(d.db, id, end, now); err != nil {
		d.logger.Printf("spec review sweep: revealing ask %d: %v", id, err)
	}
}

// stopSpecReviewer sends SIGTERM to an overdue reviewer's process group: the
// launcher starts it with Setsid, so its pid leads its own group, and its
// shutdown handler cancels the model call. Only a process that still leads
// its group and started no later than the row's started_at (a second of
// slack: started_at has whole seconds) is the reviewer; a reused pid is left
// alone.
func (d *Daemon) stopSpecReviewer(askID int64, pid int, started time.Time) {
	if pgid, err := syscall.Getpgid(pid); err != nil || pgid != pid {
		return
	}
	ident, err := readProcessIdentityOS(pid)
	if err != nil || ident.startTime.After(started.Add(time.Second)) {
		return
	}
	if err := syscall.Kill(-pid, syscall.SIGTERM); err != nil && !errors.Is(err, syscall.ESRCH) {
		d.logger.Printf("spec review sweep: stopping the reviewer of ask %d: %v", askID, err)
	}
}

// specReviewPIDAlive reports whether a process with pid exists. EPERM means it
// exists (another user's); only ESRCH, or a pid that was never recorded, is gone.
func specReviewPIDAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	return !errors.Is(syscall.Kill(pid, 0), syscall.ESRCH)
}
