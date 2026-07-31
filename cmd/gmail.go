package cmd

import (
	"fmt"

	"watchtower/internal/calendar"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gmail"

	"github.com/spf13/cobra"
)

var gmailSyncFlagAccount int64

var gmailCmd = &cobra.Command{
	Use:   "gmail",
	Short: "Gmail integration",
}

var gmailLoginCmd = &cobra.Command{
	Use:   "login",
	Short: "Connect Gmail (alias for 'google login --gmail' on account #1)",
	RunE:  runGmailLogin,
}

var gmailLogoutCmd = &cobra.Command{
	Use:   "logout",
	Short: "Disconnect Gmail",
	RunE:  runGmailLogout,
}

var gmailSyncCmd = &cobra.Command{
	Use:   "sync",
	Short: "Sync Gmail inbox messages for every connected account",
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
	gmailSyncCmd.Flags().Int64Var(&gmailSyncFlagAccount, "account", 0, "sync only this account id")

	gmailCmd.AddCommand(gmailLoginCmd)
	gmailCmd.AddCommand(gmailLogoutCmd)
	gmailCmd.AddCommand(gmailSyncCmd)
	gmailCmd.AddCommand(gmailStatusCmd)

	rootCmd.AddCommand(gmailCmd)
}

// runGmailLogin is the `gmail login` alias: it targets google_accounts row #1
// (creating it if this is the very first Google login ever), requesting
// Gmail access — plus Calendar too when account #1 already has it enabled,
// so an existing Calendar grant on the shared token survives the re-consent.
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

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	accountID, isNewRow, err := resolveAccountOneForLogin(cmd, cfg, database)
	if err != nil {
		return err
	}
	acct, err := database.GetGoogleAccount(accountID)
	if err != nil {
		return fmt.Errorf("loading account %d: %w", accountID, err)
	}

	return connectGoogleAccount(cmd, cfg, database, accountID, acct.CalendarEnabled, true, isNewRow)
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

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	return disconnectGoogleService(cmd, cfg, database, "gmail")
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
	total, synced := 0, 0
	for _, acct := range accounts {
		if !acct.GmailEnabled {
			continue
		}
		if gmailSyncFlagAccount != 0 && acct.ID != gmailSyncFlagAccount {
			continue
		}
		store := gmail.NewAccountTokenStore(cfg.WorkspaceDir(), acct.ID)
		if !store.Exists() {
			continue
		}
		token, err := store.Load()
		if err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "account %d: failed to load token: %v\n", acct.ID, err)
			continue
		}
		googleCfg := resolveGoogleOAuthConfigForAccount(cfg.WorkspaceDir(), acct.ID)
		client, err := gmail.NewClient(cmd.Context(), token.RefreshToken,
			gmail.GoogleOAuthConfig{ClientID: googleCfg.ClientID, ClientSecret: googleCfg.ClientSecret})
		if err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "account %d: failed to create client: %v\n", acct.ID, err)
			continue
		}
		syncer := gmail.NewSyncer(client, database, cfg, nil, acct.ID)
		count, err := syncer.Sync(cmd.Context())
		if err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "account %d: sync failed: %v\n", acct.ID, err)
			continue
		}
		total += count
		synced++
	}

	if synced == 0 {
		fmt.Fprintln(out, "No connected Gmail accounts to sync. Run 'watchtower gmail login' first.")
		return nil
	}
	fmt.Fprintf(out, "Synced %d gmail messages across %d account(s).\n", total, synced)
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
	found := false
	for _, a := range accounts {
		if !a.GmailEnabled {
			continue
		}
		found = true
		tokenPath := calendar.NewAccountTokenStore(cfg.WorkspaceDir(), a.ID).Path()
		connected := calendar.NewAccountTokenStore(cfg.WorkspaceDir(), a.ID).Exists()
		state := "connected"
		if !connected {
			state = "token missing"
		}
		fmt.Fprintf(out, "#%d %s — %s (%s)\n", a.ID, googleAccountDisplayName(a), a.Status, state)
		fmt.Fprintf(out, "  Token file: %s\n", tokenPath)
	}
	if !found {
		fmt.Fprintln(out, "Gmail: not connected")
		fmt.Fprintln(out, "Run 'watchtower gmail login' to connect.")
	}
	return nil
}
