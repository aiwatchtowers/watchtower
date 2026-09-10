package mcpoauth

import (
	"context"
	"fmt"
	"time"

	"watchtower/internal/externalmcp"
)

// RefreshSkew is how early before expiry a token is refreshed.
const RefreshSkew = 60 * time.Second

// EnsureFresh refreshes g in place when it is expiring (or already expired) and
// reports whether it changed. A grant without a refresh token that is expiring
// is an error (sign in again). Returns ErrInvalidGrant when the server revoked it.
func EnsureFresh(ctx context.Context, g *externalmcp.OAuthGrant, now time.Time) (changed bool, err error) {
	if !g.Expiring(now, RefreshSkew) {
		return false, nil
	}
	if g.RefreshToken == "" {
		return false, fmt.Errorf("mcpoauth: access token expiring with no refresh token available (sign in again)")
	}

	tok, err := Refresh(ctx, g.TokenEndpoint, g.ClientID, g.ClientSecret, g.RefreshToken, g.Resource)
	if err != nil {
		return false, err
	}

	g.AccessToken = tok.AccessToken
	if tok.RefreshToken != "" {
		g.RefreshToken = tok.RefreshToken
	}
	if tok.ExpiresIn > 0 {
		g.ExpiresAt = now.Add(time.Duration(tok.ExpiresIn) * time.Second)
	} else {
		g.ExpiresAt = time.Time{} // unknown, never proactively refreshed again
	}
	return true, nil
}
