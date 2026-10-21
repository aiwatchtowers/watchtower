package purge

import (
	"context"
	"errors"
	"fmt"
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

// Run purges one account (PURGE-02): it starts a scheduled row, runs every
// step in chunks of ChunkRows rows until the step deletes nothing, counts the
// rows on the ledger, deletes the account's token files outside any
// transaction and marks the row done and the account purged. It stops when
// budget is spent or ctx is done and returns done=false; the next cycle
// resumes the running row from the top of its (idempotent) step list. A
// failed chunk is recorded on the row and returned. No remote revoke call is
// made: the grant is already dead, or there is no network.
func Run(ctx context.Context, d *db.DB, workspaceDir string, p db.AccountPurge, budget time.Duration) (bool, error) {
	if p.State == "scheduled" {
		if err := d.StartAccountPurge(p.ID); err != nil {
			return false, err
		}
	}
	steps, err := db.PurgeSteps(p.Source, p.AccountID)
	if err != nil {
		return false, err
	}
	deadline := time.Now().Add(budget)
	for _, step := range steps {
		for {
			if ctx.Err() != nil || !time.Now().Before(deadline) {
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
				break
			}
			if err := d.AddPurgeRows(p.ID, n); err != nil {
				return false, err
			}
		}
	}
	if err := deleteTokens(ctx, workspaceDir, p.Source, p.AccountID); err != nil {
		return false, fail(d, p.ID, err)
	}
	if err := d.FinishAccountPurge(p.ID, p.Source, p.AccountID); err != nil {
		return false, err
	}
	return true, nil
}

// fail records err on the ledger row and returns it (joined with a failure
// to record it).
func fail(d *db.DB, id int64, err error) error {
	if ferr := d.FailAccountPurge(id, err.Error()); ferr != nil {
		return errors.Join(err, ferr)
	}
	return err
}

// deleteTokens removes the account's credential files, as the per-source
// remove commands do; a missing file is fine. Jira and Linear tokens are
// deleted under their cross-process token lock, so a refresh in another
// process cannot write the file back.
func deleteTokens(ctx context.Context, dir, source string, id int64) error {
	switch source {
	case "slack":
		return wrapTokenErr(source, slack.NewTokenStore(dir, id).Delete())
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
