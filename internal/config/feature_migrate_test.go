package config

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/spf13/viper"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// rawConfig reads configPath through a bare viper — no defaults registered,
// no struct decoding — so a test can assert a key is genuinely ABSENT from
// the file rather than merely reading back as its default through Load.
func rawConfig(t *testing.T, path string) *viper.Viper {
	t.Helper()
	v := viper.New()
	v.SetConfigFile(path)
	require.NoError(t, v.ReadInConfig())
	return v
}

// writeConfigKey replicates cmd.setConfigKey's typed viper write — the exact
// path `watchtower features disable` takes to flip one key — so the sequence
// test below exercises a real product write instead of a hand-rolled yaml
// edit. internal/config cannot import cmd, hence the small copy.
func writeConfigKey(t *testing.T, path, key string, value any) {
	t.Helper()
	v := viper.New()
	v.SetConfigFile(path)
	require.NoError(t, v.ReadInConfig())
	v.Set(key, value)
	require.NoError(t, v.WriteConfigAs(path))
}

// assertNoFeatureKeysWritten asserts that none of the nine legacy-mapping
// keys is present in the file at all — the difference between "off" and
// "never written", which Load cannot see because it fills in defaults.
func assertNoFeatureKeysWritten(t *testing.T, v *viper.Viper, why string) {
	t.Helper()
	for _, key := range legacyDigestOffFeatureKeys {
		assert.False(t, v.IsSet(key), "%s must not be written: %s", key, why)
	}
}

func TestMigrateFeatureGates_LegacyDigestOff(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte("digest:\n  enabled: false\n"), 0o600))
	migrated, err := MigrateFeatureGates(p)
	require.NoError(t, err)
	require.True(t, migrated)

	cfg, err := Load(p)
	require.NoError(t, err)
	for name, got := range map[string]bool{
		"inbox": cfg.Inbox.Enabled, "streams": cfg.Streams.Enabled,
		"tracks": cfg.Tracks.Enabled, "people": cfg.People.Enabled,
		"ideas": cfg.Ideas.Enabled, "memory": cfg.Memory.Enabled,
		"briefing": cfg.Briefing.Enabled, "day_plan": cfg.DayPlan.Enabled,
		"next_step": cfg.Targets.NextStep.Enabled,
	} {
		assert.False(t, got, "%s should be false after migration", name)
	}

	// Second run is a no-op (marker present).
	migrated2, err := MigrateFeatureGates(p)
	require.NoError(t, err)
	assert.False(t, migrated2)
}

// TestMigrateFeatureGates_DigestOnStampsMarkerOnly covers the first-contact
// stamp on a healthy install: digest.enabled=true is not a legacy signature,
// so the file gains the marker and nothing else. (Formerly
// TestMigrateFeatureGates_DigestOnUntouched, which asserted the file stayed
// byte-identical — that is now true only from the second call onward.)
func TestMigrateFeatureGates_DigestOnStampsMarkerOnly(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte("digest:\n  enabled: true\n"), 0o600))

	migrated, err := MigrateFeatureGates(p)
	require.NoError(t, err)
	assert.False(t, migrated, "digest.enabled=true is not a legacy install")

	v := rawConfig(t, p)
	assert.True(t, v.IsSet("features.migrated"), "first contact must stamp the marker")
	assert.True(t, v.GetBool("digest.enabled"), "digest.enabled must be left alone")
	assertNoFeatureKeysWritten(t, v, "a first-contact stamp maps nothing")

	assertSecondCallIsByteIdenticalNoOp(t, p)
}

// TestMigrateFeatureGates_DigestKeyAbsent is the common fresh install: no
// digest section at all. Absent is not "explicitly false", so this is a
// first-contact stamp too.
func TestMigrateFeatureGates_DigestKeyAbsent(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte("active_workspace: test\n"), 0o600))

	migrated, err := MigrateFeatureGates(p)
	require.NoError(t, err)
	assert.False(t, migrated)

	v := rawConfig(t, p)
	assert.True(t, v.IsSet("features.migrated"), "first contact must stamp the marker")
	assert.False(t, v.IsSet("digest.enabled"), "the stamp must not invent a digest.enabled key")
	assert.Equal(t, "test", v.GetString("active_workspace"), "unrelated keys must survive")
	assertNoFeatureKeysWritten(t, v, "a first-contact stamp maps nothing")

	assertSecondCallIsByteIdenticalNoOp(t, p)
}

// TestMigrateFeatureGates_ProductDisableAfterMarkerIsNotLegacy pins the
// regression the first-contact stamp exists to prevent. `features disable
// slack-digests` writes digest.enabled=false through the ordinary typed
// config write; without a marker already on the file that is byte-for-byte
// indistinguishable from a pre-feature-manager install, so the very next
// MigrateFeatureGates call — a read-only `features list`, or the daemon
// restarting after the Desktop applied the change — mass-disabled nine
// features the owner never touched.
func TestMigrateFeatureGates_ProductDisableAfterMarkerIsNotLegacy(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte("active_workspace: test\ndigest:\n  enabled: true\n"), 0o600))

	// First contact on a healthy install: the marker lands.
	migrated, err := MigrateFeatureGates(p)
	require.NoError(t, err)
	require.False(t, migrated)

	// The product write — what `watchtower features disable slack-digests` does.
	writeConfigKey(t, p, "digest.enabled", false)

	before, err := os.ReadFile(p)
	require.NoError(t, err)

	migrated2, err := MigrateFeatureGates(p)
	require.NoError(t, err)
	assert.False(t, migrated2, "a product disable must never read as a legacy install")

	after, err := os.ReadFile(p)
	require.NoError(t, err)
	assert.Equal(t, string(before), string(after), "no cascade: the file must be byte-identical")

	v := rawConfig(t, p)
	assert.False(t, v.GetBool("digest.enabled"), "the owner's own disable stands")
	assertNoFeatureKeysWritten(t, v, "a product disable must not cascade")
}

