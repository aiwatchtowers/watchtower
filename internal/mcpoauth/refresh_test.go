package mcpoauth

import (
	"context"
	"errors"
	"testing"
	"time"

	"watchtower/internal/externalmcp"
)

func TestEnsureFresh_FreshGrantUnchanged(t *testing.T) {
	as := newFakeAS(t)
	now := time.Now()
	g := &externalmcp.OAuthGrant{
		AccessToken:   "access-token-1",
		RefreshToken:  "refresh-token-1",
		ExpiresAt:     now.Add(time.Hour),
		TokenEndpoint: as.server.URL + "/token",
		ClientID:      as.ClientID,
	}

	changed, err := EnsureFresh(context.Background(), g, now)
	if err != nil {
		t.Fatalf("EnsureFresh: %v", err)
	}
	if changed {
		t.Errorf("changed = true, want false for a fresh grant")
	}
	if len(as.TokenRequests) != 0 {
		t.Errorf("TokenRequests = %d, want 0 (no refresh call for a fresh grant)", len(as.TokenRequests))
	}
	if g.AccessToken != "access-token-1" {
		t.Errorf("AccessToken changed to %q, want unchanged", g.AccessToken)
	}
}

func TestEnsureFresh_ExpiringGrantRefreshes(t *testing.T) {
	as := newFakeAS(t)
	now := time.Now()
	g := &externalmcp.OAuthGrant{
		AccessToken:   "access-token-1",
		RefreshToken:  "refresh-token-1",
		ExpiresAt:     now.Add(30 * time.Second), // inside RefreshSkew
		TokenEndpoint: as.server.URL + "/token",
		ClientID:      as.ClientID,
	}

	changed, err := EnsureFresh(context.Background(), g, now)
	if err != nil {
		t.Fatalf("EnsureFresh: %v", err)
	}
	if !changed {
		t.Fatalf("changed = false, want true for an expiring grant")
	}
	if len(as.TokenRequests) != 1 {
		t.Fatalf("TokenRequests = %d, want 1", len(as.TokenRequests))
	}
	if g.AccessToken != "access-token-1-r" {
		t.Errorf("AccessToken = %q, want rotated", g.AccessToken)
	}
	if g.RefreshToken != "refresh-token-1-r" {
		t.Errorf("RefreshToken = %q, want rotated", g.RefreshToken)
	}
	wantExpiry := now.Add(time.Hour)
	if g.ExpiresAt.Before(wantExpiry.Add(-time.Minute)) || g.ExpiresAt.After(wantExpiry.Add(time.Minute)) {
		t.Errorf("ExpiresAt = %v, want ~%v (advanced from now)", g.ExpiresAt, wantExpiry)
	}
}

func TestEnsureFresh_ExpiringWithoutRefreshTokenErrors(t *testing.T) {
	as := newFakeAS(t)
	now := time.Now()
	g := &externalmcp.OAuthGrant{
		AccessToken:   "access-token-1",
		RefreshToken:  "", // nothing to refresh with
		ExpiresAt:     now.Add(30 * time.Second),
		TokenEndpoint: as.server.URL + "/token",
		ClientID:      as.ClientID,
	}

	changed, err := EnsureFresh(context.Background(), g, now)
	if err == nil {
		t.Fatalf("EnsureFresh: want error for expiring grant with no refresh token")
	}
	if changed {
		t.Errorf("changed = true, want false on error")
	}
	if len(as.TokenRequests) != 0 {
		t.Errorf("TokenRequests = %d, want 0 (never called the server)", len(as.TokenRequests))
	}
}

func TestEnsureFresh_NilGrant(t *testing.T) {
	changed, err := EnsureFresh(context.Background(), nil, time.Now())
	if err == nil {
		t.Fatalf("EnsureFresh: want error for a nil grant")
	}
	if changed {
		t.Errorf("changed = true, want false for a nil grant")
	}
}

