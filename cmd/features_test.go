package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/spf13/viper"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/features"
)

// writeFeaturesConfig writes a minimal config.yaml (just active_workspace,
// plus any extra yaml the caller appends) and points flagConfig at it,
// restoring the original value on cleanup.
func writeFeaturesConfig(t *testing.T, extraYAML string) string {
	t.Helper()
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.yaml")
	content := "active_workspace: test\n" + extraYAML
	require.NoError(t, os.WriteFile(configPath, []byte(content), 0o600))

	original := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = original })
	return configPath
}

// TestFeaturesCmd_PersistentPreRunAlsoRunsRootHook pins that the features
// hook does not shadow rootCmd's. cobra runs only the CLOSEST
// PersistentPreRunE in the chain (EnableTraverseRunHooks is unset), so
// declaring one on featuresCmd replaced the root's ensureSchemaFormat for
// every `features` subcommand. Both effects are asserted on the config file:
// the schema-format bump (root hook) and the migration marker (features
// hook). No database file exists under the temp HOME, so ensureSchemaFormat
// skips RunSchemaUpgrade and the test stays cheap.
func TestFeaturesCmd_PersistentPreRunAlsoRunsRootHook(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	configPath := writeFeaturesConfig(t, "")

	require.NoError(t, featuresCmd.PersistentPreRunE(featuresCmd, nil))

	v := viper.New()
	v.SetConfigFile(configPath)
	require.NoError(t, v.ReadInConfig())
	assert.Equal(t, db.CurrentSchemaFormat, v.GetInt("db.schema_format"), "rootCmd's ensureSchemaFormat must still run")
	assert.True(t, v.IsSet("features.migrated"), "the features hook's own migration must run too")
}

// TestToFeatureJSON_NilSlicesMarshalAsEmptyArrays pins the nil-slice
// normalisation inside toFeatureJSON. TestFeaturesList_JSONShape cannot: every
// registry entry carries 2-3 benefits, so nothing in that command's output is
// ever a nil slice and the check passed regardless of what toFeatureJSON did.
// The Desktop side decodes benefits into a non-optional [String], which throws
// on `null` (FeatureManagerServiceTests' loadDecodesEmptyBenefitsArray is this
// pin's other half).
func TestToFeatureJSON_NilSlicesMarshalAsEmptyArrays(t *testing.T) {
	out := toFeatureJSON(features.Feature{ID: "test", Benefits: nil, FeedsInto: nil}, &config.Config{})

	raw, err := json.Marshal(out)
	require.NoError(t, err)
	assert.Contains(t, string(raw), `"benefits":[]`, "benefits must never marshal as null")
	assert.Contains(t, string(raw), `"feeds_into":[]`, "feeds_into must never marshal as null")
}

