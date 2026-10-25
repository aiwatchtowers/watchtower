package policy

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestPolicy_CurrentCaches30s(t *testing.T) {
	base := time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)
	clock := base
	oldNow := now
	now = func() time.Time { return clock }
	t.Cleanup(func() { now = oldNow })

	reads := 0
	restore := SetReaderForTesting(func() map[string]any {
		reads++
		return map[string]any{KeyMobileSync: "off"}
	})
	t.Cleanup(restore)

	assert.Equal(t, MobileOff, MobileSync())
	clock = base.Add(29 * time.Second)
	assert.Equal(t, MobileOff, MobileSync())
	assert.Equal(t, 1, reads)

	clock = base.Add(31 * time.Second)
	Current()
	assert.Equal(t, 2, reads)

	// A clock stepped back never serves a read from the "future".
	clock = base
	Current()
	assert.Equal(t, 3, reads)
}

func TestPolicy_SetReaderForTestingResetsCache(t *testing.T) {
	restore := SetReaderForTesting(func() map[string]any { return map[string]any{KeyAllowAutomationShell: false} })
	assert.False(t, ShellAllowed())
	inner := SetReaderForTesting(func() map[string]any { return nil })
	assert.True(t, ShellAllowed(), "a new reader is read at once")
	inner()
	assert.False(t, ShellAllowed(), "restore drops the cache too")
	restore()
}

func TestPolicy_PackageHelpers(t *testing.T) {
	restore := SetReaderForTesting(func() map[string]any {
		return map[string]any{
			KeyAllowedSources:          []any{"slack"},
			KeyAllowedQuickConnections: []any{"/usr/local/bin/acme-mcp"},
			KeyAllowedAIProviders:      []any{"claude"},
			KeyAllowClaudeAITools:      false,
			KeyPurgeRevokedData:        true,
		}
	})
	t.Cleanup(restore)
	assert.True(t, SourceAllowed("slack"))
	assert.False(t, SourceAllowed("jira"))
	assert.True(t, ConnectionAllowed("stdio", "", "/usr/local/bin/acme-mcp"))
	assert.False(t, ConnectionAllowed("http", "https://mcp.example.com/", ""))
	assert.True(t, ProviderAllowed("claude"))
	assert.False(t, ProviderAllowed("codex"))
	assert.False(t, ClaudeAIToolsAllowed())
	assert.True(t, ShellAllowed())
	on, set := PurgeRevokedData()
	assert.True(t, on)
	assert.True(t, set)
}
