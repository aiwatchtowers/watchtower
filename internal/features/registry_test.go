package features

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
)

var kebabCaseID = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// defaultConfig loads config.Config with every value at its viper default —
// no config.yaml on disk at all, the TestLoad_MissingFile precedent.
func defaultConfig(t *testing.T) *config.Config {
	t.Helper()
	cfg, err := config.Load(filepath.Join(t.TempDir(), "absent.yaml"))
	require.NoError(t, err)
	return cfg
}

// loadConfig writes yaml to a temp config file and loads it, so a test can
// override one or two keys while every other key still gets its real default.
func loadConfig(t *testing.T, yaml string) *config.Config {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(path, []byte(yaml), 0o600))
	cfg, err := config.Load(path)
	require.NoError(t, err)
	return cfg
}

func idSet(fs []Feature) map[string]bool {
	out := make(map[string]bool, len(fs))
	for _, f := range fs {
		out[f.ID] = true
	}
	return out
}

func TestRegistry_Valid(t *testing.T) {
	all := All()
	require.NotEmpty(t, all)

	seen := make(map[string]bool, len(all))
	for _, f := range all {
		assert.False(t, seen[f.ID], "duplicate id %q", f.ID)
		seen[f.ID] = true

		assert.True(t, kebabCaseID.MatchString(f.ID), "id %q is not kebab-case", f.ID)
		assert.NotEmpty(t, f.Title, "feature %q has no Title", f.ID)
		assert.NotEmpty(t, f.Description, "feature %q has no Description", f.ID)

		// Selling attributes (onboarding splash + Desktop Feature Manager
		// cards): every entry, core included, needs real copy — core
		// features are sold too, just without a toggle.
		assert.NotEmpty(t, f.Tagline, "feature %q has no Tagline", f.ID)
		assert.NotEmpty(t, f.Icon, "feature %q has no Icon", f.ID)
		assert.GreaterOrEqual(t, len(f.Benefits), 2, "feature %q has fewer than 2 Benefits", f.ID)
		assert.LessOrEqual(t, len(f.Benefits), 3, "feature %q has more than 3 Benefits", f.ID)
		for i, b := range f.Benefits {
			assert.NotEmpty(t, b, "feature %q Benefits[%d] is empty", f.ID, i)
		}

		if f.Core {
			// Core entries have no Enabled/ConfigKey requirement — some carry
			// a real ConfigKey + Enabled anyway (e.g. "feed"), some don't.
			continue
		}
		assert.NotEmpty(t, f.ConfigKey, "non-core feature %q has no ConfigKey", f.ID)
		assert.NotNil(t, f.Enabled, "non-core feature %q has a nil Enabled func", f.ID)
	}

	for _, f := range all {
		for _, dep := range f.FeedsInto {
			_, ok := ByID(dep)
			assert.True(t, ok, "feature %q FeedsInto unknown id %q", f.ID, dep)
		}
		if f.Parent != "" {
			_, ok := ByID(f.Parent)
			assert.True(t, ok, "feature %q Parent unknown id %q", f.ID, f.Parent)
		}
	}
}

func TestRegistry_EnabledReadsConfig(t *testing.T) {
	inboxOff := loadConfig(t, "inbox:\n  enabled: false\n")
	f, ok := ByID("secretary-inbox")
	require.True(t, ok)
	require.NotNil(t, f.Enabled)
	assert.False(t, f.Enabled(inboxOff))

	defaults := defaultConfig(t)
	wantEnabled := map[string]bool{
		"feed":            true,
		"secretary-inbox": true,
		"slack-digests":   true,
		"stream-digests":  true,
		"tracks":          true,
		"people-cards":    true,
		"ideas":           true,
		"memory":          false, // spec default: off until the feature settles
		"briefing":        true,
		"day-plan":        true,
		"next-step":       true,
	}
	for id, want := range wantEnabled {
		feat, ok := ByID(id)
		require.True(t, ok, "missing feature %q", id)
		require.NotNil(t, feat.Enabled, "feature %q has a nil Enabled func", id)
		assert.Equal(t, want, feat.Enabled(defaults), "feature %q against defaults", id)
	}
}

func TestRegistry_DependentsTransitive(t *testing.T) {
	defaults := defaultConfig(t)
	deps := idSet(Dependents("slack-digests", defaults))

	for _, want := range []string{"secretary-inbox", "tracks", "people-cards", "ideas", "briefing"} {
		assert.True(t, deps[want], "slack-digests dependents should include %q", want)
	}
	assert.False(t, deps["memory"], "memory defaults off; it must not appear as a dependent")
	assert.False(t, deps["day-plan"],
		"day-plan is only reachable through memory, which is off by default; "+
			"a disabled intermediate must not propagate further")

	memoryOn := loadConfig(t, "memory:\n  enabled: true\n")
	depsWithMemory := idSet(Dependents("slack-digests", memoryOn))
	assert.True(t, depsWithMemory["memory"],
		"memory should appear transitively via secretary-inbox once memory.enabled is true")
	assert.True(t, depsWithMemory["day-plan"],
		"day-plan should appear transitively via memory once memory.enabled is true")

	assert.Empty(t, Dependents("briefing", defaults), "briefing feeds nothing else")
}
