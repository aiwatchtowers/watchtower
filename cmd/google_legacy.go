package cmd

import (
	"context"
	"log"
	"os"

	"watchtower/internal/calendar"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gmail"
)

// ensureLegacyGoogleAccount seeds google_accounts from a pre-multi-account
// single-user Google connection (google_token.json for Calendar,
// gmail_token.json for Gmail — both produced by the same `google login`
// consent flow). It migrates the calendar legacy token file in place to
// become the new account's shared google_token_<id>.json (calendar and
// gmail token stores resolve to the same path for a given account ID), so
// wireGoogleSyncers picks it up without a re-login. A no-op once any
// google_accounts row exists — the returned ID is then the first row's, the
// stable "legacy" account this workspace has always used.
//
// Task 7 extends this with an email lookup once the account is seeded.
func ensureLegacyGoogleAccount(_ context.Context, cfg *config.Config, database *db.DB, logger *log.Logger) (int64, error) {
	accounts, err := database.ListGoogleAccounts()
	if err != nil {
		return 0, err
	}
	if len(accounts) > 0 {
		return accounts[0].ID, nil
	}

	calStore := calendar.NewTokenStore(cfg.WorkspaceDir())
	if !calStore.Exists() {
		return 0, nil
	}
	gmStore := gmail.NewTokenStore(cfg.WorkspaceDir())
	gmailEnabled := gmStore.Exists()

	id, err := database.CreateGoogleAccount(db.GoogleAccount{
		CalendarEnabled: true,
		GmailEnabled:    gmailEnabled,
	})
	if err != nil {
		return 0, err
	}

	accountStore := calendar.NewAccountTokenStore(cfg.WorkspaceDir(), id)
	if err := os.Rename(calStore.Path(), accountStore.Path()); err != nil {
		logger.Printf("google: failed to migrate legacy calendar token: %v", err)
		return id, err
	}
	if gmailEnabled {
		if err := gmStore.Delete(); err != nil {
			logger.Printf("google: failed to remove legacy gmail token: %v", err)
		}
	}
	return id, nil
}
