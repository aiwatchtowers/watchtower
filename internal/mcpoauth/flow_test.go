package mcpoauth

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"sync"
	"testing"

	"watchtower/internal/auth"
)

// fakeAS is a minimal RFC 8414/7591/7009 authorization server for
// mcpoauth's own tests, reused as-is by Tasks 5 and 6's package tests
// (loopback callback capture, token-store persistence).
//
// Construct with newFakeAS(t); the config fields below may be set right
// after construction, before the flow under test is exercised. Recorded
// requests and issued token state are read back afterwards for assertions.
type fakeAS struct {
	server *httptest.Server

	// Config knobs.
	NoRegistrationEndpoint bool // omit registration_endpoint from metadata
	RefreshInvalidGrant    bool // /token refresh_token grant always 400s invalid_grant

	// AuthCode is the code /token accepts for grant_type=authorization_code.
	AuthCode string
	// CodeChallenge is the PKCE challenge /token requires the code_verifier
	// to hash to; empty skips the check.
	CodeChallenge string
	// RedirectURI is the redirect_uri /token requires on the
	// authorization_code grant; empty skips the check.
	RedirectURI string

	mu sync.Mutex

	// ClientID is the id issued by /register (also the id fakeAS accepts
	// on every endpoint below).
	ClientID string
	// AccessToken/RefreshToken are the currently valid tokens: the initial
	// values issued by exchange, updated in place on each refresh
	// rotation.
	AccessToken  string
	RefreshToken string

	RegisterRequests  []registerRequest
	AuthorizeRequests []url.Values
	TokenRequests     []url.Values
	RevokeRequests    []url.Values
}

func newFakeAS(t *testing.T) *fakeAS {
	t.Helper()
	as := &fakeAS{
		ClientID:     "test-client-id",
		AuthCode:     "test-auth-code",
		AccessToken:  "access-token-1",
		RefreshToken: "refresh-token-1",
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/oauth-protected-resource", func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	})
	mux.HandleFunc("/.well-known/oauth-authorization-server", as.handleMetadata)
	mux.HandleFunc("/register", as.handleRegister(t))
	mux.HandleFunc("/authorize", as.handleAuthorize)
	mux.HandleFunc("/token", as.handleToken(t))
	mux.HandleFunc("/revoke", as.handleRevoke(t))

	as.server = httptest.NewServer(mux)
	t.Cleanup(as.server.Close)
	return as
}

func (as *fakeAS) handleMetadata(w http.ResponseWriter, r *http.Request) {
	as.mu.Lock()
	defer as.mu.Unlock()

	meta := Metadata{
		Issuer:                            as.server.URL,
		AuthorizationEndpoint:             as.server.URL + "/authorize",
		TokenEndpoint:                     as.server.URL + "/token",
		RevocationEndpoint:                as.server.URL + "/revoke",
		CodeChallengeMethodsSupported:     []string{"S256"},
		TokenEndpointAuthMethodsSupported: []string{"none", "client_secret_post"},
	}
	if !as.NoRegistrationEndpoint {
		meta.RegistrationEndpoint = as.server.URL + "/register"
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(meta)
}

func (as *fakeAS) handleRegister(t *testing.T) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		t.Helper()
		var req registerRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "bad request body", http.StatusBadRequest)
			return
		}

		as.mu.Lock()
		as.RegisterRequests = append(as.RegisterRequests, req)
		clientID := as.ClientID
		as.mu.Unlock()

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(registerResponse{ClientID: clientID})
	}
}

func (as *fakeAS) handleAuthorize(w http.ResponseWriter, r *http.Request) {
	as.mu.Lock()
	as.AuthorizeRequests = append(as.AuthorizeRequests, r.URL.Query())
	code := as.AuthCode
	as.mu.Unlock()

	redirectURI := r.URL.Query().Get("redirect_uri")
	state := r.URL.Query().Get("state")
	if redirectURI == "" {
		http.Error(w, "missing redirect_uri", http.StatusBadRequest)
		return
	}
	dest, err := url.Parse(redirectURI)
	if err != nil {
		http.Error(w, "invalid redirect_uri", http.StatusBadRequest)
		return
	}
	q := dest.Query()
	q.Set("code", code)
	q.Set("state", state)
	dest.RawQuery = q.Encode()
	http.Redirect(w, r, dest.String(), http.StatusFound)
}

