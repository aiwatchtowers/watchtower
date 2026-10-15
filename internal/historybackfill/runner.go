// Package historybackfill walks each new source's history back to its floor,
// one chunk per source per daemon cycle, newest first
// (docs/features/history-backfill.md).
package historybackfill

import (
	"context"
	"fmt"
	"log"
	"math"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/planusage"
)

// Source fetches one account's raw data for a range. Process runs the AI
// steps over that range. Auth reports whether the account can be used now.
type Source interface {
	Kind() string // slack | gmail | imap
	AccountID() int64
	Fetch(ctx context.Context, from, to time.Time) error
	Process(ctx context.Context, from, to time.Time) (complete bool, err error)
}

// AccountState is what the account lookup says about a row's account.
type AccountState int

const (
	AccountOK AccountState = iota
	AccountRevoked
	AccountGone
)

// Store is the persistence the runner needs; *db.DB satisfies it.
type Store interface {
	ListHistoryBackfills() ([]db.HistoryBackfill, error)
	AdvanceHistoryBackfill(id int64, reachedTS float64, now time.Time) error
	RecordHistoryBackfillFailure(id int64, msg string, now time.Time) (int, error)
	SetHistoryBackfillStatus(id int64, status string, now time.Time) error
	SetHistoryBackfillWaiting(id int64, waiting string, now time.Time) error
	GetPlanUsageStatus() (*db.PlanUsageStatus, error)
}

// Runner is the daemon's history backfill phase.
type Runner struct {
	Store       Store
	Sources     []Source                                   // the cycle's wired sources
	Account     func(kind string, id int64) AccountState   // auth/removal lookup
	OnSlackDone func(ctx context.Context, floor time.Time) // once, when every slack row is done
	Budget      time.Duration                              // 5 min
	Now         func() time.Time
	Logger      *log.Logger
}

const waitingPlanLimit = "plan_limit"

// Step runs one cycle: at most one chunk per running source, within Budget.
func (r *Runner) Step(ctx context.Context) error {
	rows, err := r.Store.ListHistoryBackfills()
	if err != nil {
		return err
	}
	slackDone, err := r.runRows(ctx, rows)
	// The done transition is the trigger, so a restart never repeats the hook.
	// It runs even when the loop stopped on an error after the transition.
	if slackDone {
		r.maybeSlackDone(ctx, rows)
	}
	return err
}

// runRows walks the rows in id order, updating each row's in-memory copy as
// it changes it, and reports whether a slack row became done.
func (r *Runner) runRows(ctx context.Context, rows []db.HistoryBackfill) (slackDone bool, err error) {
	start := r.Now()
	for i := range rows {
		row := &rows[i]
		if row.Status == "done" || row.Status == "off" {
			continue
		}
		if err := ctx.Err(); err != nil {
			return slackDone, err
		}
		if r.Now().Sub(start) >= r.Budget {
			return slackDone, nil
		}
		stop, err := r.runRow(ctx, row)
		if row.Status == "done" && row.SourceKind == "slack" {
			slackDone = true
		}
		if err != nil || stop {
			return slackDone, err
		}
	}
	return slackDone, nil
}

// runRow handles one row; stop ends the Step.
func (r *Runner) runRow(ctx context.Context, row *db.HistoryBackfill) (stop bool, err error) {
	switch r.Account(row.SourceKind, row.AccountID) {
	case AccountGone:
		return false, r.setStatus(row, "off")
	case AccountRevoked:
		if row.Status != "paused" {
			return false, r.setStatus(row, "paused")
		}
		return false, nil
	case AccountOK:
	}
	if row.Status == "paused" {
		if err := r.setStatus(row, "running"); err != nil {
			return false, err
		}
	}

	src := r.source(row.SourceKind, row.AccountID)
	if src == nil {
		return false, nil // feature off or wiring failed: wait for a later cycle
	}

	fromTS, toTS, ok := NextChunk(row.ReachedTS, row.FloorTS)
	if !ok {
		return false, r.advance(row, row.FloorTS)
	}
	from, to := unixTime(fromTS), unixTime(toTS)

	if err := src.Fetch(ctx, from, to); err != nil {
		return false, r.fail(ctx, row, fromTS, from, to, fmt.Errorf("fetch: %w", err))
	}

	if r.nearLimit() {
		if row.Waiting != waitingPlanLimit {
			if err := r.Store.SetHistoryBackfillWaiting(row.ID, waitingPlanLimit, r.Now()); err != nil {
				return true, err
			}
			row.Waiting = waitingPlanLimit
		}
		r.logf("history backfill: Claude plan limit near, processing waits (%s account %d)", row.SourceKind, row.AccountID)
		return true, nil
	}
	if row.Waiting != "" {
		if err := r.Store.SetHistoryBackfillWaiting(row.ID, "", r.Now()); err != nil {
			return true, err
		}
		row.Waiting = ""
	}

	complete, err := src.Process(ctx, from, to)
	if err != nil {
		return false, r.fail(ctx, row, fromTS, from, to, fmt.Errorf("process: %w", err))
	}
	if !complete {
		return true, nil // budget cut or lock held: retry the chunk next cycle
	}
	return false, r.advance(row, fromTS)
}

