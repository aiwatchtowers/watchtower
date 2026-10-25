package cmd

import (
	"context"
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
// with Gmail off opens nothing.
func gmailMediaOpener(cfg *config.Config, database *db.DB) media.GmailOpener {
	var mu sync.Mutex
	clients := map[int64]*gmail.Client{}
	return media.GmailOpener{Client: func(ctx context.Context, accountID int64) (media.GmailImageSource, error) {
		acct, err := database.GetGoogleAccount(accountID)
		if err != nil {
			return nil, fmt.Errorf("gmail account %d: %w", accountID, err)
		}
		if !cfg.Gmail.Enabled || !acct.GmailEnabled {
			return nil, fmt.Errorf("gmail account %d: gmail is off", accountID)
		}
		mu.Lock()
		defer mu.Unlock()
		if c := clients[accountID]; c != nil {
			return c, nil
		}
		token, err := calendar.NewAccountTokenStore(cfg.WorkspaceDir(), accountID).Load()
		if err != nil {
			return nil, fmt.Errorf("gmail account %d: loading token: %w", accountID, err)
		}
		googleCfg := resolveGoogleOAuthConfigForAccount(cfg.WorkspaceDir(), accountID)
		c, err := newGmailClient(ctx, token.RefreshToken,
			gmail.GoogleOAuthConfig{ClientID: googleCfg.ClientID, ClientSecret: googleCfg.ClientSecret})
		if err != nil {
			return nil, fmt.Errorf("gmail account %d: %w", accountID, err)
		}
		clients[accountID] = c
		return c, nil
	}}
}

// imapMediaOpener opens IMAP image parts for the media pass: each open
// dials the account afresh with its stored settings and credentials.
func imapMediaOpener(cfg *config.Config, database *db.DB, logger *log.Logger) media.IMAPOpener {
	return media.IMAPOpener{Dial: func(_ context.Context, accountID int64) (media.IMAPMessageSource, uint32, error) {
		acct, err := database.GetEmailAccount(accountID)
		if err != nil {
			return nil, 0, fmt.Errorf("imap account %d: %w", accountID, err)
		}
		accountCfg, auth := imapAccountAuth(cfg, database, acct, logger)
		if auth == nil {
			return nil, 0, fmt.Errorf("imap account %d: no usable credentials", accountID)
		}
		c, validity, err := imap.Dial(accountCfg, auth)
		if err != nil {
			return nil, 0, err
		}
		return c, validity, nil
	}}
}
