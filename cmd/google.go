package cmd

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"strconv"
	"strings"

	"watchtower/internal/calendar"
	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gmail"
	"watchtower/internal/oauthpage"
	"watchtower/internal/policy"

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
		"Pass --client-id together with --client-secret-stdin to sign in through your own\n" +
		"Google Cloud project instead of Watchtower's build-time default: the client is\n" +
		"stored as your personal company (see 'watchtower company list') and an account\n" +
		"of the same Gmail address moves onto it. Refused when your organization's\n" +
		"policy sets AllowOwnGoogleProject to false.",
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
	googleLoginCmd.Flags().Bool("app-return", false, "bring the Watchtower app back to the front when done")
	googleLoginCmd.Flags().Int64("account", 0, "existing account id to re-consent (default: account #1, created if it doesn't exist)")

	googleAddCmd.Flags().Bool("calendar", false, "request Google Calendar access")
	googleAddCmd.Flags().Bool("gmail", false, "request Gmail access")
	googleAddCmd.Flags().String("label", "", "display name for this account")
	googleAddCmd.Flags().String("client-id", "", "bring your own Google OAuth client id (non-secret half)")
	googleAddCmd.Flags().Bool("client-secret-stdin", false, "read the OAuth client secret from stdin (required with --client-id)")
	googleAddCmd.Flags().String("company", "", "sign in through this stored company's Google app (its slug, see 'watchtower company list'); the account is tied to the company")
	googleAddCmd.Flags().Bool("no-open", false, "print the authorize URL instead of opening a browser")
	googleAddCmd.Flags().Bool("app-return", false, "bring the Watchtower app back to the front when done")
	googleAddCmd.Flags().Bool("json", false, "with --client-id: end with one JSON result line (ok|rejected|network|cancelled, the account and its address)")

	googleCmd.AddCommand(googleLoginCmd)
	googleCmd.AddCommand(googleAddCmd)
	googleAccountsCmd.Flags().Bool("json", false, "print JSON (with each account's company and shared-client flags)")
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
	if asJSON, _ := cmd.Flags().GetBool("json"); asJSON && clientID == "" {
		return usageError("--json is for --client-id (your own Google project)")
	}
	// The company's client comes first: an unknown company fails here,
	// before any row, seed or browser.
	slug, _ := cmd.Flags().GetString("company")
	var companyClient *companybundle.Google
	if slug != "" {
		if clientID != "" {
			return fmt.Errorf("--company and --client-id cannot be combined")
		}
		if err := refusePersonalCompany(cfg.WorkspaceDir(), slug); err != nil {
			return err
		}
		if companyClient, err = companyGoogle(cfg.WorkspaceDir(), slug); err != nil {
			return err
		}
	}
	// An own Google project (#1887 §4): refused by the policy before the
	// secret is read, a malformed client before the browser opens.
	var ownClient *companybundle.Google
	if clientID != "" {
		if !policy.Current().OwnGoogleProjectAllowed() {
			return errOwnGoogleProjectForbidden
		}
		secret, err := readLineFromStdin(cmd)
		if err != nil {
			return fmt.Errorf("reading client secret: %w", err)
		}
		g, err := company.CheckPersonalGoogle(companybundle.Google{ClientID: clientID, ClientSecret: secret})
		if err != nil {
			return err
		}
		ownClient = &g
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	// Seed account #1 from a pre-multi-account legacy token file, if one
	// exists and no account row does yet — closes the narrow window where an
	// onboarding entry point could call `google add` before the daemon/CLI
	// has ever run the same seed, creating a duplicate for the same login.
	// This only SEEDS legacy state; `google add` always creates a NEW account
	// below regardless of whether a seed happened.
	logger := log.New(cmd.ErrOrStderr(), "[google] ", log.LstdFlags)
	if _, err := ensureLegacyGoogleAccount(cmd.Context(), cfg, database, logger); err != nil {
		logger.Printf("failed to seed legacy account: %v", err)
	}

	if companyClient != nil {
		return addGoogleAccountForCompany(cmd, cfg, database, companyClient, slug, label, wantCalendar, wantGmail)
	}
	if ownClient != nil {
		return addOwnGoogleProject(cmd, cfg, database, ownClient, label, wantCalendar, wantGmail)
	}

	id, err := database.CreateGoogleAccount(db.GoogleAccount{Label: label})
	if err != nil {
		return fmt.Errorf("creating account: %w", err)
	}
	return connectGoogleAccount(cmd, cfg, database, id, wantCalendar, wantGmail, true)
}

