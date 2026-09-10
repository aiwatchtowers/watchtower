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
