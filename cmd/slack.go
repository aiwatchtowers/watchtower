package cmd

import (
	"context"
	"fmt"
	"io"
	"log"
	"strconv"

	"watchtower/internal/auth"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/oauthpage"

	watchtowerslack "watchtower/internal/slack"

	"github.com/spf13/cobra"
)

var slackCmd = &cobra.Command{
	Use:   "slack",
	Short: "Slack workspace integration (multiple workspaces supported)",
}

var slackAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Connect a new Slack workspace via OAuth",
	Long: "Runs a browser-based OAuth flow, creates a new slack_accounts row, and\n" +
		"records the resolved team info. Each connected workspace syncs independently.",
	RunE: runSlackAdd,
}

var slackLoginCmd = &cobra.Command{
	Use:   "login",
	Short: "Re-consent (re-authorize) a connected Slack workspace",
	Long: "Runs the OAuth flow again for an existing account and overwrites its token.\n\n" +
		"Without --account, operates on account #1 — the implicit account every\n" +
		"single-account install already has, created on first use if it doesn't exist yet.",
	RunE: runSlackLogin,
}

var slackAccountsCmd = &cobra.Command{
	Use:   "accounts",
	Short: "List connected Slack workspaces",
	RunE:  runSlackAccounts,
}

var slackEnableCmd = &cobra.Command{
	Use:   "enable <account-id>",
	Short: "Resume syncing a Slack workspace",
	Args:  cobra.ExactArgs(1),
	RunE:  runSlackEnable,
}

var slackDisableCmd = &cobra.Command{
	Use:   "disable <account-id>",
	Short: "Pause syncing a Slack workspace (keeps its data)",
	Args:  cobra.ExactArgs(1),
	RunE:  runSlackDisable,
}

var slackRemoveCmd = &cobra.Command{
	Use:   "remove <account-id>",
	Short: "Disconnect a Slack workspace (non-destructive: keeps synced data)",
	Long: "Deletes the account's stored OAuth token and marks it removed so it stops\n" +
		"syncing. Its synced messages, channels, digests, tracks, situations, and\n" +
		"memory are deliberately kept — removal is a soft delete, not a purge.",
	Args: cobra.ExactArgs(1),
	RunE: runSlackRemove,
}

func init() {
	slackLoginCmd.Flags().Bool("no-open", false, "print the authorize URL instead of opening a browser")
	slackLoginCmd.Flags().Bool("app-return", false, "bring the Watchtower app back to the front when done")
	slackLoginCmd.Flags().Int64("account", 0, "existing account id to re-consent (default: account #1, created if it doesn't exist)")

	slackAddCmd.Flags().String("label", "", "display name for this workspace")
	slackAddCmd.Flags().Bool("no-open", false, "print the authorize URL instead of opening a browser")
	slackAddCmd.Flags().Bool("app-return", false, "bring the Watchtower app back to the front when done")

	slackCmd.AddCommand(slackAddCmd)
	slackCmd.AddCommand(slackLoginCmd)
	slackCmd.AddCommand(slackAccountsCmd)
	slackCmd.AddCommand(slackEnableCmd)
	slackCmd.AddCommand(slackDisableCmd)
	slackCmd.AddCommand(slackRemoveCmd)
	rootCmd.AddCommand(slackCmd)
}

// newSlackClientForToken builds a Slack API client from a raw access token.
// It is a package var seam so tests can point identity resolution at an
// httptest server instead of the live Slack API.
var newSlackClientForToken = func(token string) *watchtowerslack.Client {
	return watchtowerslack.NewClient(token)
}

// slackIdentity is the workspace + owner identity resolved from a Slack token.
type slackIdentity struct {
	TeamID     string
	TeamName   string
	TeamDomain string
	UserID     string
}

// resolveSlackIdentity identifies the token's workspace and owner via auth.test
// (required — also validates the token) plus team.info (best-effort — supplies
// the human-readable name/domain). A team.info failure is non-fatal: name and
// domain are cosmetic and fill in on the next successful call.
func resolveSlackIdentity(ctx context.Context, accessToken string) (slackIdentity, error) {
	client := newSlackClientForToken(accessToken)
	authResp, err := client.AuthTest(ctx)
	if err != nil {
		return slackIdentity{}, fmt.Errorf("auth.test: %w", err)
	}
	id := slackIdentity{TeamID: authResp.TeamID, UserID: authResp.UserID}
	if info, infoErr := client.GetTeamInfo(ctx); infoErr == nil && info != nil {
		id.TeamName = info.Name
		id.TeamDomain = info.Domain
		if info.ID != "" {
			id.TeamID = info.ID
		}
	}
	return id, nil
}

