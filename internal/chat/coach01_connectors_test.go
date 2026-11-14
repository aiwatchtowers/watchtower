package chat

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// COACH-01 (context actions): the coach's claude_connectors_off writes
// env.ENABLE_CLAUDEAI_MCP_SERVERS = "false" into the owner's user settings.
// The Watchtower chat must not follow it: its child skips user settings
// (--setting-sources project,local) and sets the variable itself from the
// owner's claude.ai switch, so the chat's connectors stay as Settings say.
func TestCOACH01_ConnectorsOffNeverReachesChat(t *testing.T) {
	home := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(home, ".claude"), 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(home, ".claude", "settings.json"),
		[]byte(`{"env":{"ENABLE_CLAUDEAI_MCP_SERVERS":"false"}}`), 0o600))
	t.Setenv("HOME", home)
	// Even a value inherited from the app's own environment loses.
	t.Setenv("ENABLE_CLAUDEAI_MCP_SERVERS", "false")

	for _, mode := range []ClaudeAIMode{{}, {On: true, Connectors: true}, {On: true}} {
		o := claudeAITestOptions(mode)
		args := claudeArgs(o, "/tmp/p", "/tmp/m")
		i := indexOf(args, "--setting-sources")
		require.GreaterOrEqual(t, i, 0, "%+v", mode)
		assert.Equal(t, "project,local", args[i+1], "user settings never load: %+v", mode)

		env := claudeEnv(o)
		if !mode.On {
			assert.Contains(t, args, "--strict-mcp-config", "off, no connector loads at all")
			continue
		}
		want := "0"
		if mode.Connectors {
			want = "1"
		}
		assert.Equal(t, want, envValue(env, "ENABLE_CLAUDEAI_MCP_SERVERS"),
			"the chat sets the variable itself: %+v", mode)
	}
}
