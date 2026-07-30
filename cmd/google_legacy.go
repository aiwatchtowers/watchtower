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
// exist in place to become the first account's shared google_token_<id>.json
// (calendar and gmail token stores resolve to the same path for a given
// account ID), so wireGoogleSyncers picks it up without a re-login.
//
// The migration guard is file existence, not row existence: migration 00043
// itself seeds account #1's row (from calendar_calendars/gmail_messages
// evidence) whenever a real upgrading install has legacy Google data, so by
// the time this Go step runs the row usually already exists — only the
// token-file rename is still outstanding, since SQL can't touch files. A
// row-existence guard would make that rename unreachable forever for every
// such install; keying on "does this account already own a
// google_token_<id>.json" instead makes the step naturally retry-able too —
// if a previous rename attempt failed partway (e.g. permission error), a
// later call sees the account file still missing and tries again.
//
// A DB that never had any Google connection (no row, no legacy token file)
// is a no-op returning (0, nil). Once a row exists (seeded by the migration,
// created here, or created by any other caller), it's returned regardless of
// whether a rename happened — the "legacy" account this workspace has always
// used.
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

	calStore := calendar.NewTokenStore(cfg.WorkspaceDir())
	gmStore := gmail.NewTokenStore(cfg.WorkspaceDir())
	calExists := calStore.Exists()
	gmExists := gmStore.Exists()

	var id int64
	if len(accounts) > 0 {
		id = accounts[0].ID
	} else {
		if !calExists && !gmExists {
			return 0, nil
		}
		id, err = database.CreateGoogleAccount(db.GoogleAccount{
			CalendarEnabled: calExists,
			GmailEnabled:    gmExists,
		})
		if err != nil {
			return 0, err
		}
	}

	// Materialize the shared per-account token file from whichever legacy
	// file exists — calendar's wins when both are present (same OAuth
	// grant; the other is then a redundant copy and gets deleted). Skipped
	// once the account already owns its token file (nothing left to
	// migrate) or no legacy file remains.
	accountStore := calendar.NewAccountTokenStore(cfg.WorkspaceDir(), id)
	if !accountStore.Exists() && (calExists || gmExists) {
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
