// Package slackmanifest is the single source of the Watchtower Slack app's
// manifest: the user scopes the OAuth login requests (auth.UserScopes) and
// the app's descriptions, which disclose why each scope is needed and where
// message text goes (spec 2026-11-17-slack-policy-hygiene §4, §6).
package slackmanifest

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"unicode/utf8"
)

//go:embed slack-app-manifest.json
var manifestJSON []byte

// MaxLongDescription is Slack's limit on display_information.long_description,
// in characters, the connect block included.
const MaxLongDescription = 4000

// ShortDescription is display_information.description.
const ShortDescription = "Your Slack on your Mac, with the AI provider you choose"

// PrivacyURL is the privacy policy the long description links to.
const PrivacyURL = "https://aiwatchtowers.com/privacy/"

// scopeParagraph says why each scope is asked for (spec §4, verbatim).
const scopeParagraph = "Why Watchtower asks for each permission: read history and the channel list of public and private channels, DMs and group DMs, and search, to keep a local copy on your Mac; open a DM and post a message, only when you press Approve; read people's names and emails, to match them with your calendar, Jira and Linear; read files, to describe images you were sent; read your reactions, for reaction commands; read the workspace's name and custom emoji, to show them."

// aiParagraph discloses where message text goes (spec §6 item 1, verbatim).
const aiParagraph = "Watchtower keeps its copy on each person's Mac and has no server. To write summaries and answer questions it sends message text to the AI provider each person chooses — Anthropic (Claude) or OpenAI (Codex) under that person's own account, or a local model (Ollama) — and nowhere else. AI output can be wrong. Privacy: " + PrivacyURL

type manifestScopes struct {
	OAuthConfig struct {
		Scopes struct {
			User []string `json:"user"`
		} `json:"scopes"`
	} `json:"oauth_config"`
}

// userScopes is parsed once; a malformed embedded file is a build defect.
var userScopes = func() []string {
	var m manifestScopes
	if err := json.Unmarshal(manifestJSON, &m); err != nil {
		panic(fmt.Sprintf("slackmanifest: embedded manifest: %v", err))
	}
	return m.OAuthConfig.Scopes.User
}()

// UserScopes returns the manifest's user scopes, in manifest order.
func UserScopes() []string {
	return append([]string(nil), userScopes...)
}

// Description is the long description: connectBlock (omitted when empty),
// the scope paragraph and the AI paragraph, separated by blank lines. It
// errors when the result is over Slack's MaxLongDescription characters.
func Description(connectBlock string) (string, error) {
	d := scopeParagraph + "\n\n" + aiParagraph
	if connectBlock != "" {
		d = connectBlock + "\n\n" + d
	}
	if n := utf8.RuneCountInString(d); n > MaxLongDescription {
		return "", fmt.Errorf("slack app long description is %d characters, over Slack's %d", n, MaxLongDescription)
	}
	return d, nil
}

// Manifest returns the embedded manifest with display_information's
// description and long_description (Description(connectBlock)) filled.
func Manifest(connectBlock string) ([]byte, error) {
	long, err := Description(connectBlock)
	if err != nil {
		return nil, err
	}
	var m map[string]any
	if err := json.Unmarshal(manifestJSON, &m); err != nil {
		return nil, fmt.Errorf("parsing the embedded slack app manifest: %w", err)
	}
	info, ok := m["display_information"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("embedded slack app manifest has no display_information")
	}
	info["description"] = ShortDescription
	info["long_description"] = long
	return json.MarshalIndent(m, "", "  ")
}