func TestEnsureFresh_SkewBoundary_JustInsideRefreshes(t *testing.T) {
	as := newFakeAS(t)
	now := time.Now()
	g := &externalmcp.OAuthGrant{
		AccessToken:   "access-token-1",
		RefreshToken:  "refresh-token-1",
		ExpiresAt:     now.Add(59 * time.Second), // inside the 60s RefreshSkew
		TokenEndpoint: as.server.URL + "/token",
		ClientID:      as.ClientID,
	}

	changed, err := EnsureFresh(context.Background(), g, now)
	if err != nil {
		t.Fatalf("EnsureFresh: %v", err)
	}
	if !changed {
		t.Errorf("changed = false, want true for a token expiring in 59s (inside RefreshSkew)")
	}
	if len(as.TokenRequests) != 1 {
		t.Errorf("TokenRequests = %d, want 1", len(as.TokenRequests))
	}
}

func TestEnsureFresh_SkewBoundary_JustOutsideSkipsRefresh(t *testing.T) {
	as := newFakeAS(t)
	now := time.Now()
	g := &externalmcp.OAuthGrant{
		AccessToken:   "access-token-1",
		RefreshToken:  "refresh-token-1",
		ExpiresAt:     now.Add(61 * time.Second), // just outside the 60s RefreshSkew
		TokenEndpoint: as.server.URL + "/token",
		ClientID:      as.ClientID,
	}

	changed, err := EnsureFresh(context.Background(), g, now)
	if err != nil {
		t.Fatalf("EnsureFresh: %v", err)
	}
	if changed {
		t.Errorf("changed = true, want false for a token expiring in 61s (outside RefreshSkew)")
	}
	if len(as.TokenRequests) != 0 {
		t.Errorf("TokenRequests = %d, want 0", len(as.TokenRequests))
	}
}

func TestEnsureFresh_ServerOmitsRefreshToken_KeepsOldOne(t *testing.T) {
	as := newFakeAS(t)
	as.OmitRefreshTokenOnRefresh = true
	now := time.Now()
	g := &externalmcp.OAuthGrant{
		AccessToken:   "access-token-1",
		RefreshToken:  "refresh-token-1",
		ExpiresAt:     now.Add(30 * time.Second),
		TokenEndpoint: as.server.URL + "/token",
		ClientID:      as.ClientID,
	}

	changed, err := EnsureFresh(context.Background(), g, now)
	if err != nil {
		t.Fatalf("EnsureFresh: %v", err)
	}
	if !changed {
		t.Fatalf("changed = false, want true")
	}
	if g.AccessToken != "access-token-1-r" {
		t.Errorf("AccessToken = %q, want rotated", g.AccessToken)
	}
	if g.RefreshToken != "refresh-token-1" {
		t.Errorf("RefreshToken = %q, want unchanged when the server didn't send a new one", g.RefreshToken)
	}
}

// TestEnsureFresh_ZeroExpiresIn_ClearsExpiresAt pins that a refresh response
// with no expires_in leaves ExpiresAt zero rather than stamping a bogus
// expiry. A zero ExpiresAt is no longer "never expires" (see
// TestEnsureFresh_UnknownExpiryWithRefreshToken_AlwaysVerifies below) — it
// means "unknown, must verify on the next call" — but this test only pins
// the clearing behavior itself.
func TestEnsureFresh_ZeroExpiresIn_ClearsExpiresAt(t *testing.T) {
	as := newFakeAS(t)
	as.ZeroExpiresInOnRefresh = true
	now := time.Now()
	g := &externalmcp.OAuthGrant{
		AccessToken:   "access-token-1",
		RefreshToken:  "refresh-token-1",
		ExpiresAt:     now.Add(30 * time.Second),
		TokenEndpoint: as.server.URL + "/token",
		ClientID:      as.ClientID,
	}

	changed, err := EnsureFresh(context.Background(), g, now)
	if err != nil {
		t.Fatalf("EnsureFresh: %v", err)
	}
	if !changed {
		t.Fatalf("changed = false, want true")
	}
	if !g.ExpiresAt.IsZero() {
		t.Errorf("ExpiresAt = %v, want zero (unknown lifetime) when expires_in is 0", g.ExpiresAt)
	}
}

