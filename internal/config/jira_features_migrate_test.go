package config

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// legacyJiraFeaturesConfig is what the pre-repair `jira features` writer left
// on disk: the whole JiraFeatureToggles struct serialized by yaml.v3, which
// has no yaml tags to follow and therefore emits lowercased Go field names.
// Two flags are on — an owner who enabled them and has been looking at a
// product that reads them as off ever since.
const legacyJiraFeaturesConfig = `active_workspace: test
jira:
  enabled: true
  features:
    myissuesinbriefing: true
    awaitingmyinput: false
    whoping: false
    trackjiralinking: false
    teamworkload: true
    blockermap: false
    iterationprogress: false
    epicprogress: false
    writebacksuggestions: false
    releasedashboard: false
    withoutjiradetection: false
  sync_interval_mins: 15
`

// assertSecondJiraCallIsByteIdenticalNoOp is the jira counterpart of
// assertSecondCallIsByteIdenticalNoOp: once the marker is on the file, the
// migration must never write again.
func assertSecondJiraCallIsByteIdenticalNoOp(t *testing.T, path string) {
	t.Helper()
	before, err := os.ReadFile(path)
	require.NoError(t, err)

	repaired, err := MigrateJiraFeatureKeys(path)
	require.NoError(t, err)
	assert.False(t, repaired, "a marker-present call must repair nothing")

	after, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, string(before), string(after), "a marker-present call must write nothing")
}

// TestMigrateJiraFeatureKeys_CarriesValuesToReadableKeys is the point of the
// migration: the owner's enables survive the repair. Deleting the squashed
// block instead would silently discard them — the reader would then see an
// absent key where the owner sees a toggle they switched on.
func TestMigrateJiraFeatureKeys_CarriesValuesToReadableKeys(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte(legacyJiraFeaturesConfig), 0o600))

	repaired, err := MigrateJiraFeatureKeys(p)
	require.NoError(t, err)
	assert.True(t, repaired, "a config carrying squashed keys is a repair")

	v := rawConfig(t, p)
	for squashed, long := range squashedJiraFeatureKeys {
		assert.False(t, v.IsSet("jira.features."+squashed), "the dead key %q must be gone", squashed)
		assert.True(t, v.IsSet("jira.features."+long), "every value must land under %q", long)
	}

	// The values, read through the product's own reader.
	cfg, err := Load(p)
	require.NoError(t, err)
	assert.True(t, cfg.Jira.Features.MyIssuesInBriefing, "the owner's enable must survive")
	assert.True(t, cfg.Jira.Features.TeamWorkload, "the owner's enable must survive")
	assert.False(t, cfg.Jira.Features.BlockerMap, "an off flag must stay off")

	assert.True(t, v.IsSet(JiraFeaturesMigratedKey), "the marker must be stamped")
	assert.True(t, v.GetBool("jira.enabled"), "unrelated jira keys must survive")
	assert.Equal(t, 15, v.GetInt("jira.sync_interval_mins"), "unrelated jira keys must survive")

	assertSecondJiraCallIsByteIdenticalNoOp(t, p)
}

// TestMigrateJiraFeatureKeys_ExplicitSnakeKeyWins pins that the migration
// never overwrites a value the owner — or the repaired writer — set under
// the readable spelling. A stale squashed key from before the repair must
// not resurrect an old value on top of a current one.
func TestMigrateJiraFeatureKeys_ExplicitSnakeKeyWins(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	content := "active_workspace: test\n" +
		"jira:\n" +
		"  features:\n" +
		"    team_workload: false\n" +
		"    teamworkload: true\n" +
		"    blockermap: true\n"
	require.NoError(t, os.WriteFile(p, []byte(content), 0o600))

	repaired, err := MigrateJiraFeatureKeys(p)
	require.NoError(t, err)
	assert.True(t, repaired)

	cfg, err := Load(p)
	require.NoError(t, err)
	assert.False(t, cfg.Jira.Features.TeamWorkload, "the explicit readable key must win over the squashed one")
	assert.True(t, cfg.Jira.Features.BlockerMap, "a squashed key with no readable counterpart is still carried over")

	v := rawConfig(t, p)
	assert.False(t, v.IsSet("jira.features.teamworkload"), "the squashed key is removed either way")
	assert.False(t, v.IsSet("jira.features.blockermap"), "the squashed key is removed either way")
}

