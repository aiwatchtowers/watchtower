package daemon

import (
	"context"
	"errors"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/jira"
	"watchtower/internal/policy"
	"watchtower/internal/purge"
)

// purgeCycleBudget caps the time one cycle spends deleting purged accounts'
// rows; an unfinished purge resumes on the next cycle.
const purgeCycleBudget = 5 * time.Minute

// purgeKey names one account of one purge source.
type purgeKey struct {
	source string
	id     int64
}

// phaseAccountPurge is the first phase of a cycle (board #601, PURGE-01/02):
// a cheap scheduling pass over the account rows and the ledger, then the due
// purges within purgeCycleBudget. Off means off — nothing is scheduled and
// every scheduled row is cancelled — except that a running purge always
// finishes. Errors are logged and never abort the cycle. This pass schedules
// no lease rows: phaseAccountPurgeLeases does, after the cycle's syncs had
// their chance to prove access (a Mac back from a long absence would
// otherwise get a false notice). It then refreshes purgeHold, which the sync
// phases read to skip accounts being or already purged: a syncer wired at
// daemon start must not re-fill a purged account.
func (d *Daemon) phaseAccountPurge(ctx context.Context) {
	if d.db == nil || ctx.Err() != nil {
		return
	}
	rules := d.purgeRules()
	actions := d.applyPurgeSchedule(rules, false)
	deadline := time.Now().Add(purgeCycleBudget)
	for _, p := range actions.Due {
		remaining := time.Until(deadline)
		if remaining <= 0 || ctx.Err() != nil {
			break
		}
		done, err := purge.Run(ctx, d.db, d.config.WorkspaceDir(), p, rules, remaining)
		switch {
		case errors.Is(err, purge.ErrNoLongerDue):
			d.logger.Printf("account purge: %s account %d not started: no longer due", p.Source, p.AccountID)
		case err != nil:
			d.logger.Printf("account purge: %s account %d: %v", p.Source, p.AccountID, err)
		case done:
			d.logger.Printf("account purge: %s account %d purged", p.Source, p.AccountID)
		default:
			d.logger.Printf("account purge: %s account %d paused, resumes next cycle", p.Source, p.AccountID)
		}
	}
	d.refreshPurgeHold()
}

// phaseAccountPurgeLeases is the scheduling pass after the cycle's sync
// phases: the same decision as phaseAccountPurge's, lease rows included. Its
// due rows run next cycle.
func (d *Daemon) phaseAccountPurgeLeases(ctx context.Context) {
	if d.db == nil || ctx.Err() != nil {
		return
	}
	d.applyPurgeSchedule(d.purgeRules(), true)
}

// purgeRules is the per-account purge rule of this pass (#1769, A21): the
// switch and its origin from purge.Enabled, the hold from the live policy
// (POLICY-03): a forbidden source, or an account the policy stops
// (SetAccountSyncAllowed), is not synced, so its leases are held.
func (d *Daemon) purgeRules() func(db.PurgeAccount) purge.Rule {
	on, origin := purge.Enabled(d.config)
	return purge.AccountRules(on, origin, func(a db.PurgeAccount) bool {
		return AccountSyncAllowed(a) && d.accountAllowedQuiet(a.Source, a.ID)
	})
}

// AccountSyncAllowed reports whether the organization's policy lets the
// account sync: its source is allowed (AllowedSources, #608) and, for an
// Atlassian API-token account, so are API tokens (AllowAtlassianAPIToken,
// #1887 D24). A stopped account keeps its data: its leases are held.
func AccountSyncAllowed(a db.PurgeAccount) bool {
	p := policy.Current()
	if !p.SourceAllowed(a.Source) {
		return false
	}
	return a.AuthKind != jira.AuthKindAPIToken || p.AtlassianAPITokenAllowed()
}

// applyPurgeSchedule runs one scheduling pass and logs what it wrote.
func (d *Daemon) applyPurgeSchedule(rules func(db.PurgeAccount) purge.Rule, leases bool) purge.Actions {
	actions, err := purge.Apply(d.db, rules, leases, time.Now())
	if err != nil {
		d.logger.Printf("account purge: scheduling: %v", err)
	}
	for _, s := range actions.Schedule {
		d.logger.Printf("account purge: %s account %d scheduled (%s), due %s",
			s.Source, s.AccountID, s.Reason, s.DueAt.UTC().Format(time.RFC3339))
	}
	for _, id := range actions.Cancel {
		d.logger.Printf("account purge: purge %d cancelled", id)
	}
	return actions
}

// refreshPurgeHold rebuilds the set of accounts the sync phases skip: status
// purged, a purge running, or — with the purge on — a revoked or removed
// account whose purge failed its verify count with rows left
// (purge.VerifyHeld, until a Re-login or an add-back confirms access); a
// purge failed by its chunks, or a live account's, releases its account. A failed
// read keeps the previous set.
func (d *Daemon) refreshPurgeHold() {
	if d.db == nil {
		return
	}
	accounts, err := d.db.ListPurgeAccounts()
	if err != nil {
		d.logger.Printf("account purge: reading accounts: %v", err)
		return
	}
	ledger, err := d.db.ListAccountPurges(false)
	if err != nil {
		d.logger.Printf("account purge: reading ledger: %v", err)
		return
	}
	verifyHeld := purge.VerifyHeld(accounts, ledger)
	on, _ := purge.Enabled(d.config)
	hold := map[purgeKey]bool{}
	for _, a := range accounts {
		if a.Status == "purged" || (on && verifyHeld(a.Source, a.ID)) {
			hold[purgeKey{a.Source, a.ID}] = true
		}
	}
	for _, p := range ledger {
		if p.State == "running" {
			hold[purgeKey{p.Source, p.AccountID}] = true
		}
	}
	d.purgeHold = hold
}

// purgeHeld reports whether a sync phase must skip the account.
func (d *Daemon) purgeHeld(source string, id int64) bool {
	return d.purgeHold[purgeKey{source, id}]
}