// addOwnGoogleProject is `google add --client-id`: the company path
// (googleCompanyConsent → recordGoogleCompanyGrant) with the own project g
// stored as a personal bundle named after the signed-in address
// (company.SavePersonal) once the consent succeeded and the row's checks
// passed (googleCompanyGrantRow): a cancelled consent or a refused re-tie
// stores nothing. A failure after it (the token write) leaves the bundle,
// which the next add of the same client reuses.
//
// With --json (the Desktop's own-project page, #1887 C4) a failed sign-in or
// a refused re-tie is a result line in `company check`'s shape (rejected
// with the vendor's code, network, cancelled) and exit 0, as a success is
// (ok, the account and its address); any other failure stays an error.
func addOwnGoogleProject(cmd *cobra.Command, cfg *config.Config, database *db.DB, g *companybundle.Google, label string, wantCalendar, wantGmail bool) error {
	asJSON, _ := cmd.Flags().GetBool("json")
	grant, err := googleCompanyConsent(cmd, g, wantCalendar, wantGmail)
	if err != nil {
		if asJSON {
			return writeCompanyResult(cmd, classifySignInError(cmd.Context(), err), nil)
		}
		return err
	}
	if _, err := googleCompanyGrantRow(database, grant); err != nil {
		if res, rerr := refusedGrant(err); asJSON && rerr == nil {
			return writeCompanyResult(cmd, res, nil)
		}
		return err
	}
	// Asked again: IT may have forbidden own projects during the consent.
	if !policy.Current().OwnGoogleProjectAllowed() {
		return errOwnGoogleProjectForbidden
	}
	slug, err := company.SavePersonal(company.NewStore(cfg.WorkspaceDir()), companyForcedBundle(), grant.result.email, *g)
	if err != nil {
		return fmt.Errorf("saving your own Google project: %w", err)
	}
	id, err := recordGoogleCompanyGrant(cmd, cfg, database, grant, slug, label)
	if err != nil || !asJSON {
		return err
	}
	return writeCompanyResult(cmd, companyCheckResult{Result: checkOK, Slug: slug, AccountID: id, Email: grant.result.email,
		NotGranted: grant.result.notGranted()}, nil)
}

// notGranted names the requested services the consent left unapproved
// ("calendar", "gmail"); nil when every one was granted.
func (r googleConnectResult) notGranted() []string {
	var missing []string
	if r.wantCalendar && !r.calEnabled {
		missing = append(missing, "calendar")
	}
	if r.wantGmail && !r.gmEnabled {
		missing = append(missing, "gmail")
	}
	return missing
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
	if asJSON, _ := cmd.Flags().GetBool("json"); asJSON {
		return writeGoogleAccountsJSON(out, cfg.WorkspaceDir(), accounts)
	}
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

	removed, err := removeGoogleAccount(cmd.Context(), cfg, database, id, cmd.ErrOrStderr())
	if err != nil {
		return fmt.Errorf("removing account: %w", err)
	}

	out := cmd.OutOrStdout()
	fmt.Fprintf(out, "Removed account %d.\n", id)
	if len(removed) > 0 {
		fmt.Fprintf(out, "Deleted: %s\n", strings.Join(removed, ", "))
	}
	return nil
}

