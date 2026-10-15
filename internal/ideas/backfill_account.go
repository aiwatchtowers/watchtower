package ideas

import (
	"context"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// BackfillEmail is the history backfill's stage-1 pass for ONE Google
// account (docs/features/history-backfill.md, R28): it lowers only that
// account's ideas_email_floor to from, drains its email pre-digests in
// (from, to] (the process side of the chunk convention in
// internal/historybackfill/chunk.go), and restores the floor to max(saved, reached). No other account, no
// Jira pass and no consolidator: the stream digests it writes are
// consolidated by the regular ideas run, which keeps the ideas.enabled gate.
// complete is false when the drain hit its cycle cap before the window was
// empty; the caller retries the chunk. reached is the floor the drain got to
// before the restore — also on an error or a cut ctx — so a retry can start
// there instead of re-paying the passes already done (F2).
func (p *Pipeline) BackfillEmail(ctx context.Context, accountID int64, from, to time.Time) (reached time.Time, complete bool, err error) {
	if p.generator == nil {
		return to, true, nil
	}
	acct, err := p.db.GetGoogleAccount(accountID)
	if err != nil {
		return from, false, fmt.Errorf("backfill email: account %d: %w", accountID, err)
	}
	saved, err := p.db.IdeasEmailFloor(accountID)
	if err != nil {
		return from, false, fmt.Errorf("backfill email: reading floor for account %d: %w", accountID, err)
	}
	// Never raise a floor that is already below the window: that would skip
	// the mail between it and from, and the restore would then jump past it.
	lowered := float64(from.Unix())
	if saved > 0 && saved < lowered {
		lowered = saved
	}
	if err := p.db.SetIdeasEmailFloor(accountID, lowered); err != nil {
		return from, false, fmt.Errorf("backfill email: lowering floor for account %d: %w", accountID, err)
	}
	defer p.restoreEmailFloors(map[int64]float64{accountID: saved})

	floor := func() (string, error) {
		f, err := p.db.IdeasEmailFloor(accountID)
		return fmt.Sprint(f), err
	}
	complete, err = p.drainAccount(floor, func() error { return p.runEmailDigestAccount(ctx, acct, to) },
		fmt.Sprintf("email account %d", accountID))
	reached = from
	if f, ferr := p.db.IdeasEmailFloor(accountID); ferr == nil && f > 0 {
		reached = time.Unix(int64(f), 0).UTC() // floors are whole seconds (maxTS of a rendered window)
	}
	return reached, complete, err
}

// BackfillJira is BackfillEmail's Jira counterpart (R29): it lowers only
// that Jira account's ideas_jira_floor to from, drains its Jira pre-digests
// bounded by to, and restores max(saved, reached). No email, no consolidator.
// reached is as in BackfillEmail.
func (p *Pipeline) BackfillJira(ctx context.Context, accountID int64, from, to time.Time) (reached time.Time, complete bool, err error) {
	if p.generator == nil {
		return to, true, nil
	}
	acct, err := p.db.GetJiraAccount(accountID)
	if err != nil {
		return from, false, fmt.Errorf("backfill jira: account %d: %w", accountID, err)
	}
	saved, err := p.db.IdeasJiraFloor(accountID)
	if err != nil {
		return from, false, fmt.Errorf("backfill jira: reading floor for account %d: %w", accountID, err)
	}
	lowered := db.FormatJiraTime(from)
	if savedTS, ok := db.ParseJiraTime(saved); ok {
		if fromTS, _ := db.ParseJiraTime(lowered); savedTS < fromTS {
			lowered = saved
		}
	}
	if err := p.db.SetIdeasJiraFloor(accountID, lowered); err != nil {
		return from, false, fmt.Errorf("backfill jira: lowering floor for account %d: %w", accountID, err)
	}
	defer p.restoreJiraFloors(map[int64]string{accountID: saved})

	floor := func() (string, error) { return p.db.IdeasJiraFloor(accountID) }
	complete, err = p.drainAccount(floor, func() error { return p.runJiraDigestAccount(ctx, acct, to) },
		fmt.Sprintf("jira account %d", accountID))
	reached = from
	// The floor keeps milliseconds (FormatJiraTime); parse it whole, since a
	// floor truncated to the second would re-mine the issue at the boundary.
	if f, ferr := p.db.IdeasJiraFloor(accountID); ferr == nil {
		if t, perr := time.Parse(time.RFC3339, f); perr == nil {
			reached = t.UTC()
		}
	}
	return reached, complete, err
}

// drainAccount repeats one account's stage-1 pass until a pass leaves its
// floor where it was (the window is drained) or backfillMaxCycles passes
// ran (complete=false). A pass error ends the drain.
func (p *Pipeline) drainAccount(floor func() (string, error), pass func() error, what string) (bool, error) {
	for range backfillMaxCycles {
		before, err := floor()
		if err != nil {
			return false, fmt.Errorf("backfill %s: reading floor: %w", what, err)
		}
		if err := pass(); err != nil {
			return false, fmt.Errorf("backfill %s: %w", what, err)
		}
		after, err := floor()
		if err != nil {
			return false, fmt.Errorf("backfill %s: reading floor: %w", what, err)
		}
		if after == before {
			return true, nil
		}
	}
	p.logf("ideas: backfill %s hit the %d-cycle cap — the chunk resumes next cycle", what, backfillMaxCycles)
	return false, nil
}
