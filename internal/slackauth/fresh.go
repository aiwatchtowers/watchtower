// Package slackauth keeps Slack user tokens fresh: every token reader goes
// through LoadFresh, which refreshes a rotated token under the account's
// per-account flock (slack.TokenStore.Lock) and repairs an account row whose
// app ids lag behind its token file.
package slackauth

import (
	"context"
	"errors"
	"fmt"
	"log"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/slack"
)

// refreshAhead refreshes an access token this long before it expires.
// Plan B Task 16 adjusts it from the spike (Q9).
var refreshAhead = time.Hour

// refreshTokenAhead refreshes while the refresh token itself has this long
// left, so a Mac that syncs rarely never lets it lapse (parent spec §5.5).
var refreshTokenAhead = 7 * 24 * time.Hour

// slackAccessTokenDefaultTTL is a new access token's lifetime when Slack's
// answer does not state it: 12 hours (the spike saw expires_in=43200).
const slackAccessTokenDefaultTTL = 12 * time.Hour

// slackRefreshTokenDefaultTTL is a rotated refresh token's lifetime when
// Slack's answer does not state it: 30 days for an app with PKCE on (the
// plan B spike, Task 1). Task 16 confirms it.
const slackRefreshTokenDefaultTTL = 30 * 24 * time.Hour

// lockWait bounds the wait for another process's refresh — the one-minute
// wait of the other token writers.
const lockWait = time.Minute

// ReloginMessage is the account row's error once the refresh token is dead:
// the existing Re-login state.
const ReloginMessage = "Sign in again: the Slack sign-in expired"

// ErrReloginNeeded is returned when Slack refused the refresh token: only a
// new sign-in brings the account back.
var ErrReloginNeeded = errors.New("slack: the sign-in expired; sign in again")

// LoadFresh returns accountID's token, refreshed first when it rotates and
// is due (refreshDue). A token without a refresh token is returned as is (no
// rotation: the retired shared app, a company app without rotation, old
// files); a missing file is (nil, nil), as TokenStore.Load. The refresh and
// the row repair run under the account's flock and re-read the file there, so
// a second process that waited for the lock uses the token the first one
// saved instead of spending the old refresh token again.
func LoadFresh(ctx context.Context, workspaceDir string, database *db.DB, accountID int64, refresh Refresher, now func() time.Time) (*slack.Token, error) {
	if now == nil {
		now = time.Now
	}
	store := slack.NewTokenStore(workspaceDir, accountID)
	tok, err := store.Load()
	if err != nil || tok == nil {
		return tok, err
	}
	row, err := database.GetSlackAccount(accountID)
	if err != nil {
		return nil, err
	}
	if !rowNeedsRepair(row, tok) && !refreshDue(tok, now()) {
		return tok, nil
	}
	return freshLocked(ctx, store, database, accountID, refresh, now)
}

// freshLocked is LoadFresh's slow path: under the lock it re-reads the file
// and the row, repairs the row, and refreshes if the token is still due.
func freshLocked(ctx context.Context, store *slack.TokenStore, database *db.DB, accountID int64, refresh Refresher, now func() time.Time) (*slack.Token, error) {
	lockCtx, cancel := context.WithTimeout(ctx, lockWait)
	defer cancel()
	unlock, err := store.Lock(lockCtx)
	if err != nil {
		return nil, err
	}
	defer unlock()

	tok, err := store.Load()
	if err != nil || tok == nil {
		return tok, err
	}
	row, err := database.GetSlackAccount(accountID)
	if err != nil {
		return nil, err
	}
	if err := repairRow(database, row, tok); err != nil {
		return nil, err
	}
	at := now()
	if !refreshDue(tok, at) {
		return tok, nil
	}
	clientID := tok.ClientID
	if clientID == "" {
		clientID = row.ClientID
	}
	if clientID == "" {
		// Nothing to refresh with; the token is used as is until it fails.
		return tok, nil
	}
	// Slack rotates the refresh token on use: once it answers, only the new
	// one works, so a cancel of the caller (Sync Now, a sleep, Ctrl-C) must
	// not drop the answer before it is saved. The caller's ctx bounded only
	// the lock wait; the refresh and the save run to the end.
	// The lock can be taken after the caller gave up: start nothing then.
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	refreshCtx, cancelRefresh := context.WithTimeout(context.WithoutCancel(ctx), refreshTimeout)
	defer cancelRefresh()
	got, err := refresh(refreshCtx, clientID, tok.RefreshToken)
	if err != nil {
		if IsReloginError(err) {
			if dbErr := database.SetSlackAccountAuthState(accountID, "error", ReloginMessage); dbErr != nil {
				return nil, errors.Join(fmt.Errorf("%w: %w", ErrReloginNeeded, err), dbErr)
			}
			return nil, fmt.Errorf("%w: %w", ErrReloginNeeded, err)
		}
		return nil, fmt.Errorf("refreshing slack account %d: %w", accountID, err)
	}
	next := refreshedToken(tok, got, clientID, at)
	save := func() error {
		if saveFault != nil {
			if err := saveFault(); err != nil {
				return err
			}
		}
		return store.Save(next)
	}
	if err := save(); err != nil {
		// One more try: the old file's refresh token is likely spent.
		if retryErr := save(); retryErr != nil {
			log.Printf("slack account %d: the rotated token was not persisted: %v", accountID, retryErr)
			return nil, fmt.Errorf("saving the refreshed slack token of account %d: %w", accountID, errors.Join(err, retryErr))
		}
	}
	// The file is the truth; a stale column is only a display lag.
	if err := database.SetSlackRefreshExpiry(accountID, next.RefreshExpiresAt); err != nil {
		log.Printf("slack account %d: recording the refresh token's expiry: %v", accountID, err)
	}
	return next, nil
}

