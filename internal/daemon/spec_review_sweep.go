package daemon

import (
	"context"
	"database/sql"
	"errors"
	"syscall"
	"time"

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

// phaseSpecReviewSweep repairs spec reviews the process that queued them never
// finished (docs/features/spec-review.md): a queued row older than a minute is
// launched again (three per cycle; a row launched three times is failed with
// "could not start"), and a running row whose process is gone, or that started
// longer ago than the reviewer's timeout plus a grace, is failed.
func (d *Daemon) phaseSpecReviewSweep(ctx context.Context) {
	if d.db == nil || d.specReviewLaunch == nil || ctx.Err() != nil {
		return
	}
	now := time.Now()
	queued, running, err := d.db.SpecReviewsToSweep(now)
	if err != nil {
		d.logger.Printf("spec review sweep: %v", err)
		return
	}
	for _, r := range running {
		dead := !specReviewPIDAlive(r.PID)
		if !dead {
			started, perr := time.Parse("2006-01-02T15:04:05Z", r.StartedAt)
			dead = perr == nil && now.Sub(started) > specreview.RunTimeout+specReviewGrace
		}
		if !dead {
			continue
		}
		if err := d.db.FailSpecReview(r.AskID, r.PID, specReviewDeadReason, now); err != nil {
			d.logger.Printf("spec review sweep: failing ask %d: %v", r.AskID, err)
		}
	}
	launched := 0
	for _, id := range queued {
		if ctx.Err() != nil || launched >= specReviewMaxRelaunch {
			return
		}
		row, err := d.db.GetSpecReview(id)
		if err != nil {
			d.logger.Printf("spec review sweep: reading ask %d: %v", id, err)
			continue
		}
		if row.Attempt >= specReviewMaxAttempts {
			// Failing needs a running row: claim it under pid 0 first.
			ok, err := d.db.ClaimSpecReview(id, 0, now)
			if err != nil || !ok {
				if err != nil {
					d.logger.Printf("spec review sweep: ask %d: %v", id, err)
				}
				continue
			}
			if err := d.db.FailSpecReview(id, 0, "could not start", now); err != nil {
				d.logger.Printf("spec review sweep: failing ask %d: %v", id, err)
			}
			continue
		}
		// Queueing again counts the launch and restarts the minute.
		if err := d.db.WithTx(func(tx *sql.Tx) error { return d.db.QueueSpecReview(tx, id, now) }); err != nil {
			d.logger.Printf("spec review sweep: requeueing ask %d: %v", id, err)
			continue
		}
		launched++
		if err := d.specReviewLaunch(id); err != nil {
			d.logger.Printf("spec review sweep: launching ask %d: %v", id, err)
		}
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
