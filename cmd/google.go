package cmd

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"strconv"
	"strings"

	"watchtower/internal/calendar"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gmail"

	"github.com/spf13/cobra"
)

var googleCmd = &cobra.Command{
	Use:   "google",
	Short: "Google account integration",
}

var googleLoginCmd = &cobra.Command{
	Use:   "login",
	Short: "Connect (or re-consent) a Google account's Calendar and/or Gmail access",
	Long: "Runs one OAuth flow requesting exactly the scopes for the selected services,\n" +
		"so Google shows a single consent screen listing precisely what access is granted.\n" +
		"With both services selected Google shows one checkbox per permission — a partial\n" +
		"grant connects only the approved services.\n\n" +
		"Without --account, operates on account #1 — the implicit account every\n" +
		"single-account install already has, created on first use if it doesn't exist yet.\n" +
		"With --account <id>, re-consents an existing account: --calendar/--gmail widen its\n" +
		"access, otherwise the account's currently enabled services are re-requested as-is.",
	RunE: runGoogleLogin,
}

var googleAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Connect a new Google account (Calendar and/or Gmail)",
	Long: "Creates a new google_accounts row and runs the OAuth consent flow for it.\n" +
		"Pass --client-id together with --client-secret-stdin to bring the account's own\n" +
		"Google Cloud OAuth client instead of Watchtower's build-time default.",
	RunE: runGoogleAdd,
}

var googleAccountsCmd = &cobra.Command{
	Use:   "accounts",
	Short: "List connected Google accounts",
	RunE:  runGoogleAccounts,
}

var googleRemoveCmd = &cobra.Command{
	Use:   "remove <account-id>",
	Short: "Disconnect a Google account",
	Args:  cobra.ExactArgs(1),
	RunE:  runGoogleRemove,
}

func init() {
	googleLoginCmd.Flags().Bool("calendar", false, "request Google Calendar access")
	googleLoginCmd.Flags().Bool("gmail", false, "request Gmail access")
	googleLoginCmd.Flags().Bool("no-open", false, "print the authorize URL instead of opening a browser")
	googleLoginCmd.Flags().Bool("app-return", false, "redirect the browser back to the Watchtower app when done")
	googleLoginCmd.Flags().Int64("account", 0, "existing account id to re-consent (default: account #1, created if it doesn't exist)")

	googleAddCmd.Flags().Bool("calendar", false, "request Google Calendar access")
	googleAddCmd.Flags().Bool("gmail", false, "request Gmail access")
	googleAddCmd.Flags().String("label", "", "display name for this account")
	googleAddCmd.Flags().String("client-id", "", "bring your own Google OAuth client id (non-secret half)")
	googleAddCmd.Flags().Bool("client-secret-stdin", false, "read the OAuth client secret from stdin (required with --client-id)")
	googleAddCmd.Flags().Bool("no-open", false, "print the authorize URL instead of opening a browser")
	googleAddCmd.Flags().Bool("app-return", false, "redirect the browser back to the Watchtower app when done")

	googleCmd.AddCommand(googleLoginCmd)
	googleCmd.AddCommand(googleAddCmd)
	googleCmd.AddCommand(googleAccountsCmd)
	googleCmd.AddCommand(googleRemoveCmd)
	rootCmd.AddCommand(googleCmd)
}

func runGoogleLogin(cmd *cobra.Command, _ []string) error {
	wantCalendarFlag, _ := cmd.Flags().GetBool("calendar")
	wantGmailFlag, _ := cmd.Flags().GetBool("gmail")
	accountFlag, _ := cmd.Flags().GetInt64("account")

	if accountFlag == 0 && !wantCalendarFlag && !wantGmailFlag {
		return fmt.Errorf("select at least one service: --calendar and/or --gmail")
	}

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

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	var accountID int64
	isNewRow := false
	if accountFlag != 0 {
		if _, err := database.GetGoogleAccount(accountFlag); err != nil {
			return fmt.Errorf("account %d not found: %w", accountFlag, err)
		}
		accountID = accountFlag
	} else {
		accountID, isNewRow, err = resolveAccountOneForLogin(cmd, cfg, database)
		if err != nil {
			return err
		}
	}

	acct, err := database.GetGoogleAccount(accountID)
	if err != nil {
		return fmt.Errorf("loading account %d: %w", accountID, err)
	}

	wantCalendar := wantCalendarFlag || acct.CalendarEnabled
	wantGmail := wantGmailFlag || acct.GmailEnabled
	if !wantCalendar && !wantGmail {
		return fmt.Errorf("select at least one service: --calendar and/or --gmail")
	}

	return connectGoogleAccount(cmd, cfg, database, accountID, wantCalendar, wantGmail, isNewRow)
}

