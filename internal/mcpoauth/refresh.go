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
//
// A zero ExpiresAt (the server never told us a lifetime) is treated as
// "must verify, not never expires": with a refresh token present, EnsureFresh
// refreshes on every call rather than handing over a token that could have
// silently expired server-side — QC-04 promises fresh-or-visible, and an
// unknown expiry that never gets checked is neither. Only when there is
// also no refresh token do we fall back to handing the token over
// unverified, because nothing better is possible (documented below).
func EnsureFresh(ctx context.Context, g *externalmcp.OAuthGrant, now time.Time) (changed bool, err error) {
	if g == nil {
		return false, fmt.Errorf("mcpoauth: EnsureFresh called with a nil grant")
	}
	unknownExpiry := g.ExpiresAt.IsZero()
	if !unknownExpiry && !g.Expiring(now, RefreshSkew) {
		return false, nil
	}
	if g.RefreshToken == "" {
		if unknownExpiry {
			// Unknown expiry and nothing to refresh with: hand the token
			// over unverified rather than blocking the caller. This is the
			// one case QC-04 cannot make fresh-or-visible — there is no
			// refresh token to verify against and no expiry to check.
			return false, nil
		}
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
