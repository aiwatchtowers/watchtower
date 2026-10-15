// Package historybackfill walks each new source's history back to its floor,
// one chunk per source per daemon cycle, newest first
// (docs/features/history-backfill.md).
package historybackfill

import (
	"context"
	"errors"
	"fmt"
	"log"
	"math"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/planusage"
)

// ErrHold is what a Source returns (wrapped) for a transient condition such
// as a Slack rate limit: the runner holds the chunk for a later cycle like a
// passed budget deadline — no strike, no advance, the Step ends (R23).
var ErrHold = errors.New("history backfill: hold the chunk")

// Source fetches one account's raw data for a range. Process runs the AI
// steps over that range. Auth reports whether the account can be used now.
type Source interface {
	Kind() string // slack | gmail | imap | jira
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
	SetHistoryBackfillLastError(id int64, msg string, now time.Time) error
	GetPlanUsageStatus() (*db.PlanUsageStatus, error)
}

// Runner is the daemon's history backfill phase.
type Runner struct {
	Store       Store
	Sources     []Source                                         // the cycle's wired sources
	Account     func(kind string, id int64) AccountState         // auth/removal lookup
	OnSlackDone func(ctx context.Context, floor time.Time) error // each Step while every slack row is done/off, under the budget ctx; the caller owns run-once
	Budget      time.Duration                                    // 5 min
	Now         func() time.Time
	Logger      *log.Logger
}

const waitingPlanLimit = "plan_limit"

// Step runs one cycle: at most one chunk per running source, within Budget.
// Fetch, Process and the Slack-done hook all run under the Budget deadline.
func (r *Runner) Step(ctx context.Context) error {
	rows, err := r.Store.ListHistoryBackfills()
	if err != nil {
		return err
	}
	bctx, cancel := context.WithTimeout(ctx, r.Budget)
	defer cancel()
	err = r.runRows(ctx, bctx, rows)
	if ctx.Err() == nil && bctx.Err() == nil {
		r.slackDone(bctx, rows)
	}
	return err
}

// runRows walks the rows in id order, updating each row's in-memory copy as
// it changes it.
func (r *Runner) runRows(ctx, bctx context.Context, rows []db.HistoryBackfill) error {
	start := r.Now()
	for i := range rows {
		row := &rows[i]
		if row.Status == "done" || row.Status == "off" {
			continue
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if bctx.Err() != nil || r.Now().Sub(start) >= r.Budget {
			return nil //nolint:nilerr // the budget is spent: the rest waits for the next Step, not a failure
		}
		stop, err := r.runRow(ctx, bctx, row)
		if err != nil || stop {
			return err
		}
	}
	return nil
}

// runRow handles one row; stop ends the Step.
func (r *Runner) runRow(ctx, bctx context.Context, row *db.HistoryBackfill) (stop bool, err error) {
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

	if err := src.Fetch(bctx, from, to); err != nil {
		return r.fail(ctx, bctx, row, fromTS, from, to, fmt.Errorf("fetch: %w", err))
	}

	if r.nearLimit() {
		if row.Waiting != waitingPlanLimit {
			if err := r.Store.SetHistoryBackfillWaiting(row.ID, waitingPlanLimit, r.Now()); err != nil {
				return true, err
			}
			row.Waiting = waitingPlanLimit
			r.logf("history backfill: Claude plan limit near, processing waits (%s account %d)", row.SourceKind, row.AccountID)
		}
		return true, nil
	}
	if row.Waiting != "" {
		if err := r.Store.SetHistoryBackfillWaiting(row.ID, "", r.Now()); err != nil {
			return true, err
		}
		row.Waiting = ""
	}

	complete, err := src.Process(bctx, from, to)
	if err != nil {
		return r.fail(ctx, bctx, row, fromTS, from, to, fmt.Errorf("process: %w", err))
	}
	if !complete {
		return true, nil // budget cut or lock held: retry the chunk next cycle
	}
	return false, r.advance(row, fromTS)
}

// fail records a chunk failure; the third failure of a chunk skips it. A
// canceled context is a shutdown, and a passed Budget deadline or a source's
// ErrHold holds the chunk for the next cycle: none is a failure, and all
// stop the Step.
func (r *Runner) fail(ctx, bctx context.Context, row *db.HistoryBackfill, fromTS float64, from, to time.Time, err error) (stop bool, _ error) {
	if ctxErr := ctx.Err(); ctxErr != nil {
		return true, ctxErr
	}
	select {
	case <-bctx.Done(): // the Budget deadline passed: hold the chunk
		return true, nil
	default:
	}
	if errors.Is(err, ErrHold) {
		r.logf("history backfill: %s account %d chunk [%s, %s) held for a later cycle: %v",
			row.SourceKind, row.AccountID, from.Format(time.RFC3339), to.Format(time.RFC3339), err)
		return true, nil
	}
	n, recErr := r.Store.RecordHistoryBackfillFailure(row.ID, err.Error(), r.Now())
	if recErr != nil {
		return false, recErr
	}
	row.ChunkFailures = n
	row.LastError = err.Error()
	if n < MaxChunkFailures {
		r.logf("history backfill: %s account %d chunk [%s, %s) failed (%d of %d): %v",
			row.SourceKind, row.AccountID, from.Format(time.RFC3339), to.Format(time.RFC3339), n, MaxChunkFailures, err)
		return false, nil
	}
	r.logf("history backfill: SKIPPING %s account %d chunk [%s, %s) after %d failures: %v",
		row.SourceKind, row.AccountID, from.Format(time.RFC3339), to.Format(time.RFC3339), n, err)
	if advErr := r.advance(row, fromTS); advErr != nil {
		return false, advErr
	}
	// The advance cleared last_error; keep a trace of the skip until the
	// next successful chunk clears it (R23).
	trace := fmt.Sprintf("skipped %s..%s: %v", from.Format(time.RFC3339), to.Format(time.RFC3339), err)
	if setErr := r.Store.SetHistoryBackfillLastError(row.ID, trace, r.Now()); setErr != nil {
		return false, setErr
	}
	row.LastError = trace
	return false, nil
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

// slackDone calls OnSlackDone when every slack row is done or off and at
// least one is done, with the lowest floor of the done rows. It runs on every
// such Step; the caller keeps its own run-once stamp. An error is only logged.
func (r *Runner) slackDone(ctx context.Context, rows []db.HistoryBackfill) {
	if r.OnSlackDone == nil {
		return
	}
	floor := math.Inf(1)
	for _, row := range rows {
		if row.SourceKind != "slack" {
			continue
		}
		switch row.Status {
		case "done":
			floor = min(floor, row.FloorTS)
		case "off":
		default:
			return
		}
	}
	if math.IsInf(floor, 1) {
		return // no done slack row
	}
	if err := r.OnSlackDone(ctx, unixTime(floor)); err != nil {
		r.logf("history backfill: slack-done follow-up: %v", err)
	}
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
