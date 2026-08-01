package cmd

import (
	"context"
	"log"

	"watchtower/internal/config"
	"watchtower/internal/db"

	watchtowerslack "watchtower/internal/slack"

	"github.com/spf13/viper"
)

// ensureLegacySlackAccount seeds slack_accounts from a pre-multi-account
// single-workspace Slack connection, whose token lived in config.yaml
// (workspaces.<ws>.slack_token) rather than a file. It is idempotent and
// safe to call from the daemon sync wiring and every alias command.
//
// Two upgrading shapes land here:
//
//   - Token-only install (config token set, Slack never actually synced):
//     migration 00044 could NOT seed a row (it keys on synced current_user_id/
//     team id, which a token-only install lacks), so slack_accounts is empty.
//     This creates account #1.
//   - Synced install (config token set AND Slack data synced): migration 00044
//     already seeded row #1 from the workspace singleton, but the token is
//     still in config — only Go can move it to a file. This reuses the row.
//
// In BOTH shapes the outstanding work is the same: materialize the per-account
// token file (slack_token_<id>.json) so wireSlackSyncers finds a usable token,
// and blank the now-migrated config key. The guard for that work is token-file
// existence, not row existence — a row-existence guard would make the synced
// install's token migration unreachable forever (the Google C1 lesson), and
// keying on the file makes the step naturally retry-able if a prior attempt
// failed partway.
//
// A DB that never had any Slack connection (empty table, no config token) is a
// clean no-op returning (0, nil). Team info + the namespaced current_user_id
// are resolved best-effort from the token via auth.test/team.info; that step
// needs the network, so an offline call still migrates the token file and just
// leaves team info to fill in on the next online call — it never fails the seed.
func ensureLegacySlackAccount(ctx context.Context, cfg *config.Config, database *db.DB, logger *log.Logger) (int64, error) {
	accounts, err := database.ListSlackAccounts()
	if err != nil {
		return 0, err
	}

	legacyToken := legacySlackConfigToken(cfg)

	var id int64
	if len(accounts) > 0 {
		id = accounts[0].ID
	} else {
		if legacyToken == "" {
			return 0, nil
		}
		id, err = database.CreateSlackAccount(db.SlackAccount{})
		if err != nil {
			return 0, err
		}
	}

	store := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id)
	if store.Exists() || legacyToken == "" {
		// Either the token already migrated (steady state / retry no-op) or
		// there is nothing in config to migrate.
		return id, nil
	}

	// Best-effort identity resolution (network); the token-file migration
	// below must not depend on it.
	identity, resolveErr := resolveSlackIdentity(ctx, legacyToken)

	if err := store.Save(&watchtowerslack.Token{
		AccessToken: legacyToken,
		TeamID:      identity.TeamID,
		TeamName:    identity.TeamName,
		UserID:      identity.UserID,
	}); err != nil {
		// Token file wasn't written -> wireSlackSyncers can't sync this
		// account. Surface the error like Google's rename failure; a later
		// call retries since the file still won't exist.
		logger.Printf("slack: account %d: failed to migrate legacy token: %v", id, err)
		return id, err
	}

	if resolveErr == nil {
		if err := database.UpdateSlackAccountConnection(id, identity.TeamID, identity.TeamName, identity.TeamDomain,
			watchtowerslack.Namespace(id, identity.UserID)); err != nil {
			logger.Printf("slack: account %d: failed to record team info: %v", id, err)
		}
	} else {
		logger.Printf("slack: account %d: failed to resolve team info (will retry): %v", id, resolveErr)
	}

	blankLegacySlackConfigToken(cfg, logger)
	return id, nil
}

// legacySlackConfigToken returns the active workspace's config-embedded Slack
// token, or "" when none is set (or the workspace has no config entry).
func legacySlackConfigToken(cfg *config.Config) string {
	ws, err := cfg.GetActiveWorkspace()
	if err != nil || ws == nil {
		return ""
	}
	return ws.SlackToken
}

// blankLegacySlackConfigToken clears the now-migrated config token so the
// token lives only in slack_token_<id>.json going forward. Best-effort: old
// configs may be read-only, so a failure is logged, never fatal.
func blankLegacySlackConfigToken(cfg *config.Config, logger *log.Logger) {
	if flagConfig == "" {
		return
	}
	v := viper.New()
	v.SetConfigFile(flagConfig)
	if err := v.ReadInConfig(); err != nil {
		logger.Printf("slack: failed to read config to blank legacy token: %v", err)
		return
	}
	key := "workspaces." + cfg.ActiveWorkspace + ".slack_token"
	if v.GetString(key) == "" {
		return
	}
	v.Set(key, "")
	if err := writeConfigAtomic(v, flagConfig); err != nil {
		logger.Printf("slack: failed to blank legacy config token: %v", err)
	}
}
