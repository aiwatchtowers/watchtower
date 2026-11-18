package linear

import (
	"context"
	"errors"
	"net/http"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/oauthclient"
)

// A refresh Linear refuses for the client is oauthclient.ErrClientRejected,
// not ErrAuthRevoked (LINEAR-03 stays for a refused grant): the account needs
// a new sign-in, but no revoked purge clock starts (#1887 P5). The stored
// pair is untouched.
func TestLinearRefresh_InvalidClientIsRejectedNotRevoked(t *testing.T) {
	c, store := newTestClient(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"invalid_client","error_description":"client not found"}`))
	})
	err := c.Do(context.Background(), `query { viewer { id } }`, nil, &struct{}{})
	require.ErrorIs(t, err, oauthclient.ErrClientRejected)
	assert.NotErrorIs(t, err, ErrAuthRevoked)
	assert.True(t, accountLost(err), "a rejected client ends the account's pass")
	saved, err := store.Load()
	require.NoError(t, err)
	assert.Equal(t, "r0", saved.RefreshToken)
}

// SetOAuthSource: every refresh asks the source for the client, under the
// token lock; a source error refreshes nothing and comes back as is.
func TestLinearClient_OAuthSourceAtRefresh(t *testing.T) {
	var gotClient string
	calls := 0
	c, _ := newTestClient(t, func(w http.ResponseWriter, _ *http.Request) {
		calls++
		if calls == 1 {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = w.Write([]byte(`{"data":{}}`))
	}, func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		gotClient = r.PostForm.Get("client_id")
		_, _ = w.Write([]byte(`{"access_token":"a1","refresh_token":"r1","expires_in":86399}`))
	})
	c.SetOAuthSource(func() (OAuthConfig, error) { return OAuthConfig{ClientID: "company-client"}, nil })
	require.NoError(t, c.Do(context.Background(), `query { viewer { id } }`, nil, &struct{}{}))
	assert.Equal(t, "company-client", gotClient)

	sourceErr := errors.New("no client")
	c2, _ := newTestClient(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}, func(http.ResponseWriter, *http.Request) {
		t.Error("no refresh without a client")
	})
	c2.SetOAuthSource(func() (OAuthConfig, error) { return OAuthConfig{}, sourceErr })
	err := c2.Do(context.Background(), `query { viewer { id } }`, nil, &struct{}{})
	assert.ErrorIs(t, err, sourceErr)
}
