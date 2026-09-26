package cmd

import (
	"fmt"
	"io"
	"os"
	"strconv"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/imap"

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
	outlookLoginCmd.Flags().BoolVar(&outlookLoginFlagAppReturn, "app-return", false, "redirect the browser back to the Watchtower app when done")
	outlookLoginCmd.Flags().StringVar(&outlookLoginFlagLabel, "label", "", "display name for this account")

	outlookCmd.AddCommand(outlookLoginCmd)
	outlookCmd.AddCommand(outlookLogoutCmd)
	rootCmd.AddCommand(outlookCmd)
}

// resolveMicrosoftOAuthConfig returns Microsoft OAuth credentials —
// mirrors resolveGoogleOAuthConfig/resolveJiraOAuthConfig exactly. Unlike
// those, there is no client secret: Outlook login is a PKCE public client
// (see imap.MicrosoftOAuthConfig).
func resolveMicrosoftOAuthConfig() imap.MicrosoftOAuthConfig {
	clientID := os.Getenv("WATCHTOWER_MICROSOFT_CLIENT_ID")
	if clientID == "" {
		clientID = imap.DefaultMicrosoftClientID
	}
	return imap.MicrosoftOAuthConfig{ClientID: clientID}
}

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

	token, email, err := imap.LoginOutlook(cmd.Context(), resolveMicrosoftOAuthConfig(), out,
		imap.OutlookLoginOptions{SkipBrowserOpen: outlookLoginFlagNoOpen, AppReturn: outlookLoginFlagAppReturn})
	if err != nil {
		return fmt.Errorf("outlook login: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	id, err := finishOutlookLogin(database, cfg.WorkspaceDir(), email, token, outlookLoginFlagLabel, cmd.ErrOrStderr())
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
// the real browser-based imap.LoginOutlook flow.
func finishOutlookLogin(database *db.DB, workspaceDir, email string, token *imap.MicrosoftOAuthToken, label string, warnOut io.Writer) (int64, error) {
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

	return createEmailAccountWithCredentials(database, workspaceDir, db.EmailAccount{
		Provider: "outlook", EmailAddress: email,
		Host: outlookIMAPHost, Port: outlookIMAPPort,
		Security: "ssl", Folder: "INBOX", Label: label,
	}, &imap.Credentials{RefreshToken: token.RefreshToken}, warnOut)
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
	if err := imap.NewCredentialStore(cfg.WorkspaceDir(), id).Delete(); err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: failed to remove credentials file: %v\n", err)
	}

	fmt.Fprintf(cmd.OutOrStdout(), "Removed account %d.\n", id)
	return nil
}
