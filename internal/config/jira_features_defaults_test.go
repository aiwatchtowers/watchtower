package config

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestLoad_AbsentJiraFeaturesGetRoleDefaults pins the pristine install: a
// config with no jira.features block at all decodes the IC baseline, not
// all falses. Before the SetDefault seeding, the Jira feature surface was
// entirely off on every install that had never run `jira features` — which,
// given the writer bug, was every install.
func TestLoad_AbsentJiraFeaturesGetRoleDefaults(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte("active_workspace: test\njira:\n  enabled: true\n"), 0o600))

	cfg, err := Load(p)
	require.NoError(t, err)
	assert.Equal(t, DefaultJiraFeatures(DefaultJiraFeaturesRole), cfg.Jira.Features,
		"an absent key must mean the role default, not false")
}

// TestLoad_ExplicitJiraFeatureValueBeatsDefault pins the other half: a key
// the owner actually wrote wins over the seeded default, in both directions.
// Without this a `jira features disable my_issues` would be silently undone
// by the default on the very next read.
func TestLoad_ExplicitJiraFeatureValueBeatsDefault(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	content := "active_workspace: test\n" +
		"jira:\n" +
		"  features:\n" +
		"    my_issues_in_briefing: false\n" +
		"    team_workload: true\n"
	require.NoError(t, os.WriteFile(p, []byte(content), 0o600))

	cfg, err := Load(p)
	require.NoError(t, err)
	assert.False(t, cfg.Jira.Features.MyIssuesInBriefing, "an explicit false must survive an on-by-default key")
	assert.True(t, cfg.Jira.Features.TeamWorkload, "an explicit true must survive an off-by-default key")
	assert.True(t, cfg.Jira.Features.AwaitingMyInput, "an untouched key still takes the default")
}

// TestLoad_RetiredJiraFeatureKeysAreInert pins that an install still
// carrying the removed who_ping / write_back_suggestions toggles (written by
// `jira features reset` or an explicit enable before they were retired)
// loads cleanly: the stale keys decode into nothing and leave every live
// toggle at its default. No migration strips them — this is why none is
// needed.
func TestLoad_RetiredJiraFeatureKeysAreInert(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	content := "active_workspace: test\n" +
		"jira:\n" +
		"  features:\n" +
		"    who_ping: true\n" +
		"    write_back_suggestions: true\n" +
		"    whoping: true\n" +
		"    writebacksuggestions: true\n"
	require.NoError(t, os.WriteFile(p, []byte(content), 0o600))

	cfg, err := Load(p)
	require.NoError(t, err)
	assert.Equal(t, DefaultJiraFeatures(DefaultJiraFeaturesRole), cfg.Jira.Features,
		"retired keys must not leak into any live toggle")
}

// TestLoad_MigratedInstallTakesDefaultsForDroppedArtifacts is the
// interaction between the key repair and the defaults, and it is what makes
// the repair reach the owner rather than freeze his install as it was.
//
// The migration carries a squashed `true` and drops a squashed `false`,
// because the pre-fix writer wrote all eleven keys on every call and only a
// `true` records intent. So after a repair the carried enable stands, the
// dropped artifact falls through to the role default — and a value written
// AFTERWARDS through the product's own write path still wins over that
// default, which is the half of the contract that has to keep holding.
func TestLoad_MigratedInstallTakesDefaultsForDroppedArtifacts(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	content := "active_workspace: test\n" +
		"jira:\n" +
		"  features:\n" +
		"    myissuesinbriefing: false\n" +
		"    teamworkload: true\n"
	require.NoError(t, os.WriteFile(p, []byte(content), 0o600))

	repaired, err := MigrateJiraFeatureKeys(p)
	require.NoError(t, err)
	require.True(t, repaired)

	cfg, err := Load(p)
	require.NoError(t, err)
	assert.True(t, cfg.Jira.Features.TeamWorkload, "the migrated enable stands")
	assert.True(t, cfg.Jira.Features.MyIssuesInBriefing,
		"a dropped artifact false must fall through to the on-by-default role baseline")
	assert.True(t, cfg.Jira.Features.AwaitingMyInput,
		"a key the owner never touched is absent, so it takes the default too")

	// A deliberate disable written after the repair — the shape
	// `jira features disable` now produces — must survive the default.
	require.NoError(t, patchConfigYAML(p, map[string]bool{"jira.features.my_issues_in_briefing": false}, nil))

	cfg, err = Load(p)
	require.NoError(t, err)
	assert.False(t, cfg.Jira.Features.MyIssuesInBriefing,
		"an explicit post-repair false must not be overwritten by the on-by-default seed")
}

// TestJiraFeatureDefaults_CoversEveryToggle pins that the seeded keys are the
// struct's own mapstructure tags, one per field — the property that makes
// `SetDefault("jira.features."+key, …)` reach the field it names. A default
// registered under any other spelling would be as invisible as the writes
// this repair removed.
func TestJiraFeatureDefaults_CoversEveryToggle(t *testing.T) {
	typ := reflect.TypeOf(JiraFeatureToggles{})
	defaults := jiraFeatureDefaults(DefaultJiraFeaturesRole)
	require.Len(t, defaults, typ.NumField(), "every toggle needs a default")

	ic := DefaultJiraFeatures(DefaultJiraFeaturesRole)
	icValue := reflect.ValueOf(ic)
	for i := 0; i < typ.NumField(); i++ {
		field := typ.Field(i)
		key := field.Tag.Get("mapstructure")
		got, ok := defaults[key]
		require.True(t, ok, "no default for %s under %q", field.Name, key)
		assert.Equal(t, icValue.Field(i).Bool(), got, "%s default must match the role table", field.Name)
	}
}
