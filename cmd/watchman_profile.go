package cmd

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/watchman"
)

var (
	watchmanProfileFlagWorkbench int64
	watchmanProfileFlagJSON      bool
	watchmanProfileFlagKey       string
	watchmanProfileFlagTextFile  string
)

func init() {
	profile := &cobra.Command{
		Use:   "profile",
		Short: "Show what Watchman learned: the rules per decision category and the sleep window",
		Long: "Watchman rebuilds each category's rules (at most 20 lines, from the newest decisions) and the sleep window " +
			"(HH:MM-HH:MM, from the last 28 days of your activity) once a week. An entry you set yourself is pinned: " +
			"the rebuild leaves it as it is until you unpin it.",
		Args: cobra.NoArgs,
		RunE: runWatchmanProfile,
	}
	profile.Flags().Int64Var(&watchmanProfileFlagWorkbench, "workbench", 0, "workbench id")
	profile.Flags().BoolVar(&watchmanProfileFlagJSON, "json", false, "print JSON")
	_ = profile.MarkFlagRequired("workbench")

	set := &cobra.Command{
		Use:   "set",
		Short: "Set a profile entry's text yourself and pin it",
		Long: "--key is a category (" + strings.Join(watchman.Categories, ", ") + ") or sleep_window. " +
			"A category's text is at most 20 lines; the sleep window is HH:MM-HH:MM (24-hour clock).",
		Args: cobra.NoArgs,
		RunE: runWatchmanProfileSet,
	}
	set.Flags().Int64Var(&watchmanProfileFlagWorkbench, "workbench", 0, "workbench id")
	set.Flags().StringVar(&watchmanProfileFlagKey, "key", "", "a category or sleep_window")
	set.Flags().StringVar(&watchmanProfileFlagTextFile, "text-file", "", "file with the text")
	for _, f := range []string{"workbench", "key", "text-file"} {
		_ = set.MarkFlagRequired(f)
	}

	unpin := &cobra.Command{
		Use:   "unpin",
		Short: "Unpin a profile entry: the next weekly rebuild replaces it",
		Args:  cobra.NoArgs,
		RunE:  runWatchmanProfileUnpin,
	}
	unpin.Flags().Int64Var(&watchmanProfileFlagWorkbench, "workbench", 0, "workbench id")
	unpin.Flags().StringVar(&watchmanProfileFlagKey, "key", "", "a category or sleep_window")
	_ = unpin.MarkFlagRequired("workbench")
	_ = unpin.MarkFlagRequired("key")

	profile.AddCommand(set, unpin)
	watchmanCmd.AddCommand(profile)
}

// watchmanProfileJSON is `watchman profile --json` (keys pinned by
// TestWatchmanProfile_JSONKeysPinned). SleepWindow is the sleep_window
// entry's text, "" when there is none (fewer than 7 active days).
type watchmanProfileJSON struct {
	OK          bool                       `json:"ok"`
	Workbench   int64                      `json:"workbench"`
	Profiles    []watchmanProfileEntryJSON `json:"profiles"`
	SleepWindow string                     `json:"sleep_window"`
}

type watchmanProfileEntryJSON struct {
	Key       string `json:"key"`
	Text      string `json:"text"`
	Pinned    bool   `json:"pinned"`
	Version   int    `json:"version"`
	UpdatedAt string `json:"updated_at"`
}

func openWatchmanDB() (*db.DB, error) {
	cfg, err := workspaceConfigFromFlags()
	if err != nil {
		return nil, err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, fmt.Errorf("opening database: %w", err)
	}
	return database, nil
}