func TestMigrateFeatureGates_NoFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "absent.yaml")
	migrated, err := MigrateFeatureGates(p)
	require.NoError(t, err)
	assert.False(t, migrated)
	_, statErr := os.Stat(p)
	assert.True(t, os.IsNotExist(statErr), "a missing config must not be created by the migration")
}

// TestMigrateFeatureGates_LegacyDetectedEvenWhenWriteFails pins the input to
// the daemon's fail-closed path: a legacy install whose migration could not
// be persisted must still be REPORTED as legacy, or runSyncDaemon has no way
// to tell it apart from a healthy install and comes up with nine AI features
// on. The config dir is made unwritable so the atomic temp-file write fails.
func TestMigrateFeatureGates_LegacyDetectedEvenWhenWriteFails(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte("digest:\n  enabled: false\n"), 0o600))
	require.NoError(t, os.Chmod(dir, 0o500))
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })

	legacyDetected, err := MigrateFeatureGates(p)
	require.Error(t, err, "an unwritable config dir must surface as an error")
	assert.True(t, legacyDetected, "a failed write must still report the legacy signature")

	v := rawConfig(t, p)
	assert.False(t, v.IsSet("features.migrated"), "nothing was persisted, so the next start retries")
}

func TestApplyLegacyDigestOff_FlipsNineGatesAndNothingElse(t *testing.T) {
	base := Config{
		ActiveWorkspace: "keep-me",
		Digest:          DigestConfig{Enabled: false, MinMessages: 7, Language: "English"},
		Inbox:           InboxConfig{Enabled: true, MaxTriageMessages: 42},
		Streams:         StreamsConfig{Enabled: true, IntervalHours: 3},
		Tracks:          TracksConfig{Enabled: true},
		People:          PeopleConfig{Enabled: true},
		Ideas:           IdeasConfig{Enabled: true, MineIntervalHours: 12},
		Memory:          MemoryConfig{Enabled: true},
		Briefing:        BriefingConfig{Enabled: true, Hour: 9},
		DayPlan:         DayPlanConfig{Enabled: true, Hour: 8},
		Targets:         TargetsConfig{NextStep: TargetsNextStepConfig{Enabled: true}},
		Calendar:        CalendarConfig{Enabled: true},
		Gmail:           GmailConfig{Enabled: true},
		Jira:            JiraConfig{Enabled: true},
	}

	got := base
	ApplyLegacyDigestOff(&got)

	for name, on := range map[string]bool{
		"inbox": got.Inbox.Enabled, "streams": got.Streams.Enabled,
		"tracks": got.Tracks.Enabled, "people": got.People.Enabled,
		"ideas": got.Ideas.Enabled, "memory": got.Memory.Enabled,
		"briefing": got.Briefing.Enabled, "day_plan": got.DayPlan.Enabled,
		"next_step": got.Targets.NextStep.Enabled,
	} {
		assert.False(t, on, "%s must be forced off", name)
	}

	// Nothing else moved: restoring exactly the nine gates must reproduce
	// the original config field for field — including the integration
	// switches (calendar/gmail/jira), which are deliberately NOT part of
	// the mapping (stopping an owner's data sync is worse than a degraded
	// feature; see docs/inventory/features.md).
	got.Inbox.Enabled = true
	got.Streams.Enabled = true
	got.Tracks.Enabled = true
	got.People.Enabled = true
	got.Ideas.Enabled = true
	got.Memory.Enabled = true
	got.Briefing.Enabled = true
	got.DayPlan.Enabled = true
	got.Targets.NextStep.Enabled = true
	assert.Equal(t, base, got, "ApplyLegacyDigestOff must touch nothing but the nine feature gates")
}

// TestApplyLegacyDigestOff_MatchesOnDiskMigration is the lockstep pin: the
// in-memory fail-closed mapping and the on-disk migration's key list are two
// spellings of one rule, and a key added to only one of them is exactly the
// drift this catches. It runs the real migration over a legacy file and
// compares the resulting config against ApplyLegacyDigestOff over the
// pre-migration one.
func TestApplyLegacyDigestOff_MatchesOnDiskMigration(t *testing.T) {
	legacyYAML := []byte("active_workspace: test\ndigest:\n  enabled: false\n")

	beforePath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(beforePath, legacyYAML, 0o600))
	inMemory, err := Load(beforePath)
	require.NoError(t, err)
	ApplyLegacyDigestOff(inMemory)

	migratedPath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(migratedPath, legacyYAML, 0o600))
	legacyDetected, err := MigrateFeatureGates(migratedPath)
	require.NoError(t, err)
	require.True(t, legacyDetected)
	onDisk, err := Load(migratedPath)
	require.NoError(t, err)

	assert.Equal(t, onDisk, inMemory, "the fail-closed mapping must equal what the migration writes to disk")
}

// assertSecondCallIsByteIdenticalNoOp pins the marker-present contract: once
// the marker is on the file, MigrateFeatureGates writes nothing at all.
func assertSecondCallIsByteIdenticalNoOp(t *testing.T, path string) {
	t.Helper()
	before, err := os.ReadFile(path)
	require.NoError(t, err)

	migrated, err := MigrateFeatureGates(path)
	require.NoError(t, err)
	assert.False(t, migrated)

	after, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, string(before), string(after), "a marker-present call must write nothing")
}
