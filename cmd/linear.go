package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"time"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/linear"
	"watchtower/internal/oauthpage"
)

// resolveLinearOAuthConfig returns the Linear OAuth config: the client id from
// WATCHTOWER_LINEAR_CLIENT_ID, else the built-in public default.
func resolveLinearOAuthConfig() linear.OAuthConfig {
	id := os.Getenv("WATCHTOWER_LINEAR_CLIENT_ID")
	if id == "" {
		id = linear.DefaultLinearClientID
	}
	return linear.OAuthConfig{ClientID: id}
}

var linearFlagAccount int64

var linearCmd = &cobra.Command{
	Use:   "linear",
	Short: "Linear integration (multiple workspaces supported)",
	RunE:  runLinearStatus,
}

var linearAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Connect a new Linear workspace via OAuth",
	RunE:  runLinearAdd,
}

var linearLoginCmd = &cobra.Command{
	Use:   "login",
	Short: "Re-consent (re-authorize) a connected Linear workspace",
	RunE:  runLinearLogin,
}

var linearAccountsCmd = &cobra.Command{
	Use:   "accounts",
	Short: "List connected Linear workspaces",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		_, database, err := openJiraCmdDB()
		if err != nil {
			return err
		}
		defer database.Close()
		asJSON, _ := cmd.Flags().GetBool("json")
		return printLinearAccounts(cmd.OutOrStdout(), database, asJSON)
	},
}

var linearEnableCmd = &cobra.Command{
	Use:   "enable <id>",
	Short: "Enable syncing of a Linear workspace",
	Args:  cobra.ExactArgs(1),
	RunE:  func(cmd *cobra.Command, args []string) error { return setLinearAccountEnabled(cmd, args[0], true) },
}

var linearDisableCmd = &cobra.Command{
	Use:   "disable <id>",
	Short: "Disable syncing of a Linear workspace",
	Args:  cobra.ExactArgs(1),
	RunE:  func(cmd *cobra.Command, args []string) error { return setLinearAccountEnabled(cmd, args[0], false) },
}

var linearRemoveCmd = &cobra.Command{
	Use:   "remove <id>",
	Short: "Disconnect a Linear workspace (token deleted, synced data kept)",
	Args:  cobra.ExactArgs(1),
	RunE:  runLinearRemove,
}

var linearTeamsCmd = &cobra.Command{
	Use:   "teams",
	Short: "List the teams of a Linear workspace and their selection",
	Args:  cobra.NoArgs,
	RunE:  runLinearTeams,
}

var linearTeamsSelectCmd = &cobra.Command{
	Use:   "select <TEAM-KEY>...",
	Short: "Sync the given teams",
	Args:  cobra.MinimumNArgs(1),
	RunE:  func(cmd *cobra.Command, args []string) error { return setLinearTeamsSelected(cmd, args, true) },
}

var linearTeamsDeselectCmd = &cobra.Command{
	Use:   "deselect <TEAM-KEY>...",
	Short: "Stop syncing the given teams",
	Args:  cobra.MinimumNArgs(1),
	RunE:  func(cmd *cobra.Command, args []string) error { return setLinearTeamsSelected(cmd, args, false) },
}

var linearSyncCmd = &cobra.Command{
	Use:   "sync",
	Short: "Sync Linear issues now",
	Args:  cobra.NoArgs,
	RunE:  runLinearSync,
}

var linearStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show Linear workspaces and per-team sync state",
	Args:  cobra.NoArgs,
	RunE:  runLinearStatus,
}

func init() {
	rootCmd.AddCommand(linearCmd)
	linearCmd.AddCommand(linearAddCmd, linearLoginCmd, linearAccountsCmd, linearEnableCmd,
		linearDisableCmd, linearRemoveCmd, linearTeamsCmd, linearSyncCmd, linearStatusCmd)
	linearTeamsCmd.AddCommand(linearTeamsSelectCmd, linearTeamsDeselectCmd)

	linearCmd.PersistentFlags().Int64Var(&linearFlagAccount, "account", 0,
		"Linear account id to operate on (default: the single enabled account)")
	for _, c := range []*cobra.Command{linearAddCmd, linearLoginCmd} {
		c.Flags().Bool("no-open", false, "don't open the browser automatically")
		c.Flags().Bool("app-return", false, "bring the Watchtower app back to the front when done")
	}
	linearAddCmd.Flags().String("label", "", "label for the new account")
	linearAccountsCmd.Flags().Bool("json", false, "output as JSON (for Swift integration)")
	linearTeamsCmd.Flags().Bool("json", false, "output as JSON")
}

func errLinearAccountRemoved(id int64) error {
	return fmt.Errorf("linear account %d was removed; run 'watchtower linear add' to connect it again", id)
}

