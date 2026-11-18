package aiconsenttest

import (
	"os"
	"path/filepath"
	"testing"

	"watchtower/internal/aiconsent"
	"watchtower/internal/policy/policytest"
)

// Unanswered runs the rest of the test with the test override cleared and
// aiconsent.Current reading a real config.yaml where the owner has not
// answered (no ai.background_runs key) and no profile is installed: exactly
// what a component left on its nil (default) reader reads in production
// before the answer. At the end the previous config path and override are
// back. Process-wide: never call it from a parallel test.
func Unanswered(t testing.TB) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte("digest:\n  enabled: true\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	policytest.Set(t, nil)
	prevOverride := aiconsent.SetCurrentOverrideForTest(nil)
	prevPath := aiconsent.SetConfigPath(path)
	t.Cleanup(func() {
		aiconsent.SetConfigPath(prevPath)
		aiconsent.SetCurrentOverrideForTest(prevOverride)
	})
	if s := aiconsent.Current(); s.Allowed() || s.Reason != aiconsent.ReasonUnanswered {
		t.Fatalf("unanswered config reads %+v; want paused, not answered", s)
	}
}
