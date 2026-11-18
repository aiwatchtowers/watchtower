package daemon

import (
	"watchtower/internal/company"
	"watchtower/internal/policy"
)

// applyForcedCompany marks Re-login the accounts of every vendor whose app a
// changed forced MDM CompanyBundle replaced (company.ApplyForcedChanges).
// Run calls it once per start, before automations and the first cycle, so a
// sync never refreshes through the old client first. An error is logged and
// the daemon carries on: those accounts' next refresh is refused and asks for
// the login anyway (invalid_client).
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
		d.logger.Printf("company: the forced bundle changed %d app value(s); their accounts need a new login", len(changes))
	}
}
