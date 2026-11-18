package slackapp

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// The company wizard reuses an app the person picked (a settings URL or a
// found app) through Adopt: never a create.
func TestReuse_NoCreateWhenAppChosen(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "", "ok")
	h.api.manifests["A0CORP"] = theirManifest()
	appID, ok := ParseSlackAppSettingsURL("https://api.slack.com/apps/A0CORP/oauth")
	require.True(t, ok)
	res, err := h.r.Adopt(context.Background(), cfgToken, "", appID, appID, true)
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind)
	assert.Equal(t, "A0CORP", res.AppID)
	assert.Zero(t, h.api.creates, "a chosen app is updated, never created again")
	assert.Equal(t, 1, h.api.updates)
}

func TestReuse_WrongWorkspaceRefused(t *testing.T) {
	for _, tc := range []struct {
		name string
		seed func(t *testing.T, h *harness)
	}{
		{"known by an account of another workspace", func(t *testing.T, h *harness) {
			h.account(t, "T0OTHER", "7777.8888", "A0ELSE", "ok")
		}},
		{"known by another workspace's setup record", func(t *testing.T, h *harness) {
			require.NoError(t, h.db.InsertSlackAppSetup(db.SlackAppSetup{TeamID: "T0OTHER", TeamName: "Other",
				AppID: "A0ELSE", ClientID: "7777.8888", LinkWritten: true}))
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t)
			h.account(t, "T0ACME", "5555.6666", "", "ok")
			h.api.manifests["A0ELSE"] = theirManifest()
			tc.seed(t, h)
			res, err := h.r.Adopt(context.Background(), cfgToken, "", "A0ELSE", "A0ELSE", true)
			require.NoError(t, err)
			assert.Equal(t, KindWrongWorkspace, res.Kind)
			assert.Equal(t, "T0ACME", res.TeamID, "the token's workspace")
			assert.Zero(t, h.api.exports, "nothing read")
			assert.Zero(t, h.api.updates, "nothing changed")
			assert.Zero(t, h.api.creates)
		})
	}

	// A removed account of another workspace no longer claims the app.
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "", "ok")
	h.account(t, "T0OTHER", "7777.8888", "A0ELSE", "removed")
	h.api.manifests["A0ELSE"] = theirManifest()
	res, err := h.r.Adopt(context.Background(), cfgToken, "", "A0ELSE", "A0ELSE", true)
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind)
}

func TestParseSlackAppSettingsURL(t *testing.T) {
	for in, want := range map[string]string{
		"https://api.slack.com/apps/A0123ABCD":                     "A0123ABCD",
		"  https://api.slack.com/apps/A0123ABCD/  ":                "A0123ABCD",
		"https://api.slack.com/apps/A0123ABCD/general":             "A0123ABCD",
		"https://api.slack.com/apps/A0123ABCD/oauth?success=1":     "A0123ABCD",
		"https://api.slack.com/apps/A0123ABCD#basic":               "A0123ABCD",
		"https://api.slack.com/apps/A0123ABCD/event-subscriptions": "A0123ABCD",
	} {
		got, ok := ParseSlackAppSettingsURL(in)
		assert.True(t, ok, in)
		assert.Equal(t, want, got, in)
	}
	for _, in := range []string{
		"", "A0123ABCD", "http://api.slack.com/apps/A0123ABCD",
		"https://api.slack.com.evil.example/apps/A0123ABCD", "https://evil.example/https://api.slack.com/apps/A0123ABCD",
		"https://api.slack.com/apps/a0123abcd", "https://api.slack.com/apps/B0123ABCD", "https://api.slack.com/apps/",
		"https://api.slack.com/apps/A0123ABCD-x", "https://app.slack.com/apps/A0123ABCD",
	} {
		_, ok := ParseSlackAppSettingsURL(in)
		assert.False(t, ok, in)
	}
}

func TestLinkAbout_WritesCompanyText(t *testing.T) {
	h := newHarness(t)
	_, err := h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	about := "Watchtower for Acme — connect: http://127.0.0.1:18551/company/connect?b=eyJ2IjoxfQ"
	res, err := h.r.LinkAbout(context.Background(), cfgToken, "T0ACME", about)
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind)
	long := h.api.lastUpdate.LongDescription()
	assert.Contains(t, long, about)
	assert.NotContains(t, long, "/slack/connect", "the company text replaces the Slack-only block")
	assert.Contains(t, long, "Why Watchtower asks for each permission", "the disclosures stay")
	assert.Equal(t, about, ConnectBlock(Link{About: about}), "About wins even without a client id")
}