// resolveLinearAccount resolves --account to a connected account; without it
// the single enabled account is picked. A removed account is always refused.
func resolveLinearAccount(database *db.DB, accountID int64) (db.LinearAccount, error) {
	if accountID > 0 {
		a, err := database.GetLinearAccount(accountID)
		if err != nil {
			return db.LinearAccount{}, err
		}
		if a.Status == "removed" {
			return db.LinearAccount{}, errLinearAccountRemoved(accountID)
		}
		return a, nil
	}
	accounts, err := database.ListEnabledLinearAccounts()
	if err != nil {
		return db.LinearAccount{}, err
	}
	switch len(accounts) {
	case 0:
		return db.LinearAccount{}, errors.New("no Linear workspace connected; run 'watchtower linear add'")
	case 1:
		return accounts[0], nil
	default:
		return db.LinearAccount{}, errors.New("several Linear workspaces are connected; pass --account")
	}
}

func linearAccountDisplayName(a db.LinearAccount) string {
	switch {
	case a.Label != "":
		return a.Label
	case a.OrgName != "":
		return a.OrgName
	case a.URLKey != "":
		return a.URLKey
	default:
		return "(unnamed)"
	}
}

func linearWorkspaceURL(a db.LinearAccount) string {
	if a.URLKey == "" {
		return ""
	}
	return "https://linear.app/" + a.URLKey
}

// enableLinearPhase flips the global linear.enabled daemon-phase switch on.
func enableLinearPhase() error {
	v := viper.New()
	v.SetConfigFile(flagConfig)
	_ = v.ReadInConfig()
	v.Set("linear.enabled", true)
	return writeConfigAtomic(v, flagConfig)
}

// saveLinearTokenLocked saves a freshly consented token under the account's
// cross-process token lock.
func saveLinearTokenLocked(ctx context.Context, store *linear.TokenStore, token *linear.Token) error {
	lockCtx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	unlock, err := store.Lock(lockCtx)
	if err != nil {
		return fmt.Errorf("saving token: %w", err)
	}
	defer unlock()
	if err := store.Save(token); err != nil {
		return fmt.Errorf("saving token: %w", err)
	}
	return nil
}

func linearLoginOptionsFromFlags(cmd *cobra.Command) linear.LoginOptions {
	noOpen, _ := cmd.Flags().GetBool("no-open")
	appReturn, _ := cmd.Flags().GetBool("app-return")
	return linear.LoginOptions{SkipBrowserOpen: noOpen, AppReturn: appReturn}
}

// linearClient builds an API client for the account over its token file.
func linearClient(cfg *config.Config, accountID int64) *linear.Client {
	return linear.NewClient(resolveLinearOAuthConfig(), linear.NewTokenStore(cfg.WorkspaceDir(), accountID))
}

// discardNewLinearAccount undoes a half-created account: its token is deleted
// and the row is marked removed.
func discardNewLinearAccount(cfg *config.Config, database *db.DB, id int64) {
	_ = linear.NewTokenStore(cfg.WorkspaceDir(), id).Delete()
	_ = database.SetLinearAccountRemoved(id)
}

func runLinearAdd(cmd *cobra.Command, _ []string) error {
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()

	label, _ := cmd.Flags().GetString("label")
	out := cmd.OutOrStdout()
	opts := linearLoginOptionsFromFlags(cmd)
	token, err := linear.Login(cmd.Context(), resolveLinearOAuthConfig(), out, opts)
	oauthpage.ReturnAfterLogin(opts.AppReturn, err, cmd.ErrOrStderr())
	if err != nil {
		return fmt.Errorf("linear login: %w", err)
	}

	id, err := database.CreateLinearAccount(label)
	if err != nil {
		return fmt.Errorf("creating linear account: %w", err)
	}
	if err := saveLinearTokenLocked(cmd.Context(), linear.NewTokenStore(cfg.WorkspaceDir(), id), token); err != nil {
		discardNewLinearAccount(cfg, database, id)
		return err
	}
	viewer, err := linearClient(cfg, id).FetchViewer(cmd.Context())
	if err != nil {
		discardNewLinearAccount(cfg, database, id)
		return fmt.Errorf("fetching Linear viewer: %w", err)
	}
	existing, err := database.ListLinearAccounts()
	if err != nil {
		discardNewLinearAccount(cfg, database, id)
		return err
	}
	for _, a := range existing {
		if a.ID != id && a.Status != "removed" && a.OrgID == viewer.OrgID {
			discardNewLinearAccount(cfg, database, id)
			return fmt.Errorf("this Linear workspace is already connected as account %d", a.ID)
		}
	}
	if err := database.UpdateLinearAccountConnection(id, viewer.OrgID, viewer.URLKey, viewer.OrgName); err != nil {
		return err
	}
	if err := database.SetLinearAccountOwner(id, viewer.UserID, viewer.Email, viewer.Name); err != nil {
		return err
	}
	if err := enableLinearPhase(); err != nil {
		return fmt.Errorf("saving linear config: %w", err)
	}

	fmt.Fprintf(out, "\nLinear connected as account %d!\n", id)
	fmt.Fprintf(out, "Workspace: %s (https://linear.app/%s)\n", viewer.OrgName, viewer.URLKey)
	fmt.Fprintf(out, "\nRun 'watchtower linear sync --account %d' to sync issues.\n", id)
	return nil
}

