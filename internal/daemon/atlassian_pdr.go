package daemon

import (
	"context"
	"time"

	"watchtower/internal/atlassianpdr"
)

// PDRAccount is one Atlassian account the Personal Data Reporting phase
// reports for, with the reporter that holds its OAuth client.
type PDRAccount struct {
	ID       int64
	Reporter atlassianpdr.Reporter
}

// pdrRetryAfter is how long an account whose report failed waits before the
// next try: a grant without the report scope fails until a re-login, and a
// network call plus a log line every cycle buys nothing.
const pdrRetryAfter = 6 * time.Hour

// pdrIncompleteCap is how many incomplete runs in a row (a lookup leaving
// ids unanswered) an account gets before its report is stamped anyway.
const pdrIncompleteCap = 3

// SetAtlassianPDR sets the accounts the Personal Data Reporting phase runs
// for — every wired OAuth Jira account, company or shared app alike. Empty
// disables the phase.
func (d *Daemon) SetAtlassianPDR(accounts []PDRAccount) {
	d.pdrAccounts = accounts
}

// phaseAtlassianPDR runs Personal Data Reporting for each account (#1887 §6,
// D6): atlassianpdr.Run reports only when the account's 7 days are up, and
// an error erases nothing; the account tries again pdrRetryAfter later (in
// memory: a restart tries at once) — as does one whose lookup left ids
// unanswered (Result.Unknown, last_pdr_at not stamped), up to
// pdrIncompleteCap incomplete runs in a row (an error or a complete run
// starts the count again): the last one stamps
// last_pdr_at, so an id the token can never see (a cache row of another
// site) returns the account to the 7-day cadence; an unanswered id is never
// treated as closed. Skipped for a source the organization's policy forbids
// (no request to it, POLICY-03) and for an account whose purge holds it.
func (d *Daemon) phaseAtlassianPDR(ctx context.Context) {
	if d.db == nil || len(d.pdrAccounts) == 0 || !d.sourceAllowed("jira") {
		return
	}
	now := time.Now
	if d.pdrNow != nil {
		now = d.pdrNow
	}
	for _, a := range d.pdrAccounts {
		if ctx.Err() != nil {
			return
		}
		if d.purgeHeld("jira", a.ID) || now().Before(d.pdrRetryAt[a.ID]) {
			continue
		}
		res, err := atlassianpdr.Run(ctx, d.db, a.ID, a.Reporter, now())
		retry := func() {
			if d.pdrRetryAt == nil {
				d.pdrRetryAt = map[int64]time.Time{}
			}
			d.pdrRetryAt[a.ID] = now().Add(pdrRetryAfter)
		}
		if err != nil || res.Unknown == 0 {
			delete(d.pdrIncomplete, a.ID) // a complete or failed run ends the streak
		}
		switch {
		case err != nil:
			d.logger.Printf("atlassian pdr: account %d: %v (next try in %s)", a.ID, err, pdrRetryAfter)
			retry()
		case res.Unknown > 0:
			if d.pdrIncomplete == nil {
				d.pdrIncomplete = map[int64]int{}
			}
			d.pdrIncomplete[a.ID]++
			if d.pdrIncomplete[a.ID] < pdrIncompleteCap {
				d.logger.Printf("atlassian pdr: account %d: %d reported, %d closed erased, %d not answered (next try in %s)",
					a.ID, res.Reported, res.Closed, res.Unknown, pdrRetryAfter)
				retry()
				break
			}
			delete(d.pdrIncomplete, a.ID)
			d.logger.Printf("atlassian pdr: account %d: %d ids still not answered after %d tries; next report in 7 days", a.ID, res.Unknown, pdrIncompleteCap)
			if err := d.db.SetJiraLastPDR(a.ID, now().UTC().Format(time.RFC3339)); err != nil {
				d.logger.Printf("atlassian pdr: account %d: %v (next try in %s)", a.ID, err, pdrRetryAfter)
				retry()
			}
		case res.Closed > 0 || res.Updated > 0:
			d.logger.Printf("atlassian pdr: account %d: %d reported, %d closed erased, %d updated", a.ID, res.Reported, res.Closed, res.Updated)
		}
	}
}
