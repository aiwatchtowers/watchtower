package cmd

import (
	"fmt"
	"io"
	"strconv"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/imap"
	"watchtower/internal/oauthclient"
	"watchtower/internal/oauthpage"

	"github.com/spf13/cobra"
)

// outlookIMAPHost/outlookIMAPPort are Microsoft's fixed IMAP endpoint for
// both Outlook.com and Office365 mailboxes — unlike generic IMAP (cmd/imap.go
// `add`), there's nothing for the user to specify: the OAuth login flow is
// the only setup step.
const (
	outlookIMAPHost = "outlook.office365.com"
	outlookIMAPPort = 993
)

var outlookCmd = &cobra.Command{
	Use:   "outlook",
	Short: "Outlook/Office365 email integration",
}

var (
	outlookLoginFlagNoOpen    bool
	outlookLoginFlagAppReturn bool
	outlookLoginFlagLabel     string
	outlookLoginFlagCompany   string
)

var outlookLoginCmd = &cobra.Command{
	Use:   "login",
	Short: "Connect an Outlook/Office365 mailbox",
	RunE:  runOutlookLogin,
}

var outlookLogoutCmd = &cobra.Command{
	Use:   "logout <account-id>",
	Short: "Disconnect an Outlook/Office365 mailbox",
	Args:  cobra.ExactArgs(1),
	RunE:  runOutlookLogout,
}

func init() {
	outlookLoginCmd.Flags().BoolVar(&outlookLoginFlagNoOpen, "no-open", false, "print the authorize URL instead of opening a browser")
	outlookLoginCmd.Flags().BoolVar(&outlookLoginFlagAppReturn, "app-return", false, "bring the Watchtower app back to the front when done")
	outlookLoginCmd.Flags().StringVar(&outlookLoginFlagLabel, "label", "", "display name for this account")
	outlookLoginCmd.Flags().StringVar(&outlookLoginFlagCompany, "company", "", "sign in through this stored company's Microsoft app and tenant (its slug, see 'watchtower company list'); the account is tied to the company")

	outlookCmd.AddCommand(outlookLoginCmd)
	outlookCmd.AddCommand(outlookLogoutCmd)
	rootCmd.AddCommand(outlookCmd)
}

// outlookLogin is imap.LoginOutlook; a var so tests script the sign-in.
var outlookLogin = imap.LoginOutlook

func runOutlookLogin(cmd *cobra.Command, _ []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return err
	}

	out := cmd.OutOrStdout()

	// The client comes first: an unknown company (or no client at all) fails
	// here, before any browser. A company signs in through its own Entra app
	// against its tenant (#1887 D16); no company, the shared client on
	// "common". Unlike Google/Jira there is no client secret: Outlook login
	// is a PKCE public client (see imap.MicrosoftOAuthConfig).
	slug := outlookLoginFlagCompany
	msCfg, _, err := resolveMicrosoftOAuthConfigForCompany(cfg.WorkspaceDir(), slug)
	if err != nil {
		if slug == "" {
			return fmt.Errorf("%w: set WATCHTOWER_MICROSOFT_CLIENT_ID for development", err)
		}
		return err
	}

	token, email, err := outlookLogin(cmd.Context(), msCfg, out,
		imap.OutlookLoginOptions{SkipBrowserOpen: outlookLoginFlagNoOpen, AppReturn: outlookLoginFlagAppReturn})
	oauthpage.ReturnAfterLogin(outlookLoginFlagAppReturn, err, cmd.ErrOrStderr())
	if err != nil {
		return fmt.Errorf("outlook login: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	id, err := finishOutlookLogin(database, cfg.WorkspaceDir(), email, token, outlookLoginFlagLabel, slug, msCfg, cmd.ErrOrStderr())
	if err != nil {
		return err
	}

	fmt.Fprintf(out, "\nOutlook connected: %s (account id %d)\n", email, id)
	fmt.Fprintln(out, "Restart the daemon to pick up the new mailbox immediately.")
	return nil
}

// finishOutlookLogin validates the OAuth result and persists the account —
// split out from runOutlookLogin so the validate-then-persist composition
// (a scope-rejected or refresh-tokenless grant must never reach
// createEmailAccountWithCredentials) is directly testable without driving
// the real browser-based imap.LoginOutlook flow. A sign-in through company
// slug ties the row in the same insert and records msCfg, the client the
// grant was issued to, as the account's outlook_client_<id>.json.
func finishOutlookLogin(database *db.DB, workspaceDir, email string, token *imap.MicrosoftOAuthToken, label, slug string, msCfg imap.MicrosoftOAuthConfig, warnOut io.Writer) (int64, error) {
	if email == "" {
		return 0, fmt.Errorf("outlook login: could not resolve the connected account's email address")
	}
	if token.RefreshToken == "" {
		// Microsoft can return a code/token exchange without a refresh_token
		// (e.g. Conditional Access / app-protection policies restricting
		// refresh tokens for public clients) even though the rest of the
		// exchange succeeds. Catch it here rather than persisting an account
		// that looks connected but fails on its first background sync —
		// mirrors gmail's validateGrantedScopes safety net.
		return 0, fmt.Errorf("outlook login: no refresh token granted — re-run login and approve offline access on the consent screen")
	}
	if err := imap.ValidateGrantedScopes(token.Scope); err != nil {
		return 0, fmt.Errorf("outlook login: %w", err)
	}

	id, err := createEmailAccountWithCredentials(database, workspaceDir, db.EmailAccount{
		Provider: "outlook", EmailAddress: email,
		Host: outlookIMAPHost, Port: outlookIMAPPort,
		Security: "ssl", Folder: "INBOX", Label: label, CompanySlug: slug,
	}, &imap.Credentials{RefreshToken: token.RefreshToken}, warnOut)
	if err != nil || slug == "" {
		return id, err
	}
	// The row is new and the daemon wires it only at its next start, so the
	// client record lands before any refresh can read the pair.
	if err := oauthclient.NewStore(workspaceDir, outlookClientVendor, id).
		Save(oauthclient.Client{ClientID: msCfg.ClientID, TenantID: msCfg.TenantID}); err != nil {
		removeOutlookAccountFiles(workspaceDir, id, warnOut)
		if delErr := database.DeleteEmailAccount(id); delErr != nil {
			fmt.Fprintf(warnOut, "warning: failed to roll back account %d: %v\n", id, delErr)
		}
		return 0, fmt.Errorf("saving the account's Microsoft client: %w", err)
	}
	return id, nil
}

// removeOutlookAccountFiles deletes an email account's sign-in files: its
// credentials and its company client record (Outlook only). Failures are
// warnings: the row is what makes an account.
func removeOutlookAccountFiles(workspaceDir string, id int64, warnOut io.Writer) {
	if err := imap.NewCredentialStore(workspaceDir, id).Delete(); err != nil {
		fmt.Fprintf(warnOut, "warning: failed to remove credentials file: %v\n", err)
	}
	if err := oauthclient.NewStore(workspaceDir, outlookClientVendor, id).Delete(); err != nil {
		fmt.Fprintf(warnOut, "warning: failed to remove the account's Microsoft client file: %v\n", err)
	}
}

func runOutlookLogout(cmd *cobra.Command, args []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return err
	}

	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid account id %q: %w", args[0], err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	if err := database.DeleteEmailAccount(id); err != nil {
		return fmt.Errorf("removing account: %w", err)
	}
	removeOutlookAccountFiles(cfg.WorkspaceDir(), id, cmd.ErrOrStderr())

	fmt.Fprintf(cmd.OutOrStdout(), "Removed account %d.\n", id)
	return nil
}
