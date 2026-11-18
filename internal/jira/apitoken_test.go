package jira

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/policy/policytest"
)

// A made-up API token (leak-check:allow).
const testAPIToken = "ATATT-test-token-not-real"

func testCreds(scoped bool) APITokenCreds {
	return APITokenCreds{Email: "person@example.com", Token: testAPIToken, Scoped: scoped, Scope: JiraScopes}
}

// newTestAPITokenClient is an API-token client whose gateway and site are
// test servers, with creds stored in its token file.
func newTestAPITokenClient(t *testing.T, gateway, site string, creds APITokenCreds) (*Client, *TokenStore) {
	t.Helper()
	store := NewTokenStore(t.TempDir(), 1)
	require.NoError(t, store.SaveAPIToken(creds))
	c := NewAPITokenClient("cloud-x", site, store)
	c.apiRoot = gateway
	c.rateLimiter = unthrottledLimiter()
	c.logger = log.New(io.Discard, "", 0)
	return c, store
}

func wantBasic(creds APITokenCreds) string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(creds.Email+":"+creds.Token))
}

// TestJiraClient_AuthHeaderPerKind: an OAuth account sends its access token
// as Bearer; an API-token account sends Basic base64(email:token).
func TestJiraClient_AuthHeaderPerKind(t *testing.T) {
	var got atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got.Store(r.Header.Get("Authorization"))
		_, _ = w.Write([]byte(`{"accountId":"acc-1"}`))
	}))
	t.Cleanup(srv.Close)

	_, err := makeTestClient(t, srv.URL).GetMyself(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "Bearer at-valid", got.Load())

	c, _ := newTestAPITokenClient(t, "http://gateway.invalid", srv.URL, testCreds(false))
	_, err = c.GetMyself(context.Background())
	require.NoError(t, err)
	assert.Equal(t, wantBasic(testCreds(false)), got.Load())
}

// TestJiraClient_APITokenNeverRefreshes: a 401 on an API-token account is a
// dead token at once — no refresh (there is nothing to refresh with), no
// retry, and never ErrAuthRevoked (D22: error, not revoked).
func TestJiraClient_APITokenNeverRefreshes(t *testing.T) {
	var refreshes, calls atomic.Int32
	tokens := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { refreshes.Add(1) }))
	t.Cleanup(tokens.Close)
	prev := jiraTokenEndpoint
	jiraTokenEndpoint = tokens.URL
	t.Cleanup(func() { jiraTokenEndpoint = prev })
	site := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"errorMessages":["Client must be authenticated"]}`))
	}))
	t.Cleanup(site.Close)

	c, _ := newTestAPITokenClient(t, "http://gateway.invalid", site.URL, testCreds(false))
	_, err := c.GetMyself(context.Background())

	require.ErrorIs(t, err, ErrAPITokenDead)
	assert.False(t, errors.Is(err, ErrAuthRevoked))
	assert.True(t, accountLost(err), "a dead token ends the account's pass")
	assert.Equal(t, int32(0), refreshes.Load())
	assert.Equal(t, int32(1), calls.Load())
	assert.NotContains(t, err.Error(), testAPIToken)
}

// A 401 naming a scope is a token lacking a scope, not a dead token.
func TestJiraClient_APITokenScope401IsNotDead(t *testing.T) {
	site := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"code":401,"message":"Unauthorized; scope does not match"}`))
	}))
	t.Cleanup(site.Close)
	c, _ := newTestAPITokenClient(t, "http://gateway.invalid", site.URL, testCreds(false))
	_, err := c.GetMyself(context.Background())
	require.Error(t, err)
	assert.False(t, errors.Is(err, ErrAPITokenDead))
	var herr *HTTPStatusError
	assert.True(t, errors.As(err, &herr))
}