func (as *fakeAS) handleToken(t *testing.T) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		t.Helper()
		if err := r.ParseForm(); err != nil {
			http.Error(w, "bad form body", http.StatusBadRequest)
			return
		}

		as.mu.Lock()
		as.TokenRequests = append(as.TokenRequests, cloneValues(r.PostForm))
		as.mu.Unlock()

		switch r.PostForm.Get("grant_type") {
		case "authorization_code":
			as.tokenAuthorizationCode(w, r)
		case "refresh_token":
			as.tokenRefresh(w, r)
		default:
			writeTokenError(w, http.StatusBadRequest, "unsupported_grant_type", "")
		}
	}
}

func (as *fakeAS) tokenAuthorizationCode(w http.ResponseWriter, r *http.Request) {
	as.mu.Lock()
	defer as.mu.Unlock()

	if r.PostForm.Get("code") != as.AuthCode {
		writeTokenError(w, http.StatusBadRequest, "invalid_grant", "unknown code")
		return
	}
	if as.RedirectURI != "" && r.PostForm.Get("redirect_uri") != as.RedirectURI {
		writeTokenError(w, http.StatusBadRequest, "invalid_grant", "redirect_uri mismatch")
		return
	}
	if as.CodeChallenge != "" {
		sum := sha256.Sum256([]byte(r.PostForm.Get("code_verifier")))
		got := base64.RawURLEncoding.EncodeToString(sum[:])
		if got != as.CodeChallenge {
			writeTokenError(w, http.StatusBadRequest, "invalid_grant", "code_verifier does not match code_challenge")
			return
		}
	}

	writeJSONToken(w, Token{
		AccessToken:  as.AccessToken,
		RefreshToken: as.RefreshToken,
		Scope:        r.PostForm.Get("scope"),
		ExpiresIn:    3600,
	})
}

func (as *fakeAS) tokenRefresh(w http.ResponseWriter, r *http.Request) {
	as.mu.Lock()
	defer as.mu.Unlock()

	if as.RefreshInvalidGrant {
		writeTokenError(w, http.StatusBadRequest, "invalid_grant", "refresh token revoked")
		return
	}
	if r.PostForm.Get("refresh_token") != as.RefreshToken {
		writeTokenError(w, http.StatusBadRequest, "invalid_grant", "unknown refresh token")
		return
	}

	as.AccessToken += "-r"
	as.RefreshToken += "-r"
	writeJSONToken(w, Token{
		AccessToken:  as.AccessToken,
		RefreshToken: as.RefreshToken,
		ExpiresIn:    3600,
	})
}

func (as *fakeAS) handleRevoke(t *testing.T) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		t.Helper()
		if err := r.ParseForm(); err != nil {
			http.Error(w, "bad form body", http.StatusBadRequest)
			return
		}
		as.mu.Lock()
		as.RevokeRequests = append(as.RevokeRequests, cloneValues(r.PostForm))
		as.mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}
}

func cloneValues(v url.Values) url.Values {
	out := make(url.Values, len(v))
	for k, vals := range v {
		out[k] = append([]string(nil), vals...)
	}
	return out
}

func writeJSONToken(w http.ResponseWriter, tok Token) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(tok)
}

func writeTokenError(w http.ResponseWriter, status int, errCode, desc string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(tokenErrorResponse{Error: errCode, ErrorDescription: desc})
}

func TestRegister_PublicClient(t *testing.T) {
	as := newFakeAS(t)
	md, err := Discover(context.Background(), as.server.URL)
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}

	clientID, clientSecret, err := Register(context.Background(), md, "http://127.0.0.1:0/callback")
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	if clientID == "" {
		t.Fatal("Register: got empty client_id")
	}
	if clientSecret != "" {
		t.Errorf("Register: client_secret = %q, want empty for a public client", clientSecret)
	}

	if len(as.RegisterRequests) != 1 {
		t.Fatalf("RegisterRequests = %d, want 1", len(as.RegisterRequests))
	}
	got := as.RegisterRequests[0]
	if got.ClientName != "Watchtower" {
		t.Errorf("client_name = %q, want %q", got.ClientName, "Watchtower")
	}
	if !slices.Equal(got.RedirectURIs, []string{"http://127.0.0.1:0/callback"}) {
		t.Errorf("redirect_uris = %v", got.RedirectURIs)
	}
	if !slices.Equal(got.GrantTypes, []string{"authorization_code", "refresh_token"}) {
		t.Errorf("grant_types = %v", got.GrantTypes)
	}
	if !slices.Equal(got.ResponseTypes, []string{"code"}) {
		t.Errorf("response_types = %v", got.ResponseTypes)
	}
	if got.TokenEndpointAuthMethod != "none" {
		t.Errorf("token_endpoint_auth_method = %q, want %q", got.TokenEndpointAuthMethod, "none")
	}
}

