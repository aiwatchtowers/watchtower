package purge

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"watchtower/internal/calendar"
	"watchtower/internal/db"
	"watchtower/internal/jira"
	"watchtower/internal/linear"
	"watchtower/internal/slack"
)

// tokenLockTimeout bounds the wait for a Jira/Linear token lock (a refresh
// in another process holds it for one request).
const tokenLockTimeout = time.Minute

// ErrNoLongerDue is returned by Run for a scheduled row that, re-read just
// before it would start, is cancelled or no longer due (a reconnect since the
// plan). Nothing is deleted; the scheduler handles the row next pass.
var ErrNoLongerDue = errors.New("the purge is no longer due")

// afterReplan runs between start's re-plan and its StartAccountPurge; tests
// land an access proof there.
var afterReplan = func() {}

// afterStep runs after each step of Run has drained; tests land a row there.
var afterStep = func(db.PurgeStep) {}

// afterSteps runs between Run's last step and its verify count; tests land a
// left-behind row there.
var afterSteps = func() {}

// clock is Run's time source: the start's re-plan and the budget; a seam for
// tests.
var clock = time.Now

// verifyLeftPrefix starts the error of a purge whose verify count found rows
// left; VerifyHeld recognises such a row by it.
const verifyLeftPrefix = "left: "

// purgeLeft is the verify count (db.PurgeLeft); a seam for tests.
var purgeLeft = (*db.DB).PurgeLeft

// Run purges one account (PURGE-02): it starts a scheduled row — after
// re-planning that one account against the current rows, since the caller's
// plan is a snapshot —, runs every step in chunks of ChunkRows rows until the
// step deletes nothing, counts the rows on the ledger, verifies that no step
// still matches a row (#1769, A4: rows left end the row failed with
// "left: <table>=<n>, …"; a failed count is a failed chunk), deletes the
// account's token files outside any transaction and marks the row done and
// the account purged. rules (Rules) is the scheduler's: the start re-plans
// with it. It stops when budget is spent or ctx is done and returns
// done=false; the next cycle resumes the running row from the top of its
// (idempotent) step list. A failed chunk is recorded on the row and returned;
// the MaxChunkFailures-th failure in a row ends the row failed. When the
// account proved access after the purge started (a Re-login during the run),
// its token files are kept and FinishAccountPurge keeps the account. No
// remote revoke call is made: the grant is already dead, or there is no
// network.
func Run(ctx context.Context, d *db.DB, workspaceDir string, p db.AccountPurge,
	rules func(db.PurgeAccount) Rule, budget time.Duration) (bool, error) {
	if p.State == "scheduled" {
		if err := start(d, p, rules, clock()); err != nil {
			return false, err
		}
	}
	steps, err := d.PurgeSteps(p.Source, p.AccountID)
	if err != nil {
		return false, fail(d, p.ID, err)
	}
	deadline := clock().Add(budget)
	for _, step := range steps {
		for {
			if ctx.Err() != nil || !clock().Before(deadline) {
				return false, nil //nolint:nilerr // shutdown or a spent budget is a pause, not a failure: resume next cycle
			}
			n, err := d.RunPurgeStep(ctx, step, ChunkRows)
			if err != nil {
				if ctx.Err() != nil {
					return false, nil //nolint:nilerr // shutdown cut the chunk off (rolled back): resume next cycle
				}
				return false, fail(d, p.ID, err)
			}
			if n == 0 {
				afterStep(step)
				break
			}
			if err := d.AddPurgeRows(p.ID, n); err != nil {
				return false, err
			}
		}
	}
	afterSteps()
	if paused, err := verify(ctx, d, p, steps, deadline); paused || err != nil {
		return false, err
	}
	back, err := d.PurgeAccessReturned(p.ID)
	if err != nil {
		return false, err
	}
	if !back {
		if err := deleteTokens(ctx, workspaceDir, p.Source, p.AccountID); err != nil {
			return false, fail(d, p.ID, err)
		}
	}
	if _, err := d.FinishAccountPurge(p.ID, p.Source, p.AccountID); err != nil {
		return false, err
	}
	return true, nil
}

