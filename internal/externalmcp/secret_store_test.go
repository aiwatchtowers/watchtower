package externalmcp

import (
	"os"
	"reflect"
	"testing"
	"time"
)

func TestSecretStore_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	st := NewSecretStore(dir, 7)
	if got, err := st.Load(); err != nil || got != nil {
		t.Fatalf("empty load = %v, %v", got, err)
	}
	want := &Secret{Env: map[string]string{"TRELLO_TOKEN": "abc"}}
	if err := st.Save(want); err != nil {
		t.Fatal(err)
	}
	fi, _ := os.Stat(st.Path())
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", fi.Mode().Perm())
	}
	got, err := st.Load()
	if err != nil || got.Env["TRELLO_TOKEN"] != "abc" {
		t.Fatalf("load = %v, %v", got, err)
	}
}

func TestSecret_OAuthRoundTrip(t *testing.T) {
	dir := t.TempDir()
	st := NewSecretStore(dir, 9)
	want := &Secret{
		Headers: map[string]string{"X-Foo": "bar"},
		OAuth: &OAuthGrant{
			AccessToken:        "at-123",
			RefreshToken:       "rt-456",
			ExpiresAt:          time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC),
			TokenEndpoint:      "https://issuer.example/token",
			ClientID:           "client-abc",
			ClientSecret:       "secret-xyz",
			Scope:              "mcp:read mcp:write",
			Resource:           "https://mcp.example/server",
			RevocationEndpoint: "https://issuer.example/revoke",
		},
	}
	if err := st.Save(want); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(st.Path())
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", fi.Mode().Perm())
	}
	got, err := st.Load()
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("round trip mismatch:\n got  = %+v\n want = %+v", got, want)
	}
	if !got.OAuth.ExpiresAt.Equal(want.OAuth.ExpiresAt) {
		t.Fatalf("ExpiresAt mismatch: got %v want %v", got.OAuth.ExpiresAt, want.OAuth.ExpiresAt)
	}
}

func TestSecret_LegacyJSONDecodesWithNilOAuth(t *testing.T) {
	dir := t.TempDir()
	st := NewSecretStore(dir, 11)
	legacy := []byte(`{"headers":{"X":"y"}}`)
	if err := os.WriteFile(st.Path(), legacy, 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := st.Load()
	if err != nil {
		t.Fatal(err)
	}
	if got.OAuth != nil {
		t.Fatalf("expected nil OAuth for legacy file, got %+v", got.OAuth)
	}
	if got.Headers["X"] != "y" {
		t.Fatalf("headers not intact: %+v", got.Headers)
	}
}

func TestOAuthGrant_Expiring(t *testing.T) {
	now := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	skew := 5 * time.Minute
	tests := []struct {
		name      string
		expiresAt time.Time
		want      bool
	}{
		{"expired", now.Add(-time.Minute), true},
		{"within skew", now.Add(2 * time.Minute), true},
		{"well ahead", now.Add(time.Hour), false},
		{"zero ExpiresAt", time.Time{}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			g := &OAuthGrant{ExpiresAt: tt.expiresAt}
			if got := g.Expiring(now, skew); got != tt.want {
				t.Fatalf("Expiring() = %v, want %v", got, tt.want)
			}
		})
	}
}
