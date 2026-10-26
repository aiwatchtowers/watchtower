//go:build darwin && cgo

package policy

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/policy/internal/cftest"
)

func alwaysForced(string, string) bool { return true }

// tempDomain returns an absolute-path application id under t.TempDir():
// CFPreferences then writes <domain>.plist there, never under
// ~/Library/Preferences. Cleanup removes every key the test wrote and
// checks nothing landed in ~/Library/Preferences.
func tempDomain(t *testing.T, keys ...string) string {
	t.Helper()
	domain := filepath.Join(t.TempDir(), "policytest")
	t.Cleanup(func() {
		for _, k := range keys {
			cftest.SetAppValue(domain, k, nil)
		}
		home, err := os.UserHomeDir()
		require.NoError(t, err)
		entries, err := os.ReadDir(filepath.Join(home, "Library", "Preferences"))
		require.NoError(t, err)
		for _, e := range entries {
			assert.False(t, strings.Contains(e.Name(), "policytest"), "test wrote %s into ~/Library/Preferences", e.Name())
		}
	})
	return domain
}

// TestPolicy01_UnforcedValueIgnored pins that a value written the way
// `defaults write` writes it (user layer, not forced) is never policy.
func TestPolicy01_UnforcedValueIgnored(t *testing.T) {
	domain := tempDomain(t, KeyAllowedSources)
	cftest.SetAppValue(domain, KeyAllowedSources, []any{"slack"})
	_, err := os.Stat(domain + ".plist")
	require.NoError(t, err, "the user value lands next to the absolute-path domain")
	require.Equal(t, map[string]any{KeyAllowedSources: []any{"slack"}},
		readForced(domain, []string{KeyAllowedSources}, alwaysForced), "the user value was written")

	assert.Empty(t, readForced(domain, allKeys(), nil))
}

// TestPolicy01_ForcedValuesAreRead is the positive path through a fake
// forced predicate (a real forced value needs an installed profile, a manual
// check): every forced key is read and converted, CFBoolean apart from the
// number 1, and a forced key with no value fails closed as unsupported{}.
func TestPolicy01_ForcedValuesAreRead(t *testing.T) {
	values := map[string]any{
		KeyAllowedSources:            []any{"slack", []any{true, int64(3)}},
		KeyMobileSync:                "workbench_only",
		KeyAllowAutomationShell:      int64(1),
		KeyAllowClaudeAITools:        false,
		KeyPurgeRevokedData:          true,
		KeyRetentionDays:             2.5,
		KeyBulkReadLimits:            map[string]any{"messages": int64(1000), "nested": map[string]any{}},
		KeyAllowedAIProviders:        []byte("data"),
		KeyRequireDatabaseEncryption: "ünïcode",
	}
	keys := make([]string, 0, len(values))
	for k := range values {
		keys = append(keys, k)
	}
	domain := tempDomain(t, keys...)
	for k, v := range values {
		cftest.SetAppValue(domain, k, v)
	}

	forcedSet := map[string]bool{}
	for _, k := range keys {
		forcedSet[k] = true
	}
	forcedSet[KeyAllowedQuickConnections] = true // forced, but no value
	got := readForced(domain, allKeys(), func(_, k string) bool { return forcedSet[k] })

	want := map[string]any{}
	for k, v := range values {
		want[k] = v
	}
	want[KeyAllowedAIProviders] = unsupported{}
	want[KeyAllowedQuickConnections] = unsupported{}
	assert.Equal(t, want, got)

	p := Normalize(got)
	assert.False(t, p.ShellAllowed(), "an integer 1 from a profile is a wrong type")
	assert.Equal(t, []string{}, p.Keys.AllowedAIProviders, "an unsupported CF type fails closed")
	assert.Equal(t, []string{}, p.Keys.AllowedQuickConnections, "a forced key without a value fails closed")
}

// TestPolicy_TestBinaryNeverReadsRealPreferences pins that nothing installs
// the CoreFoundation reader in a test binary: only main calls
// UseSystemReader.
func TestPolicy_TestBinaryNeverReadsRealPreferences(t *testing.T) {
	assert.Empty(t, reader())
	assert.False(t, Current().Managed)
}
