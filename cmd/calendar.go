package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	"watchtower/internal/calendar"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gmail"

	"github.com/spf13/cobra"
)

var calendarFlagDays int
var calendarFlagJSON bool

var calendarCmd = &cobra.Command{
	Use:   "calendar",
	Short: "Show upcoming calendar events",
	RunE:  runCalendar,
}

var calendarLoginCmd = &cobra.Command{
	Use:   "login",
	Short: "Connect Google Calendar",
	RunE:  runCalendarLogin,
}

var calendarLogoutCmd = &cobra.Command{
	Use:   "logout",
	Short: "Disconnect Google Calendar",
	RunE:  runCalendarLogout,
}

var calendarSyncCmd = &cobra.Command{
	Use:   "sync",
	Short: "Sync calendar events",
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

	googleCfg := resolveGoogleOAuthConfig()

	noOpen, _ := cmd.Flags().GetBool("no-open")
	appReturn, _ := cmd.Flags().GetBool("app-return")
	out := cmd.OutOrStdout()

	token, err := calendar.Login(cmd.Context(), googleCfg, out, calendar.LoginOptions{SkipBrowserOpen: noOpen, AppReturn: appReturn})
	if err != nil {
		return fmt.Errorf("google calendar login: %w", err)
	}
	if !token.GrantsCalendar() {
		return fmt.Errorf("google granted only part of the calendar access (granted: %q) — run login again and approve both calendar permissions on the consent screen", token.Scope)
	}

	store := calendar.NewTokenStore(cfg.WorkspaceDir())
	if err := store.Save(token); err != nil {
		return fmt.Errorf("saving token: %w", err)
	}

	// Clear any previously recorded auth failure so the Desktop popup dismisses.
	if database, dbErr := db.Open(cfg.DBPath()); dbErr == nil {
		_ = database.SetCalendarAuthState("ok", "")
		database.Close()
	}

	fmt.Fprintf(out, "\nGoogle Calendar connected!\n")
	fmt.Fprintf(out, "Token saved to: %s\n", store.Path())
	fmt.Fprintf(out, "Run 'watchtower calendar sync' to fetch events.\n")

	return nil
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

	store := calendar.NewTokenStore(cfg.WorkspaceDir())

	// Revoke the grant at Google — otherwise the account keeps it and the
	// next consent screen says "already has some access" instead of listing
	// permissions. Skip when the Gmail token shares this grant (combined
	// `google login`): revocation kills the whole grant, not one scope.
	if token, loadErr := store.Load(); loadErr == nil && token.RefreshToken != "" {
		sharedWithGmail := false
		if gmailToken, gErr := gmail.NewTokenStore(cfg.WorkspaceDir()).Load(); gErr == nil {
			sharedWithGmail = gmailToken.RefreshToken == token.RefreshToken
		}
		if sharedWithGmail {
			fmt.Fprintln(cmd.OutOrStdout(), "Note: Gmail shares this Google grant — not revoking it at Google. Disconnect Gmail to revoke fully.")
		} else if revokeErr := calendar.Revoke(cmd.Context(), token.RefreshToken); revokeErr != nil {
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

	if err := database.ClearCalendarEvents(); err != nil {
		return fmt.Errorf("clearing events: %w", err)
	}

	// Clear auth state — user intentionally disconnected, not a token failure.
	_ = database.SetCalendarAuthState("ok", "")

	fmt.Fprintln(cmd.OutOrStdout(), "Google Calendar disconnected. Token and events removed.")
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

	store := calendar.NewTokenStore(cfg.WorkspaceDir())
	token, err := store.Load()
	if err != nil {
		return fmt.Errorf("loading Google token: %w (run 'watchtower calendar login' first)", err)
	}

	googleCfg := resolveGoogleOAuthConfig()
	client, err := calendar.NewClient(cmd.Context(), token.RefreshToken, googleCfg)
	if err != nil {
		return fmt.Errorf("creating calendar client: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	syncer := calendar.NewSyncer(client, database, cfg, nil)
	count, err := syncer.Sync(cmd.Context())
	if err != nil {
		return fmt.Errorf("syncing calendar: %w", err)
	}

	fmt.Fprintf(cmd.OutOrStdout(), "Synced %d calendar events.\n", count)
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

	out := cmd.OutOrStdout()
	store := calendar.NewTokenStore(cfg.WorkspaceDir())

	if store.Exists() {
		fmt.Fprintln(out, "Google Calendar: connected")
		fmt.Fprintf(out, "Token file: %s\n", store.Path())
		fmt.Fprintf(out, "Calendar enabled: %v\n", cfg.Calendar.Enabled)
		fmt.Fprintf(out, "Sync days ahead: %d\n", cfg.Calendar.SyncDaysAhead)
	} else {
		fmt.Fprintln(out, "Google Calendar: not connected")
		fmt.Fprintln(out, "Run 'watchtower calendar login' to connect.")
	}
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
