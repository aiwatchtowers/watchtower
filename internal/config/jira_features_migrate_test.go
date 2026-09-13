package config

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
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

// assertSecondJiraCallWritesNothing is the jira counterpart of
// assertSecondCallIsByteIdenticalNoOp, strengthened: once the marker is on
// the file, the migration must not write AT ALL.
//
// Content equality alone cannot see that. A second pass re-encodes the same
// document to the same bytes, so dropping the marker short-circuit entirely
// leaves a content comparison green while the file is silently rewritten on
// every daemon start and every `jira features` call. The inode is what tells
// the two apart: writeFeatureMigrationConfigBytes always lands through a
// temp file plus an atomic rename, so any write at all replaces the inode.
func assertSecondJiraCallWritesNothing(t *testing.T, path string) {
	t.Helper()
	before, err := os.ReadFile(path)
	require.NoError(t, err)
	beforeStat, err := os.Stat(path)
	require.NoError(t, err)

	repaired, err := MigrateJiraFeatureKeys(path)
	require.NoError(t, err)
	assert.False(t, repaired, "a marker-present call must repair nothing")

	after, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, string(before), string(after), "a marker-present call must leave the content alone")

	afterStat, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, fileIdentity(t, beforeStat), fileIdentity(t, afterStat),
		"a marker-present call must not write the file at all — the inode moved, so it did")
	assert.Equal(t, beforeStat.ModTime(), afterStat.ModTime(), "a marker-present call must not write the file at all")
}

// fileIdentity returns the inode of a stat result. An atomic rename always
// changes it, which is what makes it a write detector rather than a content
// comparison.
func fileIdentity(t *testing.T, info os.FileInfo) uint64 {
	t.Helper()
	stat, ok := info.Sys().(*syscall.Stat_t)
	require.True(t, ok, "expected a unix stat result")
	return stat.Ino
}

// TestMigrateJiraFeatureKeys_CarriesEnablesAndDropsArtifactFalses is the
// point of the migration, and the shape of it decides whether the repair
// reaches the owner at all.
//
// The pre-fix writer wrote all eleven keys on every call, so only a `true`
// in that block can be traced to intent; a `false` is the artifact of a
// struct write. Carrying every value would leave a repaired install with
// eleven EXPLICIT values — the common shape being all-false — freezing the
// Jira surface off forever and putting Load's role defaults out of reach.
// So a `true` is carried and a `false` is dropped, leaving its readable key
// absent for the default to decide.
func TestMigrateJiraFeatureKeys_CarriesEnablesAndDropsArtifactFalses(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte(legacyJiraFeaturesConfig), 0o600))

	repaired, err := MigrateJiraFeatureKeys(p)
	require.NoError(t, err)
	assert.True(t, repaired, "a config carrying squashed keys is a repair")

	// The two enables in the fixture; everything else in it is an artifact false.
	carried := map[string]bool{"my_issues_in_briefing": true, "team_workload": true}

	v := rawConfig(t, p)
	for squashed, long := range squashedJiraFeatureKeys {
		assert.False(t, v.IsSet("jira.features."+squashed), "the dead key %q must be gone", squashed)
		if carried[long] {
			assert.True(t, v.IsSet("jira.features."+long), "the enable must land under %q", long)
			assert.True(t, v.GetBool("jira.features."+long), "%q must be carried as true", long)
		} else {
			assert.False(t, v.IsSet("jira.features."+long),
				"%q must be left ABSENT, not written false — the default decides it", long)
		}
	}

	// Read through the product's own reader: the enables stand, and an
	// artifact false takes the role default instead of a sticky false.
	cfg, err := Load(p)
	require.NoError(t, err)
	ic := DefaultJiraFeatures(DefaultJiraFeaturesRole)
	assert.True(t, cfg.Jira.Features.MyIssuesInBriefing, "the owner's enable must survive")
	assert.True(t, cfg.Jira.Features.TeamWorkload, "the owner's enable must survive")
	assert.Equal(t, ic.AwaitingMyInput, cfg.Jira.Features.AwaitingMyInput,
		"an artifact false must fall through to the role default, not freeze off")
	assert.True(t, ic.AwaitingMyInput, "fixture check: awaiting_my_input is ON in the IC baseline")
	assert.False(t, cfg.Jira.Features.BlockerMap, "a flag off in the baseline stays off")

	assert.True(t, v.IsSet(JiraFeaturesMigratedKey), "the marker must be stamped")
	assert.True(t, v.GetBool("jira.enabled"), "unrelated jira keys must survive")
	assert.Equal(t, 15, v.GetInt("jira.sync_interval_mins"), "unrelated jira keys must survive")

	assertSecondJiraCallWritesNothing(t, p)
}

// TestMigrateJiraFeatureKeys_ExplicitSnakeKeyWins pins that the migration
// never overwrites a value the owner — or the repaired writer — set under
// the readable spelling, in either direction. A stale squashed key from
// before the repair must not resurrect an old value on top of a current one.
func TestMigrateJiraFeatureKeys_ExplicitSnakeKeyWins(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	content := "active_workspace: test\n" +
		"jira:\n" +
		"  features:\n" +
		"    team_workload: false\n" +
		"    teamworkload: true\n" +
		"    epic_progress: true\n" +
		"    epicprogress: false\n" +
		"    blockermap: true\n"
	require.NoError(t, os.WriteFile(p, []byte(content), 0o600))

	repaired, err := MigrateJiraFeatureKeys(p)
	require.NoError(t, err)
	assert.True(t, repaired)

	cfg, err := Load(p)
	require.NoError(t, err)
	assert.False(t, cfg.Jira.Features.TeamWorkload, "an explicit readable false must win over a squashed true")
	assert.True(t, cfg.Jira.Features.EpicProgress, "an explicit readable true must survive a squashed false")
	assert.True(t, cfg.Jira.Features.BlockerMap, "a squashed true with no readable counterpart is carried over")

	v := rawConfig(t, p)
	for _, squashed := range []string{"teamworkload", "epicprogress", "blockermap"} {
		assert.False(t, v.IsSet("jira.features."+squashed), "the squashed key %q is removed either way", squashed)
	}
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

	assertSecondJiraCallWritesNothing(t, p)
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
		assert.NotEqual(t, squashed, long,
			"%s spells both keys identically, so the pre-fix writer already wrote the readable key: "+
				"there is nothing to repair, and listing it here would make the migration DELETE "+
				"the owner's value. Such a toggle belongs in neither the table nor this check — "+
				"exclude it from both, and from the field count above", field.Name)
	}
}

// TestPatchConfigYAML_DeleteWinsOverSet pins the set-then-delete order the
// doc comment promises. No caller names the same key in both collections
// today, so swapping the two loops is invisible — and a future caller that
// does would then get a key it asked to delete written back instead.
func TestPatchConfigYAML_DeleteWinsOverSet(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte("active_workspace: test\n"), 0o600))

	require.NoError(t, patchConfigYAML(p,
		map[string]bool{"jira.features.team_workload": true},
		[]string{"jira.features.team_workload"}))

	v := rawConfig(t, p)
	assert.False(t, v.IsSet("jira.features.team_workload"), "a key named by both must end up absent")
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