// A token replaced while a request was out (a re-auth during a daemon pass,
// maybe of the other kind) is no verdict on the new token: not dead.
func TestJiraClient_APITokenReplacedMidRequestIsNotDead(t *testing.T) {
	var store *TokenStore
	site := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		next := testCreds(true)
		next.Token = "ATATT-new-token" // leak-check:allow
		require.NoError(t, store.SaveAPIToken(next))
		w.WriteHeader(http.StatusUnauthorized)
	}))
	t.Cleanup(site.Close)
	var c *Client
	c, store = newTestAPITokenClient(t, "http://gateway.invalid", site.URL, testCreds(false))
	_, err := c.GetMyself(context.Background())
	require.Error(t, err)
	assert.False(t, errors.Is(err, ErrAPITokenDead), "got %v", err)
}

// The organization's policy (AllowAtlassianAPIToken = false) stops every
// API-token request before it is sent; OAuth accounts are not touched.
func TestJiraClient_APITokenPolicyStopsRequests(t *testing.T) {
	policytest.Set(t, map[string]any{"AllowAtlassianAPIToken": false})
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		_, _ = w.Write([]byte(`{"accountId":"acc-1"}`))
	}))
	t.Cleanup(srv.Close)

	c, _ := newTestAPITokenClient(t, srv.URL, srv.URL, testCreds(false))
	_, err := c.GetMyself(context.Background())
	require.ErrorIs(t, err, ErrAPITokenForbidden)
	assert.True(t, accountLost(err))
	assert.Equal(t, int32(0), calls.Load(), "no request leaves")

	_, err = makeTestClient(t, srv.URL).GetMyself(context.Background())
	require.NoError(t, err)
}

// The base URL per token kind is one function: the gateway for a scoped
// token, the site for a classic one, for Jira and Confluence alike.
func TestAPITokenBaseURL(t *testing.T) {
	assert.Equal(t, "https://api.atlassian.com/ex/jira/cid", APITokenBaseURL(true, "cid", "https://acme.atlassian.net"))
	assert.Equal(t, "https://acme.atlassian.net", APITokenBaseURL(false, "cid", "https://acme.atlassian.net/"))

	var paths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		_, _ = w.Write([]byte(`{"accountId":"acc-1","results":[]}`))
	}))
	t.Cleanup(srv.Close)
	for _, scoped := range []bool{false, true} {
		c, _ := newTestAPITokenClient(t, srv.URL, srv.URL+"/", testCreds(scoped))
		_, err := c.GetMyself(context.Background())
		require.NoError(t, err)
		require.NoError(t, c.Confluence().GetJSON(context.Background(), "/wiki/api/v2/spaces", nil, &struct{}{}))
	}
	assert.Equal(t, []string{
		"/rest/api/3/myself", "/wiki/api/v2/spaces",
		"/ex/jira/cloud-x/rest/api/3/myself", "/ex/confluence/cloud-x/wiki/api/v2/spaces",
	}, paths)
}

func TestTokenStore_APITokenRoundTripAndMode(t *testing.T) {
	store := NewTokenStore(t.TempDir(), 7)
	require.NoError(t, store.SaveAPIToken(testCreds(true)))
	got, err := store.LoadAPIToken()
	require.NoError(t, err)
	want := testCreds(true)
	want.AuthKind = AuthKindAPIToken
	assert.Equal(t, want, got)
	fi, err := os.Stat(store.Path())
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), fi.Mode().Perm())

	// The Confluence access checks read the file as a grant.
	tok, err := store.Load()
	require.NoError(t, err)
	assert.False(t, HasConfluenceScopes(tok))

	// An OAuth token file holds no API token.
	require.NoError(t, store.Save(&OAuthToken{AccessToken: "a"}))
	_, err = store.LoadAPIToken()
	assert.Error(t, err)

	assert.NotContains(t, fmt.Sprintf("%v %+v %#v %s", want, want, want, want), testAPIToken)
}

