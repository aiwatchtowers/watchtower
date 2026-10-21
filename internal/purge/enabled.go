// Package purge deletes an account's synced data after its access is revoked
// or its lease runs out (board #601, spec
// docs/superpowers/specs/2026-10-21-revoke-purge-design.md).
package purge

import (
	"time"

	"watchtower/internal/config"
)

// BuildDefault is the build-time default of the purge switch, set by ldflags
// (`-X watchtower/internal/purge.BuildDefault=on` from WATCHTOWER_PURGE_DEFAULT;
// the corporate build profile sets it). "on" = on; anything else = off.
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

// policy is the seam an MDM policy (#608) feeds later: set reports whether a
// policy decides the switch, on its value. Unset today.
var policy = func() (on, set bool) { return false, false }

// Enabled returns the effective purge switch and its origin: a policy first,
// then the owner's privacy.purge_revoked_data setting, then the build default.
func Enabled(cfg *config.Config) (bool, Origin) {
	if on, set := policy(); set {
		return on, OriginPolicy
	}
	if cfg != nil && cfg.Privacy.PurgeRevokedData != nil {
		return *cfg.Privacy.PurgeRevokedData, OriginSetting
	}
	if BuildDefault == "on" {
		return true, OriginBuild
	}
	return false, OriginDefault
}
