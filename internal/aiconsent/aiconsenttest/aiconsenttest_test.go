package aiconsenttest

import (
	"testing"

	"watchtower/internal/aiconsent"
)

func TestAllowByDefault(t *testing.T) {
	t.Cleanup(func() { aiconsent.SetCurrentOverrideForTest(nil) })
	if aiconsent.Current().Allowed() {
		t.Fatal("with no config path Current must read paused before the override")
	}
	AllowByDefault()
	if s := aiconsent.Current(); !s.Allowed() || s.Reason != aiconsent.ReasonOwner {
		t.Fatalf("got %+v, want allowed by the owner", s)
	}
}