func TestAuthorizeURL_ContainsPKCEStateResource(t *testing.T) {
	md := &Metadata{AuthorizationEndpoint: "https://as.example.com/authorize"}
	pkce, err := auth.NewPKCEPair()
	if err != nil {
		t.Fatalf("NewPKCEPair: %v", err)
	}

	raw, err := AuthorizeURL(md, "client-1", "http://127.0.0.1:5555/callback", "state-abc", pkce, "", "https://mcp.example.com/mcp")
	if err != nil {
		t.Fatalf("AuthorizeURL: %v", err)
	}
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parsing AuthorizeURL result: %v", err)
	}
	q := u.Query()
	if q.Get("response_type") != "code" {
		t.Errorf("response_type = %q, want code", q.Get("response_type"))
	}
	if q.Get("client_id") != "client-1" {
		t.Errorf("client_id = %q", q.Get("client_id"))
	}
	if q.Get("redirect_uri") != "http://127.0.0.1:5555/callback" {
		t.Errorf("redirect_uri = %q", q.Get("redirect_uri"))
	}
	if q.Get("state") != "state-abc" {
		t.Errorf("state = %q", q.Get("state"))
	}
	if q.Get("code_challenge") != pkce.Challenge {
		t.Errorf("code_challenge = %q, want %q", q.Get("code_challenge"), pkce.Challenge)
	}
	if q.Get("code_challenge_method") != "S256" {
		t.Errorf("code_challenge_method = %q, want S256", q.Get("code_challenge_method"))
	}
	if q.Get("resource") != "https://mcp.example.com/mcp" {
		t.Errorf("resource = %q", q.Get("resource"))
	}
	if q.Has("scope") {
		t.Errorf("scope should be omitted when not requested, got %q", q.Get("scope"))
	}

	raw2, err := AuthorizeURL(md, "client-1", "http://127.0.0.1:5555/callback", "state-abc", pkce, "mcp:read", "")
	if err != nil {
		t.Fatalf("AuthorizeURL: %v", err)
	}
	u2, err := url.Parse(raw2)
	if err != nil {
		t.Fatalf("parsing AuthorizeURL result: %v", err)
	}
	q2 := u2.Query()
	if q2.Get("scope") != "mcp:read" {
		t.Errorf("scope = %q, want mcp:read", q2.Get("scope"))
	}
	if q2.Has("resource") {
		t.Errorf("resource should be omitted when not requested, got %q", q2.Get("resource"))
	}
}

func TestExchangeCode_Success(t *testing.T) {
	as := newFakeAS(t)
	md, err := Discover(context.Background(), as.server.URL)
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}

	pkce, err := auth.NewPKCEPair()
	if err != nil {
		t.Fatalf("NewPKCEPair: %v", err)
	}
	as.CodeChallenge = pkce.Challenge
	as.RedirectURI = "http://127.0.0.1:9999/callback"

	tok, err := ExchangeCode(context.Background(), md, as.ClientID, "", as.AuthCode, as.RedirectURI, pkce.Verifier, "")
	if err != nil {
		t.Fatalf("ExchangeCode: %v", err)
	}
	if tok.AccessToken != "access-token-1" {
		t.Errorf("AccessToken = %q", tok.AccessToken)
	}
	if tok.RefreshToken != "refresh-token-1" {
		t.Errorf("RefreshToken = %q", tok.RefreshToken)
	}
	if tok.ExpiresIn != 3600 {
		t.Errorf("ExpiresIn = %d, want 3600", tok.ExpiresIn)
	}
	if len(as.TokenRequests) != 1 {
		t.Fatalf("TokenRequests = %d, want 1", len(as.TokenRequests))
	}
	if as.TokenRequests[0].Has("client_secret") {
		t.Errorf("client_secret should be omitted from the form when the caller passed an empty secret, got %q", as.TokenRequests[0].Get("client_secret"))
	}
}

