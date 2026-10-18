package config

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLegacyAutomationsOff(t *testing.T) {
	for name, tc := range map[string]struct {
		yaml string
		want bool
	}{
		"explicit false": {"automations:\n  enabled: false\n", true},
		"explicit true":  {"automations:\n  enabled: true\n", false},
		"absent key":     {"digest:\n  enabled: false\n", false},
		"empty file":     {"", false},
	} {
		t.Run(name, func(t *testing.T) {
			got, err := LegacyAutomationsOff(writeTestConfig(t, tc.yaml))
			require.NoError(t, err)
			assert.Equal(t, tc.want, got)
		})
	}

	got, err := LegacyAutomationsOff(filepath.Join(t.TempDir(), "missing.yaml"))
	require.NoError(t, err)
	assert.False(t, got, "a missing file is not off")

	_, err = LegacyAutomationsOff(writeTestConfig(t, "automations: [\n"))
	assert.Error(t, err, "a malformed file is an error, not a silent no")
}

// The key goes with a node edit: comments, sibling keys and casing survive,
// and the block goes too when the key was its only entry.
func TestRemoveLegacyAutomationsKey_KeepsTheRest(t *testing.T) {
	path := writeTestConfig(t, "# owner note\nactive_workspace: Acme\n"+
		"workspaces:\n  Acme:\n    slack_token: x # keep me\n"+
		"automations:\n  enabled: false\n"+
		"digest:\n  enabled: true\n")

	require.NoError(t, RemoveLegacyAutomationsKey(path))

	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	text := string(raw)
	assert.NotContains(t, text, "automations")
	assert.Contains(t, text, "# owner note")
	assert.Contains(t, text, "# keep me")
	assert.Contains(t, text, "Acme:")
	v := rawConfig(t, path)
	assert.True(t, v.GetBool("digest.enabled"))
	off, err := LegacyAutomationsOff(path)
	require.NoError(t, err)
	assert.False(t, off)
}

func TestRemoveLegacyAutomationsKey_KeepsOtherBlockKeys(t *testing.T) {
	path := writeTestConfig(t, "automations:\n  enabled: false\n  daily_budget_tokens: 5000\n")

	require.NoError(t, RemoveLegacyAutomationsKey(path))

	v := rawConfig(t, path)
	assert.False(t, v.IsSet(LegacyAutomationsKey))
	assert.Equal(t, 5000, v.GetInt("automations.daily_budget_tokens"))
}

// No key, no write: the file stays byte-identical.
func TestRemoveLegacyAutomationsKey_AbsentIsNoOp(t *testing.T) {
	const content = "# hand-written\ndigest: {enabled: true}\n"
	path := writeTestConfig(t, content)

	require.NoError(t, RemoveLegacyAutomationsKey(path))

	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, content, string(raw))
	require.NoError(t, RemoveLegacyAutomationsKey(filepath.Join(t.TempDir(), "missing.yaml")))
}

// Viper reads keys case-insensitively, so a capitalised key is detected; the
// removal must find it too, or every start would pause the recipes again.
func TestRemoveLegacyAutomationsKey_CapitalisedKey(t *testing.T) {
	path := writeTestConfig(t, "Automations:\n  Enabled: false\ndigest:\n  enabled: true\n")
	off, err := LegacyAutomationsOff(path)
	require.NoError(t, err)
	require.True(t, off)

	require.NoError(t, RemoveLegacyAutomationsKey(path))
	off, err = LegacyAutomationsOff(path)
	require.NoError(t, err)
	assert.False(t, off, "the capitalised key is gone")
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Contains(t, string(raw), "digest:")
}
