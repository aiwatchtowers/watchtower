package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/viper"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gopkg.in/yaml.v3"
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

// TestMigrateFeatureGates_PreservesWorkspaceKeyCasing pins the actual
// corruption the destructive WriteConfigAs rewrite caused on disk: viper
// lowercases every key when it re-serializes its internal map, including
// user-supplied ones like `workspaces.<Team>`, while leaving
// `active_workspace`'s own value cased — so a config that read
// `workspaces:\n  MyTeam:` before a first-contact marker stamp came back
// `workspaces:\n  myteam:` after it (confirmed against the old WriteConfigAs
// path). The marker write must not touch that casing at all — only the
// `features` node it adds and the `digest`/legacy keys it sets when actually
// migrating a legacy install.
//
// (Separately: viper's own read path lowercases nested map keys too, so
// `Config.GetActiveWorkspace()` could not resolve a genuinely mixed-case
// workspace name via `Load()` even from a hand-written, never-migrated
// file — a pre-existing viper limitation independent of this write-side
// fix, closed on the read side by GetActiveWorkspace's lowercase fallback;
// see TestGetActiveWorkspace_CaseInsensitiveLookup_EndToEnd in
// config_test.go.)
func TestMigrateFeatureGates_PreservesWorkspaceKeyCasing(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	original := "active_workspace: MyTeam\n" +
		"workspaces:\n" +
		"  MyTeam:\n" +
		"    slack_token: xoxb-test\n"
	require.NoError(t, os.WriteFile(p, []byte(original), 0o600))

	migrated, err := MigrateFeatureGates(p)
	require.NoError(t, err)
	assert.False(t, migrated, "digest.enabled absent is not a legacy install")

	after, err := os.ReadFile(p)
	require.NoError(t, err)
	assert.Contains(t, string(after), "MyTeam:", "the workspace key's original casing must survive the marker write")
	assert.NotContains(t, string(after), "myteam:", "the write must not introduce a lowercased duplicate key")
}

// TestSetYAMLPath_ReusesExistingMappingNode pins setYAMLPath's "descend into
// an already-present intermediate mapping" branch: a second key under the
// same first segment must land as a new sibling inside the EXISTING node,
// never a duplicate top-level key (which YAML would parse as "last one
// wins," silently dropping the first section).
func TestSetYAMLPath_ReusesExistingMappingNode(t *testing.T) {
	root := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
	setYAMLPath(root, []string{"digest", "enabled"}, true)
	require.Len(t, root.Content, 2, "one top-level key: digest")

	setYAMLPath(root, []string{"digest", "min_messages_enabled"}, false)
	require.Len(t, root.Content, 2, "still one top-level key — no duplicate 'digest' section")

	digestNode := root.Content[1]
	require.Equal(t, yaml.MappingNode, digestNode.Kind)
	require.Len(t, digestNode.Content, 4, "two keys now live under the same digest mapping")
	assert.Equal(t, "enabled", digestNode.Content[0].Value)
	assert.Equal(t, "true", digestNode.Content[1].Value, "the first key's value must survive untouched")
	assert.Equal(t, "min_messages_enabled", digestNode.Content[2].Value)
	assert.Equal(t, "false", digestNode.Content[3].Value)
}

// TestSetYAMLPath_OverwritesExistingScalarLeaf pins the other found-node
// branch: setting an already-present leaf key updates its value in place
// rather than appending a second (duplicate, YAML-illegal-in-spirit) key.
func TestSetYAMLPath_OverwritesExistingScalarLeaf(t *testing.T) {
	root := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
	setYAMLPath(root, []string{"features", "migrated"}, true)
	require.Len(t, root.Content, 2)

	setYAMLPath(root, []string{"features", "migrated"}, false)
	require.Len(t, root.Content, 2, "no duplicate 'features' key from re-setting the same path")

	featuresNode := root.Content[1]
	require.Len(t, featuresNode.Content, 2, "no duplicate 'migrated' key either")
	assert.Equal(t, "migrated", featuresNode.Content[0].Value)
	assert.Equal(t, "false", featuresNode.Content[1].Value, "the leaf was overwritten in place")
}

// TestPatchConfigYAML_SecondCallReusesExistingSection is the integration
// counterpart of the two setYAMLPath tests above, exercised through the real
// read-parse-encode-write round trip: two separate patchConfigYAML calls
// setting different keys under the same section must not fork the file into
// two "digest:" blocks.
func TestPatchConfigYAML_SecondCallReusesExistingSection(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte("active_workspace: test\n"), 0o600))

	require.NoError(t, patchConfigYAML(p, map[string]bool{"digest.enabled": true}))
	require.NoError(t, patchConfigYAML(p, map[string]bool{"digest.min_messages_enabled": false}))

	v := rawConfig(t, p)
	assert.True(t, v.GetBool("digest.enabled"), "the first call's value must survive the second")
	assert.False(t, v.GetBool("digest.min_messages_enabled"))

	raw, err := os.ReadFile(p)
	require.NoError(t, err)
	assert.Equal(t, 1, strings.Count(string(raw), "digest:"), "must not fork into two digest: sections")
}

// TestPatchConfigYAML_ReadFileError pins the read-error branch: a missing
// file must surface as a wrapped error, never a panic or a silent no-op.
func TestPatchConfigYAML_ReadFileError(t *testing.T) {
	p := filepath.Join(t.TempDir(), "absent.yaml")
	err := patchConfigYAML(p, map[string]bool{"features.migrated": true})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "reading config")
}

// TestPatchConfigYAML_MalformedYAML pins the parse-error branch: YAML
// forbids tab indentation, so a config file corrupted that way must fail
// loudly rather than silently produce a garbage patch.
func TestPatchConfigYAML_MalformedYAML(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte("digest:\n\tenabled: true\n"), 0o600))

	err := patchConfigYAML(p, map[string]bool{"features.migrated": true})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "parsing config")
}

// TestPatchConfigYAML_EmptyFile pins the "nothing parsed at all" branch: an
// empty or comment-only config file (e.g. right after `watchtower config
// init` clears it, or a hand-emptied file) must still get patched instead
// of hitting a nil-root panic.
func TestPatchConfigYAML_EmptyFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte("# nothing here yet\n"), 0o600))

	require.NoError(t, patchConfigYAML(p, map[string]bool{"features.migrated": true}))

	v := rawConfig(t, p)
	assert.True(t, v.IsSet("features.migrated"))
}

// TestPatchConfigYAML_RootNotAMapping pins the defensive check against a
// config file whose top-level YAML value isn't a mapping at all (e.g.
// corrupted into a bare list) — must error instead of panicking on
// root.Content access.
func TestPatchConfigYAML_RootNotAMapping(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte("- a\n- b\n"), 0o600))

	err := patchConfigYAML(p, map[string]bool{"features.migrated": true})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "is not a mapping")
}

// TestMigrateFeatureGates_MalformedYAMLReadError pins MigrateFeatureGates'
// own read-error path (distinct from patchConfigYAML's — this one is
// viper's ReadInConfig, hit before any legacy/marker logic runs): a
// corrupted config must surface as a real error, not be misread as "file
// absent" (which would silently skip the migration this install may need).
func TestMigrateFeatureGates_MalformedYAMLReadError(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte("digest:\n\tenabled: true\n"), 0o600))

	migrated, err := MigrateFeatureGates(p)
	require.Error(t, err)
	assert.False(t, migrated)
	assert.Contains(t, err.Error(), "reading config")
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
