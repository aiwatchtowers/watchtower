package cmd

import (
	"database/sql"
	"errors"
	"fmt"

	"watchtower/internal/calendar"
	"watchtower/internal/company"
	"watchtower/internal/db"
	"watchtower/internal/policy"
)

// errOwnGoogleProjectForbidden is the organization's refusal of own Google
// projects (AllowOwnGoogleProject = false, #1887 D24).
var errOwnGoogleProjectForbidden = fmt.Errorf("own Google projects are %w (AllowOwnGoogleProject); ask IT for your company's Watchtower link", policy.ErrNotAllowed)

// googleOwnProjectStopped reports whether the policy p stops acct: an
// account on an own Google project (company.IsOwnProject) while
// AllowOwnGoogleProject is false. Company and shared-client accounts are
// never stopped. When it cannot tell — the company directory cannot be read,
// or the account's company is not among the stored ones — it says stopped
// (fail closed, POLICY-01) and returns the reason, so a caller shows the real
// problem instead of the policy's.
func googleOwnProjectStopped(p policy.Policy, workspaceDir string, acct db.GoogleAccount) (bool, error) {
	if p.OwnGoogleProjectAllowed() {
		return false, nil
	}
	var entries []company.Entry
	if acct.CompanySlug != "" {
		var err error
		if entries, _, err = company.NewStore(workspaceDir).LoadAll(companyForcedBundle()); err != nil {
			return true, fmt.Errorf("google account %d: reading companies: %w", acct.ID, err)
		}
		if !hasCompany(entries, acct.CompanySlug) {
			return true, fmt.Errorf("google account %d: company %q is not stored; open your company's Watchtower link", acct.ID, acct.CompanySlug)
		}
	}
	return company.IsOwnProject(acct, entries, calendar.NewCredentialStore(workspaceDir, acct.ID).Exists()), nil
}

func hasCompany(entries []company.Entry, slug string) bool {
	for _, e := range entries {
		if e.Slug == slug {
			return true
		}
	}
	return false
}

// refuseStoppedOwnProject refuses a sign-in or a CLI sync of an account the
// current policy stops (googleOwnProjectStopped): a re-login must not bring
// it back.
func refuseStoppedOwnProject(workspaceDir string, acct db.GoogleAccount) error {
	stopped, err := googleOwnProjectStopped(policy.Current(), workspaceDir, acct)
	switch {
	case err != nil:
		return err
	case stopped:
		return errOwnGoogleProjectForbidden
	}
	return nil
}

// refusePersonalCompany refuses `google add --company <slug>` of a personal
// bundle while own projects are not allowed: the slug is an own project too.
func refusePersonalCompany(workspaceDir, slug string) error {
	if policy.Current().OwnGoogleProjectAllowed() {
		return nil
	}
	e, ok, err := company.NewStore(workspaceDir).Get(slug, companyForcedBundle())
	if err != nil {
		return err
	}
	if ok && e.Bundle.Personal {
		return errOwnGoogleProjectForbidden
	}
	return nil
}

// googleAccountSyncAllowed is the daemon's per-account policy verdict
// (daemon.SetAccountSyncAllowed): a Google account on an own project is
// stopped while AllowOwnGoogleProject is false — not synced, its history
// backfill waiting, its purge leases held, its row and data kept
// (POLICY-03). A row that is gone is allowed (its removed-account lease
// runs); one that cannot be read is stopped for this pass, so a transient
// read error never lets a stopped account's inactivity purge be scheduled.
// unwired are the accounts the policy kept from being wired at daemon start
// (googleAccountsStopped): they cannot sync, so they stay stopped — leases
// held — until the next start wires them, even once the policy allows them.
func googleAccountSyncAllowed(workspaceDir string, database *db.DB, unwired map[int64]bool) func(source string, id int64) bool {
	return func(source string, id int64) bool {
		if source != "google" {
			return true
		}
		if unwired[id] {
			return false
		}
		p := policy.Current()
		if p.OwnGoogleProjectAllowed() {
			return true
		}
		acct, err := database.GetGoogleAccount(id)
		if errors.Is(err, sql.ErrNoRows) {
			return true
		}
		if err != nil {
			return false
		}
		stopped, _ := googleOwnProjectStopped(p, workspaceDir, acct)
		return !stopped
	}
}

// googleAccountsStopped is the set of accounts the policy p stops
// (googleOwnProjectStopped), the ones wireGoogleSyncers leaves unwired.
func googleAccountsStopped(p policy.Policy, workspaceDir string, accounts []db.GoogleAccount) map[int64]bool {
	out := map[int64]bool{}
	for _, a := range accounts {
		if stopped, _ := googleOwnProjectStopped(p, workspaceDir, a); stopped {
			out[a.ID] = true
		}
	}
	return out
}
