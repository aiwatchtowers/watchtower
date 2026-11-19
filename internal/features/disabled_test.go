package features

import (
	"slices"
	"testing"

	"watchtower/internal/config"
)

// TestDisabledIDs_FollowTheConfigSwitches: an entry whose switch is off is
// listed, one turned on is not, and a core entry never is — the "disabled"
// state `features list` reports to the Desktop.
func TestDisabledIDs_FollowTheConfigSwitches(t *testing.T) {
	cfg := &config.Config{}
	cfg.Inbox.Enabled = false
	if !slices.Contains(DisabledIDs(cfg), "secretary-inbox") {
		t.Fatal("attention detection off is not listed")
	}
	cfg.Inbox.Enabled = true
	if slices.Contains(DisabledIDs(cfg), "secretary-inbox") {
		t.Fatal("attention detection on is listed")
	}
	for _, f := range All() {
		if f.Core && slices.Contains(DisabledIDs(cfg), f.ID) {
			t.Fatalf("core entry %s listed as disabled", f.ID)
		}
	}
}