func TestFeaturesList_JSONShape(t *testing.T) {
	writeFeaturesConfig(t, "")

	featuresListFlagJSON = true
	t.Cleanup(func() { featuresListFlagJSON = false })

	buf := new(bytes.Buffer)
	featuresListCmd.SetOut(buf)
	featuresListCmd.SetErr(&bytes.Buffer{})

	require.NoError(t, featuresListCmd.RunE(featuresListCmd, nil))

	var payload struct {
		Features []struct {
			ID          string   `json:"id"`
			Title       string   `json:"title"`
			Description string   `json:"description"`
			Tagline     string   `json:"tagline"`
			Benefits    []string `json:"benefits"`
			Icon        string   `json:"icon"`
			State       string   `json:"state"`
			Core        bool     `json:"core"`
			Parent      string   `json:"parent"`
			ConfigKey   string   `json:"config_key"`
			Cost        string   `json:"cost"`
			FeedsInto   []string `json:"feeds_into"`
			SubToggles  []struct {
				Key         string `json:"key"`
				Title       string `json:"title"`
				Description string `json:"description"`
				Enabled     bool   `json:"enabled"`
			} `json:"sub_toggles"`
		} `json:"features"`
	}
	require.NoError(t, json.Unmarshal(buf.Bytes(), &payload))
	require.NotEmpty(t, payload.Features)

	// Selling attributes decode for every entry, not just the spot-checked
	// ones below — the wire-shape counterpart to TestRegistry_Valid.
	for _, f := range payload.Features {
		assert.NotEmpty(t, f.Tagline, "feature %q missing tagline in JSON", f.ID)
		assert.NotEmpty(t, f.Icon, "feature %q missing icon in JSON", f.ID)
		assert.GreaterOrEqual(t, len(f.Benefits), 2, "feature %q has fewer than 2 benefits in JSON", f.ID)
		assert.LessOrEqual(t, len(f.Benefits), 3, "feature %q has more than 3 benefits in JSON", f.ID)
	}
	// The never-`null` half of the benefits wire contract is pinned on
	// toFeatureJSON directly, in TestToFeatureJSON_NilSlicesMarshalAsEmptyArrays
	// — this command's output has no nil slice in it to normalise.

	var sawInbox, sawTargets, sawMemory bool
	for _, f := range payload.Features {
		switch f.ID {
		case "secretary-inbox":
			sawInbox = true
			assert.Equal(t, "enabled", f.State)
			assert.False(t, f.Core)
			assert.Equal(t, "inbox.enabled", f.ConfigKey)
			assert.Equal(t, "heavy", f.Cost)
			assert.Contains(t, f.FeedsInto, "memory")
			assert.Contains(t, f.FeedsInto, "briefing")
		case "targets":
			sawTargets = true
			assert.Equal(t, "core", f.State)
			assert.True(t, f.Core)
		case "memory":
			sawMemory = true
			assert.Equal(t, "disabled", f.State, "memory defaults off")
			assert.Len(t, f.SubToggles, 13)
			for _, st := range f.SubToggles {
				assert.False(t, st.Enabled, "sub-toggle %q should read the default (off)", st.Key)
			}
		}
	}
	assert.True(t, sawInbox, "secretary-inbox must be present in the JSON output")
	assert.True(t, sawTargets, "targets (core) must be present in the JSON output")
	assert.True(t, sawMemory, "memory must be present in the JSON output")
}

// TestFeaturesList_JSONReflectsSubToggleWrite pins subToggleEnabled's
// key->field wiring end to end: write exactly one of memory's 13 sub-toggle
// keys through the same setConfigKey path `features enable`/`disable` use,
// then assert `list --json` reports that one enabled=true and every sibling
// still false — so a copy-paste mistake in the switch (e.g. two cases
// reading the same struct field) can't pass silently.
func TestFeaturesList_JSONReflectsSubToggleWrite(t *testing.T) {
	configPath := writeFeaturesConfig(t, "")
	require.NoError(t, setConfigKey(configPath, "memory.sources.gmail", true))

	featuresListFlagJSON = true
	t.Cleanup(func() { featuresListFlagJSON = false })

	buf := new(bytes.Buffer)
	featuresListCmd.SetOut(buf)
	featuresListCmd.SetErr(&bytes.Buffer{})

	require.NoError(t, featuresListCmd.RunE(featuresListCmd, nil))

	var payload featuresListJSON
	require.NoError(t, json.Unmarshal(buf.Bytes(), &payload))

	var memory *featureJSON
	for i := range payload.Features {
		if payload.Features[i].ID == "memory" {
			memory = &payload.Features[i]
		}
	}
	require.NotNil(t, memory, "memory feature must be present")
	require.Len(t, memory.SubToggles, 13)

	for _, st := range memory.SubToggles {
		if st.Key == "memory.sources.gmail" {
			assert.True(t, st.Enabled, "memory.sources.gmail should read back as enabled")
		} else {
			assert.False(t, st.Enabled, "sub-toggle %q must stay disabled — only gmail was written", st.Key)
		}
	}
}

func TestFeaturesDisable_DryRunWritesNothing(t *testing.T) {
	configPath := writeFeaturesConfig(t, "digest:\n  enabled: true\n")

	before, err := os.ReadFile(configPath)
	require.NoError(t, err)

	featuresDisableFlagDryRun = true
	t.Cleanup(func() { featuresDisableFlagDryRun = false })

	buf := new(bytes.Buffer)
	featuresDisableCmd.SetOut(buf)
	featuresDisableCmd.SetErr(&bytes.Buffer{})

	require.NoError(t, featuresDisableCmd.RunE(featuresDisableCmd, []string{"slack-digests"}))

	after, err := os.ReadFile(configPath)
	require.NoError(t, err)
	assert.Equal(t, before, after, "dry-run must not write to the config file")
	assert.Contains(t, buf.String(), "slack-digests")
}