func runLinearLogin(cmd *cobra.Command, _ []string) error {
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()

	account, err := resolveLinearAccount(database, linearFlagAccount)
	if err != nil {
		return err
	}
	out := cmd.OutOrStdout()
	opts := linearLoginOptionsFromFlags(cmd)
	token, err := linear.Login(cmd.Context(), resolveLinearOAuthConfig(), out, opts)
	oauthpage.ReturnAfterLogin(opts.AppReturn, err, cmd.ErrOrStderr())
	if err != nil {
		return fmt.Errorf("linear login: %w", err)
	}
	if err := saveLinearTokenLocked(cmd.Context(), linear.NewTokenStore(cfg.WorkspaceDir(), account.ID), token); err != nil {
		return err
	}
	if err := database.SetLinearAccountAuthState(account.ID, "ok", ""); err != nil {
		return err
	}
	if err := enableLinearPhase(); err != nil {
		return fmt.Errorf("saving linear config: %w", err)
	}
	fmt.Fprintf(out, "\nLinear account %d re-authorized.\n", account.ID)
	return nil
}

type linearAccountJSON struct {
	ID      int64  `json:"id"`
	Label   string `json:"label"`
	OrgName string `json:"org_name"`
	URL     string `json:"url"`
	Status  string `json:"status"`
	Enabled bool   `json:"enabled"`
	Error   string `json:"error"`
}

func printLinearAccounts(w io.Writer, database *db.DB, asJSON bool) error {
	accounts, err := database.ListLinearAccounts()
	if err != nil {
		return err
	}
	if asJSON {
		rows := make([]linearAccountJSON, 0, len(accounts))
		for _, a := range accounts {
			rows = append(rows, linearAccountJSON{a.ID, a.Label, a.OrgName, linearWorkspaceURL(a), a.Status, a.Enabled, a.Error})
		}
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(rows)
	}
	if len(accounts) == 0 {
		fmt.Fprintln(w, "No Linear workspaces connected. Run 'watchtower linear add' to connect one.")
		return nil
	}
	fmt.Fprintf(w, "%-4s %-24s %-36s %-8s %-8s %s\n", "ID", "Name", "Workspace URL", "Status", "Enabled", "Error")
	for _, a := range accounts {
		enabled := "yes"
		if !a.Enabled {
			enabled = "no"
		}
		fmt.Fprintf(w, "%-4d %-24s %-36s %-8s %-8s %s\n",
			a.ID, truncate(linearAccountDisplayName(a), 24), truncate(linearWorkspaceURL(a), 36), a.Status, enabled, truncate(a.Error, 40))
	}
	return nil
}

func setLinearAccountEnabled(cmd *cobra.Command, arg string, enabled bool) error {
	id, err := strconv.ParseInt(arg, 10, 64)
	if err != nil {
		return fmt.Errorf("invalid account id %q: %w", arg, err)
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	account, err := database.GetLinearAccount(id)
	if err != nil {
		return err
	}
	if account.Status == "removed" {
		return errLinearAccountRemoved(id)
	}
	if err := database.SetLinearAccountEnabled(id, enabled); err != nil {
		return err
	}
	action := "enabled"
	if !enabled {
		action = "disabled"
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Linear account %d %s.\n", id, action)
	return nil
}

func runLinearRemove(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid account id %q: %w", args[0], err)
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	if _, err := database.GetLinearAccount(id); err != nil {
		return err
	}
	store := linear.NewTokenStore(cfg.WorkspaceDir(), id)
	if tok, err := store.Load(); err == nil && tok.AccessToken != "" {
		ctx, cancel := context.WithTimeout(cmd.Context(), 10*time.Second)
		if err := linear.Revoke(ctx, tok.AccessToken); err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "Warning: revoking token: %v\n", err)
		}
		cancel()
	}
	if err := store.Delete(); err != nil {
		return fmt.Errorf("deleting token: %w", err)
	}
	if err := database.SetLinearAccountRemoved(id); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Linear account %d removed. Token deleted; synced data kept.\n", id)
	return nil
}