// connectSlackAccount records a freshly-obtained access token onto account row
// id: resolves its Slack identity, writes the namespaced current_user_id +
// team info onto the row, saves the per-account token file, and clears any
// prior auth-error state. When isNewRow is true, any failure rolls the row
// back (soft delete) so a failed connect never leaves an un-loginable ghost
// account — mirrors createEmailAccountWithCredentials. Returns the resolved
// identity on success.
//
// A sign-in into another team than the one the account's data belongs to is
// refused before anything is written (checkSlackLoginTeam, #915), and a
// sign-in that brings a moved account back to its home team rewinds its
// search watermark first (rewindMovedSlackAccount).
func connectSlackAccount(ctx context.Context, cfg *config.Config, database *db.DB, id int64, grant *auth.OAuthResult, isNewRow bool, warnOut io.Writer) (slackIdentity, error) {
	accessToken := grant.AccessToken
	identity, err := resolveSlackIdentity(ctx, accessToken)
	if err != nil {
		if isNewRow {
			rollbackSlackAccount(database, id, warnOut)
		}
		return slackIdentity{}, fmt.Errorf("resolving slack identity: %w", err)
	}
	moved, err := checkSlackLoginTeam(database, id, identity, isNewRow)
	if err != nil {
		if isNewRow {
			rollbackSlackAccount(database, id, warnOut)
		}
		return slackIdentity{}, err
	}
	if err := refuseLoginDuringPurge(database, "slack", id); err != nil {
		return slackIdentity{}, err
	}
	// First of the writes, so a failure leaves the row moved and the next
	// sign-in tries again; once the row is home, nothing would.
	if moved {
		rewound, err := rewindMovedSlackAccount(database, id)
		if err != nil {
			return slackIdentity{}, fmt.Errorf("rewinding the search of slack account %d: %w", id, err)
		}
		if !rewound {
			// No stored message older than the watermark to rewind to (or the
			// other team's messages were stored under this account): the days
			// the other team's searches passed over stay missing.
			fmt.Fprintf(warnOut, "warning: slack account %d is back on its workspace, but the next sync may not fetch "+
				"the days it missed; fetch them with `watchtower slack backfill --account %d --from YYYY-MM-DD --to YYYY-MM-DD`\n", id, id)
		}
	}

	namespacedUser := watchtowerslack.Namespace(id, identity.UserID)
	if err := database.UpdateSlackAccountConnection(id, identity.TeamID, identity.TeamName, identity.TeamDomain, namespacedUser); err != nil {
		if isNewRow {
			rollbackSlackAccount(database, id, warnOut)
		}
		return slackIdentity{}, fmt.Errorf("recording connection: %w", err)
	}

	store := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id)
	if err := store.Save(&watchtowerslack.Token{
		AccessToken: accessToken,
		TeamID:      identity.TeamID,
		TeamName:    identity.TeamName,
		UserID:      identity.UserID,
		Scope:       grant.Scope,
	}); err != nil {
		if isNewRow {
			rollbackSlackAccount(database, id, warnOut)
		}
		return slackIdentity{}, fmt.Errorf("saving token: %w", err)
	}

	if err := database.SetSlackAccountAuthState(id, "ok", ""); err != nil {
		fmt.Fprintf(warnOut, "warning: failed to record auth state: %v\n", err)
	}
	if grant.Scope != "" && !(&watchtowerslack.Token{Scope: grant.Scope}).HasScope(watchtowerslack.SendScope) {
		// Signing in again will not change this: the Slack app (or the
		// workspace admin) does not allow the send permission yet.
		fmt.Fprintf(warnOut, "warning: Slack did not grant %s, so sending from the assistant will not work for this "+
			"workspace; the Slack app's user scopes (or the workspace admin) must allow it first\n", watchtowerslack.SendScope)
	}
	return identity, nil
}

