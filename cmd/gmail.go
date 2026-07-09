package cmd

import (
	"fmt"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gmail"

	"github.com/spf13/cobra"
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
	out := cmd.OutOrStdout()

	token, err := gmail.Login(cmd.Context(), gmailOAuthConfig(), out, gmail.LoginOptions{SkipBrowserOpen: noOpen})
	if err != nil {
		return fmt.Errorf("gmail login: %w", err)
	}

	store := gmail.NewTokenStore(cfg.WorkspaceDir())
	if err := store.Save(token); err != nil {
		return fmt.Errorf("saving token: %w", err)
	}

	// Clear any previously recorded auth failure so the Desktop popup dismisses.
	if database, dbErr := db.Open(cfg.DBPath()); dbErr == nil {
		_ = database.SetGmailAuthState("ok", "")
		database.Close()
	}

	fmt.Fprintf(out, "\nGmail connected!\n")
	fmt.Fprintf(out, "Token saved to: %s\n", store.Path())
	fmt.Fprintf(out, "Run 'watchtower gmail sync' to fetch messages.\n")

	return nil
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
	if err := store.Delete(); err != nil {
		return fmt.Errorf("deleting token: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	// Clear auth state — user intentionally disconnected, not a token failure.
	_ = database.SetGmailAuthState("ok", "")

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