func runWatchmanProfile(cmd *cobra.Command, _ []string) error {
	database, err := openWatchmanDB()
	if err != nil {
		return err
	}
	defer database.Close()
	wb := watchmanProfileFlagWorkbench
	if _, err := database.GetWorkbench(wb); err != nil {
		return err
	}
	ps, err := database.WatchmanProfiles(wb)
	if err != nil {
		return err
	}
	out := watchmanProfileJSON{OK: true, Workbench: wb, Profiles: []watchmanProfileEntryJSON{}}
	for _, p := range ps {
		out.Profiles = append(out.Profiles, watchmanProfileEntryJSON{Key: p.Key, Text: p.Text, Pinned: p.Pinned,
			Version: p.Version, UpdatedAt: p.UpdatedAt.UTC().Format(time.RFC3339)})
		if p.Key == watchman.SleepWindowKey {
			out.SleepWindow = p.Text
		}
	}
	if watchmanProfileFlagJSON {
		return writeJSON(cmd.OutOrStdout(), out)
	}
	w := cmd.OutOrStdout()
	if out.SleepWindow != "" {
		fmt.Fprintf(w, "Sleep window: %s\n", out.SleepWindow)
	} else {
		fmt.Fprintln(w, "Sleep window: not learned yet (fewer than 7 days with activity)")
	}
	n := 0
	for _, p := range ps {
		if p.Key == watchman.SleepWindowKey {
			continue
		}
		n++
		pin := ""
		if p.Pinned {
			pin = ", pinned"
		}
		fmt.Fprintf(w, "\n%s (v%d%s):\n", p.Key, p.Version, pin)
		for _, l := range strings.Split(p.Text, "\n") {
			fmt.Fprintf(w, "  %s\n", l)
		}
	}
	if n == 0 {
		fmt.Fprintln(w, "No category profiles yet: a category needs at least 5 learned decisions; they are rebuilt weekly.")
	}
	return nil
}

// watchmanProfileText reads and checks the text for key: a sleep window is
// HH:MM-HH:MM; a category's text is 1–20 non-empty lines.
func watchmanProfileText(key, path string) (string, error) {
	if key != watchman.SleepWindowKey && !watchman.IsCategory(key) {
		return "", fmt.Errorf("unknown key %q: use a category (%s) or %s", key, strings.Join(watchman.Categories, ", "), watchman.SleepWindowKey)
	}
	raw, err := os.ReadFile(path) // #nosec G304 -- the owner's own file, named on his command line
	if err != nil {
		return "", fmt.Errorf("reading --text-file: %w", err)
	}
	if key == watchman.SleepWindowKey {
		start, end, err := watchman.ParseSleepWindow(string(raw))
		if err != nil {
			return "", err
		}
		return watchman.FormatSleepWindow(start, end), nil
	}
	var lines []string
	for _, l := range strings.Split(string(raw), "\n") {
		if l = strings.TrimSpace(l); l != "" {
			lines = append(lines, l)
		}
	}
	switch {
	case len(lines) == 0:
		return "", fmt.Errorf("--text-file is empty")
	case len(lines) > watchman.ProfileMaxLines:
		return "", fmt.Errorf("--text-file has %d lines; a profile holds at most %d", len(lines), watchman.ProfileMaxLines)
	}
	return strings.Join(lines, "\n"), nil
}

func runWatchmanProfileSet(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent("set a Watchman profile"); err != nil {
		return err
	}
	text, err := watchmanProfileText(watchmanProfileFlagKey, watchmanProfileFlagTextFile)
	if err != nil {
		return err
	}
	database, err := openWatchmanDB()
	if err != nil {
		return err
	}
	defer database.Close()
	if _, err := database.GetWorkbench(watchmanProfileFlagWorkbench); err != nil {
		return err
	}
	if err := database.PinWatchmanProfile(watchmanProfileFlagWorkbench, watchmanProfileFlagKey, text, time.Now()); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Saved and pinned %s for workbench %d: the weekly rebuild leaves it until you unpin it.\n",
		watchmanProfileFlagKey, watchmanProfileFlagWorkbench)
	return nil
}

func runWatchmanProfileUnpin(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent("unpin a Watchman profile"); err != nil {
		return err
	}
	database, err := openWatchmanDB()
	if err != nil {
		return err
	}
	defer database.Close()
	if err := database.UnpinWatchmanProfile(watchmanProfileFlagWorkbench, watchmanProfileFlagKey, time.Now()); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Unpinned %s for workbench %d: the next weekly rebuild replaces it.\n",
		watchmanProfileFlagKey, watchmanProfileFlagWorkbench)
	return nil
}