// removeGoogleAccount revokes id's OAuth grant at Google (best-effort — a
// revoke failure is logged and swallowed, since a stale grant on Google's
// side never blocks the local removal), purges the Gmail data that has no FK
// back to the account row, deletes id's google_accounts row (cascading its
// calendars/events/messages — an event a recording or recap references is
// kept, its calendar detached; see db.DeleteGoogleAccount), then deletes its token and
// credentials files. It also deletes any lingering legacy
// google_token.json/gmail_token.json (belt-and-braces: after the C1 fix to
// ensureLegacyGoogleAccount these shouldn't exist once any account is
// connected, but a leftover legacy file must never keep granting silent
// access after the account it was migrated into is removed).
func removeGoogleAccount(ctx context.Context, cfg *config.Config, database *db.DB, id int64, warnOut io.Writer) ([]string, error) {
	tokenStore := calendar.NewAccountTokenStore(cfg.WorkspaceDir(), id)
	if token, loadErr := tokenStore.Load(); loadErr == nil && token.RefreshToken != "" {
		if revokeErr := calendar.Revoke(ctx, token.RefreshToken); revokeErr != nil {
			fmt.Fprintf(warnOut, "warning: could not revoke the grant at Google: %v\n", revokeErr)
		}
	}

	// Before the row goes: the Gmail inbox items, their situations and the
	// learned rules keyed to them hang off the "gmail:<id>:" channel-id
	// convention, not off a foreign key, so nothing cascades them. They also
	// become unreachable once the account row is gone — `gmail purge` resolves
	// its account first — so a failure here must abort the removal rather than
	// leave orphans no command can ever clean up. ClearGmailData is
	// transactional and idempotent: the user can just retry.
	if err := database.ClearGmailData(id); err != nil {
		return nil, err
	}

	if err := database.DeleteGoogleAccount(id); err != nil {
		return nil, err
	}

	var removed []string
	removed = append(removed, deleteFileStore(tokenStore, "token file", warnOut)...)
	removed = append(removed, deleteFileStore(calendar.NewCredentialStore(cfg.WorkspaceDir(), id), "credentials file", warnOut)...)
	removed = append(removed, deleteFileStore(calendar.NewTokenStore(cfg.WorkspaceDir()), "legacy calendar token", warnOut)...)
	removed = append(removed, deleteFileStore(gmail.NewTokenStore(cfg.WorkspaceDir()), "legacy gmail token", warnOut)...)
	return removed, nil
}

// fileStore is the common shape of calendar.TokenStore/CredentialStore and
// gmail.TokenStore — enough to delete one on-disk file generically.
type fileStore interface {
	Exists() bool
	Delete() error
}

