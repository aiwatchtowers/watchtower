package cmd

import (
	"fmt"
	"log"
	"os"
	"path/filepath"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// ensureLegacyJiraAccount migrates a pre-multi-account Jira install into
// jira_accounts row #1: it moves the legacy jira_token.json to
// jira_token_1.json and lifts the site identity (cloud_id / site_url /
// user_display_name) out of config.yaml onto the row. The config keys are
// left in place but frozen — nothing reads them any more.
//
// The guard is legacy-token-file existence, not row existence (the Google C1
// lesson): migration 00049 seeds row #1 only when synced Jira data exists, so
// a token-only install has a token but no row, while a synced install has a
// row (with empty cloud_id — SQL can't see config) and a token. Keying on the
// file handles both and makes the step naturally retry-able: once the token
// is renamed, the step is a no-op forever.
//
// Returns (0, nil) as a clean no-op for an install that never connected Jira.
// Idempotent — called from daemon sync wiring, `jira add` (seed-then-create),
// and the `jira login`/`jira logout` legacy aliases.
func ensureLegacyJiraAccount(cfg *config.Config, database *db.DB, logger *log.Logger) (int64, error) {
	legacyPath := filepath.Join(cfg.WorkspaceDir(), "jira_token.json")
	if _, err := os.Stat(legacyPath); err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, fmt.Errorf("checking legacy jira token: %w", err)
	}

	accounts, err := database.ListJiraAccounts()
	if err != nil {
		return 0, fmt.Errorf("listing jira accounts: %w", err)
	}

	var acctID int64
	if len(accounts) == 0 {
		// Token-only install: the migration had no synced data to seed from.
		acctID, err = database.CreateJiraAccount(db.JiraAccount{
			CloudID:  cfg.Jira.CloudID,
			SiteURL:  cfg.Jira.SiteURL,
			SiteName: cfg.Jira.UserDisplayName,
		})
		if err != nil {
			return 0, fmt.Errorf("creating legacy jira account: %w", err)
		}
	} else {
		// Synced install: migration 00049 seeded row #1 with empty identity.
		acctID = accounts[0].ID
		if accounts[0].CloudID == "" && cfg.Jira.CloudID != "" {
			if err := database.UpdateJiraAccountConnection(acctID,
				cfg.Jira.CloudID, cfg.Jira.SiteURL, cfg.Jira.UserDisplayName); err != nil {
				return 0, fmt.Errorf("filling legacy jira account identity: %w", err)
			}
		}
	}

	newPath := jira.NewTokenStore(cfg.WorkspaceDir(), acctID).Path()
	if err := os.Rename(legacyPath, newPath); err != nil {
		return 0, fmt.Errorf("moving legacy jira token: %w", err)
	}
	logger.Printf("jira: migrated legacy single-account install to jira_accounts row %d", acctID)
	return acctID, nil
}