// start re-plans the one account of a scheduled row against the current
// account and ledger rows with the scheduler's rules and moves the row to
// running only when it is still due; otherwise ErrNoLongerDue.
// StartAccountPurge re-checks the account in its own statement against the
// row's own cutoff (Cutoff: a removed Slack account's zero lease needs the
// account still removed), so an access proof or an "add again" written
// between the re-plan and the start also leaves the row scheduled.
func start(d *db.DB, p db.AccountPurge, rules func(db.PurgeAccount) Rule, now time.Time) error {
	accounts, err := d.ListPurgeAccounts()
	if err != nil {
		return err
	}
	open, err := d.ListAccountPurges(true)
	if err != nil {
		return err
	}
	var current []db.AccountPurge
	for _, o := range open {
		if o.ID == p.ID {
			current = append(current, o)
		}
	}
	due := false
	for _, r := range Plan(accounts, current, rules, now).Due {
		due = due || (r.ID == p.ID && r.State == "scheduled")
	}
	if !due {
		return fmt.Errorf("purge %d: %w", p.ID, ErrNoLongerDue)
	}
	cutoff, requireRemoved := now.Add(-Lease), false
	for _, a := range accounts {
		if a.Source == p.Source && a.ID == p.AccountID {
			cutoff, requireRemoved = Cutoff(a, rules(a), now)
		}
	}
	afterReplan()
	started, err := d.StartAccountPurge(p.ID, cutoff, requireRemoved)
	if err != nil {
		return err
	}
	if !started {
		return fmt.Errorf("purge %d: %w", p.ID, ErrNoLongerDue)
	}
	return nil
}

// verify counts what the steps the run executed still match after the last
// one (PURGE-02, A4), under ctx and the run's budget: a shutdown or a spent
// budget there is a pause (paused, nil error: the row stays running and
// resumes next cycle). A failed count is recorded like a failed chunk
// (retried next cycle, MaxChunkFailures in a row end the row); rows left end
// the row failed at once, error verifyLeftPrefix + "<table>=<n>, …" in table
// order, and the account stays held (VerifyHeld).
func verify(ctx context.Context, d *db.DB, p db.AccountPurge, steps []db.PurgeStep, deadline time.Time) (paused bool, err error) {
	remaining := deadline.Sub(clock())
	if remaining <= 0 || ctx.Err() != nil {
		return true, nil
	}
	countCtx, cancel := context.WithTimeout(ctx, remaining)
	defer cancel()
	left, err := purgeLeft(d, countCtx, steps)
	if err != nil {
		if countCtx.Err() != nil || !clock().Before(deadline) {
			return true, nil
		}
		return false, fail(d, p.ID, err)
	}
	if len(left) == 0 {
		return false, nil
	}
	tables := make([]string, 0, len(left))
	for t := range left {
		tables = append(tables, t)
	}
	sort.Strings(tables)
	pairs := make([]string, len(tables))
	for i, t := range tables {
		pairs[i] = fmt.Sprintf("%s=%d", t, left[t])
	}
	msg := verifyLeftPrefix + strings.Join(pairs, ", ")
	if _, err := d.FailAccountPurge(p.ID, msg, 1); err != nil {
		return false, errors.Join(errors.New(msg), err)
	}
	return false, fmt.Errorf("purge %d failed: %s", p.ID, msg)
}

// fail records err on the ledger row and returns it (joined with a failure
// to record it); the MaxChunkFailures-th failure in a row ends the row.
func fail(d *db.DB, id int64, err error) error {
	failed, ferr := d.FailAccountPurge(id, err.Error(), MaxChunkFailures)
	if ferr != nil {
		return errors.Join(err, ferr)
	}
	if failed {
		return fmt.Errorf("purge %d failed after %d attempts in a row: %w", id, MaxChunkFailures, err)
	}
	return err
}

// deleteTokens removes the account's credential files, as the per-source
// remove commands do; a missing file is fine. Slack, Jira and Linear tokens
// are deleted under their cross-process token lock, so a refresh in another
// process cannot write the file back.
func deleteTokens(ctx context.Context, dir, source string, id int64) error {
	switch source {
	case "slack":
		store := slack.NewTokenStore(dir, id)
		return wrapTokenErr(source, deleteLocked(ctx, store.Lock, store.Delete))
	case "google":
		return wrapTokenErr(source, errors.Join(
			calendar.NewAccountTokenStore(dir, id).Delete(),
			calendar.NewCredentialStore(dir, id).Delete(),
		))
	case "jira":
		store := jira.NewTokenStore(dir, id)
		return wrapTokenErr(source, deleteLocked(ctx, store.Lock, store.Delete))
	case "linear":
		store := linear.NewTokenStore(dir, id)
		return wrapTokenErr(source, deleteLocked(ctx, store.Lock, store.Delete))
	default:
		return fmt.Errorf("purge: unknown source %q", source)
	}
}

func deleteLocked(ctx context.Context, lock func(context.Context) (func(), error), del func() error) error {
	lockCtx, cancel := context.WithTimeout(ctx, tokenLockTimeout)
	defer cancel()
	unlock, err := lock(lockCtx)
	if err != nil {
		return err
	}
	defer unlock()
	return del()
}

func wrapTokenErr(source string, err error) error {
	if err != nil {
		return fmt.Errorf("purge: deleting %s token files: %w", source, err)
	}
	return nil
}
