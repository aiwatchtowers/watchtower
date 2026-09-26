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

func TestAuthURLRequestsConfluenceScopes(t *testing.T) {
	u := buildAuthURL(JiraOAuthConfig{ClientID: "id"}, "http://localhost/cb", "st")
	parsed, err := url.Parse(u)
	require.NoError(t, err)
	got := strings.Fields(parsed.Query().Get("scope"))
	for _, s := range strings.Fields(ConfluenceScopes) {
		assert.Contains(t, got, s)
	}
}