// fail records a chunk failure; the third failure of a chunk skips it. A
// canceled context is a shutdown, not a failure.
func (r *Runner) fail(ctx context.Context, row *db.HistoryBackfill, fromTS float64, from, to time.Time, err error) error {
	if ctxErr := ctx.Err(); ctxErr != nil {
		return ctxErr
	}
	n, recErr := r.Store.RecordHistoryBackfillFailure(row.ID, err.Error(), r.Now())
	if recErr != nil {
		return recErr
	}
	row.ChunkFailures = n
	row.LastError = err.Error()
	if n < MaxChunkFailures {
		r.logf("history backfill: %s account %d chunk [%s, %s) failed (%d of %d): %v",
			row.SourceKind, row.AccountID, from.Format(time.RFC3339), to.Format(time.RFC3339), n, MaxChunkFailures, err)
		return nil
	}
	r.logf("history backfill: SKIPPING %s account %d chunk [%s, %s) after %d failures: %v",
		row.SourceKind, row.AccountID, from.Format(time.RFC3339), to.Format(time.RFC3339), n, err)
	return r.advance(row, fromTS)
}

func (r *Runner) advance(row *db.HistoryBackfill, reachedTS float64) error {
	if err := r.Store.AdvanceHistoryBackfill(row.ID, reachedTS, r.Now()); err != nil {
		return err
	}
	row.ReachedTS, row.ChunkFailures, row.LastError, row.Waiting = reachedTS, 0, "", ""
	if reachedTS <= row.FloorTS {
		row.Status = "done"
	}
	return nil
}

func (r *Runner) setStatus(row *db.HistoryBackfill, status string) error {
	if err := r.Store.SetHistoryBackfillStatus(row.ID, status, r.Now()); err != nil {
		return err
	}
	row.Status = status
	return nil
}

// nearLimit reads the plan gate; an unreadable status does not block.
func (r *Runner) nearLimit() bool {
	st, err := r.Store.GetPlanUsageStatus()
	if err != nil {
		r.logf("history backfill: plan usage status: %v", err)
		return false
	}
	return planusage.NearLimit(st)
}

func (r *Runner) source(kind string, id int64) Source {
	for _, s := range r.Sources {
		if s.Kind() == kind && s.AccountID() == id {
			return s
		}
	}
	return nil
}

// maybeSlackDone calls OnSlackDone with the lowest slack floor once every
// slack row is done.
func (r *Runner) maybeSlackDone(ctx context.Context, rows []db.HistoryBackfill) {
	if r.OnSlackDone == nil {
		return
	}
	floor := math.Inf(1)
	for _, row := range rows {
		if row.SourceKind != "slack" {
			continue
		}
		if row.Status != "done" {
			return
		}
		floor = min(floor, row.FloorTS)
	}
	r.OnSlackDone(ctx, unixTime(floor))
}

func (r *Runner) logf(format string, args ...any) {
	if r.Logger != nil {
		r.Logger.Printf(format, args...)
	}
}

func unixTime(ts float64) time.Time {
	sec, frac := math.Modf(ts)
	return time.Unix(int64(sec), int64(frac*1e9)).UTC()
}
