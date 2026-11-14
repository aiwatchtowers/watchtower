package codex

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func overrides(t *testing.T, config string, id string, tools ...string) ([]string, error) {
	t.Helper()
	home := t.TempDir()
	if config != "\x00" {
		require.NoError(t, os.WriteFile(filepath.Join(home, "config.toml"), []byte(config), 0o600))
	}
	return ReadOnlyAppOverrides(home, id, tools)
}

func kvs(args []string) []string {
	var out []string
	for i := 1; i < len(args); i += 2 {
		out = append(out, args[i])
	}
	return out
}

func TestReadOnlyAppOverrides(t *testing.T) {
	base := []string{
		"features.apps=true", "apps._default.enabled=false", "apps._default.default_tools_enabled=false",
		"apps.app_a.enabled=true", "apps.app_a.default_tools_enabled=false",
	}
	t.Run("no config", func(t *testing.T) {
		args, err := overrides(t, "\x00", "app_a", "list", "read")
		require.NoError(t, err)
		assert.Equal(t, append(base, "apps.app_a.tools.list.enabled=true", "apps.app_a.tools.read.enabled=true"), kvs(args))
		for i := 0; i < len(args); i += 2 {
			assert.Equal(t, "-c", args[i])
		}
	})
	t.Run("empty config", func(t *testing.T) {
		args, err := overrides(t, "", "app_a", "list")
		require.NoError(t, err)
		assert.Equal(t, append(base, "apps.app_a.tools.list.enabled=true"), kvs(args))
	})
	t.Run("config re-enabling writes and other apps", func(t *testing.T) {
		args, err := overrides(t, `
model = "x"
[apps.app_a]
enabled = true
[apps.app_a.tools.send]
enabled = true
[apps.app_a.tools.list]
enabled = true
[apps.app_b]
enabled = true
[apps._default]
enabled = true
`, "app_a", "list")
		require.NoError(t, err)
		assert.Equal(t, append(base,
			"apps.app_b.enabled=false",
			"apps.app_a.tools.send.enabled=false",
			"apps.app_a.tools.list.enabled=true"), kvs(args))
	})
	t.Run("invalid config fails closed", func(t *testing.T) {
		_, err := overrides(t, "[apps\nbroken", "app_a", "list")
		assert.Error(t, err)
	})
	t.Run("unreadable config fails closed", func(t *testing.T) {
		home := t.TempDir()
		require.NoError(t, os.Mkdir(filepath.Join(home, "config.toml"), 0o700)) // a directory cannot be read
		_, err := ReadOnlyAppOverrides(home, "app_a", []string{"list"})
		assert.Error(t, err)
	})
	t.Run("empty connector id", func(t *testing.T) {
		_, err := overrides(t, "\x00", "", "list")
		assert.Error(t, err)
	})
}

func TestReadOnlyAppOverrides_RefusesUnsafeKeys(t *testing.T) {
	_, err := overrides(t, "[apps.\"a.b\"]\nenabled = true\n", "app_a", "list")
	assert.Error(t, err, "a quoted config key with a dot")
	_, err = overrides(t, "[apps.app_a.tools.\"x y\"]\nenabled = true\n", "app_a", "list")
	assert.Error(t, err, "a quoted tool key")
	_, err = overrides(t, "\x00", "app.a", "list")
	assert.Error(t, err, "the connector id")
	_, err = overrides(t, "\x00", "app_a", "li=st")
	assert.Error(t, err, "a listed tool")
	_, err = WarmUpAppOverrides(writeConfig(t, "[apps.\"a.b\"]\nenabled = true\n"))
	assert.Error(t, err)
}

func writeConfig(t *testing.T, config string) string {
	t.Helper()
	home := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(home, "config.toml"), []byte(config), 0o600))
	return home
}

func TestWarmUpAppOverrides(t *testing.T) {
	args, err := WarmUpAppOverrides(t.TempDir())
	require.NoError(t, err)
	assert.Equal(t, []string{"features.apps=true", "apps._default.default_tools_enabled=false"}, kvs(args))

	args, err = WarmUpAppOverrides(writeConfig(t, `
[apps.app_a]
default_tools_enabled = true
[apps.app_a.tools.send]
enabled = true
[apps.app_b]
enabled = true
[apps._default]
enabled = true
`))
	require.NoError(t, err)
	assert.Equal(t, []string{
		"features.apps=true", "apps._default.default_tools_enabled=false",
		"apps.app_a.default_tools_enabled=false", "apps.app_a.tools.send.enabled=false",
		"apps.app_b.default_tools_enabled=false",
	}, kvs(args))
	assert.NotContains(t, kvs(args), "apps._default.enabled=false")

	_, err = WarmUpAppOverrides(writeConfig(t, "[apps\nbroken"))
	assert.Error(t, err)
}

func TestNoMCPServerArgs(t *testing.T) {
	home := writeConfig(t, "[mcp_servers.mine]\ncommand = \"x\"\n")
	args, err := NoMCPServerArgs(home, t.TempDir())
	require.NoError(t, err)
	require.Len(t, args, 2)
	assert.Equal(t, "-c", args[0])
	assert.Contains(t, args[1], `"mine"={enabled=false}`)
	_, err = NoMCPServerArgs(writeConfig(t, "[mcp_servers\nbroken"), t.TempDir())
	assert.Error(t, err)
}