// TestFeaturesDisable_DryRunJSONWireShape pins the exact JSON the Desktop
// cascade dialog decodes (`FeatureDependents` in
// WatchtowerDesktop/Sources/Services/FeatureManagerService.swift). It decodes
// into map[string]any rather than the Go struct on purpose: a renamed field
// then breaks a Go test here instead of only surfacing as a silent decode
// failure in the Desktop at runtime.
func TestFeaturesDisable_DryRunJSONWireShape(t *testing.T) {
	writeFeaturesConfig(t, "")

	featuresDisableFlagDryRun = true
	featuresDisableFlagJSON = true
	t.Cleanup(func() {
		featuresDisableFlagDryRun = false
		featuresDisableFlagJSON = false
	})

	runDryRun := func(t *testing.T, id string) (map[string]any, string) {
		t.Helper()
		buf := new(bytes.Buffer)
		featuresDisableCmd.SetOut(buf)
		featuresDisableCmd.SetErr(&bytes.Buffer{})
		require.NoError(t, featuresDisableCmd.RunE(featuresDisableCmd, []string{id}))

		var payload map[string]any
		require.NoError(t, json.Unmarshal(buf.Bytes(), &payload))
		return payload, buf.String()
	}

	payload, _ := runDryRun(t, "slack-digests")
	assert.Len(t, payload, 2, "the top-level wire contract is exactly feature+dependents: %v", payload)
	assert.Equal(t, "slack-digests", payload["feature"])

	deps, ok := payload["dependents"].([]any)
	require.True(t, ok, "dependents must be a JSON array, got %T", payload["dependents"])
	require.NotEmpty(t, deps, "slack-digests has enabled dependents by default — an empty list here would make the loop below assert nothing")

	for _, raw := range deps {
		dep, depOK := raw.(map[string]any)
		require.True(t, depOK, "each dependent must be a JSON object, got %T", raw)
		assert.Len(t, dep, 2, "a dependent is exactly id+title: %v", dep)
		id, idOK := dep["id"].(string)
		require.True(t, idOK, "dependent.id must be a string, got %T", dep["id"])
		assert.NotEmpty(t, id)
		title, titleOK := dep["title"].(string)
		require.True(t, titleOK, "dependent.title must be a string, got %T", dep["title"])
		assert.NotEmpty(t, title)
	}

	// A leaf feature must still emit `[]`, never `null`: Swift's non-optional
	// [Dependent] throws on a null (review-rules "wire shape"). next-step has
	// no FeedsInto edges and nothing feeds into it, so it stays a genuine
	// leaf under defaults (unlike briefing, which now feeds day-plan).
	leaf, rawJSON := runDryRun(t, "next-step")
	leafDeps, ok := leaf["dependents"].([]any)
	require.True(t, ok, "dependents must be a JSON array even with no dependents, got %T", leaf["dependents"])
	assert.Empty(t, leafDeps)
	assert.Contains(t, rawJSON, `"dependents":[]`, "an empty dependent list must marshal as [], not null")
}

func TestFeaturesDisable_WritesOnlyNamedKey(t *testing.T) {
	configPath := writeFeaturesConfig(t, "")

	buf := new(bytes.Buffer)
	featuresDisableCmd.SetOut(buf)
	featuresDisableCmd.SetErr(&bytes.Buffer{})

	require.NoError(t, featuresDisableCmd.RunE(featuresDisableCmd, []string{"secretary-inbox"}))

	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	assert.False(t, cfg.Inbox.Enabled, "secretary-inbox's own key must be written false")
	assert.True(t, cfg.Ideas.Enabled, "an unrelated feature's key must stay at its default (untouched)")
}

func TestFeaturesDisable_WithDependents(t *testing.T) {
	writeFeaturesConfig(t, "")

	featuresDisableFlagWithDependents = true
	t.Cleanup(func() { featuresDisableFlagWithDependents = false })

	buf := new(bytes.Buffer)
	featuresDisableCmd.SetOut(buf)
	featuresDisableCmd.SetErr(&bytes.Buffer{})

	require.NoError(t, featuresDisableCmd.RunE(featuresDisableCmd, []string{"slack-digests"}))

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	assert.False(t, cfg.Digest.Enabled, "slack-digests itself")
	assert.False(t, cfg.Inbox.Enabled, "secretary-inbox is an enabled dependent")
	assert.False(t, cfg.Tracks.Enabled, "tracks is an enabled dependent")
	assert.False(t, cfg.People.Enabled, "people-cards is an enabled dependent")
	assert.False(t, cfg.Ideas.Enabled, "ideas is an enabled dependent")
	assert.False(t, cfg.Briefing.Enabled, "briefing is an enabled dependent")
}