// checkSlackLoginTeam decides whether a sign-in as identity may be recorded
// on account id. It refuses a team other than the home team of the account's
// stored data (db.SlackAccountHomeTeam) — re-consenting with it would mix two
// teams under one "<id>:" namespace — and, for a row a command just created
// (`slack add`), a team another live account already holds. An account with
// no team yet accepts any team. moved reports that the row had been moved to
// another team (a Re-login before #915) and this sign-in brings it home.
func checkSlackLoginTeam(database *db.DB, id int64, identity slackIdentity, isNewRow bool) (moved bool, err error) {
	acct, err := database.GetSlackAccount(id)
	if err != nil {
		return false, err
	}
	home, err := database.SlackAccountHomeTeam(acct)
	if err != nil {
		return false, err
	}
	if home.Conflicts(identity.TeamID) {
		return false, slackOtherTeamError(identity, home)
	}
	if isNewRow {
		return false, refuseDuplicateSlackTeam(database, id, identity)
	}
	return acct.TeamID != "" && acct.TeamID != identity.TeamID, nil
}

// slackOtherTeamError is checkSlackLoginTeam's refusal, actionable part first
// and short: the Desktop shows only the first 200 characters of stderr under
// "Re-login failed".
func slackOtherTeamError(identity slackIdentity, home db.SlackHomeTeam) error {
	got := identity.TeamName
	if got == "" {
		got = identity.TeamID
	}
	return fmt.Errorf("sign in to %q, this account's Slack workspace (you chose %q); "+
		"to also connect the one you chose, use Add Slack Workspace (`watchtower slack add`)", home.DisplayName(), got)
}

// refuseDuplicateSlackTeam refuses a new account for a team another live
// (not removed) account already holds: both would sync the same team. It
// compares home teams, so the other team a moved account #1 was signed in to
// can still be added.
func refuseDuplicateSlackTeam(database *db.DB, id int64, identity slackIdentity) error {
	accounts, err := database.ListSlackAccounts()
	if err != nil {
		return err
	}
	for _, a := range accounts {
		if a.ID == id || a.Status == "removed" {
			continue
		}
		home, err := database.SlackAccountHomeTeam(a)
		if err != nil {
			return err
		}
		if home.ID != "" && home.ID == identity.TeamID {
			return fmt.Errorf("slack workspace %q is already connected as account %d; use Re-login on it instead",
				home.DisplayName(), a.ID)
		}
	}
	return nil
}

// rewindMovedSlackAccount moves a repaired account's search watermark back to
// the day of its newest stored message when that is earlier, so the next
// search sync fetches the days the wrong team's empty searches marked as done.
// The search window clamps a gap over 30 days and records it on the account.
// An account with no stored message or no watermark is left as it is.
// rewound reports that the next sync searches the missed days: the watermark
// moved back, or there is none (a first sync). It is false when nothing older
// than the watermark is stored to rewind to — no message at all, or the other
// team's messages stored under the account after its move.
func rewindMovedSlackAccount(database *db.DB, id int64) (rewound bool, err error) {
	current, err := database.GetSlackAccountSearchWatermark(id)
	if err != nil || current == "" {
		return err == nil, err
	}
	newest, ok, err := database.LatestSlackMessageTime(id)
	if err != nil || !ok {
		return false, err
	}
	day := newest.Format("2006-01-02")
	if day >= current {
		return false, nil
	}
	return true, database.SetSlackAccountSearchWatermark(id, day)
}

// rollbackSlackAccount soft-removes a row a command just created after its
// connect failed. There is deliberately no DeleteSlackAccount (accounts are
// never hard-deleted in v1 — see the plan's non-destructive decision), so the
// rollback marks the row removed/disabled: it stops syncing and drops out of
// the enabled set, achieving the goal (no un-loginable ghost account that
// still looks connected) without a hard delete. Best-effort.
func rollbackSlackAccount(database *db.DB, id int64, warnOut io.Writer) {
	if err := database.SetSlackAccountRemoved(id); err != nil {
		fmt.Fprintf(warnOut, "warning: failed to roll back orphaned slack account %d: %v\n", id, err)
	}
}

// openSlackCmdDB is the shared preamble for the slack subcommands: loads
// config, applies the --workspace override, validates the workspace, and opens
// the database. The caller is responsible for closing the returned DB.
func openSlackCmdDB() (*config.Config, *db.DB, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, nil, fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, nil, err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, nil, fmt.Errorf("opening database: %w", err)
	}
	return cfg, database, nil
}

