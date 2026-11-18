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

// SetAtlassianPDR sets the accounts the Personal Data Reporting phase runs
// for — every wired OAuth Jira account, company or shared app alike. Empty
// disables the phase.
func (d *Daemon) SetAtlassianPDR(accounts []PDRAccount) {
	d.pdrAccounts = accounts
}

// phaseAtlassianPDR runs Personal Data Reporting for each account (#1887 §6,
// D6): atlassianpdr.Run reports only when the account's 7 days are up, and
// an error erases nothing and is retried next cycle. Skipped for a source the
// organization's policy forbids (no request to it, POLICY-03) and for an
// account whose purge holds it.
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
		if d.purgeHeld("jira", a.ID) {
			continue
		}
		res, err := atlassianpdr.Run(ctx, d.db, a.ID, a.Reporter, now())
		switch {
		case err != nil:
			d.logger.Printf("atlassian pdr: account %d: %v", a.ID, err)
		case res.Closed > 0 || res.Updated > 0:
			d.logger.Printf("atlassian pdr: account %d: %d reported, %d closed erased, %d updated", a.ID, res.Reported, res.Closed, res.Updated)
		}
	}
}
