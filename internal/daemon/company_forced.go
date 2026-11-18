package daemon

import (
	"time"

	"watchtower/internal/company"
	"watchtower/internal/policy"
)

// applyForcedCompany marks Re-login the accounts of every vendor whose app a
// changed forced MDM CompanyBundle replaced (company.ApplyForcedChanges).
// Run calls it once per start, before automations and the first cycle, so a
// sync never refreshes through the old client first. An error is logged and
// the daemon carries on: an account whose client id or secret changed still
// has its next refresh refused, which asks for the login (invalid_client).
func (d *Daemon) applyForcedCompany() {
	if d.db == nil {
		return
	}
	forced := policy.Current().CompanyBundle()
	if forced == "" {
		return
	}
	changes, err := company.ApplyForcedChanges(d.db, company.NewStore(d.config.WorkspaceDir()), forced)
	if err != nil {
		d.logger.Printf("company: applying the forced bundle: %v", err)
		return
	}
	if len(changes) > 0 {
		d.logger.Printf("company: the forced bundle changed %d app value(s); the changed vendors' accounts were marked for a new login", len(changes))
	}
}

// cleanStaleBadDrafts deletes a wizard draft set aside as unreadable
// (draft.json.bad-*) once it is older than company.BadDraftMaxAge, so an
// abandoned setup does not keep its typed secrets on disk for good. Run
// calls it once per start; an error is logged.
func (d *Daemon) cleanStaleBadDrafts(now time.Time) {
	if err := company.NewStore(d.config.WorkspaceDir()).CleanStaleBadDrafts(now); err != nil {
		d.logger.Printf("company: deleting an old unreadable setup draft: %v", err)
	}
}
