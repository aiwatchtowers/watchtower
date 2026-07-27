package cmd

import (
	"fmt"
	"io"
	"strconv"
	"time"

	"watchtower/internal/caldav"
	"watchtower/internal/config"
	"watchtower/internal/db"

	"github.com/spf13/cobra"
)

var caldavCmd = &cobra.Command{
	Use:   "caldav",
	Short: "CalDAV / ICS calendar integration",
}

var (
	caldavAddFlagURL      string
	caldavAddFlagUsername string
	caldavAddFlagLabel    string
	caldavAddICSFlagLabel string
)

var caldavAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Connect a new CalDAV calendar account",
	Long: "Connects a CalDAV server (iCloud, Fastmail, Yandex, Nextcloud, corporate) " +
		"as a calendar source. The password is read from stdin — a hidden prompt when " +
		"run interactively, or the full piped input otherwise — never as a flag, which " +
		"would leak into `ps`.",
	RunE: runCalDAVAdd,
}

var caldavAddICSCmd = &cobra.Command{
	Use:   "add-ics",
	Short: "Connect a secret ICS feed URL as a calendar source",
	Long: "Connects a secret ICS feed (Google Calendar's \"Secret address in iCal " +
		"format\", Outlook published calendars). The feed URL is itself a credential, " +
		"so it is read from stdin — never as a flag, which would leak into `ps` — and " +
		"stored only in the per-account credential file, never the database.",
	RunE: runCalDAVAddICS,
}

var caldavRemoveCmd = &cobra.Command{
	Use:   "remove <account-id>",
	Short: "Disconnect a CalDAV/ICS calendar account",
	Args:  cobra.ExactArgs(1),
	RunE:  runCalDAVRemove,
}

var caldavListCmd = &cobra.Command{
	Use:   "list",
	Short: "List connected CalDAV/ICS calendar accounts",
	RunE:  runCalDAVList,
}

func init() {
	caldavAddCmd.Flags().StringVar(&caldavAddFlagURL, "url", "", "CalDAV server base URL (required)")
	caldavAddCmd.Flags().StringVar(&caldavAddFlagUsername, "username", "", "CalDAV username / email address (required)")
	caldavAddCmd.Flags().StringVar(&caldavAddFlagLabel, "label", "", "display name for this account")
	caldavAddICSCmd.Flags().StringVar(&caldavAddICSFlagLabel, "label", "", "display name for this account")

	caldavCmd.AddCommand(caldavAddCmd)
	caldavCmd.AddCommand(caldavAddICSCmd)
	caldavCmd.AddCommand(caldavRemoveCmd)
	caldavCmd.AddCommand(caldavListCmd)
	rootCmd.AddCommand(caldavCmd)
}

// createCalendarAccountWithCredentials creates the calendar_accounts row and
// then persists its credentials, rolling back the row (best-effort) if the
// credential save fails — otherwise a save failure leaves an orphaned
// "ok"-status ghost account that looks connected but can never sync. The
// calendar analog of createEmailAccountWithCredentials. Shared by
// `caldav add` and `caldav add-ics`. Returns the new account's ID on success.
func createCalendarAccountWithCredentials(database *db.DB, workspaceDir string, account db.CalendarAccount, creds *caldav.Credentials, warnOut io.Writer) (int64, error) {
	id, err := database.CreateCalendarAccount(account)
	if err != nil {
		return 0, fmt.Errorf("saving account: %w", err)
	}
	store := caldav.NewCredentialStore(workspaceDir, id)
	if err := store.Save(creds); err != nil {
		if delErr := database.DeleteCalendarAccount(id); delErr != nil {
			fmt.Fprintf(warnOut, "warning: failed to roll back orphaned account %d after credential save failure: %v\n", id, delErr)
		}
		return 0, fmt.Errorf("saving credentials: %w", err)
	}
	return id, nil
}

