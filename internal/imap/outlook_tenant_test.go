package imap

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/oauthclient"
)

// TestMicrosoftEndpoints_EmptyTenantIsCommon (#1887 D16): the shared client
// signs in through "common"; a company's bundle names its own tenant.
func TestMicrosoftEndpoints_EmptyTenantIsCommon(t *testing.T) {
	authURL, tokenURL := microsoftEndpoints("")
	assert.Equal(t, "https://login.microsoftonline.com/common/oauth2/v2.0/authorize", authURL)
	assert.Equal(t, "https://login.microsoftonline.com/common/oauth2/v2.0/token", tokenURL)

	authURL, tokenURL = microsoftEndpoints("00000000-0000-0000-0000-0000000000aa")
	assert.Equal(t, "https://login.microsoftonline.com/00000000-0000-0000-0000-0000000000aa/oauth2/v2.0/authorize", authURL)
	assert.Equal(t, "https://login.microsoftonline.com/00000000-0000-0000-0000-0000000000aa/oauth2/v2.0/token", tokenURL)

	// A tenant is one path segment, whatever it holds.
	authURL, _ = microsoftEndpoints("example.com/../evil")
	u, err := url.Parse(authURL)
	require.NoError(t, err)
	assert.Equal(t, "login.microsoftonline.com", u.Host)
	assert.Equal(t, "/example.com%2F..%2Fevil/oauth2/v2.0/authorize", u.EscapedPath())
}

// A company's tenant reaches the authorize URL and the token endpoint.
func TestMicrosoftTenant_AuthorizeAndRefresh(t *testing.T) {
	cfg := MicrosoftOAuthConfig{ClientID: "client-123", TenantID: "example.com"}
	u, err := url.Parse(buildMicrosoftAuthURL(cfg, "http://localhost/cb", "s", "c"))
	require.NoError(t, err)
	assert.Equal(t, "/example.com/oauth2/v2.0/authorize", u.Path)

	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		_, _ = w.Write([]byte(`{"access_token":"at","refresh_token":"rt2"}`))
	}))
	defer srv.Close()
	prev := microsoftLoginBase
	microsoftLoginBase = srv.URL
	defer func() { microsoftLoginBase = prev }()

	_, _, err = RefreshAccessToken(context.Background(), cfg, "rt")
	require.NoError(t, err)
	assert.Equal(t, "/example.com/oauth2/v2.0/token", gotPath)
}

// A refresh Microsoft refuses for the client (the app registration is gone
// from the tenant, or its secret changed) is oauthclient.ErrClientRejected;
// any other refusal is a plain error.
func TestMicrosoftRefresh_InvalidClientIsRejected(t *testing.T) {
	body := `{"error":"unauthorized_client","error_description":"AADSTS700016: Application not found in the directory"}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()
	prev := microsoftLoginBase
	microsoftLoginBase = srv.URL
	defer func() { microsoftLoginBase = prev }()

	_, _, err := RefreshAccessToken(context.Background(), MicrosoftOAuthConfig{ClientID: "c"}, "rt")
	assert.ErrorIs(t, err, oauthclient.ErrClientRejected)

	body = `{"error":"invalid_grant"}`
	_, _, err = RefreshAccessToken(context.Background(), MicrosoftOAuthConfig{ClientID: "c"}, "rt")
	require.Error(t, err)
	assert.NotErrorIs(t, err, oauthclient.ErrClientRejected)
}

// An Outlook account whose client Microsoft refused at the refresh becomes
// 'error' with its client code (invalid_client: tied to a company), not the
// raw refresh error (#1887 P5).
func TestOutlookSync_ClientRejectedIsMarked(t *testing.T) {
	ts := startTestServer(t)
	database := db.OpenTestDB(t)
	host, port := ts.hostPort(t)
	id, err := database.CreateEmailAccount(db.EmailAccount{
		Provider: "outlook", EmailAddress: "me@example.com", CompanySlug: "acme",
		Host: host, Port: port, Security: "none", Folder: "INBOX",
	})
	require.NoError(t, err)
	acct, err := database.GetEmailAccount(id)
	require.NoError(t, err)
	auth := RefreshingXOAUTH2Auth{Username: acct.EmailAddress, RefreshFunc: func(context.Context) (string, error) {
		return "", fmt.Errorf("refreshing: %w (400): {\"error\":\"unauthorized_client\"}", oauthclient.ErrClientRejected)
	}}
	s := NewSyncer(acct, AccountConfig{Host: host, Port: port, Security: SecurityNone, Folder: "INBOX"}, auth, database, &config.Config{}, nil)

	_, err = s.Sync(context.Background())
	require.ErrorIs(t, err, oauthclient.ErrClientRejected)
	got, err := database.GetEmailAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "error", got.Status)
	assert.Equal(t, oauthclient.CodeInvalidClient, got.Error)
}