func runGoogleAdd(cmd *cobra.Command, _ []string) error {
	wantCalendar, _ := cmd.Flags().GetBool("calendar")
	wantGmail, _ := cmd.Flags().GetBool("gmail")
	if !wantCalendar && !wantGmail {
		return fmt.Errorf("select at least one service: --calendar and/or --gmail")
	}

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

	label, _ := cmd.Flags().GetString("label")
	clientID, _ := cmd.Flags().GetString("client-id")
	clientSecretStdin, _ := cmd.Flags().GetBool("client-secret-stdin")
	if clientID != "" && !clientSecretStdin {
		return fmt.Errorf("--client-id requires --client-secret-stdin")
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	id, err := database.CreateGoogleAccount(db.GoogleAccount{Label: label, ClientID: clientID})
	if err != nil {
		return fmt.Errorf("creating account: %w", err)
	}

	if clientID != "" {
		secret, err := readLineFromStdin(cmd)
		if err != nil {
			rollbackGoogleAccount(database, cfg.WorkspaceDir(), id, cmd.ErrOrStderr())
			return fmt.Errorf("reading client secret: %w", err)
		}
		if err := calendar.NewCredentialStore(cfg.WorkspaceDir(), id).Save(&calendar.Credentials{ClientID: clientID, ClientSecret: secret}); err != nil {
			rollbackGoogleAccount(database, cfg.WorkspaceDir(), id, cmd.ErrOrStderr())
			return fmt.Errorf("saving credentials: %w", err)
		}
	}

	return connectGoogleAccount(cmd, cfg, database, id, wantCalendar, wantGmail, true)
}

func runGoogleAccounts(cmd *cobra.Command, _ []string) error {
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

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	accounts, err := database.ListGoogleAccounts()
	if err != nil {
		return fmt.Errorf("listing accounts: %w", err)
	}

	out := cmd.OutOrStdout()
	if len(accounts) == 0 {
		fmt.Fprintln(out, "No Google accounts connected.")
		fmt.Fprintln(out, "Run 'watchtower google add' to connect one.")
		return nil
	}
	for _, a := range accounts {
		fmt.Fprintf(out, "#%d %s [%s] %s\n", a.ID, googleAccountDisplayName(a), googleAccountServiceBadges(a), a.Status)
	}
	return nil
}

func runGoogleRemove(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid account id %q: %w", args[0], err)
	}

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

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	if err := database.DeleteGoogleAccount(id); err != nil {
		return fmt.Errorf("removing account: %w", err)
	}

	out := cmd.OutOrStdout()
	fmt.Fprintf(out, "Removed account %d.\n", id)

	var removed []string
	tokenStore := calendar.NewAccountTokenStore(cfg.WorkspaceDir(), id)
	if tokenStore.Exists() {
		if err := tokenStore.Delete(); err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "warning: failed to remove token file: %v\n", err)
		} else {
			removed = append(removed, "token file")
		}
	}
	credStore := calendar.NewCredentialStore(cfg.WorkspaceDir(), id)
	if credStore.Exists() {
		if err := credStore.Delete(); err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "warning: failed to remove credentials file: %v\n", err)
		} else {
			removed = append(removed, "credentials file")
		}
	}
	if len(removed) > 0 {
		fmt.Fprintf(out, "Deleted: %s\n", strings.Join(removed, ", "))
	}
	return nil
}

