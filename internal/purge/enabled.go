// Package purge deletes an account's synced data after its access is revoked
// or its lease runs out (board #601, spec
// docs/superpowers/specs/2026-10-21-revoke-purge-design.md).
package purge

import (
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/policy"
)

// BuildDefault is the build-time default of the purge switch, set by ldflags
// (`-X watchtower/internal/purge.BuildDefault=on` from WATCHTOWER_PURGE_DEFAULT;
// the corporate build profile sets it). "on" = on with origin build; anything
// else leaves the switch to the default fallback, which is on too (#1769, A1):
// the build value only changes the origin, and with it the per-account rules.
var BuildDefault = ""

// Origin names what decided the effective value of the switch.
type Origin string

// The origins, strongest first.
const (
	OriginPolicy  Origin = "policy"
	OriginSetting Origin = "setting"
	OriginBuild   Origin = "build"
	OriginDefault Origin = "default"
)

// Timing and chunk constants of the purge.
const (
	// Grace is the notice between scheduling and deleting.
	Grace = 72 * time.Hour
	// Lease is how long a source may go without confirmed access.
	Lease = 30 * 24 * time.Hour
	// ChunkRows caps the rows one purge transaction deletes.
	ChunkRows = 500
	// MaxChunkFailures failures in a row (no rows deleted in between) end a
	// running purge in the terminal state failed.
	MaxChunkFailures = 3
)

// policySwitch is the MDM policy's PurgeRevokedData (#608): set reports
// whether a forced value decides the switch, on its value. A seam for tests.
var policySwitch = policy.PurgeRevokedData

// Enabled returns the effective purge switch and its origin: a managed policy
// first, then the owner's privacy.purge_revoked_data setting, then the build
// default, then on with origin default (#1769, A1) — in every build.
func Enabled(cfg *config.Config) (bool, Origin) {
	if on, set := policySwitch(); set {
		return on, OriginPolicy
	}
	if cfg != nil && cfg.Privacy.PurgeRevokedData != nil {
		return *cfg.Privacy.PurgeRevokedData, OriginSetting
	}
	if BuildDefault == "on" {
		return true, OriginBuild
	}
	return true, OriginDefault
}

// Rule is what the purge may do to one account (#1769, A21).
type Rule int

// The rules, weakest first.
const (
	// RuleNone schedules nothing for the account and cancels its scheduled
	// rows; a running row still finishes.
	RuleNone Rule = iota
	// RuleRevokedAndRemoved runs the revoked rule (72 h) and the removed
	// account's lease (zero for Slack, Lease for the others); a live
	// account's inactivity lease is held.
	RuleRevokedAndRemoved
	// RuleFull adds the live accounts' 30-day lease.
	RuleFull
)

// Rules returns the per-account rule of the purge (spec §2 "Per-account
// rules"):
//
//   - off: RuleNone for every account;
//   - on with origin default: RuleRevokedAndRemoved — a live account is never
//     deleted for inactivity;
//   - on with origin setting, policy or build: RuleFull;
//   - a source sourceAllowed refuses (POLICY-03, #608) is not synced, so its
//     leases are held: its removed accounts get RuleNone, its live and revoked
//     ones RuleRevokedAndRemoved (the revoked rule still runs). nil allows
//     every source.
func Rules(on bool, origin Origin, sourceAllowed func(string) bool) func(db.PurgeAccount) Rule {
	var allowed func(db.PurgeAccount) bool
	if sourceAllowed != nil {
		allowed = func(a db.PurgeAccount) bool { return sourceAllowed(a.Source) }
	}
	return AccountRules(on, origin, allowed)
}

// AccountRules is Rules over a per-account verdict: an account the policy
// stops without forbidding its whole source — an Atlassian API-token account
// under AllowAtlassianAPIToken = false (#1887 D24) — is not synced either,
// so its leases are held the same way and its data kept (POLICY-03). nil
// allows every account.
func AccountRules(on bool, origin Origin, syncAllowed func(db.PurgeAccount) bool) func(db.PurgeAccount) Rule {
	return func(a db.PurgeAccount) Rule {
		switch {
		case !on:
			return RuleNone
		case syncAllowed != nil && !syncAllowed(a):
			if a.Status == "removed" {
				return RuleNone
			}
			return RuleRevokedAndRemoved
		case origin == OriginDefault:
			return RuleRevokedAndRemoved
		default:
			return RuleFull
		}
	}
}

// Cutoff is the access cutoff of a lease row's start (db.StartAccountPurge):
// now − Lease, and for a removed Slack account under a rule that schedules it
// (zero lease, A2) now, with the account required to be still removed — an
// "add again" between the re-plan and the start wins.
func Cutoff(a db.PurgeAccount, r Rule, now time.Time) (cutoff time.Time, requireRemoved bool) {
	if zeroLease(a, r) {
		return now, true
	}
	return now.Add(-Lease), false
}

// zeroLease reports whether the account is a removed Slack account whose
// rule schedules it: due Grace after the first pass after the remove (A2).
func zeroLease(a db.PurgeAccount, r Rule) bool {
	return r != RuleNone && a.Source == "slack" && a.Status == "removed"
}
