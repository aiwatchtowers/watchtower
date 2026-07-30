package cmd

import (
	"context"
	"fmt"

	"watchtower/internal/calendar"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gmail"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var gmailCmd = &cobra.Command{
	Use:   "gmail",
	Short: "Gmail integration",
}

var gmailLoginCmd = &cobra.Command{
	Use:   "login",
	Short: "Connect Gmail",
	RunE:  runGmailLogin,
}

var gmailLogoutCmd = &cobra.Command{
	Use:   "logout",
	Short: "Disconnect Gmail",
	RunE:  runGmailLogout,
}

var gmailSyncCmd = &cobra.Command{
	Use:   "sync",
	Short: "Sync Gmail inbox messages",
	RunE:  runGmailSync,
}

var gmailStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show Gmail connection status",
	RunE:  runGmailStatus,
}

func init() {
	gmailLoginCmd.Flags().Bool("no-open", false, "print the authorize URL instead of opening a browser")
	gmailLoginCmd.Flags().Bool("app-return", false, "redirect the browser back to the Watchtower app when done")

	gmailCmd.AddCommand(gmailLoginCmd)
	gmailCmd.AddCommand(gmailLogoutCmd)
	gmailCmd.AddCommand(gmailSyncCmd)
	gmailCmd.AddCommand(gmailStatusCmd)

	rootCmd.AddCommand(gmailCmd)
}

// gmailOAuthConfig converts the shared Google OAuth credentials into gmail's
// own config type — the gmail package intentionally does not import calendar.
func gmailOAuthConfig() gmail.GoogleOAuthConfig {
	c := resolveGoogleOAuthConfig()
	return gmail.GoogleOAuthConfig{ClientID: c.ClientID, ClientSecret: c.ClientSecret}
}

func runGmailLogin(cmd *cobra.Command, _ []string) error {
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

	noOpen, _ := cmd.Flags().GetBool("no-open")
	appReturn, _ := cmd.Flags().GetBool("app-return")
	out := cmd.OutOrStdout()

	token, err := gmail.Login(cmd.Context(), gmailOAuthConfig(), out, gmail.LoginOptions{SkipBrowserOpen: noOpen, AppReturn: appReturn})
	if err != nil {
		return fmt.Errorf("gmail login: %w", err)
	}

	store := gmail.NewTokenStore(cfg.WorkspaceDir())
	if err := store.Save(token); err != nil {
		return fmt.Errorf("saving token: %w", err)
	}

	// Clear any previously recorded auth failure so the Desktop popup dismisses.
	if database, dbErr := db.Open(cfg.DBPath()); dbErr == nil {
		_ = database.SetGoogleAccountAuthState(stubGoogleAccountID, "ok", "")
		database.Close()
	}

	persistGmailAccountEmail(cmd.Context(), token.RefreshToken)

	fmt.Fprintf(out, "\nGmail connected!\n")
	fmt.Fprintf(out, "Token saved to: %s\n", store.Path())
	fmt.Fprintf(out, "Run 'watchtower gmail sync' to fetch messages.\n")

	return nil
}

// persistGmailAccountEmail resolves the connected account's email via the
// Gmail profile API and writes gmail.account_email to config. It is the inbox
// detectors' identity fallback when no Slack identity exists. Best-effort:
// on failure the detectors simply keep using the Slack-derived email.
func persistGmailAccountEmail(ctx context.Context, refreshToken string) {
	client, err := gmail.NewClient(ctx, refreshToken, gmailOAuthConfig())
	if err != nil {
		return
	}
	profile, err := client.GetProfile(ctx)
	if err != nil || profile.EmailAddress == "" {
		return
	}
	v := viper.New()
	v.SetConfigFile(flagConfig)
	_ = v.ReadInConfig()
	v.Set("gmail.account_email", profile.EmailAddress)
	_ = writeConfigAtomic(v, flagConfig)
}

func runGmailLogout(cmd *cobra.Command, _ []string) error {
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

	store := gmail.NewTokenStore(cfg.WorkspaceDir())

	// Revoke the grant at Google — otherwise the account keeps it and the
	// next consent screen says "already has some access" instead of listing
	// permissions. Skip when the Calendar token shares this grant (combined
	// `google login`): revocation kills the whole grant, not one scope.
	if token, loadErr := store.Load(); loadErr == nil && token.RefreshToken != "" {
		sharedWithCalendar := false
		if calToken, cErr := calendar.NewTokenStore(cfg.WorkspaceDir()).Load(); cErr == nil {
			sharedWithCalendar = calToken.RefreshToken == token.RefreshToken
		}
		if sharedWithCalendar {
			fmt.Fprintln(cmd.OutOrStdout(), "Note: Google Calendar shares this Google grant — not revoking it at Google. Disconnect Calendar to revoke fully.")
		} else if revokeErr := gmail.Revoke(cmd.Context(), token.RefreshToken); revokeErr != nil {
			fmt.Fprintf(cmd.OutOrStdout(), "Warning: could not revoke the grant at Google: %v\n", revokeErr)
		}
	}

	if err := store.Delete(); err != nil {
		return fmt.Errorf("deleting token: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	// Clear auth state — user intentionally disconnected, not a token failure.
	_ = database.SetGoogleAccountAuthState(stubGoogleAccountID, "ok", "")

	fmt.Fprintln(cmd.OutOrStdout(), "Gmail disconnected. Token removed.")
	return nil
}

func runGmailSync(cmd *cobra.Command, _ []string) error {
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

	store := gmail.NewTokenStore(cfg.WorkspaceDir())
	token, err := store.Load()
	if err != nil {
		return fmt.Errorf("loading Gmail token: %w (run 'watchtower gmail login' first)", err)
	}

	client, err := gmail.NewClient(cmd.Context(), token.RefreshToken, gmailOAuthConfig())
	if err != nil {
		return fmt.Errorf("creating gmail client: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	syncer := gmail.NewSyncer(client, database, cfg, nil)
	count, err := syncer.Sync(cmd.Context())
	if err != nil {
		return fmt.Errorf("syncing gmail: %w", err)
	}

	fmt.Fprintf(cmd.OutOrStdout(), "Synced %d gmail messages.\n", count)
	return nil
}

func runGmailStatus(cmd *cobra.Command, _ []string) error {
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
	store := gmail.NewTokenStore(cfg.WorkspaceDir())

	if store.Exists() {
		fmt.Fprintln(out, "Gmail: connected")
		fmt.Fprintf(out, "Token file: %s\n", store.Path())
		fmt.Fprintf(out, "Gmail enabled: %v\n", cfg.Gmail.Enabled)
	} else {
		fmt.Fprintln(out, "Gmail: not connected")
		fmt.Fprintln(out, "Run 'watchtower gmail login' to connect.")
	}
	return nil
}
