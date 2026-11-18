package slackconnect

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestExchange_NoSecretInForm(t *testing.T) {
	var form url.Values
	var method, contentType string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		method, contentType = r.Method, r.Header.Get("Content-Type")
		if err := r.ParseForm(); err != nil {
			t.Errorf("parse form: %v", err)
		}
		form = r.PostForm
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true,"app_id":"A0ACME01",
			"authed_user":{"id":"U0ACME01","scope":"channels:history,users:read","access_token":"xoxp-test",
				"token_type":"user","refresh_token":"xoxe-test","expires_in":43200,"refresh_token_expires_in":2592000},
			"team":{"id":"T0ACME01","name":"Acme"}}`))
	}))
	defer srv.Close()

	ex := NewExchanger(srv.Client(), srv.URL)
	g, err := ex(context.Background(), "1111.2222", "code-1", "verifier-1", RedirectURL)
	if err != nil {
		t.Fatal(err)
	}
	if method != http.MethodPost || !strings.HasPrefix(contentType, "application/x-www-form-urlencoded") {
		t.Fatalf("request = %s %s", method, contentType)
	}
	want := map[string]string{
		"client_id": "1111.2222", "code": "code-1", "code_verifier": "verifier-1", "redirect_uri": RedirectURL,
	}
	for k, v := range want {
		if got := form.Get(k); got != v {
			t.Errorf("form %s = %q, want %q", k, got, v)
		}
	}
	if form.Has("client_secret") {
		t.Fatalf("form carries client_secret: %v", form)
	}
	if len(form) != len(want) {
		t.Fatalf("form has extra fields: %v", form)
	}
	wantGrant := Grant{
		AccessToken: "xoxp-test", RefreshToken: "xoxe-test", ExpiresIn: 43200, RefreshExpiresIn: 2592000,
		ClientID: "1111.2222", AppID: "A0ACME01", TeamID: "T0ACME01", TeamName: "Acme", UserID: "U0ACME01",
		Scope: "channels:history,users:read",
	}
	if g != wantGrant {
		t.Fatalf("grant = %+v\nwant  %+v", g, wantGrant)
	}
}

func TestExchange_SlackErrors(t *testing.T) {
	cases := []struct {
		name, body string
		status     int
		wantErr    string
	}{
		{"not ok", `{"ok":false,"error":"invalid_code"}`, http.StatusOK, "invalid_code"},
		{"no token", `{"ok":true,"authed_user":{"id":"U0ACME01"},"team":{"id":"T0ACME01"}}`, http.StatusOK, "no user token"},
		{"http error", `oops`, http.StatusBadGateway, "502"},
		{"not json", `<html>`, http.StatusOK, "decoding"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer srv.Close()
			_, err := NewExchanger(srv.Client(), srv.URL)(context.Background(), "1111.2222", "c", "v", RedirectURL)
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("err = %v, want it to mention %q", err, tc.wantErr)
			}
			if strings.Contains(err.Error(), "v&") || strings.Contains(err.Error(), "code_verifier") {
				t.Fatalf("error leaks the form: %v", err)
			}
		})
	}
}

func TestExchange_EnterpriseTeamFallback(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"ok":true,"authed_user":{"id":"U0ACME01","access_token":"xoxp-test"},
			"team":null,"enterprise":{"id":"E0ACME01","name":"Acme Grid"}}`))
	}))
	defer srv.Close()
	g, err := NewExchanger(srv.Client(), srv.URL)(context.Background(), "1111.2222", "c", "v", RedirectURL)
	if err != nil {
		t.Fatal(err)
	}
	if g.TeamID != "E0ACME01" || g.TeamName != "Acme Grid" {
		t.Fatalf("grant team = %q %q", g.TeamID, g.TeamName)
	}
}

func TestExchange_RefusesRedirects(t *testing.T) {
	var target, origin *httptest.Server
	targetHit := false
	target = httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { targetHit = true }))
	defer target.Close()
	origin = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusTemporaryRedirect)
	}))
	defer origin.Close()

	for name, ex := range map[string]Exchanger{
		"caller client": NewExchanger(origin.Client(), origin.URL),
		"nil client":    NewExchanger(nil, origin.URL),
	} {
		_, err := ex(context.Background(), "1111.2222", "code-1", "verifier-1", RedirectURL)
		if err == nil || !strings.Contains(err.Error(), "307") {
			t.Fatalf("%s: err = %v, want the 307 refused", name, err)
		}
	}
	if targetHit {
		t.Fatal("the code and verifier were replayed to the redirect target")
	}
	if origin.Client().CheckRedirect != nil {
		t.Fatal("NewExchanger changed the caller's client")
	}
}
