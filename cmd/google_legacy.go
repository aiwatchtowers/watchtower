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
// gmail_token.json for Gmail — either or both may exist, since a legacy
// install could have connected just one service via `google login
// --calendar`/`--gmail` alone). It migrates whichever legacy token file(s)
// exist in place to become the new account's shared google_token_<id>.json
// (calendar and gmail token stores resolve to the same path for a given
// account ID), so wireGoogleSyncers picks it up without a re-login. A no-op
// once any google_accounts row exists — the returned ID is then the first
// row's, the stable "legacy" account this workspace has always used. Also a
// no-op, returning (0, nil), when neither legacy token file is present.
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
	gmStore := gmail.NewTokenStore(cfg.WorkspaceDir())
	calExists := calStore.Exists()
	gmExists := gmStore.Exists()
	if !calExists && !gmExists {
		return 0, nil
	}

	id, err := database.CreateGoogleAccount(db.GoogleAccount{
		CalendarEnabled: calExists,
		GmailEnabled:    gmExists,
	})
	if err != nil {
		return 0, err
	}

	// Materialize the shared per-account token file from whichever legacy
	// file exists — calendar's wins when both are present (same OAuth
	// grant; the other is then a redundant copy and gets deleted).
	accountStore := calendar.NewAccountTokenStore(cfg.WorkspaceDir(), id)
	if calExists {
		if err := os.Rename(calStore.Path(), accountStore.Path()); err != nil {
			logger.Printf("google: failed to migrate legacy calendar token: %v", err)
			return id, err
		}
		if gmExists {
			if err := gmStore.Delete(); err != nil {
				logger.Printf("google: failed to remove legacy gmail token: %v", err)
			}
		}
	} else {
		if err := os.Rename(gmStore.Path(), accountStore.Path()); err != nil {
			logger.Printf("google: failed to migrate legacy gmail token: %v", err)
			return id, err
		}
	}
	return id, nil
}
