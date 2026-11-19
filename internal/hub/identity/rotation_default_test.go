//go:build !relaystaging

package identity

import (
	"testing"
	"time"
)

// The default build's numbers (ask #1077): only the relaystaging tag
// (rotation_staging.go) shortens them.

func TestRelayRotationAgeIs7DaysInTheDefaultBuild(t *testing.T) {
	if relayRotationAge != 7*24*time.Hour {
		t.Fatalf("relayRotationAge = %v, want 7 days", relayRotationAge)
	}
}

func TestRetentionIs7DaysInTheDefaultBuild(t *testing.T) {
	if PreviousEpochGrace != 7*24*time.Hour {
		t.Fatalf("PreviousEpochGrace = %v, want 7 days", PreviousEpochGrace)
	}
}