func runSlackAdd(cmd *cobra.Command, _ []string) error {
	cfg, database, err := openSlackCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()

	label, _ := cmd.Flags().GetString("label")
	logger := log.New(cmd.ErrOrStderr(), "[slack] ", log.LstdFlags)

	// Seed account #1 from a pre-multi-account legacy config token, if one
	// exists and no account row does yet — closes the narrow window where an
	// onboarding entry point could call `slack add` before the daemon/CLI has
	// ever run the same seed, creating a duplicate for the same login. This
	// only SEEDS legacy state; `add` always creates a NEW account below.
	if _, err := ensureLegacySlackAccount(cmd.Context(), cfg, database, logger); err != nil {
		logger.Printf("failed to seed legacy account: %v", err)
	}

	noOpen, _ := cmd.Flags().GetBool("no-open")
	appReturn, _ := cmd.Flags().GetBool("app-return")
	out := cmd.OutOrStdout()
	result, err := slackOAuthLogin(cmd, noOpen, appReturn)
	if err != nil {
		return err
	}

	id, err := database.CreateSlackAccount(db.SlackAccount{Label: label})
	if err != nil {
		return fmt.Errorf("creating account: %w", err)
	}

	identity, err := connectSlackAccount(cmd.Context(), cfg, database, id, result, true, cmd.ErrOrStderr())
	if err != nil {
		return err
	}

	printSlackConnectionResult(out, id, identity)
	return nil
}

func runSlackLogin(cmd *cobra.Command, _ []string) error {
	cfg, database, err := openSlackCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()

	accountFlag, _ := cmd.Flags().GetInt64("account")
	logger := log.New(cmd.ErrOrStderr(), "[slack] ", log.LstdFlags)

	var accountID int64
	isNewRow := false
	if accountFlag != 0 {
		if _, err := database.GetSlackAccount(accountFlag); err != nil {
			return fmt.Errorf("account %d not found: %w", accountFlag, err)
		}
		accountID = accountFlag
	} else {
		accountID, isNewRow, err = resolveSlackAccountOneForLogin(cmd, cfg, database, logger)
		if err != nil {
			return err
		}
	}

	noOpen, _ := cmd.Flags().GetBool("no-open")
	appReturn, _ := cmd.Flags().GetBool("app-return")
	out := cmd.OutOrStdout()
	result, err := slackOAuthLogin(cmd, noOpen, appReturn)
	if err != nil {
		if isNewRow {
			rollbackSlackAccount(database, accountID, cmd.ErrOrStderr())
		}
		return err
	}

	identity, err := connectSlackAccount(cmd.Context(), cfg, database, accountID, result, isNewRow, cmd.ErrOrStderr())
	if err != nil {
		return err
	}

	printSlackConnectionResult(out, accountID, identity)
	return nil
}

func runSlackAccounts(cmd *cobra.Command, _ []string) error {
	_, database, err := openSlackCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()

	accounts, err := database.ListSlackAccounts()
	if err != nil {
		return fmt.Errorf("listing accounts: %w", err)
	}

	out := cmd.OutOrStdout()
	if len(accounts) == 0 {
		fmt.Fprintln(out, "No Slack accounts connected.")
		fmt.Fprintln(out, "Run 'watchtower slack add' to connect one.")
		return nil
	}
	printSlackAccounts(out, accounts)
	return nil
}

// printSlackAccounts writes one line per account. An ok account can still
// carry a note in its error column (the search catch-up gap: messages beyond
// the cap were not fetched), printed under its line so it is not lost.
func printSlackAccounts(out io.Writer, accounts []db.SlackAccount) {
	for _, a := range accounts {
		state := "enabled"
		if !a.Enabled {
			state = "disabled"
		}
		fmt.Fprintf(out, "#%d %s %s [%s]\n", a.ID, slackAccountDisplayName(a), a.Status, state)
		if a.Status == "ok" && a.Error != "" {
			fmt.Fprintf(out, "    note: %s\n", a.Error)
		}
	}
}

func runSlackEnable(cmd *cobra.Command, args []string) error {
	return setSlackAccountEnabled(cmd, args[0], true)
}

func runSlackDisable(cmd *cobra.Command, args []string) error {
	return setSlackAccountEnabled(cmd, args[0], false)
}