// TestMigrateJiraFeatureKeys_NoSquashedKeysStampsMarkerOnly covers the
// common install — one that never touched a toggle. Nothing is repaired and
// no jira.features key is invented; only the marker lands, so the file is
// never written again.
func TestMigrateJiraFeatureKeys_NoSquashedKeysStampsMarkerOnly(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte("active_workspace: test\njira:\n  enabled: true\n"), 0o600))

	repaired, err := MigrateJiraFeatureKeys(p)
	require.NoError(t, err)
	assert.False(t, repaired, "nothing to carry over")

	v := rawConfig(t, p)
	assert.True(t, v.IsSet(JiraFeaturesMigratedKey), "first contact must stamp the marker")
	assert.Equal(t, "test", v.GetString("active_workspace"), "unrelated keys must survive")
	for squashed, long := range squashedJiraFeatureKeys {
		assert.False(t, v.IsSet("jira.features."+squashed), "the stamp must invent nothing")
		assert.False(t, v.IsSet("jira.features."+long), "the stamp must invent nothing")
	}

	assertSecondJiraCallIsByteIdenticalNoOp(t, p)
}

// TestMigrateJiraFeatureKeys_MissingFileIsNoOp pins the clean exit on a
// Desktop-only install that has no config.yaml yet: nothing to migrate, no
// file created, no error.
func TestMigrateJiraFeatureKeys_MissingFileIsNoOp(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")

	repaired, err := MigrateJiraFeatureKeys(p)
	require.NoError(t, err)
	assert.False(t, repaired)

	_, statErr := os.Stat(p)
	assert.True(t, os.IsNotExist(statErr), "the migration must not create a config file")
}

// TestMigrateJiraFeatureKeys_PreservesCommentsAndWorkspaceCasing is what
// patchConfigYAML exists for. viper's WriteConfigAs re-serializes the whole
// file from its internal map, dropping comments and lowercasing every key
// including user-supplied ones like `workspaces.<Team>`; this migration edits
// the parsed yaml node-by-node instead, so an owner's hand-written file
// survives a repair it never asked for.
func TestMigrateJiraFeatureKeys_PreservesCommentsAndWorkspaceCasing(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	original := "# Watchtower configuration — hand-edited, keep it that way\n" +
		"active_workspace: MyTeam\n" +
		"workspaces:\n" +
		"  MyTeam:\n" +
		"    slack_token: xoxb-test\n" +
		"jira:\n" +
		"  features:\n" +
		"    teamworkload: true\n"
	require.NoError(t, os.WriteFile(p, []byte(original), 0o600))

	repaired, err := MigrateJiraFeatureKeys(p)
	require.NoError(t, err)
	require.True(t, repaired)

	after, err := os.ReadFile(p)
	require.NoError(t, err)
	assert.Contains(t, string(after), "# Watchtower configuration", "comments must survive the repair")
	assert.Contains(t, string(after), "MyTeam:", "the workspace key's casing must survive the repair")
	assert.NotContains(t, string(after), "myteam:", "the repair must not introduce a lowercased duplicate key")
	assert.Contains(t, string(after), "team_workload: true", "the value must land under the readable key")
	assert.NotContains(t, string(after), "teamworkload: true", "the dead key must be gone")
}

// TestSquashedJiraFeatureKeys_MatchStruct derives both halves of the table
// from JiraFeatureToggles itself: the squashed spelling is exactly what
// yaml.v3 emits for a field with no yaml tag (the lowercased field name) and
// the readable one is the mapstructure tag. A renamed or added field that
// skips the table would leave that toggle unrepairable, silently.
func TestSquashedJiraFeatureKeys_MatchStruct(t *testing.T) {
	typ := reflect.TypeOf(JiraFeatureToggles{})
	require.Len(t, squashedJiraFeatureKeys, typ.NumField(), "every toggle needs an entry")

	for i := 0; i < typ.NumField(); i++ {
		field := typ.Field(i)
		squashed := strings.ToLower(field.Name)
		long, ok := squashedJiraFeatureKeys[squashed]
		require.True(t, ok, "no entry for %s (squashed spelling %q)", field.Name, squashed)
		assert.Equal(t, field.Tag.Get("mapstructure"), long,
			"%s must map to its mapstructure tag", field.Name)
	}
}

// TestDeleteYAMLPath_AbsentKeyIsNoOp pins the helper's degenerate branches:
// a path whose first segment is missing, and one that runs into a scalar
// where a mapping was expected, must both leave the document alone rather
// than panic or truncate a sibling.
func TestDeleteYAMLPath_AbsentKeyIsNoOp(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	original := "active_workspace: test\njira:\n  enabled: true\n"
	require.NoError(t, os.WriteFile(p, []byte(original), 0o600))

	require.NoError(t, patchConfigYAML(p, nil, []string{
		"nosuchsection.nosuchkey",
		"jira.nosuchkey",
		"jira.enabled.deeper",
	}))

	v := rawConfig(t, p)
	assert.Equal(t, "test", v.GetString("active_workspace"))
	assert.True(t, v.GetBool("jira.enabled"), "a no-op delete must not remove a real key")
}
