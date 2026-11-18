// Package slackauth keeps Slack user tokens fresh: every token reader goes
// through LoadFresh, which refreshes a rotated token under the account's
// per-account flock (slack.TokenStore.Lock) and repairs an account row whose
// app ids lag behind its token file.
package slackauth

import (
	"context"
	"errors"
	"fmt"
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
	got, err := refresh(ctx, clientID, tok.RefreshToken)
	if err != nil {
		if IsReloginError(err) {
			if dbErr := database.SetSlackAccountAuthState(accountID, "error", ReloginMessage); dbErr != nil {
				return nil, errors.Join(fmt.Errorf("%w: %w", ErrReloginNeeded, err), dbErr)
			}
			return nil, fmt.Errorf("%w: %w", ErrReloginNeeded, err)
		}
		return nil, fmt.Errorf("refreshing slack account %d: %w", accountID, err)
	}
	next := *tok
	next.AccessToken = got.AccessToken
	if got.RefreshToken != "" {
		next.RefreshToken = got.RefreshToken
	}
	next.ExpiresAt = time.Time{}
	if got.ExpiresIn > 0 {
		next.ExpiresAt = at.Add(time.Duration(got.ExpiresIn) * time.Second).UTC()
	}
	next.RefreshExpiresAt = time.Time{}
	if got.RefreshExpiresIn > 0 {
		next.RefreshExpiresAt = at.Add(time.Duration(got.RefreshExpiresIn) * time.Second).UTC()
	}
	if next.ClientID == "" {
		next.ClientID = clientID
	}
	if err := store.Save(&next); err != nil {
		return nil, fmt.Errorf("saving the refreshed slack token of account %d: %w", accountID, err)
	}
	if err := database.SetSlackRefreshExpiry(accountID, next.RefreshExpiresAt); err != nil {
		return nil, err
	}
	return &next, nil
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
