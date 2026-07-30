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
// Either way, before returning a nonzero id it makes a best-effort attempt to
// fill in the account's email via the Gmail profile API when the row doesn't
// have one yet and Gmail is enabled — legacy installs never persisted an
// email onto anything queryable from google_accounts (it lived in
// gmail.account_email, since retired). Failure there never fails the seed.
func ensureLegacyGoogleAccount(ctx context.Context, cfg *config.Config, database *db.DB, logger *log.Logger) (int64, error) {
	accounts, err := database.ListGoogleAccounts()
	if err != nil {
		return 0, err
	}
	if len(accounts) > 0 {
		fillLegacyAccountEmail(ctx, cfg, database, accounts[0].ID, logger)
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

	fillLegacyAccountEmail(ctx, cfg, database, id, logger)
	return id, nil
}

// googleAccountEmailFetcher resolves accountID's email via the Gmail profile
// API. It is a package var seam so tests can stub out the live network call
// — fetchGoogleAccountEmail is the real, production implementation.
var googleAccountEmailFetcher = fetchGoogleAccountEmail

// fetchGoogleAccountEmail opens a Gmail client with refreshToken and returns
// the authenticated account's email address.
func fetchGoogleAccountEmail(ctx context.Context, workspaceDir string, accountID int64, refreshToken string) (string, error) {
	googleCfg := resolveGoogleOAuthConfigForAccount(workspaceDir, accountID)
	client, err := gmail.NewClient(ctx, refreshToken, gmail.GoogleOAuthConfig{ClientID: googleCfg.ClientID, ClientSecret: googleCfg.ClientSecret})
	if err != nil {
		return "", err
	}
	profile, err := client.GetProfile(ctx)
	if err != nil {
		return "", err
	}
	return profile.EmailAddress, nil
}

// fillLegacyAccountEmail best-effort fills accountID's email when it is
// still blank and Gmail is enabled — a no-op (no network call) once the
// email is already known, Gmail isn't enabled, or no token is on disk yet.
// Never fails the caller: lookup errors are logged and swallowed.
func fillLegacyAccountEmail(ctx context.Context, cfg *config.Config, database *db.DB, id int64, logger *log.Logger) {
	if id == 0 {
		return
	}
	acct, err := database.GetGoogleAccount(id)
	if err != nil || acct.Email != "" || !acct.GmailEnabled {
		return
	}
	token, err := gmail.NewAccountTokenStore(cfg.WorkspaceDir(), id).Load()
	if err != nil || token.RefreshToken == "" {
		return
	}
	email, err := googleAccountEmailFetcher(ctx, cfg.WorkspaceDir(), id, token.RefreshToken)
	if err != nil || email == "" {
		if err != nil {
			logger.Printf("google: account %d: failed to resolve email: %v", id, err)
		}
		return
	}
	if err := database.UpdateGoogleAccountConnection(id, email, acct.CalendarEnabled, acct.GmailEnabled); err != nil {
		logger.Printf("google: account %d: failed to persist resolved email: %v", id, err)
	}
}
