package cmd

import (
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/imap"

	"github.com/spf13/cobra"
	"golang.org/x/term"
)

var imapCmd = &cobra.Command{
	Use:   "imap",
	Short: "IMAP email integration",
}

var (
	imapAddFlagHost     string
	imapAddFlagPort     int
	imapAddFlagUsername string
	imapAddFlagFolder   string
	imapAddFlagSecurity string
	imapAddFlagLabel    string
)

var imapAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Connect a new IMAP mailbox",
	Long: "Connects a new IMAP mailbox and adds it to the watchtower inbox. " +
		"The password is read from stdin — a hidden prompt when run interactively, " +
		"or the full piped input otherwise — never as a flag, which would leak into `ps`.",
	RunE: runImapAdd,
}

var imapRemoveCmd = &cobra.Command{
	Use:   "remove <account-id>",
	Short: "Disconnect an IMAP/Outlook mailbox",
	Args:  cobra.ExactArgs(1),
	RunE:  runImapRemove,
}

var imapListCmd = &cobra.Command{
	Use:   "list",
	Short: "List connected IMAP/Outlook mailboxes",
	RunE:  runImapList,
}

func init() {
	imapAddCmd.Flags().StringVar(&imapAddFlagHost, "host", "", "IMAP server host (required)")
	imapAddCmd.Flags().IntVar(&imapAddFlagPort, "port", 993, "IMAP server port")
	imapAddCmd.Flags().StringVar(&imapAddFlagUsername, "username", "", "IMAP username / email address (required)")
	imapAddCmd.Flags().StringVar(&imapAddFlagFolder, "folder", "INBOX", "mailbox folder to sync")
	imapAddCmd.Flags().StringVar(&imapAddFlagSecurity, "security", "ssl", "connection security: ssl | starttls | none")
	imapAddCmd.Flags().StringVar(&imapAddFlagLabel, "label", "", "display name for this account")

	imapCmd.AddCommand(imapAddCmd)
	imapCmd.AddCommand(imapRemoveCmd)
	imapCmd.AddCommand(imapListCmd)
	rootCmd.AddCommand(imapCmd)
}

// createEmailAccountWithCredentials creates the email_accounts row and then
// persists its credentials, rolling back the row (best-effort) if the
// credential save fails. Without this, a save failure after the row already
// exists leaves an orphaned "ok"-status ghost account: it looks connected in
// `imap list`/the Desktop UI, but can never actually sync since no
// credentials were ever written for it. Shared by `imap add` and
// `outlook login`. Returns the new account's ID on success.
func createEmailAccountWithCredentials(database *db.DB, workspaceDir string, account db.EmailAccount, creds *imap.Credentials, warnOut io.Writer) (int64, error) {
	id, err := database.CreateEmailAccount(account)
	if err != nil {
		return 0, fmt.Errorf("saving account: %w", err)
	}
	store := imap.NewCredentialStore(workspaceDir, id)
	if err := store.Save(creds); err != nil {
		if delErr := database.DeleteEmailAccount(id); delErr != nil {
			fmt.Fprintf(warnOut, "warning: failed to roll back orphaned account %d after credential save failure: %v\n", id, delErr)
		}
		return 0, fmt.Errorf("saving credentials: %w", err)
	}
	return id, nil
}

func runImapAdd(cmd *cobra.Command, _ []string) error {
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

	if imapAddFlagHost == "" || imapAddFlagUsername == "" {
		return fmt.Errorf("--host and --username are required")
	}
	security := strings.ToLower(imapAddFlagSecurity)
	switch security {
	case "ssl", "starttls", "none":
	default:
		return fmt.Errorf("--security must be one of ssl, starttls, none")
	}
	folder := imapAddFlagFolder
	if folder == "" {
		folder = "INBOX"
	}

	password, err := readPassword(cmd)
	if err != nil {
		return fmt.Errorf("reading password: %w", err)
	}
	if password == "" {
		return fmt.Errorf("password must not be empty")
	}

	out := cmd.OutOrStdout()
	fmt.Fprintln(out, "Testing connection...")

	accountCfg := imap.AccountConfig{
		Host: imapAddFlagHost, Port: imapAddFlagPort,
		Security: imap.Security(security), Folder: folder,
	}
	auth := imap.PasswordAuth{Username: imapAddFlagUsername, Password: password}
	client, _, err := imap.Dial(accountCfg, auth)
	if err != nil {
		return fmt.Errorf("imap add: connection test failed: %w", err)
	}
	_ = client.Close()

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	id, err := createEmailAccountWithCredentials(database, cfg.WorkspaceDir(), db.EmailAccount{
		Provider: "imap", EmailAddress: imapAddFlagUsername,
		Host: imapAddFlagHost, Port: imapAddFlagPort,
		Security: security, Folder: folder, Label: imapAddFlagLabel,
	}, &imap.Credentials{Password: password}, cmd.ErrOrStderr())
	if err != nil {
		return err
	}

	fmt.Fprintf(out, "Connected %s (account id %d).\n", imapAddFlagUsername, id)
	fmt.Fprintln(out, "Restart the daemon to pick up the new mailbox immediately.")
	return nil
}

func runImapRemove(cmd *cobra.Command, args []string) error {
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

func runImapList(cmd *cobra.Command, _ []string) error {
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

	accounts, err := database.ListEmailAccounts()
	if err != nil {
		return fmt.Errorf("listing accounts: %w", err)
	}

	out := cmd.OutOrStdout()
	if len(accounts) == 0 {
		fmt.Fprintln(out, "No IMAP/Outlook accounts connected.")
		return nil
	}
	for _, a := range accounts {
		label := a.Label
		if label == "" {
			label = "-"
		}
		fmt.Fprintf(out, "%d\t%s\t%s\t%s\t%s\n", a.ID, a.Provider, a.EmailAddress, a.Status, label)
	}
	return nil
}

// readPassword reads the mailbox password from stdin: a hidden terminal
// prompt when interactive, or the full piped input when not (e.g. spawned by
// the Desktop app) — never via a flag/argv, which would leak into `ps`.
func readPassword(cmd *cobra.Command) (string, error) {
	in := cmd.InOrStdin()
	if f, ok := in.(*os.File); ok && term.IsTerminal(int(f.Fd())) {
		out := cmd.OutOrStdout()
		fmt.Fprint(out, "Password: ")
		data, err := term.ReadPassword(int(f.Fd()))
		fmt.Fprintln(out)
		if err != nil {
			return "", err
		}
		return strings.TrimSpace(string(data)), nil
	}
	data, err := io.ReadAll(in)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}
