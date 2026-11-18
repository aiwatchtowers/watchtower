// Package aiconsenttest lets a test package run with background AI allowed.
// Test-only: production code never imports it.
package aiconsenttest

import "watchtower/internal/aiconsent"

// AllowByDefault makes aiconsent.Current return "allowed by the owner" until
// the process ends, so components built with the fail-closed default reader
// behave as before. Call it from TestMain; tests that need another state
// inject an aiconsent.Reader.
func AllowByDefault() {
	aiconsent.SetCurrentOverrideForTest(func() aiconsent.State {
		return aiconsent.Resolve(aiconsent.AnswerAllowed, nil)
	})
}
