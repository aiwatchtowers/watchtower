package slackmanifest_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/auth"
	"watchtower/internal/slackmanifest"
)

// wantScopes is the Full app's user scope list (spec §4, plan Global Constraints).
var wantScopes = []string{
	"channels:history", "groups:history", "im:history", "mpim:history",
	"channels:read", "groups:read", "im:read", "mpim:read",
	"im:write", "search:read", "users:read", "users:read.email",
	"files:read", "reactions:read", "team:read", "chat:write", "emoji:read",
}

func TestSlackManifest_ScopesAreTheRequestedOnes(t *testing.T) {
	got := slackmanifest.UserScopes()
	assert.Len(t, got, 17)
	assert.ElementsMatch(t, wantScopes, got)
	assert.Equal(t, got, auth.UserScopes, "auth requests exactly the manifest's scopes")
}

func TestSlackManifest_DescriptionFits(t *testing.T) {
	d, err := slackmanifest.Description(strings.Repeat("x", 600))
	require.NoError(t, err)
	assert.LessOrEqual(t, utf8.RuneCountInString(d), slackmanifest.MaxLongDescription)
	assert.Equal(t, 4000, slackmanifest.MaxLongDescription)

	_, err = slackmanifest.Description(strings.Repeat("x", 4000))
	assert.Error(t, err)
}

func TestSlackManifest_DescriptionDiscloses(t *testing.T) {
	d, err := slackmanifest.Description("Connect: https://example.com/connect")
	require.NoError(t, err)
	for _, s := range []string{
		"Connect: https://example.com/connect",
		"Why Watchtower asks for each permission:",
		"Anthropic (Claude)", "OpenAI (Codex)", "Ollama",
		"AI output can be wrong.", "https://aiwatchtowers.com/privacy/",
	} {
		assert.Contains(t, d, s)
	}
	assert.NotContains(t, d, "All data stays on your machine")
	assert.True(t, strings.HasPrefix(d, "Connect: https://example.com/connect"), "the connect block leads")
}

func TestSlackManifest_ManifestFillsDescriptions(t *testing.T) {
	raw, err := slackmanifest.Manifest("Connect here")
	require.NoError(t, err)
	var m struct {
		DisplayInformation struct {
			Description     string `json:"description"`
			LongDescription string `json:"long_description"`
		} `json:"display_information"`
		OAuthConfig struct {
			Scopes struct {
				User []string `json:"user"`
				Bot  []string `json:"bot"`
			} `json:"scopes"`
		} `json:"oauth_config"`
		Features map[string]any `json:"features"`
	}
	require.NoError(t, json.Unmarshal(raw, &m))
	assert.Equal(t, slackmanifest.ShortDescription, m.DisplayInformation.Description)
	assert.Equal(t, "Your Slack on your Mac, with the AI provider you choose", slackmanifest.ShortDescription)
	want, err := slackmanifest.Description("Connect here")
	require.NoError(t, err)
	assert.Equal(t, want, m.DisplayInformation.LongDescription)
	assert.Equal(t, slackmanifest.UserScopes(), m.OAuthConfig.Scopes.User)
	assert.Empty(t, m.OAuthConfig.Scopes.Bot, "no bot scopes")
	assert.NotContains(t, m.Features, "bot_user", "no bot user")

	_, err = slackmanifest.Manifest(strings.Repeat("x", 4000))
	assert.Error(t, err)
}

// repoRoot walks up from the package directory (the working directory under
// go test) to the go.mod; runtime.Caller would break under -trimpath.
func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	require.NoError(t, err)
	root := dir
	for {
		if _, statErr := os.Stat(filepath.Join(root, "go.mod")); statErr == nil {
			return root
		}
		parent := filepath.Dir(root)
		if parent == root {
			t.Fatalf("resolved repo root %q does not contain go.mod", dir)
		}
		root = parent
	}
}

func TestSlackManifest_NoRootCopy(t *testing.T) {
	root := repoRoot(t)
	_, err := os.Stat(filepath.Join(root, "go.mod"))
	require.NoError(t, err, "repo root resolved")
	_, err = os.Stat(filepath.Join(root, "slack-app-manifest.json"))
	assert.True(t, os.IsNotExist(err), "the manifest lives only in internal/slackmanifest")
}

// The committed file is a valid paste-in manifest on its own (a corp admin
// updates the app from it): its descriptions are the builder's with no
// connect block.
func TestSlackManifest_FileCarriesTheDescriptions(t *testing.T) {
	dir, err := os.Getwd()
	require.NoError(t, err)
	raw, err := os.ReadFile(filepath.Join(dir, "slack-app-manifest.json"))
	require.NoError(t, err)
	var m struct {
		DisplayInformation struct {
			Description     string `json:"description"`
			LongDescription string `json:"long_description"`
		} `json:"display_information"`
	}
	require.NoError(t, json.Unmarshal(raw, &m))
	want, err := slackmanifest.Description("")
	require.NoError(t, err)
	assert.Equal(t, want, m.DisplayInformation.LongDescription)
	assert.Equal(t, slackmanifest.ShortDescription, m.DisplayInformation.Description)
}
