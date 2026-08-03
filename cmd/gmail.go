package cmd

import (
	"bufio"
	"fmt"
	"io"
	"strings"

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

var gmailPurgeCmd = &cobra.Command{
	Use:   "purge",
	Short: "Delete one account's synced Gmail data",
	Long: "Deletes the mail Watchtower synced for one Google account and the inbox\n" +
		"items it produced, together with the situations and feed rows left orphaned.\n" +
		"Other accounts and the rest of the inbox are untouched.\n\n" +
		"This is irreversible, but not a disconnect: the account stays connected and\n" +
		"the sync watermark is preserved, so a later sync resumes from where it left\n" +
		"off rather than re-downloading the deleted mail. Run 'watchtower gmail\n" +
		"logout' first to stop syncing. Knowledge already derived into the memory\n" +
		"vault is preserved — removing that is a separate, explicit choice.",
	RunE: runGmailPurge,
}

func init() {
	gmailLoginCmd.Flags().Bool("no-open", false, "print the authorize URL instead of opening a browser")
	gmailLoginCmd.Flags().Bool("app-return", false, "redirect the browser back to the Watchtower app when done")
	gmailSyncCmd.Flags().Int64Var(&gmailSyncFlagAccount, "account", 0, "sync only this account id")
	gmailPurgeCmd.Flags().Int64("account", 0, "account id whose Gmail data to delete (required)")
	gmailPurgeCmd.Flags().Bool("yes", false, "skip the confirmation prompt")

	gmailCmd.AddCommand(gmailLoginCmd)
	gmailCmd.AddCommand(gmailLogoutCmd)
	gmailCmd.AddCommand(gmailSyncCmd)
	gmailCmd.AddCommand(gmailStatusCmd)
	gmailCmd.AddCommand(gmailPurgeCmd)

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

// runGmailPurge deletes one account's synced Gmail data. The account is never
// implicit — multi-account installs are live, so --account is required rather
// than defaulting to account #1 the way the login aliases do.
func runGmailPurge(cmd *cobra.Command, _ []string) error {
	accountID, _ := cmd.Flags().GetInt64("account")
	if accountID == 0 {
		return fmt.Errorf("--account <id> is required; run 'watchtower google accounts' to list them")
	}
	assumeYes, _ := cmd.Flags().GetBool("yes")

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

	acct, err := database.GetGoogleAccount(accountID)
	if err != nil {
		return fmt.Errorf("account %d not found: %w", accountID, err)
	}

	var messages, items int
	if err := database.QueryRow(
		`SELECT (SELECT COUNT(*) FROM gmail_messages WHERE account_id = ?),
		        (SELECT COUNT(*) FROM inbox_items WHERE channel_id LIKE ? || ':%')`,
		accountID, db.GmailChannelPrefix(accountID)).Scan(&messages, &items); err != nil {
		return fmt.Errorf("counting gmail data: %w", err)
	}

	out := cmd.OutOrStdout()
	if !assumeYes {
		fmt.Fprintf(out, "Delete %d gmail message(s) and %d inbox item(s) for account #%d (%s)? This cannot be undone. [y/N]: ",
			messages, items, acct.ID, googleAccountDisplayName(acct))
		line, readErr := bufio.NewReader(cmd.InOrStdin()).ReadString('\n')
		if readErr != nil && readErr != io.EOF {
			return fmt.Errorf("reading confirmation: %w", readErr)
		}
		if answer := strings.TrimSpace(strings.ToLower(line)); answer != "y" && answer != "yes" {
			fmt.Fprintln(out, "Aborted.")
			return nil
		}
	}

	if err := database.ClearGmailData(accountID); err != nil {
		return fmt.Errorf("purging gmail data: %w", err)
	}

	fmt.Fprintf(out, "Gmail data removed for account #%d (%s): %d message(s), %d inbox item(s).\n",
		acct.ID, googleAccountDisplayName(acct), messages, items)
	fmt.Fprintln(out, "The account stays connected and its sync watermark is preserved; run 'watchtower gmail logout' to stop syncing.")
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