func TestExchangeCode_WrongVerifierRejected(t *testing.T) {
	as := newFakeAS(t)
	md, err := Discover(context.Background(), as.server.URL)
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}

	pkce, err := auth.NewPKCEPair()
	if err != nil {
		t.Fatalf("NewPKCEPair: %v", err)
	}
	as.CodeChallenge = pkce.Challenge

	wrong, err := auth.NewPKCEPair()
	if err != nil {
		t.Fatalf("NewPKCEPair: %v", err)
	}

	_, err = ExchangeCode(context.Background(), md, as.ClientID, "", as.AuthCode, "", wrong.Verifier, "")
	if err == nil {
		t.Fatal("ExchangeCode: want error for a mismatched code_verifier, got nil")
	}
	if !errors.Is(err, ErrInvalidGrant) {
		t.Errorf("ExchangeCode: err = %v, want ErrInvalidGrant", err)
	}
}

func TestRefresh_RotatesToken(t *testing.T) {
	as := newFakeAS(t)
	md, err := Discover(context.Background(), as.server.URL)
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}

	initialRefresh := as.RefreshToken
	tok, err := Refresh(context.Background(), md.TokenEndpoint, as.ClientID, "", initialRefresh, "")
	if err != nil {
		t.Fatalf("Refresh: %v", err)
	}
	if tok.AccessToken == "" {
		t.Error("Refresh: got empty access_token")
	}
	if tok.RefreshToken == "" || tok.RefreshToken == initialRefresh {
		t.Errorf("Refresh: RefreshToken = %q, want a rotated value different from %q", tok.RefreshToken, initialRefresh)
	}
	if as.RefreshToken != tok.RefreshToken {
		t.Errorf("fakeAS.RefreshToken = %q, want it to track the newly issued %q", as.RefreshToken, tok.RefreshToken)
	}

	// The old refresh token is no longer valid once rotated.
	if _, err := Refresh(context.Background(), md.TokenEndpoint, as.ClientID, "", initialRefresh, ""); !errors.Is(err, ErrInvalidGrant) {
		t.Errorf("Refresh with the stale token: err = %v, want ErrInvalidGrant", err)
	}
}

func TestRefresh_InvalidGrantSentinel(t *testing.T) {
	as := newFakeAS(t)
	as.RefreshInvalidGrant = true
	md, err := Discover(context.Background(), as.server.URL)
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}

	_, err = Refresh(context.Background(), md.TokenEndpoint, as.ClientID, "", as.RefreshToken, "")
	if !errors.Is(err, ErrInvalidGrant) {
		t.Fatalf("Refresh: err = %v, want ErrInvalidGrant", err)
	}
}

func TestRefresh_ClientSecretPostedOnlyWhenSet(t *testing.T) {
	as := newFakeAS(t)
	md, err := Discover(context.Background(), as.server.URL)
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}

	if _, err := Refresh(context.Background(), md.TokenEndpoint, as.ClientID, "", as.RefreshToken, ""); err != nil {
		t.Fatalf("Refresh (no secret): %v", err)
	}
	if len(as.TokenRequests) != 1 {
		t.Fatalf("TokenRequests = %d, want 1", len(as.TokenRequests))
	}
	if as.TokenRequests[0].Has("client_secret") {
		t.Errorf("client_secret should be omitted from the form when empty, got %q", as.TokenRequests[0].Get("client_secret"))
	}

	if _, err := Refresh(context.Background(), md.TokenEndpoint, as.ClientID, "s3cr3t", as.RefreshToken, ""); err != nil {
		t.Fatalf("Refresh (with secret): %v", err)
	}
	if len(as.TokenRequests) != 2 {
		t.Fatalf("TokenRequests = %d, want 2", len(as.TokenRequests))
	}
	if as.TokenRequests[1].Get("client_secret") != "s3cr3t" {
		t.Errorf("client_secret = %q, want s3cr3t", as.TokenRequests[1].Get("client_secret"))
	}
}

func TestRevoke_Posts(t *testing.T) {
	as := newFakeAS(t)
	md, err := Discover(context.Background(), as.server.URL)
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}

	if err := Revoke(context.Background(), md.RevocationEndpoint, as.ClientID, "", as.AccessToken); err != nil {
		t.Fatalf("Revoke: %v", err)
	}
	if len(as.RevokeRequests) != 1 {
		t.Fatalf("RevokeRequests = %d, want 1", len(as.RevokeRequests))
	}
	got := as.RevokeRequests[0]
	if got.Get("token") != as.AccessToken {
		t.Errorf("token = %q, want %q", got.Get("token"), as.AccessToken)
	}
	if got.Get("client_id") != as.ClientID {
		t.Errorf("client_id = %q, want %q", got.Get("client_id"), as.ClientID)
	}
}
