package aiconsenttest

import (
	"testing"

	"watchtower/internal/aiconsent"
)

// Use runs the rest of the test as a process InitProcess(role, env) set up,
// with background AI allowed or paused. At the end the process is back to
// the test binary's default (owner, background AI allowed: AllowByDefault).
// The state is process-wide: never call it from a parallel test.
func Use(t testing.TB, role string, env map[string]string, allowed bool) {
	t.Helper()
	answer := aiconsent.AnswerPaused
	if allowed {
		answer = aiconsent.AnswerAllowed
	}
	aiconsent.InitProcess(role, func(k string) string { return env[k] })
	aiconsent.SetCurrentOverrideForTest(func() aiconsent.State { return aiconsent.Resolve(answer, nil) })
	t.Cleanup(func() {
		aiconsent.InitProcess("", func(string) string { return "" })
		AllowByDefault()
	})
}