// ProbeAPIToken: a classic token answers on the site; a scoped one only on
// the gateway; both refusing is a dead token; a 403 names the scope.
func TestProbeAPIToken(t *testing.T) {
	type answer struct {
		status int
		body   string
	}
	me := answer{http.StatusOK, `{"accountId":"acc-1","emailAddress":"person@example.com","displayName":"Person A"}`}
	dead := answer{http.StatusUnauthorized, `{"errorMessages":["no"]}`}
	cases := []struct {
		name         string
		site, gate   answer
		wantScoped   bool
		wantErr      error
		wantScopeErr bool
	}{
		{"classic", me, dead, false, nil, false},
		{"scoped", dead, me, true, nil, false},
		{"both refuse", dead, dead, false, ErrAPITokenDead, false},
		{"site forbids, gateway answers", answer{http.StatusForbidden, `{}`}, me, true, nil, false},
		{"both lack the scope", answer{http.StatusForbidden, `{}`}, answer{http.StatusUnauthorized, `{"message":"scope does not match"}`}, false, nil, true},
		{"scoped lacks the scope", dead, answer{http.StatusUnauthorized, `{"message":"Unauthorized; scope does not match"}`}, false, nil, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var sawBasic atomic.Int32
			serve := func(a answer) *httptest.Server {
				srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if strings.HasPrefix(r.Header.Get("Authorization"), "Basic ") {
						sawBasic.Add(1)
					}
					w.WriteHeader(a.status)
					_, _ = w.Write([]byte(a.body))
				}))
				t.Cleanup(srv.Close)
				return srv
			}
			site, gate := serve(tc.site), serve(tc.gate)
			prev, prevCheck := apiGatewayRoot, probeSiteCheck
			apiGatewayRoot, probeSiteCheck = gate.URL, func(string) error { return nil }
			t.Cleanup(func() { apiGatewayRoot, probeSiteCheck = prev, prevCheck })

			got, m, err := ProbeAPIToken(context.Background(), nil, "cloud-x", site.URL, testCreds(false))
			switch {
			case tc.wantErr != nil:
				require.ErrorIs(t, err, tc.wantErr)
			case tc.wantScopeErr:
				var se *ScopeError
				require.ErrorAs(t, err, &se)
				assert.Equal(t, "This token lacks read:jira-user — create one with the listed scopes", se.Error())
			default:
				require.NoError(t, err)
				assert.Equal(t, tc.wantScoped, got.Scoped)
				assert.Equal(t, AuthKindAPIToken, got.AuthKind)
				assert.Equal(t, "acc-1", m.AccountID)
			}
			if err != nil {
				assert.NotContains(t, err.Error(), testAPIToken)
			}
			assert.Positive(t, sawBasic.Load())
		})
	}
}