// resolveAccountOneForLogin resolves the legacy "account #1" — the single
// implicit account every pre-multi-account install already has — creating it
// if this is the very first Google login ever. Shared by `google login`
// (without --account), `gmail login`, and `calendar login`: all three keep
// working unmodified against a single-account install.
func resolveAccountOneForLogin(cmd *cobra.Command, cfg *config.Config, database *db.DB) (accountID int64, isNewRow bool, err error) {
	logger := log.New(cmd.ErrOrStderr(), "[google] ", log.LstdFlags)
	id, err := ensureLegacyGoogleAccount(cmd.Context(), cfg, database, logger)
	if err != nil {
		return 0, false, fmt.Errorf("seeding legacy account: %w", err)
	}
	if id != 0 {
		return id, false, nil
	}
	id, err = database.CreateGoogleAccount(db.GoogleAccount{})
	if err != nil {
		return 0, false, fmt.Errorf("creating account: %w", err)
	}
	return id, true, nil
}

// connectGoogleAccount runs the OAuth consent flow for accountID and records
// the result: which services actually got granted, the account's email
// (best-effort via the Gmail profile API when Gmail access was granted), and
// auth state. When isNewRow is true and the flow fails, the just-created row
// (and any credentials file) is rolled back — mirrors
// createEmailAccountWithCredentials (cmd/imap.go): a caller-visible account
// id must never be created and then left un-loginable.
func connectGoogleAccount(cmd *cobra.Command, cfg *config.Config, database *db.DB, accountID int64, wantCalendar, wantGmail, isNewRow bool) error {
	out := cmd.OutOrStdout()
	noOpen, _ := cmd.Flags().GetBool("no-open")
	appReturn, _ := cmd.Flags().GetBool("app-return")

	var scopes []string
	if wantCalendar {
		scopes = append(scopes, calendar.ScopeCalendarReadonly)
	}
	if wantGmail {
		scopes = append(scopes, gmail.ScopeGmailReadonly)
	}

	googleCfg := resolveGoogleOAuthConfigForAccount(cfg.WorkspaceDir(), accountID)
	token, err := calendar.Login(cmd.Context(), googleCfg, out, calendar.LoginOptions{
		SkipBrowserOpen: noOpen,
		Scopes:          scopes,
		AppReturn:       appReturn,
	})
	if err != nil {
		if isNewRow {
			rollbackGoogleAccount(database, cfg.WorkspaceDir(), accountID, cmd.ErrOrStderr())
		}
		return fmt.Errorf("google login: %w", err)
	}

	store := calendar.NewAccountTokenStore(cfg.WorkspaceDir(), accountID)
	if err := store.Save(token); err != nil {
		if isNewRow {
			rollbackGoogleAccount(database, cfg.WorkspaceDir(), accountID, cmd.ErrOrStderr())
		}
		return fmt.Errorf("saving token: %w", err)
	}

	calEnabled := wantCalendar && token.GrantsScope(calendar.ScopeCalendarReadonly)
	gmEnabled := wantGmail && token.GrantsScope(gmail.ScopeGmailReadonly)

	email := ""
	if gmEnabled {
		if client, cErr := gmail.NewClient(cmd.Context(), token.RefreshToken,
			gmail.GoogleOAuthConfig{ClientID: googleCfg.ClientID, ClientSecret: googleCfg.ClientSecret}); cErr == nil {
			if profile, pErr := client.GetProfile(cmd.Context()); pErr == nil {
				email = profile.EmailAddress
			}
		}
	}

	if err := database.UpdateGoogleAccountConnection(accountID, email, calEnabled, gmEnabled); err != nil {
		return fmt.Errorf("recording connection: %w", err)
	}
	_ = database.SetGoogleAccountAuthState(accountID, "ok", "")

	fmt.Fprintln(out)
	if wantCalendar {
		if calEnabled {
			fmt.Fprintln(out, "Google Calendar: connected")
		} else {
			fmt.Fprintln(out, "Google Calendar: NOT granted — its permission was left unapproved on the consent screen")
		}
	}
	if wantGmail {
		if gmEnabled {
			fmt.Fprintln(out, "Gmail: connected")
		} else {
			fmt.Fprintln(out, "Gmail: NOT granted — its permission was left unapproved on the consent screen")
		}
	}
	fmt.Fprintf(out, "Account id: %d\n", accountID)
	return nil
}

