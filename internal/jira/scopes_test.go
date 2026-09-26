package jira

import (
	"net/url"
	"sort"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestHasConfluenceScopes(t *testing.T) {
	assert.False(t, HasConfluenceScopes(&OAuthToken{Scope: JiraScopes}))
	assert.True(t, HasConfluenceScopes(&OAuthToken{Scope: JiraScopes + " " + ConfluenceScopes}))
	// order-insensitive, extra scopes fine
	fields := strings.Fields(ConfluenceScopes)
	sort.Sort(sort.Reverse(sort.StringSlice(fields)))
	assert.True(t, HasConfluenceScopes(&OAuthToken{Scope: "x " + strings.Join(fields, " ")}))
	assert.False(t, HasConfluenceScopes(nil))
}

// TestAuthURLScopes_DefaultExcludesConfluence pins the opt-in ruling: a
// buildAuthURL call with JiraScopes (what Login/Prepare pass by default —
// LoginOptions.WithConfluence defaults false) must not request any
// Confluence scope. An Atlassian OAuth app that hasn't enabled the
// Confluence API in its developer console rejects the wider scope set
// outright, so requesting it unconditionally would break every
// `jira login`/`jira add` for such an app.
func TestAuthURLScopes_DefaultExcludesConfluence(t *testing.T) {
	u := buildAuthURL(JiraOAuthConfig{ClientID: "id"}, "http://localhost/cb", "st", JiraScopes)
	parsed, err := url.Parse(u)
	require.NoError(t, err)
	got := strings.Fields(parsed.Query().Get("scope"))
	for _, s := range strings.Fields(ConfluenceScopes) {
		assert.NotContains(t, got, s)
	}
}

// TestAuthURLScopes_WithConfluenceIncludesAll is the opt-in path: a caller
// that explicitly passes OAuthScopes (LoginOptions.WithConfluence = true)
// gets every Confluence scope in the requested auth URL.
func TestAuthURLScopes_WithConfluenceIncludesAll(t *testing.T) {
	u := buildAuthURL(JiraOAuthConfig{ClientID: "id"}, "http://localhost/cb", "st", OAuthScopes)
	parsed, err := url.Parse(u)
	require.NoError(t, err)
	got := strings.Fields(parsed.Query().Get("scope"))
	for _, s := range strings.Fields(ConfluenceScopes) {
		assert.Contains(t, got, s)
	}
}
