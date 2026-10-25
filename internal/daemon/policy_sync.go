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
