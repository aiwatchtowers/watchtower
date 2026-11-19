package daemon

import "watchtower/internal/policy"

// sourceAllowed reports whether the organization's policy (AllowedSources,
// #608) lets src sync this cycle. A sync phase asks it before fetching any
// account and returns early on false; its syncers stay wired, so a source
// allowed again syncs at the next cycle. The skip is logged once per change
// of the verdict, not every cycle. Nothing is deleted or rewritten
// (POLICY-03).
func (d *Daemon) sourceAllowed(src string) bool {
	ok := policy.SourceAllowed(src)
	d.policySkipMu.Lock()
	defer d.policySkipMu.Unlock()
	if d.policySkipping == nil {
		d.policySkipping = map[string]bool{}
	}
	switch {
	case !ok && !d.policySkipping[src]:
		d.logger.Printf("policy: %s sync skipped by your organization's policy", src)
	case ok && d.policySkipping[src]:
		d.logger.Printf("policy: %s sync allowed again by your organization's policy", src)
	}
	d.policySkipping[src] = !ok
	return ok
}

// SetAccountSyncAllowed installs the policy's per-account verdict (#1887
// D24): an account it refuses — a Google account on an own project while
// AllowOwnGoogleProject is false — is skipped by its sync phase, left out
// of the history backfill, and has its purge leases held (purgeRules). A
// syncer wired before the policy tightened stays wired, so its account
// syncs again at the next cycle once allowed. Nothing is deleted or
// rewritten (POLICY-03). Set it before Run.
func (d *Daemon) SetAccountSyncAllowed(allowed func(source string, id int64) bool) {
	d.accountAllowed = allowed
}

// accountAllowedQuiet is the installed per-account verdict, without the log.
func (d *Daemon) accountAllowedQuiet(source string, id int64) bool {
	return d.accountAllowed == nil || d.accountAllowed(source, id)
}

// accountPhaseAllowed is accountAllowedQuiet for a sync phase: the skip is
// logged once per change of the verdict, not every cycle.
func (d *Daemon) accountPhaseAllowed(source string, id int64) bool {
	ok := d.accountAllowedQuiet(source, id)
	k := purgeKey{source, id}
	d.policySkipMu.Lock()
	defer d.policySkipMu.Unlock()
	if d.accountSkipping == nil {
		d.accountSkipping = map[purgeKey]bool{}
	}
	switch {
	case !ok && !d.accountSkipping[k]:
		d.logger.Printf("policy: %s account %d sync stopped by your organization's policy", source, id)
	case ok && d.accountSkipping[k]:
		d.logger.Printf("policy: %s account %d sync allowed again by your organization's policy", source, id)
	}
	d.accountSkipping[k] = !ok
	return ok
}