func TestFeaturesEnable_RunsFastForward(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeLegacyConfig(t, "")

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)

	seedDB, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	require.NoError(t, seedDB.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test"}))
	require.NoError(t, seedDB.Close())

	buf := new(bytes.Buffer)
	featuresEnableCmd.SetOut(buf)
	featuresEnableCmd.SetErr(&bytes.Buffer{})

	before := time.Now().Unix()
	require.NoError(t, featuresEnableCmd.RunE(featuresEnableCmd, []string{"secretary-inbox"}))
	after := time.Now().Unix()

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()

	ts, err := database.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.GreaterOrEqual(t, ts, float64(before), "inbox watermark should fast-forward to roughly now")
	assert.LessOrEqual(t, ts, float64(after), "inbox watermark should fast-forward to roughly now")

	composeTS, err := database.GetComposeLastRunTS()
	require.NoError(t, err)
	assert.GreaterOrEqual(t, composeTS, float64(before))

	reloaded, err := config.Load(flagConfig)
	require.NoError(t, err)
	assert.True(t, reloaded.Inbox.Enabled, "enable must write the config key too")
}

// TestFeaturesEnable_FailedFastForwardLeavesKeyUnwritten pins FEAT-03's
// failure side: if opening the DB (or fast-forwarding) fails, the config key
// must stay unwritten rather than leave the feature enabled with stale
// watermarks — which would let the next daemon cycle process the entire
// historical backlog accumulated while it was off. It blocks db.Open by
// putting a plain file where the workspace directory needs to be, so
// os.MkdirAll fails instead of creating it.
//
// Asserts on the raw file bytes (the dry-run test's precedent), not on
// reloaded.Inbox.Enabled: inbox.enabled defaults to true, so an untouched
// file would read back as "enabled" via the default regardless of whether
// setConfigKey ever ran — only a byte comparison actually proves nothing
// was written.
func TestFeaturesEnable_FailedFastForwardLeavesKeyUnwritten(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	configPath := writeLegacyConfig(t, "")

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)

	require.NoError(t, os.MkdirAll(filepath.Dir(cfg.WorkspaceDir()), 0o700))
	require.NoError(t, os.WriteFile(cfg.WorkspaceDir(), []byte("blocked"), 0o600))

	before, err := os.ReadFile(configPath)
	require.NoError(t, err)

	buf := new(bytes.Buffer)
	featuresEnableCmd.SetOut(buf)
	featuresEnableCmd.SetErr(&bytes.Buffer{})

	err = featuresEnableCmd.RunE(featuresEnableCmd, []string{"secretary-inbox"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not enabled")

	after, err := os.ReadFile(configPath)
	require.NoError(t, err)
	assert.Equal(t, before, after, "a failed fast-forward must leave the config file untouched")
}

func TestFeatures_CoreRejected(t *testing.T) {
	configPath := writeFeaturesConfig(t, "")

	buf := new(bytes.Buffer)
	featuresEnableCmd.SetOut(buf)
	featuresEnableCmd.SetErr(&bytes.Buffer{})
	err := featuresEnableCmd.RunE(featuresEnableCmd, []string{"targets"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "core")

	featuresDisableCmd.SetOut(buf)
	featuresDisableCmd.SetErr(&bytes.Buffer{})
	err = featuresDisableCmd.RunE(featuresDisableCmd, []string{"targets"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "core")

	// Neither rejected call should have touched the config file.
	data, err := os.ReadFile(configPath)
	require.NoError(t, err)
	assert.Equal(t, "active_workspace: test\n", string(data))
}

func TestFeaturesEnable_UnknownIDListsValidIDs(t *testing.T) {
	writeFeaturesConfig(t, "")

	buf := new(bytes.Buffer)
	featuresEnableCmd.SetOut(buf)
	featuresEnableCmd.SetErr(&bytes.Buffer{})

	err := featuresEnableCmd.RunE(featuresEnableCmd, []string{"not-a-real-feature"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "secretary-inbox", "error should list valid toggleable ids")
	assert.NotContains(t, err.Error(), "targets", "core ids are not valid toggle targets")
}
