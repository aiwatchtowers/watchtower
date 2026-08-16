package config

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestMigrateFeatureGates_LegacyDigestOff(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	_ = os.WriteFile(p, []byte("digest:\n  enabled: false\n"), 0o600)
	migrated, err := MigrateFeatureGates(p)
	if err != nil || !migrated {
		t.Fatalf("migrated=%v err=%v", migrated, err)
	}
	cfg, _ := Load(p)
	for name, got := range map[string]bool{
		"inbox": cfg.Inbox.Enabled, "streams": cfg.Streams.Enabled,
		"tracks": cfg.Tracks.Enabled, "people": cfg.People.Enabled,
		"ideas": cfg.Ideas.Enabled, "briefing": cfg.Briefing.Enabled,
		"day_plan": cfg.DayPlan.Enabled, "next_step": cfg.Targets.NextStep.Enabled,
	} {
		if got {
			t.Errorf("%s should be false after migration", name)
		}
	}
	// Second run is a no-op (marker present).
	migrated2, err := MigrateFeatureGates(p)
	if err != nil || migrated2 {
		t.Fatalf("second run migrated=%v err=%v", migrated2, err)
	}
}

func TestMigrateFeatureGates_DigestOnUntouched(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	orig := []byte("digest:\n  enabled: true\n")
	_ = os.WriteFile(p, orig, 0o600)
	if migrated, err := MigrateFeatureGates(p); err != nil || migrated {
		t.Fatalf("migrated=%v err=%v", migrated, err)
	}
	after, _ := os.ReadFile(p)
	if !bytes.Equal(after, orig) {
		t.Error("file must be byte-identical when no migration is needed")
	}
}

func TestMigrateFeatureGates_NoFile(t *testing.T) {
	if migrated, err := MigrateFeatureGates(filepath.Join(t.TempDir(), "absent.yaml")); err != nil || migrated {
		t.Fatalf("migrated=%v err=%v", migrated, err)
	}
}
