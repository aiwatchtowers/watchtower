package ideas

import (
	"context"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// BackfillEmail is the history backfill's stage-1 pass for ONE Google
// account (docs/features/history-backfill.md, R28): it drains that account's
// email pre-digests in (from, to] (the process side of the chunk convention
// in internal/historybackfill/chunk.go) from a floor it keeps in memory —
// from, or the stored ideas_email_floor when that is already lower — and
// then raises the stored floor to what it reached when that is higher. The
// stored floor is never lowered, so a process killed mid-drain leaves the
// forward run exactly where it was instead of weeks back. No other account,
// no Jira pass and no consolidator: the stream digests it writes are
// consolidated by the regular ideas run, which keeps the ideas.enabled gate.
// complete is false when the drain hit its cycle cap before the window was
// empty; the caller retries the chunk. reached is the floor the drain got to
// — also on an error or a cut ctx — so a retry can start there instead of
// re-paying the passes already done (F2).
func (p *Pipeline) BackfillEmail(ctx context.Context, accountID int64, from, to time.Time) (reached time.Time, complete bool, err error) {
	if p.generator == nil {
		return to, true, nil
	}
	if _, err := p.db.GetGoogleAccount(accountID); err != nil {
		return from, false, fmt.Errorf("backfill email: account %d: %w", accountID, err)
	}
	return p.backfillMailbox(ctx, gmailBox(accountID), from, to)
}

// BackfillImap is BackfillEmail for one IMAP/Outlook mailbox (an
// email_accounts row): the same in-memory drain over its imap_messages and
// the same never-lowered raise of its email_accounts.ideas_email_floor.
func (p *Pipeline) BackfillImap(ctx context.Context, accountID int64, from, to time.Time) (reached time.Time, complete bool, err error) {
	if p.generator == nil {
		return to, true, nil
	}
	if _, err := p.db.GetEmailAccount(accountID); err != nil {
		return from, false, fmt.Errorf("backfill email: imap account %d: %w", accountID, err)
	}
	// A mailbox whose address is already mined elsewhere is skipped here too,
	// like the forward run (see mailboxes): the chunk is done with nothing to do.
	if ok, err := p.mines(imapBox(accountID)); err != nil || !ok {
		if err != nil {
			return from, false, fmt.Errorf("backfill email: %w", err)
		}
		return to, true, nil
	}
	return p.backfillMailbox(ctx, imapBox(accountID), from, to)
}

// backfillMailbox is the shared body of BackfillEmail and BackfillImap.
func (p *Pipeline) backfillMailbox(ctx context.Context, mb mailbox, from, to time.Time) (reached time.Time, complete bool, err error) {
	saved, err := p.mailFloor(mb)
	if err != nil {
		return from, false, fmt.Errorf("backfill email: reading floor for %s: %w", mb.what(), err)
	}
	// Never start above a floor that is already below the window: that would
	// skip the mail between it and from.
	floor := float64(from.Unix())
	if saved > 0 && saved < floor {
		floor = saved
	}
	complete, err = p.drainAccount(
		func() (string, error) { return fmt.Sprint(floor), nil },
		func() error {
			var perr error
			floor, perr = p.emailDigestPass(ctx, mb, floor, to)
			return perr
		},
		mb.what())
	p.raiseEmailFloor(mb, floor)
	return time.Unix(int64(floor), 0).UTC(), complete, err // floors are whole seconds (maxTS of a rendered window)
}

// raiseEmailFloor moves the mailbox's stored floor up to reached when the
// drain got past it (also when it was never initialized), so the forward run
// does not mine the drained window again; it never lowers it.
func (p *Pipeline) raiseEmailFloor(mb mailbox, reached float64) {
	live, err := p.mailFloor(mb)
	if err != nil {
		p.logf("ideas: backfill: reading email floor for %s: %v", mb.what(), err)
		return
	}
	if reached <= live {
		return
	}
	if err := p.setMailFloor(mb, reached); err != nil {
		p.logf("ideas: backfill: raising email floor for %s: %v", mb.what(), err)
	}
}

// BackfillJira is BackfillEmail's Jira counterpart (R29): it drains that
// Jira account's pre-digests bounded by to from an in-memory floor and
// raises the stored ideas_jira_floor to what it reached. No email, no
// consolidator. reached is as in BackfillEmail.
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
	floor := db.FormatJiraTime(from)
	if savedTS, ok := db.ParseJiraTime(saved); ok {
		if fromTS, _ := db.ParseJiraTime(floor); savedTS < fromTS {
			floor = saved
		}
	}
	complete, err = p.drainAccount(
		func() (string, error) { return floor, nil },
		func() error {
			var perr error
			floor, perr = p.jiraDigestPass(ctx, acct, floor, to)
			return perr
		},
		fmt.Sprintf("jira account %d", accountID))
	p.raiseJiraFloor(accountID, floor)
	reached = from
	// The floor keeps milliseconds (FormatJiraTime); parse it whole, since a
	// floor truncated to the second would re-mine the issue at the boundary.
	if t, perr := time.Parse(time.RFC3339, floor); perr == nil {
		reached = t.UTC()
	}
	return reached, complete, err
}

// raiseJiraFloor is raiseEmailFloor's Jira sibling.
func (p *Pipeline) raiseJiraFloor(accountID int64, reached string) {
	live, err := p.db.IdeasJiraFloor(accountID)
	if err != nil {
		p.logf("ideas: backfill: reading jira floor for account %d: %v", accountID, err)
		return
	}
	if raised := maxJiraFloor(live, reached); raised != live {
		if err := p.db.SetIdeasJiraFloor(accountID, raised); err != nil {
			p.logf("ideas: backfill: raising jira floor for account %d: %v", accountID, err)
		}
	}
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
