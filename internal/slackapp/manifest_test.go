package slackapp

import (
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/slackconnect"
	"watchtower/internal/slackmanifest"
)

var update = flag.Bool("update", false, "rewrite testdata/manifest.golden.json")

var acme = Link{TeamID: "T0ACME", TeamName: "Acme", ClientID: "1111.2222"}

func userScopes(t *testing.T, m Manifest) []string {
	t.Helper()
	oauth, ok := m["oauth_config"].(map[string]any)
	require.True(t, ok)
	scopes, ok := oauth["scopes"].(map[string]any)
	require.True(t, ok)
	return toStrings(scopes["user"])
}

func redirects(t *testing.T, m Manifest) []string {
	t.Helper()
	oauth, ok := m["oauth_config"].(map[string]any)
	require.True(t, ok)
	return toStrings(oauth["redirect_urls"])
}

func TestManifest_Golden(t *testing.T) {
	m, err := BuildManifest(acme)
	require.NoError(t, err)
	got, err := json.MarshalIndent(m, "", "  ")
	require.NoError(t, err)
	got = append(got, '\n')
	path := filepath.Join("testdata", "manifest.golden.json")
	if *update {
		require.NoError(t, os.MkdirAll("testdata", 0o755))
		require.NoError(t, os.WriteFile(path, got, 0o644))
	}
	want, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, string(want), string(got))
}

func TestManifest_Scopes(t *testing.T) {
	m, err := BuildManifest(acme)
	require.NoError(t, err)
	got := userScopes(t, m)
	assert.Equal(t, slackmanifest.UserScopes(), got)
	assert.Contains(t, got, "im:write")
	assert.Contains(t, got, "chat:write")
}

func TestManifest_NoBotNoSecretFields(t *testing.T) {
	m, err := BuildManifest(acme)
	require.NoError(t, err)
	raw, err := json.Marshal(m)
	require.NoError(t, err)
	s := string(raw)
	for _, banned := range []string{"bot_user", `"bot"`, "event_subscriptions", "client_secret", "signing_secret", "verification_token", "credentials"} {
		assert.NotContains(t, s, banned)
	}
	_, hasFeatures := m["features"]
	assert.False(t, hasFeatures, "no features (no bot user, no slash commands)")
	assert.Equal(t, []string{slackconnect.RedirectURL}, redirects(t, m))
	oauth := m["oauth_config"].(map[string]any)
	assert.Equal(t, true, oauth["pkce_enabled"], "Slack refuses a secret-less exchange without PKCE")
	assert.Equal(t, true, m["settings"].(map[string]any)["token_rotation_enabled"])
	info := m["display_information"].(map[string]any)
	assert.Equal(t, "Watchtower", info["name"])
	assert.Equal(t, slackmanifest.ShortDescription, info["description"])
}

func TestManifest_CreateHasNoLinkLines(t *testing.T) {
	m, err := BuildManifest(Link{TeamID: "T0ACME", TeamName: "Acme"})
	require.NoError(t, err)
	want, err := slackmanifest.Description("")
	require.NoError(t, err)
	assert.Equal(t, want, m.LongDescription())
	assert.NotContains(t, m.LongDescription(), "/slack/connect")
}

func TestManifest_ConnectBlock(t *testing.T) {
	want := "Watchtower for Acme. Connect: http://127.0.0.1:18551/slack/connect?team=T0ACME&client=1111.2222\n" +
		"Connect code: T0ACME:1111.2222 — paste it in Watchtower → Connections → Slack if the link does not open.\n" +
		"Open Watchtower first. No Watchtower yet? Download it from " + ReleasePage + "."
	assert.Equal(t, want, ConnectBlock(acme))
	assert.Equal(t, "", ConnectBlock(Link{TeamID: "T0ACME"}))
	got, err := slackconnect.ParseConnectInput(acme.ConnectLink())
	require.NoError(t, err)
	assert.Equal(t, slackconnect.Target{TeamID: "T0ACME", ClientID: "1111.2222"}, got)
	got, err = slackconnect.ParseConnectInput(acme.ConnectCode())
	require.NoError(t, err)
	assert.Equal(t, "1111.2222", got.ClientID)
}

// theirManifest is a company's existing app: its own redirect, a bot, a
// scope we do not use, rotation off, PKCE off, a credentials object.
func theirManifest() Manifest {
	var m Manifest
	if err := json.Unmarshal([]byte(`{
  "display_information": {"name": "Acme Watchtower", "description": "theirs", "long_description": "old text"},
  "features": {"bot_user": {"display_name": "acmebot", "always_online": false}},
  "oauth_config": {
    "redirect_urls": ["https://127.0.0.1:18491/callback"],
    "scopes": {"user": ["channels:history", "admin"], "bot": ["chat:write"]}
  },
  "settings": {"token_rotation_enabled": false, "org_deploy_enabled": false},
  "credentials": {"client_secret": "their-secret-value"}
}`), &m); err != nil {
		panic(err)
	}
	return m
}

func TestAdopt_MergeKeepsTheirFields(t *testing.T) {
	theirs := theirManifest()
	m, err := MergeManifest(theirs, acme)
	require.NoError(t, err)

	assert.Equal(t, []string{"https://127.0.0.1:18491/callback", slackconnect.RedirectURL}, redirects(t, m))
	scopes := userScopes(t, m)
	assert.Equal(t, []string{"channels:history", "admin"}, scopes[:2], "their scopes first, kept")
	for _, s := range slackmanifest.UserScopes() {
		assert.Contains(t, scopes, s)
	}
	assert.Len(t, scopes, len(slackmanifest.UserScopes())+1, "channels:history is not added twice")
	oauth := m["oauth_config"].(map[string]any)
	assert.Equal(t, []any{"chat:write"}, oauth["scopes"].(map[string]any)["bot"])
	assert.Equal(t, true, oauth["pkce_enabled"], "the About link's secret-less exchange needs PKCE (Task 16)")
	assert.Equal(t, false, m["settings"].(map[string]any)["token_rotation_enabled"], "rotation is never touched")
	assert.Equal(t, "acmebot", m["features"].(map[string]any)["bot_user"].(map[string]any)["display_name"])
	info := m["display_information"].(map[string]any)
	assert.Equal(t, "Acme Watchtower", info["name"])
	assert.Equal(t, "theirs", info["description"])
	assert.True(t, strings.HasPrefix(m.LongDescription(), ConnectBlock(acme)))
	_, creds := m["credentials"]
	assert.False(t, creds)
	assert.Equal(t, "old text", theirs.LongDescription(), "the input is not changed")
}

func TestManifest_WithLongDescriptionOnly(t *testing.T) {
	theirs := theirManifest()
	m, err := WithLongDescription(theirs, acme)
	require.NoError(t, err)
	assert.Equal(t, []string{"https://127.0.0.1:18491/callback"}, redirects(t, m))
	assert.Equal(t, []string{"channels:history", "admin"}, userScopes(t, m))
	assert.Contains(t, m.LongDescription(), acme.ConnectLink())
}