// saveFault, a test seam, fails a save of a refreshed token before it is
// written; nil outside tests.
var saveFault func() error

// refreshedToken is tok after Slack's refresh answer got at at. An expiry
// Slack did not state is kept from tok — except for a new token: a new access
// token gets slackAccessTokenDefaultTTL, a new refresh token
// slackRefreshTokenDefaultTTL.
func refreshedToken(tok *slack.Token, got Refreshed, clientID string, at time.Time) *slack.Token {
	next := *tok
	next.AccessToken = got.AccessToken
	switch {
	case got.ExpiresIn > 0:
		next.ExpiresAt = at.Add(time.Duration(got.ExpiresIn) * time.Second).UTC()
	case got.AccessToken != tok.AccessToken:
		// A new token never inherits the old one's (near or past) expiry,
		// which would rotate it again on every read.
		next.ExpiresAt = at.Add(slackAccessTokenDefaultTTL).UTC()
	}
	rotatedRefresh := got.RefreshToken != "" && got.RefreshToken != tok.RefreshToken
	if rotatedRefresh {
		next.RefreshToken = got.RefreshToken
	}
	switch {
	case got.RefreshExpiresIn > 0:
		next.RefreshExpiresAt = at.Add(time.Duration(got.RefreshExpiresIn) * time.Second).UTC()
	case rotatedRefresh:
		next.RefreshExpiresAt = at.Add(slackRefreshTokenDefaultTTL).UTC()
	}
	if next.ClientID == "" {
		next.ClientID = clientID
	}
	return &next
}

// refreshDue reports whether a rotated token must be refreshed at now: the
// access token has less than refreshAhead left, or the refresh token less
// than refreshTokenAhead. An unknown (zero) expiry is never due.
func refreshDue(tok *slack.Token, now time.Time) bool {
	if tok.RefreshToken == "" {
		return false
	}
	if !tok.ExpiresAt.IsZero() && tok.ExpiresAt.Sub(now) < refreshAhead {
		return true
	}
	return !tok.RefreshExpiresAt.IsZero() && tok.RefreshExpiresAt.Sub(now) < refreshTokenAhead
}

// rowNeedsRepair reports whether the token file names an app the row does
// not (the crash window between a connect's token save and its row update,
// A6). Only non-empty file values count: files written before client and app
// ids were recorded carry none, and an empty value never overwrites the row.
func rowNeedsRepair(row db.SlackAccount, tok *slack.Token) bool {
	if tok.ClientID != "" && tok.ClientID != row.ClientID {
		return true
	}
	return tok.AppID != "" && tok.ClientID == row.ClientID && tok.AppID != row.AppID
}

// repairRow copies the token file's non-empty client and app ids onto the
// row when they differ (rowNeedsRepair); the file is the truth (A6).
func repairRow(database *db.DB, row db.SlackAccount, tok *slack.Token) error {
	if !rowNeedsRepair(row, tok) {
		return nil
	}
	clientID := tok.ClientID
	if clientID == "" {
		clientID = row.ClientID
	}
	if tok.AppID != "" {
		return database.SetSlackAccountApp(row.ID, clientID, tok.AppID)
	}
	return database.SetSlackAccountClientID(row.ID, clientID)
}