// rollbackGoogleAccount deletes accountID's row and credentials file
// (best-effort) after a failed connect on a row this command just created —
// otherwise a login failure leaves an orphaned ghost account that can never
// sync since no working token was ever written for it.
func rollbackGoogleAccount(database *db.DB, workspaceDir string, accountID int64, warnOut io.Writer) {
	if err := calendar.NewCredentialStore(workspaceDir, accountID).Delete(); err != nil {
		fmt.Fprintf(warnOut, "warning: failed to remove credentials file for account %d: %v\n", accountID, err)
	}
	if err := database.DeleteGoogleAccount(accountID); err != nil {
		fmt.Fprintf(warnOut, "warning: failed to roll back orphaned account %d: %v\n", accountID, err)
	}
}

// disconnectGoogleService disables one service flag on google_accounts row
// #1 — the `gmail logout`/`calendar logout` alias. The Google grant is
// revoked only once BOTH flags end up false: a single OAuth grant can cover
// both scopes, so revoking while the other service is still enabled would
// silently break it too. Once both are false the token file is deleted as
// housekeeping, but the account row stays — `google remove` deletes the
// account itself.
func disconnectGoogleService(cmd *cobra.Command, cfg *config.Config, database *db.DB, service string) error {
	accounts, err := database.ListGoogleAccounts()
	if err != nil {
		return fmt.Errorf("listing accounts: %w", err)
	}
	out := cmd.OutOrStdout()
	if len(accounts) == 0 {
		fmt.Fprintln(out, "No Google account connected.")
		return nil
	}
	acct := accounts[0]

	calendarEnabled, gmailEnabled := acct.CalendarEnabled, acct.GmailEnabled
	switch service {
	case "calendar":
		calendarEnabled = false
	case "gmail":
		gmailEnabled = false
	}

	if err := database.UpdateGoogleAccountConnection(acct.ID, acct.Email, calendarEnabled, gmailEnabled); err != nil {
		return fmt.Errorf("updating account: %w", err)
	}

	if !calendarEnabled && !gmailEnabled {
		store := calendar.NewAccountTokenStore(cfg.WorkspaceDir(), acct.ID)
		if token, loadErr := store.Load(); loadErr == nil && token.RefreshToken != "" {
			if revokeErr := calendar.Revoke(cmd.Context(), token.RefreshToken); revokeErr != nil {
				fmt.Fprintf(out, "Warning: could not revoke the grant at Google: %v\n", revokeErr)
			}
		}
		if err := store.Delete(); err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "warning: failed to remove token file: %v\n", err)
		}
		fmt.Fprintf(out, "%s disconnected. No Google services remain connected on account %d — run 'watchtower google remove %d' to remove it entirely.\n",
			googleServiceLabel(service), acct.ID, acct.ID)
		return nil
	}

	// Clear any previously recorded auth failure so the Desktop popup dismisses.
	_ = database.SetGoogleAccountAuthState(acct.ID, "ok", "")
	fmt.Fprintf(out, "%s disconnected.\n", googleServiceLabel(service))
	return nil
}

func googleServiceLabel(service string) string {
	if service == "calendar" {
		return "Google Calendar"
	}
	return "Gmail"
}

func googleAccountDisplayName(a db.GoogleAccount) string {
	if a.Email != "" {
		return a.Email
	}
	if a.Label != "" {
		return a.Label
	}
	return "(unnamed)"
}

func googleAccountServiceBadges(a db.GoogleAccount) string {
	var services []string
	if a.CalendarEnabled {
		services = append(services, "calendar")
	}
	if a.GmailEnabled {
		services = append(services, "gmail")
	}
	if len(services) == 0 {
		return "none"
	}
	return strings.Join(services, ",")
}

// readLineFromStdin reads one line (trimmed) from cmd's stdin — used for
// --client-secret-stdin, so a client secret never appears as a flag/argv,
// which would leak into `ps`.
func readLineFromStdin(cmd *cobra.Command) (string, error) {
	line, err := bufio.NewReader(cmd.InOrStdin()).ReadString('\n')
	if err != nil && err != io.EOF {
		return "", err
	}
	line = strings.TrimSpace(line)
	if line == "" {
		return "", fmt.Errorf("client secret must not be empty")
	}
	return line, nil
}
