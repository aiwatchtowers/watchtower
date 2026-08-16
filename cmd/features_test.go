package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
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