func setSlackAccountEnabled(cmd *cobra.Command, idArg string, enabled bool) error {
	id, err := strconv.ParseInt(idArg, 10, 64)
	if err != nil {
		return fmt.Errorf("invalid account id %q: %w", idArg, err)
	}
	_, database, err := openSlackCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()

	if enabled {
		acct, err := database.GetSlackAccount(id)
		if err != nil {
			return fmt.Errorf("account %d not found: %w", id, err)
		}
		if acct.Status == "removed" {
			return fmt.Errorf("account %d was removed — run \"slack add\" to reconnect it, enable has no effect on a removed account", id)
		}
	}

	if err := database.SetSlackAccountEnabled(id, enabled); err != nil {
		return fmt.Errorf("updating account: %w", err)
	}
	out := cmd.OutOrStdout()
	if enabled {
		fmt.Fprintf(out, "Account %d enabled.\n", id)
	} else {
		fmt.Fprintf(out, "Account %d disabled.\n", id)
	}
	return nil
}

func runSlackRemove(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid account id %q: %w", args[0], err)
	}
	cfg, database, err := openSlackCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()

	if err := removeSlackAccount(cfg, database, id); err != nil {
		return fmt.Errorf("removing account: %w", err)
	}
	out := cmd.OutOrStdout()
	fmt.Fprintf(out, "Removed account %d. Its synced data was kept.\n", id)
	return nil
}

// removeSlackAccount disconnects account id: deletes its stored OAuth token
// file and marks the row removed/disabled so it stops syncing. Deliberately
// non-destructive — the account's synced messages/channels/digests/tracks/
// situations/memory are kept (SetSlackAccountRemoved, NOT a cascade delete),
// per the plan's v1 decision.
func removeSlackAccount(cfg *config.Config, database *db.DB, id int64) error {
	if _, err := database.GetSlackAccount(id); err != nil {
		return err
	}
	if err := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id).Delete(); err != nil {
		return fmt.Errorf("deleting token file: %w", err)
	}
	return database.SetSlackAccountRemoved(id)
}

// resolveSlackAccountOneForLogin resolves the legacy "account #1" — the single
// implicit account every pre-multi-account install already has — creating it
// if this is the very first Slack login ever. Shared by `slack login` (without
// --account) and the `auth login` alias.
func resolveSlackAccountOneForLogin(cmd *cobra.Command, cfg *config.Config, database *db.DB, logger *log.Logger) (accountID int64, isNewRow bool, err error) {
	id, err := ensureLegacySlackAccount(cmd.Context(), cfg, database, logger)
	if err != nil {
		return 0, false, fmt.Errorf("seeding legacy account: %w", err)
	}
	if id != 0 {
		return id, false, nil
	}
	id, err = database.CreateSlackAccount(db.SlackAccount{})
	if err != nil {
		return 0, false, fmt.Errorf("creating account: %w", err)
	}
	return id, true, nil
}

// slackOAuthLogin runs the browser-based OAuth flow and returns the result.
func slackOAuthLogin(cmd *cobra.Command, noOpen, appReturn bool) (*auth.OAuthResult, error) {
	oauthCfg, err := resolveOAuthConfig()
	if err != nil {
		return nil, err
	}
	result, err := auth.Login(cmd.Context(), oauthCfg, cmd.OutOrStdout(), auth.LoginOptions{SkipBrowserOpen: noOpen, AppReturn: appReturn})
	oauthpage.ReturnAfterLogin(appReturn, err, cmd.ErrOrStderr())
	if err != nil {
		return nil, fmt.Errorf("oauth login: %w", err)
	}
	return result, nil
}

func printSlackConnectionResult(out io.Writer, id int64, identity slackIdentity) {
	fmt.Fprintln(out)
	name := identity.TeamName
	if name == "" {
		name = identity.TeamID
	}
	fmt.Fprintf(out, "Connected Slack workspace %q (team: %s, user: %s)\n", name, identity.TeamID, identity.UserID)
	fmt.Fprintf(out, "Account id: %d\n", id)
	fmt.Fprintf(out, "Run 'watchtower sync' to start syncing.\n")
}

func slackAccountDisplayName(a db.SlackAccount) string {
	if a.Label != "" {
		return a.Label
	}
	if a.TeamName != "" {
		return a.TeamName
	}
	if a.TeamID != "" {
		return a.TeamID
	}
	return "(unnamed)"
}
