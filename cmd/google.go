package cmd

import (
	"fmt"

	"watchtower/internal/calendar"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gmail"

	"github.com/spf13/cobra"
)

// stubGoogleAccountID is a placeholder google_accounts id used across cmd's
// Google-related commands until they thread a real connected account
// (multi-account plan Task 7) — single-account installs always seed/migrate
// account id 1.
const stubGoogleAccountID = 1

var googleCmd = &cobra.Command{
	Use:   "google",
	Short: "Google account integration",
}

var googleLoginCmd = &cobra.Command{
	Use:   "login",
	Short: "Connect Google services (Calendar and/or Gmail) in a single consent flow",
	Long: "Runs one OAuth flow requesting exactly the scopes for the selected services,\n" +
		"so Google shows a single consent screen listing precisely what access is granted.\n" +
		"With both services selected Google shows one checkbox per permission — a partial\n" +
		"grant connects only the approved services.",
	RunE: runGoogleLogin,
}

func init() {
	googleLoginCmd.Flags().Bool("calendar", false, "request Google Calendar access")
	googleLoginCmd.Flags().Bool("gmail", false, "request Gmail access")
	googleLoginCmd.Flags().Bool("no-open", false, "print the authorize URL instead of opening a browser")
	googleLoginCmd.Flags().Bool("app-return", false, "redirect the browser back to the Watchtower app when done")

	googleCmd.AddCommand(googleLoginCmd)
	rootCmd.AddCommand(googleCmd)
}

func runGoogleLogin(cmd *cobra.Command, _ []string) error {
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

	var scopes []string
	if wantCalendar {
		scopes = append(scopes, calendar.ScopeCalendarReadonly)
	}
	if wantGmail {
		scopes = append(scopes, gmail.ScopeGmailReadonly)
	}

	noOpen, _ := cmd.Flags().GetBool("no-open")
	appReturn, _ := cmd.Flags().GetBool("app-return")
	out := cmd.OutOrStdout()

	token, err := calendar.Login(cmd.Context(), resolveGoogleOAuthConfig(), out, calendar.LoginOptions{
		SkipBrowserOpen: noOpen,
		Scopes:          scopes,
		AppReturn:       appReturn,
	})
	if err != nil {
		return fmt.Errorf("google login: %w", err)
	}

	fmt.Fprintln(out)
	if wantCalendar {
		if token.GrantsScope(calendar.ScopeCalendarReadonly) {
			store := calendar.NewTokenStore(cfg.WorkspaceDir())
			if err := store.Save(token); err != nil {
				return fmt.Errorf("saving calendar token: %w", err)
			}
			if database, dbErr := db.Open(cfg.DBPath()); dbErr == nil {
				_ = database.SetGoogleAccountAuthState(stubGoogleAccountID, "ok", "")
				database.Close()
			}
			fmt.Fprintln(out, "Google Calendar: connected")
		} else {
			fmt.Fprintln(out, "Google Calendar: NOT granted — its permission was left unapproved on the consent screen")
		}
	}
	if wantGmail {
		if token.GrantsScope(gmail.ScopeGmailReadonly) {
			store := gmail.NewTokenStore(cfg.WorkspaceDir())
			gmailToken := &gmail.OAuthToken{
				AccessToken:  token.AccessToken,
				TokenType:    token.TokenType,
				RefreshToken: token.RefreshToken,
				Expiry:       token.Expiry,
				Scope:        token.Scope,
			}
			if err := store.Save(gmailToken); err != nil {
				return fmt.Errorf("saving gmail token: %w", err)
			}
			if database, dbErr := db.Open(cfg.DBPath()); dbErr == nil {
				_ = database.SetGoogleAccountAuthState(stubGoogleAccountID, "ok", "")
				database.Close()
			}
			persistGmailAccountEmail(cmd.Context(), token.RefreshToken)
			fmt.Fprintln(out, "Gmail: connected")
		} else {
			fmt.Fprintln(out, "Gmail: NOT granted — its permission was left unapproved on the consent screen")
		}
	}

	return nil
}
