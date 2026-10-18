package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"strconv"
	"strings"
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

// linearLoginConfig is resolveLinearOAuthConfig for the browser flows: an
// empty client id fails before any browser opens.
func linearLoginConfig() (linear.OAuthConfig, error) {
	cfg := resolveLinearOAuthConfig()
	if cfg.ClientID == "" {
		return cfg, errors.New("linear OAuth client id is not configured (set WATCHTOWER_LINEAR_CLIENT_ID)")
	}
	return cfg, nil
}

var linearFlagAccount int64

var linearCmd = &cobra.Command{
	Use:   "linear",
	Short: "Linear integration (multiple workspaces supported)",
	RunE:  runLinearStatus,
}

var linearAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Connect a new Linear workspace via OAuth or a personal API key (--api-key)",
	RunE:  runLinearAdd,
}

var linearLoginCmd = &cobra.Command{
	Use:   "login",
	Short: "Re-authorize a connected Linear workspace (OAuth, or --api-key to replace the key)",
	RunE:  runLinearLogin,
}

var linearAccountsCmd = &cobra.Command{
	Use:   "accounts",
	Short: "List connected Linear workspaces",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		cfg, database, err := openJiraCmdDB()
		if err != nil {
			return err
		}
		defer database.Close()
		asJSON, _ := cmd.Flags().GetBool("json")
		return printLinearAccounts(cmd.OutOrStdout(), database, cfg.WorkspaceDir(), asJSON)
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
	for _, c := range []*cobra.Command{linearAddCmd, linearLoginCmd} {
		c.Flags().Bool("api-key", false, "use a personal API key read from stdin instead of OAuth")
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

// Seams for the browser flow and the API call, swapped by tests.
var (
	linearLogin       = linear.Login
	linearFetchViewer = linear.FetchViewerWithToken
	linearRevoke      = linear.Revoke
	linearSyncAccount = func(ctx context.Context, cfg *config.Config, database *db.DB, accountID int64) (int, error) {
		return linear.NewSyncer(linearClient(cfg, accountID), database, accountID, cfg.Linear.BackfillDays).Sync(ctx)
	}
)

// discardNewLinearAccount undoes a half-created account: its token is deleted
// and the row is marked removed. Cleanup failures are returned, not dropped.
func discardNewLinearAccount(cfg *config.Config, database *db.DB, id int64) error {
	var errs []error
	if err := linear.NewTokenStore(cfg.WorkspaceDir(), id).Delete(); err != nil {
		errs = append(errs, fmt.Errorf("deleting token of discarded account %d: %w", id, err))
	}
	if err := database.SetLinearAccountRemoved(id); err != nil {
		errs = append(errs, fmt.Errorf("marking discarded account %d removed: %w", id, err))
	}
	return errors.Join(errs...)
}

// connectLinearAccount turns a fresh token into a connected account. A
// workspace already connected is refused; one that was removed is revived
// (its unique org_id index would reject a second row).
func connectLinearAccount(ctx context.Context, cfg *config.Config, database *db.DB, token *linear.Token, label string) (id int64, revived bool, err error) {
	id, err = database.CreateLinearAccount(label)
	if err != nil {
		return 0, false, fmt.Errorf("creating linear account: %w", err)
	}
	newID := id
	defer func() {
		if err != nil {
			err = errors.Join(err, discardNewLinearAccount(cfg, database, newID))
		}
	}()
	if err = saveLinearTokenLocked(ctx, linear.NewTokenStore(cfg.WorkspaceDir(), id), token); err != nil {
		return 0, false, err
	}
	viewer, err := linearFetchViewer(ctx, token)
	if err != nil {
		return 0, false, fmt.Errorf("fetching Linear viewer: %w", err)
	}
	existing, err := database.ListLinearAccounts()
	if err != nil {
		return 0, false, err
	}
	if a, ok := sameWorkspaceAccount(existing, id, viewer.OrgID); ok {
		if a.Status != "removed" {
			return 0, false, fmt.Errorf("this Linear workspace is already connected as account %d", a.ID)
		}
		if err = reviveLinearAccount(ctx, cfg, database, a, token, label, viewer); err != nil {
			return 0, false, err
		}
		// The new row is discarded by the deferred cleanup only on error;
		// on success it is discarded here.
		if derr := discardNewLinearAccount(cfg, database, id); derr != nil {
			return a.ID, true, derr
		}
		return a.ID, true, nil
	}
	if err = database.UpdateLinearAccountConnection(id, viewer.OrgID, viewer.URLKey, viewer.OrgName); err != nil {
		return 0, false, err
	}
	if err = database.SetLinearAccountOwner(id, viewer.UserID, viewer.Email, viewer.Name); err != nil {
		return 0, false, err
	}
	if err = enableLinearPhase(); err != nil {
		return 0, false, fmt.Errorf("saving linear config: %w", err)
	}
	return id, false, nil
}

// sameWorkspaceAccount returns the account other than newID that already
// holds the workspace orgID.
func sameWorkspaceAccount(accounts []db.LinearAccount, newID int64, orgID string) (db.LinearAccount, bool) {
	for _, a := range accounts {
		if a.ID != newID && a.OrgID != "" && a.OrgID == orgID {
			return a, true
		}
	}
	return db.LinearAccount{}, false
}

func reviveLinearAccount(ctx context.Context, cfg *config.Config, database *db.DB, a db.LinearAccount, token *linear.Token, label string, viewer linear.Viewer) error {
	if err := saveLinearTokenLocked(ctx, linear.NewTokenStore(cfg.WorkspaceDir(), a.ID), token); err != nil {
		return err
	}
	if err := database.SetLinearAccountAuthState(a.ID, "ok", ""); err != nil {
		return err
	}
	if err := database.SetLinearAccountEnabled(a.ID, true); err != nil {
		return err
	}
	if strings.TrimSpace(label) != "" {
		if err := database.SetLinearAccountLabel(a.ID, label); err != nil {
			return err
		}
	}
	if err := database.UpdateLinearAccountConnection(a.ID, viewer.OrgID, viewer.URLKey, viewer.OrgName); err != nil {
		return err
	}
	if err := database.SetLinearAccountOwner(a.ID, viewer.UserID, viewer.Email, viewer.Name); err != nil {
		return err
	}
	if err := enableLinearPhase(); err != nil {
		return fmt.Errorf("saving linear config: %w", err)
	}
	return nil
}

// linearCredentialFlow is the credential step of add/login, prepared up front
// so a missing OAuth client id fails before anything else runs.
type linearCredentialFlow struct {
	apiKey   bool
	oauthCfg linear.OAuthConfig
}

func prepareLinearCredential(cmd *cobra.Command) (linearCredentialFlow, error) {
	if useKey, _ := cmd.Flags().GetBool("api-key"); useKey {
		return linearCredentialFlow{apiKey: true}, nil
	}
	oauthCfg, err := linearLoginConfig()
	if err != nil {
		return linearCredentialFlow{}, err
	}
	return linearCredentialFlow{oauthCfg: oauthCfg}, nil
}

// acquire returns the credential for add/login: a personal API key read from
// stdin with --api-key (hidden prompt on a terminal, one line from a pipe,
// never argv), otherwise the OAuth browser flow. Callers open the database
// and resolve the account first, so a bad --account or a DB failure never
// costs the owner a consent screen or drops a fresh token unused.
func (f linearCredentialFlow) acquire(cmd *cobra.Command) (*linear.Token, error) {
	if f.apiKey {
		key, err := readSecret(cmd, "Linear API key: ")
		if err != nil {
			return nil, fmt.Errorf("reading API key: %w", err)
		}
		if key == "" {
			return nil, errors.New("empty API key")
		}
		return linear.APIKeyToken(key), nil
	}
	opts := linearLoginOptionsFromFlags(cmd)
	token, err := linearLogin(cmd.Context(), f.oauthCfg, cmd.OutOrStdout(), opts)
	oauthpage.ReturnAfterLogin(opts.AppReturn, err, cmd.ErrOrStderr())
	if err != nil {
		return nil, fmt.Errorf("linear login: %w", err)
	}
	return token, nil
}

func runLinearAdd(cmd *cobra.Command, _ []string) error {
	flow, err := prepareLinearCredential(cmd)
	if err != nil {
		return err
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()

	token, err := flow.acquire(cmd)
	if err != nil {
		return err
	}

	label, _ := cmd.Flags().GetString("label")
	out := cmd.OutOrStdout()
	id, revived, err := connectLinearAccount(cmd.Context(), cfg, database, token, label)
	if err != nil {
		return err
	}
	if revived {
		fmt.Fprintf(out, "\nLinear workspace reconnected as account %d\n", id)
		return nil
	}
	a, err := database.GetLinearAccount(id)
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "\nLinear connected as account %d!\n", id)
	fmt.Fprintf(out, "Workspace: %s (%s)\n", a.OrgName, linearWorkspaceURL(a))
	fmt.Fprintf(out, "\nRun 'watchtower linear sync --account %d' to sync issues.\n", id)
	return nil
}

func runLinearLogin(cmd *cobra.Command, _ []string) error {
	flow, err := prepareLinearCredential(cmd)
	if err != nil {
		return err
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()

	account, err := resolveLinearAccount(database, linearFlagAccount)
	if err != nil {
		return err
	}
	token, err := flow.acquire(cmd)
	if err != nil {
		return err
	}
	out := cmd.OutOrStdout()
	if err := relinkLinearAccount(cmd.Context(), cfg, database, account, token); err != nil {
		return err
	}
	fmt.Fprintf(out, "\nLinear account %d re-authorized.\n", account.ID)
	return nil
}

// relinkLinearAccount checks the new token belongs to the account's workspace
// before saving it, then refreshes the workspace name, the owner and sets the
// status ok.
func relinkLinearAccount(ctx context.Context, cfg *config.Config, database *db.DB, account db.LinearAccount, token *linear.Token) error {
	// The viewer is fetched with the new token in memory, before it is saved,
	// so a wrong-workspace login never overwrites the account's token.
	viewer, err := linearFetchViewer(ctx, token)
	if err != nil {
		return fmt.Errorf("fetching Linear viewer: %w", err)
	}
	if account.OrgID != "" && viewer.OrgID != account.OrgID {
		return fmt.Errorf("this login is for workspace %s, but account %d is %s; run 'watchtower linear add' to connect another workspace",
			viewer.OrgName, account.ID, account.OrgName)
	}
	if err := saveLinearTokenLocked(ctx, linear.NewTokenStore(cfg.WorkspaceDir(), account.ID), token); err != nil {
		return err
	}
	// A renamed workspace (name or URL key) is picked up on every re-login.
	if err := database.UpdateLinearAccountConnection(account.ID, viewer.OrgID, viewer.URLKey, viewer.OrgName); err != nil {
		return err
	}
	if err := database.SetLinearAccountOwner(account.ID, viewer.UserID, viewer.Email, viewer.Name); err != nil {
		return err
	}
	if err := database.SetLinearAccountAuthState(account.ID, "ok", ""); err != nil {
		return err
	}
	if err := enableLinearPhase(); err != nil {
		return fmt.Errorf("saving linear config: %w", err)
	}
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
	Auth    string `json:"auth"`
}

// linearAuthKind reads the credential kind from the account's token file:
// "oauth", "api_key", "" when there is no token file, or "error" when the file
// exists but cannot be read or parsed, so a corrupt credential never shows as
// a blank one.
func linearAuthKind(workspaceDir string, accountID int64) string {
	tok, err := linear.NewTokenStore(workspaceDir, accountID).Load()
	if errors.Is(err, fs.ErrNotExist) {
		return ""
	}
	if err != nil {
		return "error"
	}
	if tok.IsAPIKey() {
		return linear.TokenTypeAPIKey
	}
	return "oauth"
}

func printLinearAccounts(w io.Writer, database *db.DB, workspaceDir string, asJSON bool) error {
	accounts, err := database.ListLinearAccounts()
	if err != nil {
		return err
	}
	if asJSON {
		rows := make([]linearAccountJSON, 0, len(accounts))
		for _, a := range accounts {
			rows = append(rows, linearAccountJSON{a.ID, a.Label, a.OrgName, linearWorkspaceURL(a), a.Status, a.Enabled, a.Error, linearAuthKind(workspaceDir, a.ID)})
		}
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(rows)
	}
	if len(accounts) == 0 {
		fmt.Fprintln(w, "No Linear workspaces connected. Run 'watchtower linear add' to connect one.")
		return nil
	}
	fmt.Fprintf(w, "%-4s %-24s %-36s %-8s %-8s %-8s %s\n", "ID", "Name", "Workspace URL", "Status", "Enabled", "Auth", "Error")
	for _, a := range accounts {
		enabled := "yes"
		if !a.Enabled {
			enabled = "no"
		}
		fmt.Fprintf(w, "%-4d %-24s %-36s %-8s %-8s %-8s %s\n",
			a.ID, truncate(linearAccountDisplayName(a), 24), truncate(linearWorkspaceURL(a), 36), a.Status, enabled,
			linearAuthKind(workspaceDir, a.ID), truncate(a.Error, 40))
	}
	return nil
}

// parseLinearAccountArg parses the positional account id of enable, disable
// and remove; a --account that names a different account is refused.
func parseLinearAccountArg(arg string) (int64, error) {
	id, err := strconv.ParseInt(arg, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid account id %q: %w", arg, err)
	}
	if linearFlagAccount > 0 && linearFlagAccount != id {
		return 0, fmt.Errorf("--account and the positional id disagree (%d vs %d)", linearFlagAccount, id)
	}
	return id, nil
}

func setLinearAccountEnabled(cmd *cobra.Command, arg string, enabled bool) error {
	id, err := parseLinearAccountArg(arg)
	if err != nil {
		return err
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
	id, err := parseLinearAccountArg(args[0])
	if err != nil {
		return err
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	if _, err := database.GetLinearAccount(id); err != nil {
		return err
	}
	if err := revokeAndDeleteLinearToken(cmd.Context(), linear.NewTokenStore(cfg.WorkspaceDir(), id), cmd.ErrOrStderr()); err != nil {
		return err
	}
	if err := database.SetLinearAccountRemoved(id); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Linear account %d removed. Token deleted; synced data kept.\n", id)
	return nil
}

// revokeAndDeleteLinearToken revokes (best effort) and deletes the account's
// token under its cross-process lock, so a daemon refresh in flight cannot
// write the file back after the delete.
func revokeAndDeleteLinearToken(ctx context.Context, store *linear.TokenStore, errOut io.Writer) error {
	lockCtx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	unlock, err := store.Lock(lockCtx)
	if err != nil {
		return fmt.Errorf("deleting token: %w", err)
	}
	defer unlock()
	if tok, err := store.Load(); err == nil && tok.IsAPIKey() {
		fmt.Fprintln(errOut, "Note: a personal API key can't be revoked from here; revoke it in Linear's settings (Settings > Account > Security & access).")
	} else if err == nil && tok.AccessToken != "" {
		revokeCtx, cancelRevoke := context.WithTimeout(ctx, 10*time.Second)
		if err := linearRevoke(revokeCtx, tok.AccessToken); err != nil {
			fmt.Fprintf(errOut, "Warning: revoking token: %v\n", err)
		}
		cancelRevoke()
	}
	if err := store.Delete(); err != nil {
		return fmt.Errorf("deleting token: %w", err)
	}
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

// linearTeamKeys maps team id to key for the account's sync-state rows. A
// read failure is reported on errOut and leaves the keys empty, so the caller
// still prints the states.
func linearTeamKeys(database *db.DB, accountID int64, errOut io.Writer) map[string]string {
	keys := map[string]string{}
	teams, err := database.ListLinearTeams(accountID)
	if err != nil {
		fmt.Fprintf(errOut, "account %d: reading teams: %v\n", accountID, err)
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
	// Every per-account failure is joined into the returned error (the
	// runJiraSync rule): the command exits non-zero when any account failed.
	var errs error
	for _, a := range accounts {
		n, err := linearSyncAccount(cmd.Context(), cfg, database, a.ID)
		if errors.Is(err, linear.ErrAuthRevoked) {
			fmt.Fprintf(cmd.ErrOrStderr(), "account %d: authorization revoked; run 'watchtower linear login --account %d'\n", a.ID, a.ID)
			errs = errors.Join(errs, fmt.Errorf("account %d: %w", a.ID, err))
			if werr := database.SetLinearAccountAuthState(a.ID, "revoked", err.Error()); werr != nil {
				fmt.Fprintf(cmd.ErrOrStderr(), "account %d: recording revoked state: %v\n", a.ID, werr)
				errs = errors.Join(errs, fmt.Errorf("account %d: recording revoked state: %w", a.ID, werr))
			}
			continue
		}
		if err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "account %d: sync failed: %v\n", a.ID, err)
			errs = errors.Join(errs, fmt.Errorf("account %d: %w", a.ID, err))
		}
		fmt.Fprintf(out, "account %d: %d issues synced\n", a.ID, n)
		keys := linearTeamKeys(database, a.ID, cmd.ErrOrStderr())
		states, serr := database.ListLinearSyncStates(a.ID)
		if serr != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "account %d: reading sync state: %v\n", a.ID, serr)
		}
		for _, s := range states {
			if s.LastError != "" {
				fmt.Fprintf(out, "  team %s: %s\n", keys[s.TeamID], s.LastError)
			}
		}
	}
	if errs != nil {
		return fmt.Errorf("syncing: %w", errs)
	}
	return nil
}

func runLinearStatus(cmd *cobra.Command, _ []string) error {
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()
	if err := printLinearAccounts(out, database, cfg.WorkspaceDir(), false); err != nil {
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
		keys := linearTeamKeys(database, a.ID, cmd.ErrOrStderr())
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
