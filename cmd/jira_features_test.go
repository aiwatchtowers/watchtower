package cmd

import (
	"bytes"
	"reflect"
	"testing"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
)

// loadJiraFeatures reads configPath through the real config.Load — the only
// reader that matters, and the half of the round trip every pre-existing test
// skipped by asserting on a struct it had built itself.
func loadJiraFeatures(t *testing.T, configPath string) config.JiraFeatureToggles {
	t.Helper()
	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	return cfg.Jira.Features
}

// TestJiraFeaturesEnable_RoundTripsThroughConfigLoad is the test that did not
// exist in either language: write a toggle through the real CLI writer, read
// it back through the real config.Load. Before the scalar-key fix the writer
// emitted `jira.features.teamworkload` (yaml.v3's lowercased Go field name,
// the struct carries no yaml tags) while the reader's mapstructure tag is
// `team_workload`, so every toggle the product ever wrote decoded as false.
//
// team_workload and blocker_map are both OFF in the IC defaults, so this
// asserts the write, not a default.
func TestJiraFeaturesEnable_RoundTripsThroughConfigLoad(t *testing.T) {
	configPath := writeFeaturesConfig(t, "")

	require.NoError(t, setJiraFeatureToggle(newJiraFeaturesTestCmd(), "team_workload", true))

	features := loadJiraFeatures(t, configPath)
	assert.True(t, features.TeamWorkload, "an enabled toggle must read back true through config.Load")
	assert.False(t, features.BlockerMap, "enabling one toggle must not touch its siblings")

	// The key on disk is the mapstructure long name — the spelling the two
	// Swift readers of the raw yaml (JiraKeyExtractor, ConfigService) expect.
	v := viper.New()
	v.SetConfigFile(configPath)
	require.NoError(t, v.ReadInConfig())
	assert.True(t, v.IsSet("jira.features.team_workload"), "the canonical snake_case key must be on disk")
	assert.False(t, v.IsSet("jira.features.teamworkload"), "the squashed key must never be written again")
}

// TestJiraFeaturesEnable_AcceptsLongName pins that the long spelling the
// Desktop shells out with (`jira features enable my_issues_in_briefing`,
// JiraFeaturesSettingsView) resolves to the same canonical key as the short
// CLI name.
func TestJiraFeaturesEnable_AcceptsLongName(t *testing.T) {
	configPath := writeFeaturesConfig(t, "")

	require.NoError(t, setJiraFeatureToggle(newJiraFeaturesTestCmd(), "epic_progress", true))
	require.NoError(t, setJiraFeatureToggle(newJiraFeaturesTestCmd(), "write_back_suggestions", true))

	features := loadJiraFeatures(t, configPath)
	assert.True(t, features.EpicProgress)
	assert.True(t, features.WriteBackSuggestions, "the long spelling must write the same key as the short one")
}

// TestJiraFeaturesDisable_RoundTripsThroughConfigLoad pins the other
// direction: a disable must land as an explicit false, not as a key the
// reader cannot see.
func TestJiraFeaturesDisable_RoundTripsThroughConfigLoad(t *testing.T) {
	configPath := writeFeaturesConfig(t, "")

	require.NoError(t, setJiraFeatureToggle(newJiraFeaturesTestCmd(), "team_workload", true))
	require.True(t, loadJiraFeatures(t, configPath).TeamWorkload)

	require.NoError(t, setJiraFeatureToggle(newJiraFeaturesTestCmd(), "team_workload", false))
	assert.False(t, loadJiraFeatures(t, configPath).TeamWorkload, "a disabled toggle must read back false")

	v := viper.New()
	v.SetConfigFile(configPath)
	require.NoError(t, v.ReadInConfig())
	assert.True(t, v.IsSet("jira.features.team_workload"), "disable writes an explicit false, not an absent key")
	assert.False(t, v.GetBool("jira.features.team_workload"))
}

// TestJiraFeaturesReset_RoundTripsThroughConfigLoad pins the reset writer,
// which wrote the same unreadable struct. After a reset to the IC baseline,
// my_issues_in_briefing is on and team_workload — enabled beforehand — is
// off, both observed through config.Load.
func TestJiraFeaturesReset_RoundTripsThroughConfigLoad(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	configPath := writeFeaturesConfig(t, "")

	require.NoError(t, setJiraFeatureToggle(newJiraFeaturesTestCmd(), "team_workload", true))
	require.True(t, loadJiraFeatures(t, configPath).TeamWorkload)

	require.NoError(t, runJiraFeaturesReset(newJiraFeaturesTestCmd(), nil))

	features := loadJiraFeatures(t, configPath)
	ic := config.DefaultJiraFeatures(config.DefaultJiraFeaturesRole)
	assert.Equal(t, ic, features, "reset must write every toggle at the role default, readably")

	v := viper.New()
	v.SetConfigFile(configPath)
	require.NoError(t, v.ReadInConfig())
	for _, name := range featureNames {
		assert.True(t, v.IsSet("jira.features."+jiraFeatureConfigKeys[name]),
			"reset must write %s explicitly", name)
	}
}

// TestJiraFeaturesEnable_UnknownNameIsRejected pins that an unknown feature
// is refused before anything is written.
func TestJiraFeaturesEnable_UnknownNameIsRejected(t *testing.T) {
	configPath := writeFeaturesConfig(t, "")

	err := setJiraFeatureToggle(newJiraFeaturesTestCmd(), "not_a_feature", true)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "unknown feature")

	v := viper.New()
	v.SetConfigFile(configPath)
	require.NoError(t, v.ReadInConfig())
	assert.False(t, v.IsSet("jira.features"), "a rejected name must not create the features block")
}

// TestJiraFeatureConfigKeys_MatchStructAndToggleRef keeps the three
// vocabularies in step: every canonical key must be a real
// config.JiraFeatureToggles mapstructure tag, every struct field must be
// reachable, and every name the table accepts must also be accepted by
// featureToggleRef.
func TestJiraFeatureConfigKeys_MatchStructAndToggleRef(t *testing.T) {
	tags := map[string]bool{}
	typ := reflect.TypeOf(config.JiraFeatureToggles{})
	for i := 0; i < typ.NumField(); i++ {
		tags[typ.Field(i).Tag.Get("mapstructure")] = true
	}
	require.Len(t, tags, typ.NumField(), "every field needs its own mapstructure tag")

	seen := map[string]bool{}
	for name, key := range jiraFeatureConfigKeys {
		assert.True(t, tags[key], "key %q (for %q) is not a JiraFeatureToggles mapstructure tag", key, name)
		seen[key] = true

		var toggles config.JiraFeatureToggles
		_, ok := featureToggleRef(&toggles, name)
		assert.True(t, ok, "featureToggleRef does not accept %q", name)
	}
	assert.Len(t, seen, typ.NumField(), "every toggle must have a canonical key")

	for _, name := range featureNames {
		assert.NotEmpty(t, jiraFeatureConfigKeys[name], "short name %q has no canonical key", name)
	}
}

// newJiraFeaturesTestCmd returns a cobra command whose output is discarded,
// so the writers under test can print their confirmation lines.
func newJiraFeaturesTestCmd() *cobra.Command {
	cmd := &cobra.Command{}
	cmd.SetOut(&bytes.Buffer{})
	cmd.SetErr(&bytes.Buffer{})
	return cmd
}
