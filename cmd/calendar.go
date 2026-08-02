package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	"watchtower/internal/calendar"
	"watchtower/internal/config"
	"watchtower/internal/db"

	"github.com/spf13/cobra"
)

var calendarFlagDays int
var calendarFlagJSON bool
var calendarSyncFlagAccount int64

var calendarCmd = &cobra.Command{
	Use:   "calendar",
	Short: "Show upcoming calendar events",
	RunE:  runCalendar,
}

var calendarLoginCmd = &cobra.Command{
	Use:   "login",
	Short: "Connect Google Calendar (alias for 'google login --calendar' on account #1)",
	RunE:  runCalendarLogin,
}

var calendarLogoutCmd = &cobra.Command{
	Use:   "logout",
	Short: "Disconnect Google Calendar",
	RunE:  runCalendarLogout,
}

var calendarSyncCmd = &cobra.Command{
	Use:   "sync",
	Short: "Sync calendar events for every connected account",
	RunE:  runCalendarSync,
}

var calendarStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show calendar connection status",
	RunE:  runCalendarStatus,
}

var calendarListCmd = &cobra.Command{
	Use:   "list",
	Short: "List synced calendars",
	RunE:  runCalendarList,
}

var calendarEventsCmd = &cobra.Command{
	Use:   "events",
	Short: "List calendar events",
	RunE:  runCalendarEvents,
}

var calendarSelectCmd = &cobra.Command{
	Use:   "select [calendar-id]",
	Short: "Toggle calendar selection for sync",
	Args:  cobra.ExactArgs(1),
	RunE:  runCalendarSelect,
}

func init() {
	rootCmd.AddCommand(calendarCmd)
	calendarCmd.AddCommand(calendarLoginCmd)
	calendarCmd.AddCommand(calendarLogoutCmd)
	calendarCmd.AddCommand(calendarSyncCmd)
	calendarCmd.AddCommand(calendarStatusCmd)
	calendarCmd.AddCommand(calendarListCmd)
	calendarCmd.AddCommand(calendarEventsCmd)
	calendarCmd.AddCommand(calendarSelectCmd)

	calendarCmd.Flags().IntVar(&calendarFlagDays, "days", 0, "number of days to show (default: sync_days_ahead from config)")
	calendarCmd.Flags().BoolVar(&calendarFlagJSON, "json", false, "output as JSON")
	calendarEventsCmd.Flags().IntVar(&calendarFlagDays, "days", 0, "number of days to show")
	calendarEventsCmd.Flags().BoolVar(&calendarFlagJSON, "json", false, "output as JSON")

	calendarLoginCmd.Flags().Bool("no-open", false, "don't open the browser automatically")
	calendarLoginCmd.Flags().Bool("app-return", false, "redirect the browser back to the Watchtower app when done")
	calendarSyncCmd.Flags().Int64Var(&calendarSyncFlagAccount, "account", 0, "sync only this account id")
}

func runCalendar(cmd *cobra.Command, _ []string) error {
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

	days := cfg.Calendar.SyncDaysAhead
	if calendarFlagDays > 0 {
		days = calendarFlagDays
	}
	if days <= 0 {
		days = config.DefaultCalendarSyncDaysAhead
	}

	now := time.Now().UTC()
	fromTime := now.Format(time.RFC3339)
	toTime := now.Add(time.Duration(days) * 24 * time.Hour).Format(time.RFC3339)

	events, err := database.GetCalendarEvents(db.CalendarEventFilter{FromTime: fromTime, ToTime: toTime})
	if err != nil {
		return fmt.Errorf("querying events: %w", err)
	}

	out := cmd.OutOrStdout()

	if calendarFlagJSON {
		return json.NewEncoder(out).Encode(events)
	}

	if len(events) == 0 {
		fmt.Fprintln(out, "No upcoming calendar events.")
		fmt.Fprintln(out, "Run 'watchtower calendar login' to connect Google Calendar.")
		return nil
	}

	printCalendarEvents(cmd, events)
	return nil
}

// runCalendarLogin is the `calendar login` alias: it targets google_accounts
// row #1 (creating it if this is the very first Google login ever),
// requesting Calendar access — plus Gmail too when account #1 already has it
// enabled, so an existing Gmail grant on the shared token survives the
// re-consent.
func runCalendarLogin(cmd *cobra.Command, _ []string) error {
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

	return connectGoogleAccount(cmd, cfg, database, accountID, true, acct.GmailEnabled, isNewRow)
}

func runCalendarLogout(cmd *cobra.Command, _ []string) error {
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

	if err := disconnectGoogleService(cmd, cfg, database, "calendar"); err != nil {
		return err
	}

	if err := database.ClearCalendarEvents(); err != nil {
		return fmt.Errorf("clearing events: %w", err)
	}
	fmt.Fprintln(cmd.OutOrStdout(), "Calendar events removed.")
	return nil
}

