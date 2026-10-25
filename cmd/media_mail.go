package cmd

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"sync"

	"watchtower/internal/calendar"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gmail"
	"watchtower/internal/imap"
	"watchtower/internal/media"
)

// gmailMediaOpener opens Gmail image parts for the media pass through one
// client per account, built on first use from the account's token file
// (the wireGoogleSyncers path) and kept for the daemon's life. An account
// with Gmail off, revoked or signed out opens nothing (media.ErrSourceOff:
// the row waits); a removed account is media.ErrGone.
func gmailMediaOpener(cfg *config.Config, database *db.DB) media.GmailOpener {
	var mu sync.Mutex
	clients := map[int64]*gmail.Client{}
	return media.GmailOpener{Client: func(ctx context.Context, accountID int64) (media.GmailImageSource, error) {
		acct, err := database.GetGoogleAccount(accountID)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, media.ErrGone
		}
		if err != nil {
			return nil, fmt.Errorf("gmail account %d: %w", accountID, err)
		}
		if !cfg.Gmail.Enabled || !acct.GmailEnabled || acct.Status == "revoked" {
			return nil, media.ErrSourceOff
		}
		mu.Lock()
		defer mu.Unlock()
		if c := clients[accountID]; c != nil {
			return c, nil
		}
		store := calendar.NewAccountTokenStore(cfg.WorkspaceDir(), accountID)
		if !store.Exists() {
			return nil, media.ErrSourceOff // signed out: waits for a re-login
		}
		token, err := store.Load()
		if err != nil {
			return nil, fmt.Errorf("gmail account %d: loading token: %w", accountID, err)
		}
		googleCfg := resolveGoogleOAuthConfigForAccount(cfg.WorkspaceDir(), accountID)
		c, err := newGmailClient(ctx, token.RefreshToken,
			gmail.GoogleOAuthConfig{ClientID: googleCfg.ClientID, ClientSecret: googleCfg.ClientSecret})
		if errors.Is(err, gmail.ErrAuthRevoked) {
			return nil, media.ErrSourceOff
		}
		if err != nil {
			return nil, fmt.Errorf("gmail account %d: %w", accountID, err)
		}
		clients[accountID] = c
		return c, nil
	}}
}

// imapMediaOpener opens IMAP image parts for the media pass: each open
// dials the account afresh with its stored settings and credentials (a
// failed login records the account's auth state, as the syncer's does). A
// removed account is media.ErrGone; unusable credentials media.ErrSourceOff.
func imapMediaOpener(cfg *config.Config, database *db.DB, logger *log.Logger) media.IMAPOpener {
	return media.IMAPOpener{Dial: func(_ context.Context, accountID int64) (media.IMAPMessageSource, uint32, error) {
		acct, err := database.GetEmailAccount(accountID)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, 0, media.ErrGone
		}
		if err != nil {
			return nil, 0, fmt.Errorf("imap account %d: %w", accountID, err)
		}
		accountCfg, auth := imapAccountAuth(cfg, database, acct, logger)
		if auth == nil {
			return nil, 0, media.ErrSourceOff // credentials unusable: waits for a re-login
		}
		c, validity, err := imap.Dial(accountCfg, auth)
		if err != nil {
			return nil, 0, err
		}
		return c, validity, nil
	}}
}