// deleteFileStore deletes store's file if present, returning []string{label}
// on success (for the caller's "Deleted: ..." summary) or nil otherwise — a
// missing file is a silent no-op, a delete error is logged to warnOut and
// swallowed (matches the house no-op/best-effort pattern for cleanup steps).
func deleteFileStore(store fileStore, label string, warnOut io.Writer) []string {
	if !store.Exists() {
		return nil
	}
	if err := store.Delete(); err != nil {
		fmt.Fprintf(warnOut, "warning: failed to remove %s: %v\n", label, err)
		return nil
	}
	return []string{label}
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

// googleOAuthLogin is calendar.Login; a var so tests can script the grant.
var googleOAuthLogin = calendar.Login

// loginAndSaveGoogleToken runs the OAuth consent flow for accountID and
// persists the resulting token — with recordClient (a company's account),
// together with the client it was issued to (saveGoogleGrant). When isNewRow
// is true, either failure rolls back the just-created row (and any
// credentials file) — mirrors createEmailAccountWithCredentials
// (cmd/imap.go): a caller-visible account id must never be created and then
// left un-loginable.
func loginAndSaveGoogleToken(cmd *cobra.Command, cfg *config.Config, database *db.DB, accountID int64, googleCfg calendar.GoogleOAuthConfig, recordClient bool, scopes []string, noOpen, appReturn, isNewRow bool) (*calendar.OAuthToken, error) {
	token, err := runGoogleConsent(cmd, googleCfg, scopes, noOpen, appReturn)
	if err != nil {
		if isNewRow {
			rollbackGoogleAccount(database, cfg.WorkspaceDir(), accountID, cmd.ErrOrStderr())
		}
		return nil, err
	}
	if err := refuseLoginDuringPurge(database, "google", accountID); err != nil {
		return nil, err
	}
	if err := saveGoogleGrant(cfg.WorkspaceDir(), accountID, googleCfg, recordClient, token); err != nil {
		if isNewRow {
			rollbackGoogleAccount(database, cfg.WorkspaceDir(), accountID, cmd.ErrOrStderr())
		}
		return nil, err
	}
	return token, nil
}

// runGoogleConsent runs one Google consent through googleCfg.
func runGoogleConsent(cmd *cobra.Command, googleCfg calendar.GoogleOAuthConfig, scopes []string, noOpen, appReturn bool) (*calendar.OAuthToken, error) {
	token, err := googleOAuthLogin(cmd.Context(), googleCfg, cmd.OutOrStdout(), calendar.LoginOptions{
		SkipBrowserOpen: noOpen,
		Scopes:          scopes,
		AppReturn:       appReturn,
	})
	oauthpage.ReturnAfterLogin(appReturn, err, cmd.ErrOrStderr())
	if err != nil {
		return nil, fmt.Errorf("google login: %w", err)
	}
	return token, nil
}

// saveGoogleGrant writes accountID's new token and, with recordClient, first
// the client it was issued to (google_credentials_<id>.json, the record the
// resolver compares a company's app with, #1887 P4). A failed token write
// puts the previous credentials back, so the record never names a client the
// stored token was not issued to. No lock is needed: only a sign-in writes
// either file (Google never rotates the refresh token), and the daemon keeps
// the pair it was wired with.
func saveGoogleGrant(workspaceDir string, accountID int64, googleCfg calendar.GoogleOAuthConfig, recordClient bool, token *calendar.OAuthToken) error {
	restore := func() error { return nil }
	if recordClient {
		var err error
		if restore, err = replaceGoogleCredentials(workspaceDir, accountID, googleCfg); err != nil {
			return fmt.Errorf("saving the account's Google client: %w", err)
		}
	}
	if err := calendar.NewAccountTokenStore(workspaceDir, accountID).Save(token); err != nil {
		return errors.Join(fmt.Errorf("saving token: %w", err), restore())
	}
	return nil
}

// replaceGoogleCredentials writes googleCfg as accountID's credentials and
// returns how to put the previous file (or its absence) back.
func replaceGoogleCredentials(workspaceDir string, accountID int64, googleCfg calendar.GoogleOAuthConfig) (func() error, error) {
	store := calendar.NewCredentialStore(workspaceDir, accountID)
	var prev *calendar.Credentials
	if store.Exists() {
		prev, _ = store.Load() // a damaged file is not worth restoring
	}
	if err := store.Save(&calendar.Credentials{ClientID: googleCfg.ClientID, ClientSecret: googleCfg.ClientSecret}); err != nil {
		return nil, err
	}
	return func() error {
		var err error
		if prev != nil {
			err = store.Save(prev)
		} else {
			err = store.Delete()
		}
		if err != nil {
			return fmt.Errorf("restoring the account's previous Google client: %w", err)
		}
		return nil
	}, nil
}

// googleGrantEmail is the Gmail profile's address for a fresh grant; a var
// so tests answer it without Google.
var googleGrantEmail = func(ctx context.Context, googleCfg calendar.GoogleOAuthConfig, refreshToken string) (string, error) {
	client, err := gmail.NewClient(ctx, refreshToken,
		gmail.GoogleOAuthConfig{ClientID: googleCfg.ClientID, ClientSecret: googleCfg.ClientSecret})
	if err != nil {
		return "", err
	}
	profile, err := client.GetProfile(ctx)
	if err != nil {
		return "", err
	}
	return profile.EmailAddress, nil
}

// resolveGoogleConnectionResult derives which of the requested services
// actually got granted from token's scopes and, when Gmail was granted,
// best-effort fetches the account's email via the Gmail profile API — any
// lookup failure just leaves email blank, it never fails the connect.
func resolveGoogleConnectionResult(ctx context.Context, googleCfg calendar.GoogleOAuthConfig, token *calendar.OAuthToken, wantCalendar, wantGmail bool) (calEnabled, gmEnabled bool, email string) {
	calEnabled = wantCalendar && token.GrantsScope(calendar.ScopeCalendarReadonly)
	gmEnabled = wantGmail && token.GrantsScope(gmail.ScopeGmailReadonly)
	if !gmEnabled {
		return calEnabled, gmEnabled, ""
	}
	email, err := googleGrantEmail(ctx, googleCfg, token.RefreshToken)
	if err != nil {
		return calEnabled, gmEnabled, ""
	}
	return calEnabled, gmEnabled, email
}

// printGoogleConnectionResult reports which of the requested services
// actually got granted — a partial consent leaves one unapproved on the
// consent screen — plus the account id.
func printGoogleConnectionResult(out io.Writer, wantCalendar, wantGmail, calEnabled, gmEnabled bool, accountID int64) {
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
}

// connectGoogleAccount runs the OAuth consent flow for accountID and records
// the result: which services actually got granted, the account's email
// (best-effort via the Gmail profile API when Gmail access was granted), and
// auth state. An account tied to a company signs in through the company's
// app as it stands and records it as the account's client (#1887).
func connectGoogleAccount(cmd *cobra.Command, cfg *config.Config, database *db.DB, accountID int64, wantCalendar, wantGmail, isNewRow bool) error {
	out := cmd.OutOrStdout()
	noOpen, _ := cmd.Flags().GetBool("no-open")
	appReturn, _ := cmd.Flags().GetBool("app-return")

	acct, err := database.GetGoogleAccount(accountID)
	if err != nil {
		return fmt.Errorf("loading account %d: %w", accountID, err)
	}
	if err := refuseStoppedOwnProject(cfg.WorkspaceDir(), acct); err != nil {
		return err
	}
	googleCfg, err := googleLoginOAuthConfig(cfg.WorkspaceDir(), acct)
	if err != nil {
		if isNewRow {
			rollbackGoogleAccount(database, cfg.WorkspaceDir(), accountID, cmd.ErrOrStderr())
		}
		return fmt.Errorf("%w: open your company's Watchtower link, or set WATCHTOWER_GOOGLE_CLIENT_ID for development", err)
	}
	scopes, err := googleScopesFor(googleCfg.ClientID, wantCalendar, wantGmail)
	if err != nil {
		if isNewRow {
			rollbackGoogleAccount(database, cfg.WorkspaceDir(), accountID, cmd.ErrOrStderr())
		}
		return fmt.Errorf("google account %d: %w", accountID, err)
	}
	tied := acct.CompanySlug != ""
	token, err := loginAndSaveGoogleToken(cmd, cfg, database, accountID, googleCfg, tied, scopes, noOpen, appReturn, isNewRow)
	if err != nil {
		return err
	}
	if tied {
		if err := database.SetGoogleAccountClient(accountID, googleCfg.ClientID, acct.CompanySlug); err != nil {
			return fmt.Errorf("recording the account's client: %w", err)
		}
	}

	calEnabled, gmEnabled, email := resolveGoogleConnectionResult(cmd.Context(), googleCfg, token, wantCalendar, wantGmail)
	return recordGoogleConnection(out, cmd.ErrOrStderr(), flagConfig, cfg, database, accountID,
		googleConnectResult{wantCalendar: wantCalendar, wantGmail: wantGmail, calEnabled: calEnabled, gmEnabled: gmEnabled, email: email})
}

// addGoogleAccountForCompany is `google add --company <slug>`: the sign-in
// runs through the company's Google app (an unknown slug, or a company
// without one, fails before the browser opens), and the grant lands on the
// row of the same Google user when one exists — that row is re-tied to the
// company and records the company's client, so a person who had the account
// on the shared client keeps one row (#1887 Review Focus 5) — else on a new
// row tied to the company in the same insert. The same user is the same
// Gmail address (case-insensitive): a Calendar-only grant has no address and
// always gets a new row; a Gmail grant whose address cannot be read creates
// nothing.
func addGoogleAccountForCompany(cmd *cobra.Command, cfg *config.Config, database *db.DB, g *companybundle.Google, slug, label string, wantCalendar, wantGmail bool) error {
	grant, err := googleCompanyConsent(cmd, g, wantCalendar, wantGmail)
	if errors.Is(err, errGmailNeedsOwnProject) {
		return fmt.Errorf("company %s: %w", slug, err)
	}
	if err != nil {
		return err
	}
	_, err = recordGoogleCompanyGrant(cmd, cfg, database, grant, slug, label)
	return err
}

// googleCompanyGrant is a finished consent through a company's Google app,
// not yet stored anywhere.
type googleCompanyGrant struct {
	cfg    calendar.GoogleOAuthConfig
	token  *calendar.OAuthToken
	result googleConnectResult
}

// googleCompanyConsent runs the consent through g and reads the account's
// Gmail address; it stores nothing.
func googleCompanyConsent(cmd *cobra.Command, g *companybundle.Google, wantCalendar, wantGmail bool) (googleCompanyGrant, error) {
	noOpen, _ := cmd.Flags().GetBool("no-open")
	appReturn, _ := cmd.Flags().GetBool("app-return")
	googleCfg := calendar.GoogleOAuthConfig{ClientID: g.ClientID, ClientSecret: g.ClientSecret}

	scopes, err := googleScopesFor(googleCfg.ClientID, wantCalendar, wantGmail)
	if err != nil {
		return googleCompanyGrant{}, err
	}
	token, err := runGoogleConsent(cmd, googleCfg, scopes, noOpen, appReturn)
	if err != nil {
		return googleCompanyGrant{}, err
	}
	calEnabled, gmEnabled, email := resolveGoogleConnectionResult(cmd.Context(), googleCfg, token, wantCalendar, wantGmail)
	if gmEnabled && email == "" {
		// Without the address the person's existing row cannot be found; a
		// second row for the same user is worse than asking again.
		return googleCompanyGrant{}, errors.New("google sign-in: could not read the Gmail address of the account — try again")
	}
	return googleCompanyGrant{cfg: googleCfg, token: token, result: googleConnectResult{
		wantCalendar: wantCalendar, wantGmail: wantGmail, calEnabled: calEnabled, gmEnabled: gmEnabled, email: email,
	}}, nil
}

// recordGoogleCompanyGrant lands grant on the row of the same Google user
// (re-tied to slug) or on a new row tied to slug, and returns the row.
func recordGoogleCompanyGrant(cmd *cobra.Command, cfg *config.Config, database *db.DB, grant googleCompanyGrant, slug, label string) (int64, error) {
	r := grant.result
	id, err := googleCompanyGrantRow(database, grant)
	if err != nil {
		return 0, err
	}
	isNewRow := id == 0
	if isNewRow {
		if id, err = database.CreateGoogleAccount(db.GoogleAccount{Label: label, ClientID: grant.cfg.ClientID, CompanySlug: slug}); err != nil {
			return 0, fmt.Errorf("creating account: %w", err)
		}
	}
	if err := saveGoogleGrant(cfg.WorkspaceDir(), id, grant.cfg, true, grant.token); err != nil {
		if isNewRow {
			rollbackGoogleAccount(database, cfg.WorkspaceDir(), id, cmd.ErrOrStderr())
		}
		return 0, err
	}
	if !isNewRow {
		if err := database.SetGoogleAccountClient(id, grant.cfg.ClientID, slug); err != nil {
			return 0, fmt.Errorf("tying account %d to %s: %w", id, slug, err)
		}
		fmt.Fprintf(cmd.OutOrStdout(), "Google account %d (%s) now signs in through %s's app.\n", id, r.email, slug)
	}
	return id, recordGoogleConnection(cmd.OutOrStdout(), cmd.ErrOrStderr(), flagConfig, cfg, database, id, r)
}

// errGrantTooNarrow is a grant that lacks a service the row it replaces
// syncs.
var errGrantTooNarrow = errors.New("the new sign-in lacks a service the account syncs")

// googleGrantCoversRow refuses a re-tie of account id whose new grant lacks
// a service the row already syncs (errGrantTooNarrow).
func googleGrantCoversRow(database *db.DB, id int64, calGranted, gmGranted bool) error {
	acct, err := database.GetGoogleAccount(id)
	if err != nil {
		return fmt.Errorf("loading account %d: %w", id, err)
	}
	if (acct.CalendarEnabled && !calGranted) || (acct.GmailEnabled && !gmGranted) {
		return fmt.Errorf("%w: google account %d also syncs %s; run again with --calendar --gmail and approve both on the consent screen",
			errGrantTooNarrow, id, googleAccountServiceBadges(acct))
	}
	return nil
}

// googleCompanyGrantRow is the row a company's Google grant lands on: the
// first account of the same Gmail address, or 0 for a new row. A grant that
// cannot replace that row's (it lacks a service the row syncs —
// errGrantTooNarrow — or the row's purge is running) is refused. It writes
// nothing.
func googleCompanyGrantRow(database *db.DB, grant googleCompanyGrant) (int64, error) {
	r := grant.result
	if r.email == "" {
		return 0, nil
	}
	accounts, err := database.ListGoogleAccounts()
	if err != nil {
		return 0, fmt.Errorf("listing accounts: %w", err)
	}
	for _, a := range accounts {
		if !strings.EqualFold(a.Email, r.email) {
			continue
		}
		// The new grant replaces the row's: it must cover every service the
		// row syncs, or re-tying would silently switch one off.
		if err := googleGrantCoversRow(database, a.ID, r.calEnabled, r.gmEnabled); err != nil {
			return 0, err
		}
		if err := refuseLoginDuringPurge(database, "google", a.ID); err != nil {
			return 0, err
		}
		return a.ID, nil
	}
	return 0, nil
}

// googleConnectResult is what one consent asked for and what it granted.
type googleConnectResult struct {
	wantCalendar, wantGmail bool
	calEnabled, gmEnabled   bool
	email                   string
}

// recordGoogleConnection stores a finished consent for accountID — granted
// services, email, auth state — reports it, and turns on the global sync
// switch for every service the consent granted (#740). A re-consent counts
// too: reconnecting a service is asking for it to sync, so a switch the
// owner turned off in Settings comes back on (owner decision 2026-10-14).
// The account is connected once the row is written, so a failed switch write
// is a warning, not a failed connect (the Calendar tab offers Turn On
// Calendar Sync).
func recordGoogleConnection(out, errOut io.Writer, configPath string, cfg *config.Config, database *db.DB, accountID int64, r googleConnectResult) error {
	if err := database.UpdateGoogleAccountConnection(accountID, r.email, r.calEnabled, r.gmEnabled); err != nil {
		return fmt.Errorf("recording connection: %w", err)
	}
	// A login always clears a Re-login mark; a check relies on it to clear
	// its own Replace mark.
	if err := database.SetGoogleAccountAuthState(accountID, "ok", ""); err != nil {
		return fmt.Errorf("recording auth state: %w", err)
	}

	printGoogleConnectionResult(out, r.wantCalendar, r.wantGmail, r.calEnabled, r.gmEnabled, accountID)
	if err := enableGoogleSyncSwitches(configPath, cfg, r.calEnabled, r.gmEnabled); err != nil {
		fmt.Fprintf(errOut, "warning: account connected, but turning its sync on failed: %v\n", err)
	}
	return nil
}

// enableGoogleSyncSwitches turns on the global `calendar.enabled` /
// `gmail.enabled` daemon-phase switches for the given services.
// `wireGoogleSyncers` wires a syncer only when both the switch and the
// account's flag are on. Both switches default to on (#757), so this matters
// for a config that carries an explicit `enabled: false` — without it a newly
// connected account would never sync. Called from the one connect path every
// surface shares (onboarding, Settings, the Calendar tab, the CLI). A switch
// already on is not rewritten.
func enableGoogleSyncSwitches(configPath string, cfg *config.Config, calGranted, gmGranted bool) error {
	if calGranted && !cfg.Calendar.Enabled {
		if err := setConfigKey(configPath, "calendar.enabled", true); err != nil {
			return err
		}
	}
	if gmGranted && !cfg.Gmail.Enabled {
		if err := setConfigKey(configPath, "gmail.enabled", true); err != nil {
			return err
		}
	}
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
//
// "Account #1" here means accounts[0] — the oldest surviving row
// (ListGoogleAccounts orders by id ASC), NOT literally the row whose id
// column equals 1. This is deliberate and matches resolveAccountOneForLogin
// (used by `google login`/`gmail login`/`calendar login` without --account):
// that function also resolves to whatever ensureLegacyGoogleAccount reports,
// which is likewise the first row by id. So if id=1 is ever removed via
// `google remove 1`, the next-oldest remaining account transparently becomes
// the new "account #1" for every one of these aliases — consistent, not a
// bug, even though no code enforces id==1 anywhere.
//
// It returns the id of the account it disconnected, or 0 when no Google
// account exists, so `calendar logout` can scope its purge to that account.
func disconnectGoogleService(cmd *cobra.Command, cfg *config.Config, database *db.DB, service string) (int64, error) {
	accounts, err := database.ListGoogleAccounts()
	if err != nil {
		return 0, fmt.Errorf("listing accounts: %w", err)
	}
	out := cmd.OutOrStdout()
	if len(accounts) == 0 {
		fmt.Fprintln(out, "No Google account connected.")
		return 0, nil
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
		return 0, fmt.Errorf("updating account: %w", err)
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
		return acct.ID, nil
	}

	// Clear a previously recorded plain error so the Desktop popup dismisses.
	// No authenticated call was made: the access facts stay (a revocation, and
	// a purge it scheduled, are not cleared by a disconnect, #601).
	if err := database.ClearGoogleAccountError(acct.ID); err != nil {
		return 0, err
	}
	fmt.Fprintf(out, "%s disconnected.\n", googleServiceLabel(service))
	return acct.ID, nil
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