func runCalendarSync(cmd *cobra.Command, _ []string) error {
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
		if !acct.CalendarEnabled {
			continue
		}
		if calendarSyncFlagAccount != 0 && acct.ID != calendarSyncFlagAccount {
			continue
		}
		store := calendar.NewAccountTokenStore(cfg.WorkspaceDir(), acct.ID)
		if !store.Exists() {
			continue
		}
		token, err := store.Load()
		if err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "account %d: failed to load token: %v\n", acct.ID, err)
			continue
		}
		googleCfg := resolveGoogleOAuthConfigForAccount(cfg.WorkspaceDir(), acct.ID)
		client, err := calendar.NewClient(cmd.Context(), token.RefreshToken, googleCfg)
		if err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "account %d: failed to create client: %v\n", acct.ID, err)
			continue
		}
		syncer := calendar.NewSyncer(client, database, cfg, nil, acct.ID)
		count, err := syncer.Sync(cmd.Context())
		if err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "account %d: sync failed: %v\n", acct.ID, err)
			continue
		}
		total += count
		synced++
	}

	if synced == 0 {
		fmt.Fprintln(out, "No connected calendar accounts to sync. Run 'watchtower calendar login' first.")
		return nil
	}
	fmt.Fprintf(out, "Synced %d calendar events across %d account(s).\n", total, synced)
	return nil
}

func runCalendarStatus(cmd *cobra.Command, _ []string) error {
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
		if !a.CalendarEnabled {
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
		fmt.Fprintln(out, "Google Calendar: not connected")
		fmt.Fprintln(out, "Run 'watchtower calendar login' to connect.")
		return nil
	}
	fmt.Fprintf(out, "Sync days ahead: %d\n", cfg.Calendar.SyncDaysAhead)
	return nil
}

func runCalendarList(cmd *cobra.Command, _ []string) error {
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

	cals, err := database.GetCalendars()
	if err != nil {
		return fmt.Errorf("querying calendars: %w", err)
	}

	out := cmd.OutOrStdout()
	if len(cals) == 0 {
		fmt.Fprintln(out, "No calendars synced. Run 'watchtower calendar sync' first.")
		return nil
	}

	for _, c := range cals {
		selected := " "
		if c.IsSelected {
			selected = "*"
		}
		primary := ""
		if c.IsPrimary {
			primary = " (primary)"
		}
		fmt.Fprintf(out, "[%s] %s%s  — %s\n", selected, c.Name, primary, c.ID)
	}
	return nil
}

func runCalendarEvents(cmd *cobra.Command, _ []string) error {
	return runCalendar(cmd, nil)
}

func runCalendarSelect(cmd *cobra.Command, args []string) error {
	calendarID := args[0]

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

	// Toggle: find current state and flip it.
	cals, err := database.GetCalendars()
	if err != nil {
		return fmt.Errorf("querying calendars: %w", err)
	}

	found := false
	newState := true
	for _, c := range cals {
		if c.ID == calendarID {
			found = true
			newState = !c.IsSelected
			break
		}
	}
	if !found {
		return fmt.Errorf("calendar %q not found; run 'watchtower calendar sync' first", calendarID)
	}

	if err := database.SetCalendarSelected(calendarID, newState); err != nil {
		return fmt.Errorf("updating calendar selection: %w", err)
	}

	action := "selected"
	if !newState {
		action = "deselected"
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Calendar %q %s.\n", calendarID, action)
	return nil
}

func printCalendarEvents(cmd *cobra.Command, events []db.CalendarEvent) {
	out := cmd.OutOrStdout()
	lastDate := ""
	for _, e := range events {
		start, _ := time.Parse(time.RFC3339, e.StartTime)
		end, _ := time.Parse(time.RFC3339, e.EndTime)
		start = start.Local()
		end = end.Local()
		dateStr := start.Format("Mon, Jan 2")

		if dateStr != lastDate {
			if lastDate != "" {
				fmt.Fprintln(out)
			}
			fmt.Fprintf(out, "%s\n", dateStr)
			lastDate = dateStr
		}

		var timeStr string
		if e.IsAllDay {
			timeStr = "  All day"
		} else {
			timeStr = fmt.Sprintf("  %s-%s", start.Format("15:04"), end.Format("15:04"))
		}

		fmt.Fprintf(out, "%s  %s", timeStr, e.Title)
		if e.Location != "" {
			fmt.Fprintf(out, " @ %s", e.Location)
		}
		fmt.Fprintln(out)
	}
}

// resolveGoogleOAuthConfig returns Google OAuth credentials.
func resolveGoogleOAuthConfig() calendar.GoogleOAuthConfig {
	clientID := os.Getenv("WATCHTOWER_GOOGLE_CLIENT_ID")
	if clientID == "" {
		clientID = calendar.DefaultGoogleClientID
	}
	clientSecret := os.Getenv("WATCHTOWER_GOOGLE_CLIENT_SECRET")
	if clientSecret == "" {
		clientSecret = calendar.DefaultGoogleClientSecret
	}
	return calendar.GoogleOAuthConfig{
		ClientID:     clientID,
		ClientSecret: clientSecret,
	}
}

// resolveGoogleOAuthConfigForAccount returns accountID's own OAuth client
// credentials (google_credentials_<id>.json) when the account brought its
// own Google Cloud project, falling back to resolveGoogleOAuthConfig's
// env/build defaults otherwise.
func resolveGoogleOAuthConfigForAccount(workspaceDir string, accountID int64) calendar.GoogleOAuthConfig {
	store := calendar.NewCredentialStore(workspaceDir, accountID)
	if store.Exists() {
		if creds, err := store.Load(); err == nil && creds.ClientID != "" {
			return calendar.GoogleOAuthConfig{
				ClientID:     creds.ClientID,
				ClientSecret: creds.ClientSecret,
			}
		}
	}
	return resolveGoogleOAuthConfig()
}