func runLinearTeams(cmd *cobra.Command, _ []string) error {
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	account, err := resolveLinearAccount(database, linearFlagAccount)
	if err != nil {
		return err
	}
	teams, err := database.ListLinearTeams(account.ID)
	if err != nil {
		return err
	}
	out := cmd.OutOrStdout()
	if asJSON, _ := cmd.Flags().GetBool("json"); asJSON {
		type teamJSON struct {
			Key      string `json:"key"`
			Name     string `json:"name"`
			Selected bool   `json:"selected"`
		}
		rows := make([]teamJSON, 0, len(teams))
		for _, t := range teams {
			rows = append(rows, teamJSON{t.Key, t.Name, t.IsSelected})
		}
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		return enc.Encode(rows)
	}
	if len(teams) == 0 {
		fmt.Fprintf(out, "No teams yet for account %d. Run 'watchtower linear sync --account %d' first.\n", account.ID, account.ID)
		return nil
	}
	fmt.Fprintf(out, "%-10s %-32s %s\n", "Key", "Name", "Selected")
	for _, t := range teams {
		sel := "no"
		if t.IsSelected {
			sel = "yes"
		}
		fmt.Fprintf(out, "%-10s %-32s %s\n", t.Key, truncate(t.Name, 32), sel)
	}
	return nil
}

func setLinearTeamsSelected(cmd *cobra.Command, keys []string, selected bool) error {
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	account, err := resolveLinearAccount(database, linearFlagAccount)
	if err != nil {
		return err
	}
	verb := "selected"
	if !selected {
		verb = "deselected"
	}
	for _, key := range keys {
		if err := database.SetLinearTeamSelected(account.ID, key, selected); err != nil {
			return err
		}
		fmt.Fprintf(cmd.OutOrStdout(), "Team %s %s.\n", key, verb)
	}
	return nil
}

// linearTeamKeys maps team id to key for the account's sync-state rows.
func linearTeamKeys(database *db.DB, accountID int64) map[string]string {
	keys := map[string]string{}
	teams, err := database.ListLinearTeams(accountID)
	if err != nil {
		return keys
	}
	for _, t := range teams {
		keys[t.ID] = t.Key
	}
	return keys
}

func runLinearSync(cmd *cobra.Command, _ []string) error {
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()

	var accounts []db.LinearAccount
	if linearFlagAccount > 0 {
		a, err := resolveLinearAccount(database, linearFlagAccount)
		if err != nil {
			return err
		}
		accounts = []db.LinearAccount{a}
	} else if accounts, err = database.ListEnabledLinearAccounts(); err != nil {
		return err
	}
	if len(accounts) == 0 {
		return errors.New("no Linear workspace connected; run 'watchtower linear add'")
	}

	out := cmd.OutOrStdout()
	var revoked error
	for _, a := range accounts {
		syncer := linear.NewSyncer(linearClient(cfg, a.ID), database, a.ID, cfg.Linear.BackfillDays)
		n, err := syncer.Sync(cmd.Context())
		if errors.Is(err, linear.ErrAuthRevoked) {
			_ = database.SetLinearAccountAuthState(a.ID, "revoked", err.Error())
			fmt.Fprintf(cmd.ErrOrStderr(), "account %d: authorization revoked; run 'watchtower linear login --account %d'\n", a.ID, a.ID)
			revoked = err
			continue
		}
		if err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "account %d: sync failed: %v\n", a.ID, err)
		}
		fmt.Fprintf(out, "account %d: %d issues synced\n", a.ID, n)
		keys := linearTeamKeys(database, a.ID)
		states, _ := database.ListLinearSyncStates(a.ID)
		for _, s := range states {
			if s.LastError != "" {
				fmt.Fprintf(out, "  team %s: %s\n", keys[s.TeamID], s.LastError)
			}
		}
	}
	return revoked
}

func runLinearStatus(cmd *cobra.Command, _ []string) error {
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()
	if err := printLinearAccounts(out, database, false); err != nil {
		return err
	}
	accounts, err := database.ListLinearAccounts()
	if err != nil {
		return err
	}
	for _, a := range accounts {
		if a.Status == "removed" {
			continue
		}
		states, err := database.ListLinearSyncStates(a.ID)
		if err != nil {
			return err
		}
		if len(states) == 0 {
			continue
		}
		keys := linearTeamKeys(database, a.ID)
		fmt.Fprintf(out, "\nAccount %d teams:\n", a.ID)
		fmt.Fprintf(out, "%-10s %-26s %s\n", "Team", "Last synced", "Error")
		for _, s := range states {
			last := s.LastSyncedAt
			if last == "" {
				last = "never"
			}
			fmt.Fprintf(out, "%-10s %-26s %s\n", keys[s.TeamID], last, truncate(s.LastError, 60))
		}
	}
	return nil
}
