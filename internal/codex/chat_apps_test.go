package codex

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func authHome(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "auth.json"), []byte(body), 0o600))
	return dir
}

func TestChatGPTLogin(t *testing.T) {
	assert.True(t, ChatGPTLogin(authHome(t, `{"auth_mode":"chatgpt","tokens":{}}`)))
	assert.False(t, ChatGPTLogin(authHome(t, `{"auth_mode":"apikey"}`)))
	assert.False(t, ChatGPTLogin(authHome(t, `not json`)))
	assert.False(t, ChatGPTLogin(t.TempDir()))
}

func TestCodexChatApps_SlackReadOnlyAllowList(t *testing.T) {
	c := &Client{model: "m"}
	assert.Contains(t, c.execArgs(), "features.apps=false")

	c.SetChatApps(SlackReadOnlyOverrides("conn_x", []string{"slack_read_channel", "slack_search_public"}))
	args := c.execArgs()
	assert.NotContains(t, args, "features.apps=false")
	assert.Contains(t, args, "features.plugins=false", "other features stay off")
	for _, want := range []string{
		"apps._default.enabled=false",
		"apps.conn_x.enabled=true",
		"apps.conn_x.default_tools_enabled=false",
		"apps.conn_x.tools.slack_read_channel.enabled=true",
		"apps.conn_x.tools.slack_search_public.enabled=true",
	} {
		assert.True(t, slices.Contains(args, want), want)
	}
	for _, a := range args {
		assert.NotContains(t, a, "slack_send_message")
	}
	assert.Nil(t, SlackReadOnlyOverrides("", []string{"x"}))
}
