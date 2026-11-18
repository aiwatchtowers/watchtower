package slackmode

import (
	"fmt"

	"watchtower/internal/auth"
	"watchtower/internal/db"
)

// Relogin values of `slack accounts --json`: how an account signs in again.
const (
	// ReloginBuiltin signs in again through the build's own Slack app.
	ReloginBuiltin = "builtin"
	// ReloginConnect signs in again through the connect flow (PKCE) with
	// the account's client id.
	ReloginConnect = "connect"
	// ReloginMove means the account is on the retired shared app and no
	// build signs in through it any more: it moves to Full instead.
	ReloginMove = "move"
)

// SharedApp reports whether account a is on the retired public shared Slack
// app. It is the one rule (ask #1425), with no build-flavor input: the
// retired id is shared, every other client id (a workspace app made by
// setup, an MDM or link id, a company app a build bakes) is a company app.
// An empty retiredID means nothing is shared.
func SharedApp(a db.SlackAccount, retiredID string) bool {
	return retiredID != "" && a.ClientID == retiredID
}

// Relogin says how account a signs in again, first match wins (review
// #1439): the retired shared id signs in through the build's app while the
// build still has that app, else it moves (never connect: the retired app
// has no loopback redirect, so PKCE would fail); an empty client id or the
// build's own id signs in through the build's app; any other id connects.
// builtinID is the client id of auth.BuiltinApp when it is ok, else "".
func Relogin(a db.SlackAccount, retiredID, builtinID string) string {
	switch {
	case retiredID != "" && a.ClientID == retiredID:
		if builtinID == retiredID {
			return ReloginBuiltin
		}
		return ReloginMove
	case a.ClientID == "" || a.ClientID == builtinID:
		return ReloginBuiltin
	default:
		return ReloginConnect
	}
}

// BackfillSource is the client id that accounts without one (connected
// before migration 00196) are given (A17): the build's baked or env client
// id, else auth.RetiredSharedClientID, else "" (no backfill).
func BackfillSource() string {
	if cfg, _ := auth.BuiltinApp(); cfg.ClientID != "" {
		return cfg.ClientID
	}
	return auth.RetiredSharedClientID
}

// BackfillClientIDs runs the A17 backfill from BackfillSource and returns how
// many rows it filled; with no source it writes nothing. Callers: `slack
// accounts`, the daemon's start and every connect.
func BackfillClientIDs(d *db.DB) (int64, error) {
	src := BackfillSource()
	if src == "" {
		return 0, nil
	}
	n, err := d.BackfillSlackClientIDs(src)
	if err != nil {
		return 0, fmt.Errorf("slack client id backfill: %w", err)
	}
	return n, nil
}
