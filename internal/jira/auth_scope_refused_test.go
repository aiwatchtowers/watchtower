package jira

import (
	"context"
	"net/http"
	"net/url"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/oauthpage/oauthpagetest"
)

// loginWithCallbackError runs Login and answers its loopback callback with
// error=<code>, returning Login's error (#573).
func loginWithCallbackError(t *testing.T, code string) error {
	t.Helper()
	out := &oauthpagetest.Output{}
	resultCh := make(chan error, 1)
	go func() {
		_, err := Login(context.Background(), JiraOAuthConfig{ClientID: "cid", ClientSecret: "s"}, out,
			LoginOptions{SkipBrowserOpen: true, WithConfluence: true})
		resultCh <- err
	}()
	authorizeURL := out.WaitURL("https://")
	parsed, err := url.Parse(authorizeURL)
	require.NoError(t, err)
	cb, err := url.Parse(parsed.Query().Get("redirect_uri"))
	require.NoError(t, err)
	q := cb.Query()
	q.Set("error", code)
	q.Set("state", parsed.Query().Get("state"))
	cb.RawQuery = q.Encode()
	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, cb.String(), nil)
	require.NoError(t, err)
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	_ = resp.Body.Close()
	return <-resultCh
}

func TestLogin_InvalidScopeIsErrScopeRefused(t *testing.T) {
	err := loginWithCallbackError(t, "invalid_scope")
	require.Error(t, err)
	assert.ErrorIs(t, err, ErrScopeRefused)
	assert.Contains(t, err.Error(), "jira authorization denied: invalid_scope")
}

func TestLogin_AccessDeniedIsNotErrScopeRefused(t *testing.T) {
	err := loginWithCallbackError(t, "access_denied")
	require.Error(t, err)
	assert.NotErrorIs(t, err, ErrScopeRefused)
}
