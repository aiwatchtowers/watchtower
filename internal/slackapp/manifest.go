// Package slackapp sets up a company's own Watchtower app in its Slack
// workspace from a configuration token: it builds our manifest (or merges it
// into an app the company already has), creates or updates the app through
// Slack's apps.manifest.* methods, writes the connect link to the app's About
// page and keeps a resumable setup record (slack_app_setups) so a run cut off
// after the create never creates a second app. The configuration token and
// the app's client secret are never stored (SLACKFULL-02).
package slackapp

import (
	"encoding/json"
	"fmt"
	"net/url"
	"slices"

	"watchtower/internal/slackconnect"
	"watchtower/internal/slackmanifest"
)

// Manifest is a Slack app manifest as a JSON object. It is a map, not a
// struct, so a manifest read from an existing app keeps every field we do not
// know about when it is written back (A20).
type Manifest map[string]any

// ReleasePage is where the About page sends a colleague without Watchtower.
const ReleasePage = "https://github.com/aiwatchtowers/watchtower/releases/latest"

// Link names what the About page's connect block points at: the workspace and
// the app's client id. An empty ClientID (the create call, before Slack has
// issued one) means no connect block.
type Link struct {
	TeamID   string
	TeamName string
	ClientID string
}

// ConnectLink is the connect link of screens §4.1.
func (l Link) ConnectLink() string {
	return fmt.Sprintf("http://127.0.0.1:%d/slack/connect?team=%s&client=%s",
		slackconnect.Port, url.QueryEscape(l.TeamID), url.QueryEscape(l.ClientID))
}

// ConnectCode is the connect code of screens §4.1.
func (l Link) ConnectCode() string { return l.TeamID + ":" + l.ClientID }

// ConnectBlock is the text the About page starts with (screens §4.1); "" for
// a Link without a client id.
func ConnectBlock(l Link) string {
	if l.ClientID == "" {
		return ""
	}
	workspace := l.TeamName
	if workspace == "" {
		workspace = l.TeamID
	}
	return "Watchtower for " + workspace + ". Connect: " + l.ConnectLink() + "\n" +
		"Connect code: " + l.ConnectCode() + " — paste it in Watchtower → Connections → Slack if the link does not open.\n" +
		"Open Watchtower first. No Watchtower yet? Download it from " + ReleasePage + "."
}

// BuildManifest is our manifest for a new app: slackmanifest's name,
// descriptions and user scopes (A11), the About text with l's connect block,
// one redirect URL (the loopback listener), token rotation on and PKCE on
// (Slack refuses a secret-less code exchange without pkce_enabled), no bot
// user, no features, no event subscriptions.
func BuildManifest(l Link) (Manifest, error) {
	raw, err := slackmanifest.Manifest(ConnectBlock(l))
	if err != nil {
		return nil, err
	}
	var m Manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("parsing the slack app manifest: %w", err)
	}
	oauth := m.object("oauth_config")
	oauth["redirect_urls"] = []any{slackconnect.RedirectURL}
	oauth["pkce_enabled"] = true
	oauth.object("scopes")["user"] = toAny(slackmanifest.UserScopes())
	m.object("settings")["token_rotation_enabled"] = true
	return m, nil
}

// MergeManifest brings a company's existing app in line with ours without
// replacing it (A20): it adds our redirect URL and any missing user scopes,
// turns PKCE on, writes long_description (with l's connect block) and keeps
// every other field — their redirect URLs, bot user, scopes we do not use,
// names and settings. It never touches settings.token_rotation_enabled (Slack
// refuses turning rotation off once on: cannot_disable_once_enabled).
//
// PKCE is always turned on (plan B Task 16): the connect link written to the
// About page exchanges its code without a client secret, which Slack refuses
// with bad_client_secret unless oauth_config.pkce_enabled is set, so an
// adopted app without it would publish a link that cannot work. Turning it
// on is one-way and makes every refresh token the app issues expire after 30
// days; PKCE arguments stay optional for the app's existing web-URL OAuth
// flows (https://docs.slack.dev/authentication/using-pkce,
// https://docs.slack.dev/changelog/2026/03/30/pkce). Adopt needs the
// owner's opt-in for it (KindNeedsPKCEConsent); the adopt sheet says so
// before Update the app. A manifest that carries a credentials object loses
// it: secrets are never sent back or kept.
func MergeManifest(theirs Manifest, l Link) (Manifest, error) {
	m, err := WithLongDescription(theirs, l)
	if err != nil {
		return nil, err
	}
	oauth := m.object("oauth_config")
	redirects := toStrings(oauth["redirect_urls"])
	if !slices.Contains(redirects, slackconnect.RedirectURL) {
		redirects = append(redirects, slackconnect.RedirectURL)
	}
	oauth["redirect_urls"] = toAny(redirects)
	scopes := oauth.object("scopes")
	user := toStrings(scopes["user"])
	for _, s := range slackmanifest.UserScopes() {
		if !slices.Contains(user, s) {
			user = append(user, s)
		}
	}
	scopes["user"] = toAny(user)
	oauth["pkce_enabled"] = true
	return m, nil
}

// WithLongDescription is theirs with only display_information.long_description
// replaced by our About text for l (the `slack app link` merge); a copy, so
// theirs is never changed.
func WithLongDescription(theirs Manifest, l Link) (Manifest, error) {
	long, err := slackmanifest.Description(ConnectBlock(l))
	if err != nil {
		return nil, err
	}
	m, err := clone(theirs)
	if err != nil {
		return nil, err
	}
	m.object("display_information")["long_description"] = long
	return m, nil
}

// PKCEEnabled reports whether the manifest has oauth_config.pkce_enabled on.
func (m Manifest) PKCEEnabled() bool {
	oauth, _ := m["oauth_config"].(map[string]any)
	on, _ := oauth["pkce_enabled"].(bool)
	return on
}

// LongDescription is the manifest's About text, "" when it has none.
func (m Manifest) LongDescription() string {
	info, _ := m["display_information"].(map[string]any)
	s, _ := info["long_description"].(string)
	return s
}

// object returns m[key] as an object, creating (or replacing a non-object
// value with) an empty one.
func (m Manifest) object(key string) Manifest {
	if o, ok := m[key].(map[string]any); ok {
		return o
	}
	o := map[string]any{}
	m[key] = o
	return o
}

// clone deep-copies m through JSON and drops a top-level credentials object.
func clone(m Manifest) (Manifest, error) {
	raw, err := json.Marshal(m)
	if err != nil {
		return nil, fmt.Errorf("copying the slack app manifest: %w", err)
	}
	out := Manifest{}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("copying the slack app manifest: %w", err)
	}
	delete(out, "credentials")
	return out, nil
}

func toStrings(v any) []string {
	list, _ := v.([]any)
	out := make([]string, 0, len(list))
	for _, x := range list {
		if s, ok := x.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func toAny(s []string) []any {
	out := make([]any, len(s))
	for i, x := range s {
		out[i] = x
	}
	return out
}