// TestEnsureFresh_UnknownExpiryWithRefreshToken_AlwaysVerifies pins the I3
// fix: a grant with an unknown expiry (ExpiresAt zero) and a refresh token
// is refreshed on every call rather than handed over forever unverified.
func TestEnsureFresh_UnknownExpiryWithRefreshToken_AlwaysVerifies(t *testing.T) {
	as := newFakeAS(t)
	as.ZeroExpiresInOnRefresh = true // keep the expiry unknown across both calls
	now := time.Now()
	g := &externalmcp.OAuthGrant{
		AccessToken:   "access-token-1",
		RefreshToken:  "refresh-token-1",
		ExpiresAt:     time.Time{}, // unknown expiry
		TokenEndpoint: as.server.URL + "/token",
		ClientID:      as.ClientID,
	}

	changed, err := EnsureFresh(context.Background(), g, now)
	if err != nil {
		t.Fatalf("EnsureFresh: %v", err)
	}
	if !changed {
		t.Fatalf("changed = false, want true (unknown expiry must be verified)")
	}
	if len(as.TokenRequests) != 1 {
		t.Fatalf("TokenRequests = %d, want exactly 1 for a single call", len(as.TokenRequests))
	}
	if g.AccessToken != "access-token-1-r" {
		t.Errorf("AccessToken = %q, want rotated", g.AccessToken)
	}

	// A second call refreshes again — unknown expiry is verified every time,
	// not just once.
	changed2, err := EnsureFresh(context.Background(), g, now)
	if err != nil {
		t.Fatalf("EnsureFresh (2nd call): %v", err)
	}
	if !changed2 {
		t.Fatalf("changed = false on 2nd call, want true (still unknown expiry)")
	}
	if len(as.TokenRequests) != 2 {
		t.Fatalf("TokenRequests = %d after 2nd call, want 2", len(as.TokenRequests))
	}
}

// TestEnsureFresh_UnknownExpiryNoRefreshToken_HandedOverUnverified pins the
// documented fallback: with no refresh token to verify against, an unknown
// expiry is handed over as-is (nothing better is possible) rather than
// erroring or blocking the caller.
func TestEnsureFresh_UnknownExpiryNoRefreshToken_HandedOverUnverified(t *testing.T) {
	as := newFakeAS(t)
	now := time.Now()
	g := &externalmcp.OAuthGrant{
		AccessToken:   "access-token-1",
		RefreshToken:  "", // nothing to refresh with
		ExpiresAt:     time.Time{},
		TokenEndpoint: as.server.URL + "/token",
		ClientID:      as.ClientID,
	}

	changed, err := EnsureFresh(context.Background(), g, now)
	if err != nil {
		t.Fatalf("EnsureFresh: %v, want no error (hand over unverified)", err)
	}
	if changed {
		t.Errorf("changed = true, want false (nothing to refresh with)")
	}
	if len(as.TokenRequests) != 0 {
		t.Errorf("TokenRequests = %d, want 0 (no refresh token, no network call)", len(as.TokenRequests))
	}
	if g.AccessToken != "access-token-1" {
		t.Errorf("AccessToken changed to %q, want unchanged", g.AccessToken)
	}
}

func TestEnsureFresh_InvalidGrantReported(t *testing.T) {
	as := newFakeAS(t)
	as.RefreshInvalidGrant = true
	now := time.Now()
	g := &externalmcp.OAuthGrant{
		AccessToken:   "access-token-1",
		RefreshToken:  "refresh-token-1",
		ExpiresAt:     now.Add(30 * time.Second),
		TokenEndpoint: as.server.URL + "/token",
		ClientID:      as.ClientID,
	}

	changed, err := EnsureFresh(context.Background(), g, now)
	if !errors.Is(err, ErrInvalidGrant) {
		t.Fatalf("EnsureFresh err = %v, want ErrInvalidGrant", err)
	}
	if changed {
		t.Errorf("changed = true, want false on invalid_grant")
	}
}