// caldavTestWindow is the connection-test fetch window: same shape as the
// syncer's real window, just fixed to the default days-ahead.
func caldavTestWindow() (time.Time, time.Time) {
	now := time.Now().UTC()
	return now.Add(-24 * time.Hour), now.Add(config.DefaultCalendarSyncDaysAhead * 24 * time.Hour)
}

func runCalDAVAdd(cmd *cobra.Command, _ []string) error {
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

	if caldavAddFlagURL == "" || caldavAddFlagUsername == "" {
		return fmt.Errorf("--url and --username are required")
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

	client, err := caldav.DialCalDAV(caldavAddFlagURL, caldavAddFlagUsername, password)
	if err != nil {
		return fmt.Errorf("caldav add: connection test failed: %w", err)
	}
	winStart, winEnd := caldavTestWindow()
	if _, err := client.FetchEvents(cmdContext(cmd), winStart, winEnd); err != nil {
		return fmt.Errorf("caldav add: connection test failed: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	id, err := createCalendarAccountWithCredentials(database, cfg.WorkspaceDir(), db.CalendarAccount{
		Provider: "caldav", Username: caldavAddFlagUsername,
		URL: caldavAddFlagURL, Label: caldavAddFlagLabel,
	}, &caldav.Credentials{Password: password}, cmd.ErrOrStderr())
	if err != nil {
		return err
	}

	fmt.Fprintf(out, "Connected %s (account id %d).\n", caldavAddFlagUsername, id)
	fmt.Fprintln(out, "Restart the daemon to pick up the new calendar immediately.")
	return nil
}

func runCalDAVAddICS(cmd *cobra.Command, _ []string) error {
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

	// The secret feed URL is a credential: read it from stdin exactly like a
	// password (hidden prompt when interactive, piped input otherwise).
	feedURL, err := readPassword(cmd)
	if err != nil {
		return fmt.Errorf("reading feed URL: %w", err)
	}
	if feedURL == "" {
		return fmt.Errorf("feed URL must not be empty")
	}

	out := cmd.OutOrStdout()
	fmt.Fprintln(out, "Testing connection...")

	if _, err := caldav.FetchICS(cmdContext(cmd), feedURL); err != nil {
		return fmt.Errorf("caldav add-ics: connection test failed: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	// url column stays EMPTY for ics: the feed URL lives only in the
	// credential file (see internal/db/migrations/00023_calendar_accounts.sql).
	id, err := createCalendarAccountWithCredentials(database, cfg.WorkspaceDir(), db.CalendarAccount{
		Provider: "ics", Label: caldavAddICSFlagLabel,
	}, &caldav.Credentials{FeedURL: feedURL}, cmd.ErrOrStderr())
	if err != nil {
		return err
	}

	fmt.Fprintf(out, "Connected ICS feed (account id %d).\n", id)
	fmt.Fprintln(out, "Restart the daemon to pick up the new calendar immediately.")
	return nil
}

func runCalDAVRemove(cmd *cobra.Command, args []string) error {
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

	if err := database.DeleteCalendarAccount(id); err != nil {
		return fmt.Errorf("removing account: %w", err)
	}
	if err := caldav.NewCredentialStore(cfg.WorkspaceDir(), id).Delete(); err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: failed to remove credentials file: %v\n", err)
	}

	fmt.Fprintf(cmd.OutOrStdout(), "Removed account %d.\n", id)
	return nil
}

func runCalDAVList(cmd *cobra.Command, _ []string) error {
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

	accounts, err := database.ListCalendarAccounts()
	if err != nil {
		return fmt.Errorf("listing accounts: %w", err)
	}

	out := cmd.OutOrStdout()
	if len(accounts) == 0 {
		fmt.Fprintln(out, "No CalDAV/ICS calendar accounts connected.")
		return nil
	}
	for _, a := range accounts {
		who := a.Username
		if a.Provider == "ics" {
			who = "(ics feed)"
		}
		label := a.Label
		if label == "" {
			label = "-"
		}
		fmt.Fprintf(out, "%d\t%s\t%s\t%s\t%s\n", a.ID, a.Provider, who, a.Status, label)
	}
	return nil
}