// TenantInfo reads the site's cloudId without a credential and without
// following a redirect; a site that is not Atlassian Cloud is refused.
func TestTenantInfo(t *testing.T) {
	var auth atomic.Value
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth.Store(r.Header.Get("Authorization"))
		switch r.URL.Path {
		case "/_edge/tenant_info":
			_, _ = w.Write([]byte(`{"cloudId":" cloud-acme "}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)

	id, err := TenantInfo(context.Background(), srv.Client(), srv.URL)
	require.NoError(t, err)
	assert.Equal(t, "cloud-acme", id)
	assert.Equal(t, "", auth.Load())

	_, err = TenantInfo(context.Background(), srv.Client(), "http://acme.atlassian.net")
	require.ErrorIs(t, err, ErrNotAtlassianCloud)
	_, err = TenantInfo(context.Background(), srv.Client(), srv.URL+"/wiki")
	require.ErrorIs(t, err, ErrNotAtlassianCloud)

	redirect := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, srv.URL+"/_edge/tenant_info", http.StatusFound)
	}))
	t.Cleanup(redirect.Close)
	_, err = TenantInfo(context.Background(), redirect.Client(), redirect.URL)
	require.ErrorIs(t, err, ErrNotAtlassianCloud, "a redirect is not followed")
}

// A dead token ends the whole pass, like a revoked grant, so the daemon can
// record it on the account.
func TestSyncer_Sync_AbortsWholeAccountOnDeadAPIToken(t *testing.T) {
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	db.SeedTestJiraAccount(t, database)
	for i, key := range []string{"OPS", "SEC"} {
		require.NoError(t, database.UpsertJiraBoard(db.JiraBoard{
			AccountID: 1, ID: i + 1, Name: key, ProjectKey: key, IsSelected: true, SyncedAt: "now",
		}))
	}
	var calls atomic.Int32
	site := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusUnauthorized)
	}))
	t.Cleanup(site.Close)
	c, _ := newTestAPITokenClient(t, "http://gateway.invalid", site.URL, testCreds(false))
	s := NewSyncer(c, database, nil, nil, 1)
	s.SetLogger(log.New(io.Discard, "", 0))

	_, err = s.Sync(context.Background())
	require.ErrorIs(t, err, ErrAPITokenDead)
	assert.Equal(t, int32(1), calls.Load(), "the pass stops at the first refusal")
}

// TestConfluence_APITokenReusesCreds: Confluence reuses the account's API
// token, as it reuses an OAuth grant.
func TestConfluence_APITokenReusesCreds(t *testing.T) {
	var got atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got.Store(r.Header.Get("Authorization"))
		_, _ = w.Write([]byte(`{"results":[]}`))
	}))
	t.Cleanup(srv.Close)
	creds := testCreds(false)
	c, _ := newTestAPITokenClient(t, "http://gateway.invalid", srv.URL, creds)
	require.NoError(t, c.Confluence().GetJSON(context.Background(), "/wiki/api/v2/spaces", nil, &struct{}{}))
	assert.Equal(t, wantBasic(creds), got.Load())
}

// Only an https <name>.atlassian.net origin gets an API token: a custom
// domain's tenant_info is that host's own word.
func TestValidateAPITokenSite(t *testing.T) {
	assert.NoError(t, ValidateAPITokenSite("https://acme.atlassian.net"))
	assert.NoError(t, ValidateAPITokenSite("https://Acme.atlassian.net/"))
	for _, bad := range []string{
		"https://jira.example.com", "http://acme.atlassian.net", "https://acme.atlassian.net:8443",
		"https://a.b.atlassian.net", "https://atlassian.net", "https://acme.atlassian.net.example.com",
		"https://acme.atlassian.net/wiki", "https://user@acme.atlassian.net", "https://acme.atlassian.net?", // leak-check:allow (a URL with a user part, not an email)
	} {
		assert.ErrorIs(t, ValidateAPITokenSite(bad), ErrNotAtlassianCloud, bad)
	}

	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { calls.Add(1) }))
	t.Cleanup(srv.Close)
	_, _, err := ProbeAPIToken(context.Background(), nil, "cloud-x", srv.URL, testCreds(false))
	require.ErrorIs(t, err, ErrNotAtlassianCloud)
	assert.Equal(t, int32(0), calls.Load(), "the probe sends nothing to such a site")
}

// The dead-token hook fires on a dead token whoever made the request, and
// not on a scope refusal.
func TestClient_OnAPITokenDead(t *testing.T) {
	body := `{"errorMessages":["no"]}`
	site := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(site.Close)
	c, _ := newTestAPITokenClient(t, "http://gateway.invalid", site.URL, testCreds(false))
	var fired int
	c.SetOnAPITokenDead(func() { fired++ })

	require.Error(t, c.Confluence().GetJSON(context.Background(), "/wiki/api/v2/spaces", nil, &struct{}{}))
	assert.Equal(t, 1, fired)

	body = `{"message":"Unauthorized; scope does not match"}`
	_, err := c.GetMyself(context.Background())
	require.Error(t, err)
	assert.Equal(t, 1, fired, "a refused scope is not a dead token")
}
