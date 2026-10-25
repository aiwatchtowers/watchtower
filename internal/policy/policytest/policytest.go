// Package policytest sets a managed policy for one test.
package policytest

import (
	"maps"
	"testing"

	"watchtower/internal/policy"
)

// Set makes raw the forced values every policy read sees until the test ends.
// nil = no profile.
func Set(t testing.TB, raw map[string]any) {
	t.Helper()
	snapshot := maps.Clone(raw)
	restore := policy.SetReaderForTesting(func() map[string]any { return maps.Clone(snapshot) })
	t.Cleanup(restore)
}
