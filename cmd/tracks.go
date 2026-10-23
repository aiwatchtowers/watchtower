package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/automations/watch"
	"watchtower/internal/config"
	"watchtower/internal/customtracks"
	"watchtower/internal/db"
	"watchtower/internal/jira"
	"watchtower/internal/prompts"
	"watchtower/internal/tracks"
	"watchtower/internal/ui"

	"github.com/dustin/go-humanize"
	"github.com/spf13/cobra"
)

var (
	tracksFlagPriority    string
	tracksFlagOwnership   string
	tracksFlagChannel     string
	tracksFlagUpdates     bool
	tracksFlagDismissed   bool
	tracksFlagJira        bool
	tracksFlagNoJira      bool
	tracksGenFlagProgress bool
)

var tracksCmd = &cobra.Command{
	Use:   "tracks",
	Short: "Show auto-generated informational tracks",
	Long:  "Displays tracks — auto-generated thematic summaries that evolve over time across channels.",
	RunE:  runTracks,
}

var tracksShowCmd = &cobra.Command{
	Use:   "show <id>",
	Short: "Show track details",
	Args:  cobra.ExactArgs(1),
	RunE:  runTracksShow,
}

var tracksReadCmd = &cobra.Command{
	Use:   "read <id>",
	Short: "Mark a track as read",
	Args:  cobra.ExactArgs(1),
	RunE:  runTracksRead,
}

var tracksDismissCmd = &cobra.Command{
	Use:   "dismiss <id>",
	Short: "Dismiss a track (hide from default view)",
	Args:  cobra.ExactArgs(1),
	RunE:  runTracksDismiss,
}

var tracksRestoreCmd = &cobra.Command{
	Use:   "restore <id>",
	Short: "Restore a dismissed track",
	Args:  cobra.ExactArgs(1),
	RunE:  runTracksRestore,
}

var tracksGenerateCmd = &cobra.Command{
	Use:   "generate",
	Short: "Run tracks pipeline to create/update tracks from digest topics",
	RunE:  runTracksGenerate,
}

var (
	tracksCreateFlagText     string
	tracksCreateFlagTextFile string
	tracksCreateFlagTarget   int
	tracksScanFlagSince      string
)

var tracksCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a custom track from a description (AI drafts the watch instruction)",
	RunE:  runTracksCreate,
}

var tracksWatchCmd = &cobra.Command{
	Use:   "watch <target-id>",
	Short: "Create a custom track linked to a target",
	Args:  cobra.ExactArgs(1),
	RunE:  runTracksWatch,
}

var tracksScanCmd = &cobra.Command{
	Use:   "scan [<id>]",
	Short: "Run the custom-track scan (all enabled, or one id)",
	Args:  cobra.MaximumNArgs(1),
	RunE:  runTracksScan,
}

var tracksEventsCmd = &cobra.Command{
	Use:   "events <id>",
	Short: "Show a custom track's event timeline",
	Args:  cobra.ExactArgs(1),
	RunE:  runTracksEvents,
}

var (
	tracksStartFlagJSON           bool
	tracksInstructionFlagText     string
	tracksInstructionFlagTextFile string
)

var tracksStartCmd = &cobra.Command{
	Use:   "start <id>",
	Short: "Watch a custom track: make its watch recipe and confirm it (owner only)",
	Args:  cobra.ExactArgs(1),
	RunE:  runTracksStart,
}

var tracksInstructionCmd = &cobra.Command{
	Use:   "instruction <id>",
	Short: "Change a watched track's instruction and confirm it (owner only)",
	Args:  cobra.ExactArgs(1),
	RunE:  runTracksInstruction,
}

var tracksEnableCmd = &cobra.Command{
	Use:   "enable <id>",
	Short: "Enable scanning for a custom track",
	Args:  cobra.ExactArgs(1),
	RunE:  func(c *cobra.Command, a []string) error { return setTrackEnabled(c, a, true) },
}

var tracksDisableCmd = &cobra.Command{
	Use:   "disable <id>",
	Short: "Disable scanning for a custom track",
	Args:  cobra.ExactArgs(1),
	RunE:  func(c *cobra.Command, a []string) error { return setTrackEnabled(c, a, false) },
}

func init() {
	rootCmd.AddCommand(tracksCmd)
	tracksCmd.AddCommand(tracksShowCmd)
	tracksCmd.AddCommand(tracksReadCmd)
	tracksCmd.AddCommand(tracksDismissCmd)
	tracksCmd.AddCommand(tracksRestoreCmd)
	tracksCmd.AddCommand(tracksGenerateCmd)
	tracksCmd.AddCommand(tracksCreateCmd, tracksWatchCmd, tracksScanCmd,
		tracksEventsCmd, tracksEnableCmd, tracksDisableCmd, tracksStartCmd, tracksInstructionCmd)
	tracksStartCmd.Flags().BoolVar(&tracksStartFlagJSON, "json", false, "print {track_id, automation_id} as JSON")
	tracksInstructionCmd.Flags().StringVar(&tracksInstructionFlagText, "text", "", "the new watch instruction")
	tracksInstructionCmd.Flags().StringVar(&tracksInstructionFlagTextFile, "text-file", "", "read the instruction from this file instead of --text")
	tracksInstructionCmd.MarkFlagsMutuallyExclusive("text", "text-file")
	tracksCreateCmd.Flags().StringVar(&tracksCreateFlagText, "text", "", "description of what to watch")
	tracksCreateCmd.Flags().StringVar(&tracksCreateFlagTextFile, "text-file", "", "read the description from this file instead of --text")
	tracksCreateCmd.MarkFlagsMutuallyExclusive("text", "text-file")
	tracksCreateCmd.Flags().IntVar(&tracksCreateFlagTarget, "target", 0, "optional linked target id")
	tracksScanCmd.Flags().StringVar(&tracksScanFlagSince, "since", "", "scan history from this ISO8601 instant")
	tracksCmd.Flags().StringVar(&tracksFlagPriority, "priority", "", "filter by priority (high, medium, low)")
	tracksCmd.Flags().StringVar(&tracksFlagOwnership, "ownership", "", "filter by ownership (mine, delegated, watching)")
	tracksCmd.Flags().StringVar(&tracksFlagChannel, "channel", "", "filter by channel name")
	tracksCmd.Flags().BoolVar(&tracksFlagUpdates, "updates", false, "show only tracks with updates")
	tracksCmd.Flags().BoolVar(&tracksFlagDismissed, "dismissed", false, "show dismissed tracks")
	tracksCmd.Flags().BoolVar(&tracksFlagJira, "jira", false, "show only tracks with Jira links")
	tracksCmd.Flags().BoolVar(&tracksFlagNoJira, "no-jira", false, "show only tracks without Jira links")
	tracksGenerateCmd.Flags().BoolVar(&tracksGenFlagProgress, "progress-json", false, "output progress as JSON lines")
}

func runTracks(cmd *cobra.Command, args []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	out := cmd.OutOrStdout()

	// Validate flag values
	validPriorities := map[string]bool{"high": true, "medium": true, "low": true, "": true}
	if !validPriorities[tracksFlagPriority] {
		return fmt.Errorf("invalid --priority %q: must be one of high, medium, low", tracksFlagPriority)
	}
	validOwnerships := map[string]bool{"mine": true, "delegated": true, "watching": true, "": true}
	if !validOwnerships[tracksFlagOwnership] {
		return fmt.Errorf("invalid --ownership %q: must be one of mine, delegated, watching", tracksFlagOwnership)
	}

	channelIDFilter := ""
	if tracksFlagChannel != "" {
		ch, err := database.GetChannelByName(tracksFlagChannel)
		if err != nil {
			return fmt.Errorf("looking up channel: %w", err)
		}
		if ch == nil {
			return fmt.Errorf("channel #%s not found", tracksFlagChannel)
		}
		channelIDFilter = ch.ID
	}

	// The track_linking toggle governs Jira and Linear links alike (spec 3.5),
	// each only while its tracker is enabled.
	linkScope, jiraEnabled := jira.TrackerFeatureScope(cfg, "track_linking")
	jiraLinks := jiraEnabled && jira.ScopeCovers(linkScope, db.TrackerJira)
	linearLinks := jiraEnabled && jira.ScopeCovers(linkScope, db.TrackerLinear)

	if (tracksFlagJira || tracksFlagNoJira) && !jiraEnabled {
		fmt.Fprintln(out, "Jira track linking is not enabled. Ignoring --jira/--no-jira flags.")
	}

	f := db.TrackFilter{
		Priority:         tracksFlagPriority,
		Ownership:        tracksFlagOwnership,
		ChannelID:        channelIDFilter,
		IncludeDismissed: tracksFlagDismissed,
	}
	if tracksFlagUpdates {
		v := true
		f.HasUpdates = &v
	}
	if jiraEnabled {
		f.LinkTracker = linkScope
		if tracksFlagJira {
			v := true
			f.HasJira = &v
		} else if tracksFlagNoJira {
			v := false
			f.HasJira = &v
		}
	}

	items, err := database.GetTracks(f)
	if err != nil {
		return fmt.Errorf("querying tracks: %w", err)
	}

	if len(items) == 0 {
		fmt.Fprintln(out, "No tracks found. Tracks are generated automatically from digest topics.")
		return nil
	}

	var buf strings.Builder
	fmt.Fprintf(&buf, "## Tracks (%d)\n\n", len(items))
	printTracks(&buf, items, database, jiraLinks, linearLinks)

	fmt.Fprint(out, ui.RenderMarkdown(buf.String()))
	return nil
}

// printTracks renders the list; jiraLinks/linearLinks turn on each tracker's
// linked-issue badges (only for an enabled tracker with track_linking on).
func printTracks(w io.Writer, items []db.Track, database *db.DB, jiraLinks, linearLinks bool) {
	priorityIcon := map[string]string{
		"high":   "!",
		"medium": "-",
		"low":    ".",
	}

	ownershipBadge := map[string]string{
		"mine":      "[mine]",
		"delegated": "[delegated]",
		"watching":  "[watching]",
	}

	// Batch-load each enabled tracker's linked issues in a single query.
	trackIDs := make([]int, len(items))
	for i, item := range items {
		trackIDs[i] = item.ID
	}
	var jiraByTrack map[int][]db.JiraIssue
	var linearByTrack map[int][]db.LinkedLinearIssue
	if jiraLinks {
		var jiraErr error
		jiraByTrack, jiraErr = database.GetJiraIssuesForTracks(trackIDs)
		if jiraErr != nil {
			log.Printf("warning: failed to load Jira issues for tracks: %v", jiraErr)
		}
		if jiraByTrack == nil {
			jiraByTrack = make(map[int][]db.JiraIssue)
		}
	}
	if linearLinks {
		var linearErr error
		linearByTrack, linearErr = database.GetLinearIssuesForTracks(trackIDs)
		if linearErr != nil {
			log.Printf("warning: failed to load Linear issues for tracks: %v", linearErr)
		}
	}

	for _, item := range items {
		icon := priorityIcon[item.Priority]
		if icon == "" {
			icon = "-"
		}

		badge := ownershipBadge[item.Ownership]
		if badge == "" {
			badge = "[" + item.Ownership + "]"
		}

		updateBadge := ""
		if item.HasUpdates {
			updateBadge = " [NEW]"
		}

		readBadge := ""
		if item.ReadAt == "" {
			readBadge = " *"
		}

		catLabel := ""
		if item.Category != "" {
			catLabel = " (" + item.Category + ")"
		}

		// Jira badges
		jiraBadges := ""
		if jiraLinks || linearLinks {
			if issues := jiraByTrack[item.ID]; len(issues) > 0 {
				var badges []string
				for _, issue := range issues {
					badges = append(badges, jira.FormatJiraBadge(issue))
				}
				jiraBadges = " " + strings.Join(badges, " ")
			}
			for _, issue := range linearByTrack[item.ID] {
				jiraBadges += fmt.Sprintf(" [%s %s]", issue.Key, issue.Status)
			}
		}

		fmt.Fprintf(w, "%s #%d %s%s **%s**%s%s%s\n", icon, item.ID, badge, catLabel, item.Text, jiraBadges, updateBadge, readBadge)

		// Show channels
		var channelIDs []string
		if json.Unmarshal([]byte(item.ChannelIDs), &channelIDs) == nil && len(channelIDs) > 0 {
			var names []string
			for _, chID := range channelIDs {
				name := chID
				if ch, err := database.GetChannelByID(chID); err == nil && ch != nil && ch.Name != "" {
					name = "#" + ch.Name
				}
				names = append(names, name)
			}
			fmt.Fprintf(w, "   Channels: %s\n", strings.Join(names, ", "))
		}

		// Age
		if item.UpdatedAt != "" {
			if t, err := time.Parse("2006-01-02T15:04:05Z", item.UpdatedAt); err == nil {
				fmt.Fprintf(w, "   %s\n", humanize.Time(t))
			}
		}
		fmt.Fprintln(w)
	}
}

func runTracksShow(cmd *cobra.Command, args []string) error {
	id, err := strconv.Atoi(args[0])
	if err != nil || id <= 0 {
		return fmt.Errorf("invalid track ID %q: must be a positive integer", args[0])
	}

	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	track, err := database.GetTrackByID(id)
	if err != nil {
		return fmt.Errorf("track #%d not found: %w", id, err)
	}

	out := cmd.OutOrStdout()
	printTrackHeader(out, track)
	printTrackParticipants(out, track)
	printTrackSourceRefs(out, database, track)
	printTrackSubItems(out, track)
	printTrackDecisions(out, track)
	printTrackChannelsAndTags(out, database, track)
	printTrackLinkedJiraIssues(out, database, cfg, track)
	printTrackLinkedLinearIssues(out, database, cfg, track)
	return nil
}

func printTrackHeader(out io.Writer, track *db.Track) {
	fmt.Fprintf(out, "Track #%d: %s\n", track.ID, track.Text)
	fmt.Fprintf(out, "Priority: %s | Category: %s | Ownership: %s | Updated: %s\n",
		track.Priority, track.Category, track.Ownership, track.UpdatedAt)
	if track.Context != "" {
		fmt.Fprintf(out, "\nContext:\n%s\n", track.Context)
	}
	if track.RequesterName != "" {
		fmt.Fprintf(out, "\nRequester: %s\n", track.RequesterName)
	}
	if track.Blocking != "" {
		fmt.Fprintf(out, "Blocking: %s\n", track.Blocking)
	}
	if track.DueDate != 0 {
		dueTime := time.Unix(int64(track.DueDate), 0)
		fmt.Fprintf(out, "Due: %s\n", dueTime.Format("2006-01-02"))
	}
}

func printTrackParticipants(out io.Writer, track *db.Track) {
	if track.Participants == "" || track.Participants == "[]" {
		return
	}
	type participant struct {
		UserID string `json:"user_id"`
		Name   string `json:"name"`
		Stance string `json:"stance"`
	}
	var parts []participant
	if json.Unmarshal([]byte(track.Participants), &parts) != nil || len(parts) == 0 {
		return
	}
	fmt.Fprintf(out, "\nParticipants:\n")
	for _, p := range parts {
		if p.Stance != "" {
			fmt.Fprintf(out, "  - %s (%s)\n", p.Name, p.Stance)
		} else {
			fmt.Fprintf(out, "  - %s\n", p.Name)
		}
	}
}

func printTrackSourceRefs(out io.Writer, database *db.DB, track *db.Track) {
	if track.SourceRefs == "" || track.SourceRefs == "[]" {
		return
	}
	type sourceRef struct {
		TS        string `json:"ts"`
		Author    string `json:"author"`
		Text      string `json:"text"`
		ChannelID string `json:"channel_id"`
		DigestID  int    `json:"digest_id"`
		TopicID   int    `json:"topic_id"`
	}
	var refs []sourceRef
	if json.Unmarshal([]byte(track.SourceRefs), &refs) != nil || len(refs) == 0 {
		return
	}
	fmt.Fprintf(out, "\nSource Refs:\n")
	for _, r := range refs {
		if r.Author != "" && r.Text != "" {
			chName := r.ChannelID
			if ch, chErr := database.GetChannelByID(r.ChannelID); chErr == nil && ch != nil && ch.Name != "" {
				chName = "#" + ch.Name
			}
			fmt.Fprintf(out, "  [%s] %s: %s\n", chName, r.Author, r.Text)
		} else if r.DigestID > 0 {
			fmt.Fprintf(out, "  digest=%d topic=%d channel=%s\n", r.DigestID, r.TopicID, r.ChannelID)
		}
	}
}

func printTrackSubItems(out io.Writer, track *db.Track) {
	if track.SubItems == "" || track.SubItems == "[]" {
		return
	}
	type subItem struct {
		Text   string `json:"text"`
		Status string `json:"status"`
	}
	var subs []subItem
	if json.Unmarshal([]byte(track.SubItems), &subs) != nil || len(subs) == 0 {
		return
	}
	fmt.Fprintf(out, "\nSub-items:\n")
	for _, s := range subs {
		marker := "[ ]"
		if s.Status == "done" {
			marker = "[x]"
		}
		fmt.Fprintf(out, "  %s %s\n", marker, s.Text)
	}
}

func printTrackDecisions(out io.Writer, track *db.Track) {
	if track.DecisionOptions != "" && track.DecisionOptions != "[]" {
		type decOption struct {
			Option     string   `json:"option"`
			Supporters []string `json:"supporters"`
			Pros       string   `json:"pros"`
			Cons       string   `json:"cons"`
		}
		var opts []decOption
		if json.Unmarshal([]byte(track.DecisionOptions), &opts) == nil && len(opts) > 0 {
			fmt.Fprintf(out, "\nDecision Options:\n")
			for _, o := range opts {
				fmt.Fprintf(out, "  - %s\n", o.Option)
				if len(o.Supporters) > 0 {
					fmt.Fprintf(out, "    Supporters: %s\n", strings.Join(o.Supporters, ", "))
				}
				if o.Pros != "" {
					fmt.Fprintf(out, "    Pros: %s\n", o.Pros)
				}
				if o.Cons != "" {
					fmt.Fprintf(out, "    Cons: %s\n", o.Cons)
				}
			}
		}
	}
	if track.DecisionSummary != "" {
		fmt.Fprintf(out, "\nDecision Summary: %s\n", track.DecisionSummary)
	}
}

func printTrackChannelsAndTags(out io.Writer, database *db.DB, track *db.Track) {
	var channelIDs []string
	if json.Unmarshal([]byte(track.ChannelIDs), &channelIDs) == nil && len(channelIDs) > 0 {
		var names []string
		for _, chID := range channelIDs {
			name := chID
			if ch, chErr := database.GetChannelByID(chID); chErr == nil && ch != nil && ch.Name != "" {
				name = "#" + ch.Name
			}
			names = append(names, name)
		}
		fmt.Fprintf(out, "\nChannels: %s\n", strings.Join(names, ", "))
	}
	var tags []string
	if json.Unmarshal([]byte(track.Tags), &tags) == nil && len(tags) > 0 {
		fmt.Fprintf(out, "Tags: %s\n", strings.Join(tags, ", "))
	}
}

func printTrackLinkedJiraIssues(out io.Writer, database *db.DB, cfg *config.Config, track *db.Track) {
	if !jira.IsFeatureEnabled(cfg, "track_linking") {
		return
	}
	issues, jiraErr := database.GetJiraIssuesForTrack(track.ID)
	if jiraErr != nil || len(issues) == 0 {
		return
	}
	fmt.Fprintf(out, "\nLinked Jira Issues:\n")
	now := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	for _, issue := range issues {
		overdue := ""
		if issue.DueDate != "" && !strings.EqualFold(issue.StatusCategory, "done") {
			if due, parseErr := time.Parse("2006-01-02", issue.DueDate); parseErr == nil && due.Before(today) {
				overdue = " *** OVERDUE ***"
			}
		}
		line := jira.BuildIssueListForCLI([]db.JiraIssue{issue})
		fmt.Fprintf(out, "  %s%s\n", line, overdue)
	}
}

func runTracksRead(cmd *cobra.Command, args []string) error {
	id, err := strconv.Atoi(args[0])
	if err != nil || id <= 0 {
		return fmt.Errorf("invalid track ID %q: must be a positive integer", args[0])
	}

	database, err := openTracksDB()
	if err != nil {
		return err
	}
	defer database.Close()

	if err := database.MarkTrackRead(id); err != nil {
		return fmt.Errorf("marking track read: %w", err)
	}

	fmt.Fprintf(cmd.OutOrStdout(), "Track #%d marked as read\n", id)
	return nil
}

func runTracksDismiss(cmd *cobra.Command, args []string) error {
	id, err := strconv.Atoi(args[0])
	if err != nil || id <= 0 {
		return fmt.Errorf("invalid track ID %q: must be a positive integer", args[0])
	}

	database, err := openTracksDB()
	if err != nil {
		return err
	}
	defer database.Close()

	if err := database.DismissTrack(id); err != nil {
		return fmt.Errorf("dismissing track: %w", err)
	}

	fmt.Fprintf(cmd.OutOrStdout(), "Track #%d dismissed\n", id)
	return nil
}

func runTracksRestore(cmd *cobra.Command, args []string) error {
	id, err := strconv.Atoi(args[0])
	if err != nil || id <= 0 {
		return fmt.Errorf("invalid track ID %q: must be a positive integer", args[0])
	}

	database, err := openTracksDB()
	if err != nil {
		return err
	}
	defer database.Close()

	if err := database.RestoreTrack(id); err != nil {
		return fmt.Errorf("restoring track: %w", err)
	}

	fmt.Fprintf(cmd.OutOrStdout(), "Track #%d restored\n", id)
	// A dismissed custom track was not moved to a watch recipe (it scanned
	// nothing); restored, it scans again only once it is watched.
	if t, err := database.GetTrackByID(id); err == nil && t.Origin == "custom" && t.AutomationID == 0 {
		fmt.Fprintf(cmd.OutOrStdout(), "Run `watchtower tracks start %d` to watch it again.\n", id)
	}
	return nil
}

// tracksProgressJSON is one `tracks generate --progress-json` line.
type tracksProgressJSON struct {
	Pipeline         string  `json:"pipeline"`
	Done             int     `json:"done"`
	Total            int     `json:"total"`
	Status           string  `json:"status,omitempty"`
	InputTokens      int     `json:"input_tokens"`
	OutputTokens     int     `json:"output_tokens"`
	Error            string  `json:"error,omitempty"`
	Finished         bool    `json:"finished"`
	ItemsFound       int     `json:"items_found"`
	StepDurationSec  float64 `json:"step_duration_seconds,omitempty"`
	StepInputTokens  int     `json:"step_input_tokens,omitempty"`
	StepOutputTokens int     `json:"step_output_tokens,omitempty"`
	TotalAPITokens   int     `json:"total_api_tokens,omitempty"`
}

// runTracksGenerate runs the tracks extraction once now. Once Track my
// threads has moved to Automations it runs through the built-in's current
// recipe (the shipped text or the owner's confirmed copy) as one manual run
// inline in this process; before, the pipeline straight with the prompt
// store's row, as the daemon's legacy phase does. Either way the run is
// tracked as pipeline_runs "tracks" (cli), and the output and progress lines
// are as they always were.
func runTracksGenerate(cmd *cobra.Command, _ []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}

	if err := validateModel(cfg); err != nil {
		return err
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	moved, err := builtinMoved(database, trackMyThreadsID)
	if err != nil {
		return err
	}
	ctx := cmdContext(cmd)
	if moved {
		if !cfg.Digest.Enabled {
			return errors.New(msgTrackMyThreadsNeedsDigests) //nolint:staticcheck // ST1005: the built-in's name
		}
		if err := syncBuiltinForCLI(ctx, cfg, database, trackMyThreadsID); err != nil {
			return err
		}
	}

	logger := log.New(cmd.ErrOrStderr(), "[tracks] ", log.LstdFlags)
	gen, cleanupPool := cliBuiltinGenerator(cfg)
	defer cleanupPool()
	pipe := tracks.New(database, cfg, gen, logger)
	pipe.SetPromptStore(prompts.New(database, nil))

	out := cmd.OutOrStdout()
	emit := func(p tracksProgressJSON) { data, _ := json.Marshal(p); fmt.Fprintln(out, string(data)) }

	var runID int64
	if tracksGenFlagProgress {
		pipe.OnProgress = func(done, total int, status string) {
			inTok, outTok, _, totalAPI := pipe.AccumulatedUsage()
			p := tracksProgressJSON{Pipeline: "tracks", Done: done, Total: total, Status: status, InputTokens: inTok, OutputTokens: outTok, TotalAPITokens: totalAPI}
			if pipe.LastStepDurationSeconds > 0 {
				p.StepDurationSec = pipe.LastStepDurationSeconds
			}
			p.StepInputTokens = pipe.LastStepInputTokens
			p.StepOutputTokens = pipe.LastStepOutputTokens
			emit(p)

			// Log step to DB.
			if runID > 0 && p.StepDurationSec > 0 {
				_ = database.InsertPipelineStep(db.PipelineStep{
					RunID: runID, Step: done, Total: total, Status: status,
					InputTokens:     p.StepInputTokens,
					OutputTokens:    p.StepOutputTokens,
					CostUSD:         0,
					TotalAPITokens:  totalAPI,
					DurationSeconds: p.StepDurationSec,
				})
			}
		}
	} else {
		fmt.Fprintln(out, "Running tracks pipeline...")
	}

	// track is the run's pipeline_runs row: the recipe's tracks.extract and
	// the legacy run alike.
	var created, updated int
	track := func(run func() (int, int, error)) (int, int, error) {
		runID, _ = database.CreatePipelineRun("tracks", "cli", "auto")
		var runErr error
		created, updated, runErr = run()
		if runID > 0 {
			inTok, outTok, cost, totalAPI := pipe.AccumulatedUsage()
			errMsg := ""
			if runErr != nil {
				errMsg = runErr.Error()
			}
			var pFrom, pTo *float64
			if pipe.LastFrom > 0 {
				pFrom = &pipe.LastFrom
			}
			if pipe.LastTo > 0 {
				pTo = &pipe.LastTo
			}
			_ = database.CompletePipelineRun(runID, created+updated, inTok, outTok, cost, totalAPI, pFrom, pTo, errMsg)
		}
		return created, updated, runErr
	}

	if moved {
		r := newCLIBuiltinRunner(cfg, database, gen, logger, cliBuiltinPipes{tracks: pipe, tracksHooks: builtin.ThreadsHooks{Track: track}})
		err = runBuiltinNow(ctx, r, trackMyThreadsID, automations.BuiltinInput{})
	} else {
		_, _, err = track(func() (int, int, error) { return pipe.Run(ctx) })
		if err != nil {
			err = fmt.Errorf("tracks pipeline: %w", err)
		}
	}

	if tracksGenFlagProgress {
		inTok, outTok, _, totalAPI := pipe.AccumulatedUsage()
		p := tracksProgressJSON{Pipeline: "tracks", Finished: true, InputTokens: inTok, OutputTokens: outTok, TotalAPITokens: totalAPI}
		if err != nil {
			p.Error = err.Error()
		} else {
			p.ItemsFound = created + updated
		}
		emit(p)
		return err
	}
	if err != nil {
		return err
	}
	if created > 0 || updated > 0 {
		fmt.Fprintf(out, "Tracks: created %d, updated %d\n", created, updated)
	} else {
		fmt.Fprintln(out, "No new or updated tracks.")
	}
	return nil
}

func openTracksDBWithConfig() (*db.DB, *config.Config, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, nil, fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, nil, fmt.Errorf("invalid config: %w", err)
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, nil, err
	}
	return database, cfg, nil
}

func openTracksDB() (*db.DB, error) {
	database, _, err := openTracksDBWithConfig()
	return database, err
}

// msgConfirmInAutomations is the note of a watch recipe left unconfirmed
// (written under an AI agent's markers).
const msgConfirmInAutomations = "Confirm it in Automations."

// runTracksCreate composes a custom track from a description, creates it and
// starts its watch recipe (watch.Start). The owner's command confirms the
// recipe it renders; under an AI agent's markers the recipe is left
// unconfirmed (it scans nothing until the owner confirms it) and the JSON
// says so.
func runTracksCreate(cmd *cobra.Command, _ []string) error {
	text, err := textFlagValue(tracksCreateFlagText, tracksCreateFlagTextFile)
	if err != nil {
		return err
	}
	if strings.TrimSpace(text) == "" {
		return fmt.Errorf("--text or --text-file is required")
	}
	database, cfg, err := openTracksDBWithConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	// Resolved before the AI compose call: a track nobody is assigned to is
	// never created, and no model call is spent finding that out.
	owner, err := database.RequireOwner()
	if err != nil {
		return err
	}
	// The recipe is confirmed only by the owner (AGENT-07): no agent marker,
	// and the owner's confirmation in the Desktop, asked before the compose
	// call (up to 120 s) so the Desktop's launch grant is still live; a
	// denial writes nothing. Under an agent's markers the recipe waits,
	// unconfirmed, for Automations.
	confirm := refuseUnderAgent(tracksStartVerb) == nil
	if confirm {
		if err := confirmWithOwner(tracksStartVerb, tracksCreateConfirmDetail(text)); err != nil {
			return err
		}
	}
	applyProviderOverride(cfg)
	gen, closeGen := cliBuiltinGenerator(cfg)
	defer closeGen()
	pipe := customtracks.New(database, gen, cfg.Digest.Language, nil)
	ctx, cancel := context.WithTimeout(cmdContext(cmd), 120*time.Second)
	defer cancel()
	res, err := pipe.Compose(ctx, tracksCreateFlagTarget, text)
	if err != nil {
		return fmt.Errorf("compose failed: %w", err)
	}
	id, err := database.CreateCustomTrack(db.Track{
		AssigneeUserID: owner.ID, Text: res.Title, Context: text,
		Instruction: res.Instruction, LinkedTargetID: tracksCreateFlagTarget,
	})
	if err != nil {
		return err
	}
	if _, err := startTrackWatch(ctx, cfg, database, int(id), confirm); err != nil {
		return fmt.Errorf("track #%d was created but is not watched: %w — run `watchtower tracks start %d`", id, err, id)
	}
	body := map[string]any{"id": id, "title": res.Title, "instruction": res.Instruction}
	if !confirm {
		body["confirmed"] = false
		body["note"] = msgConfirmInAutomations
	}
	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(body)
}

// startTrackWatch makes custom track id a watch (watch.Start through the
// personal folder's indexer), confirming the recipe when confirm is set.
func startTrackWatch(ctx context.Context, cfg *config.Config, database *db.DB, id int, confirm bool) (*db.Automation, error) {
	t, err := database.GetTrackByID(id)
	if err != nil {
		return nil, fmt.Errorf("track #%d not found: %w", id, err)
	}
	ix := automations.NewIndexer(database, cfg.WorkspaceDir(), automations.RealClock{})
	return watch.Start(ctx, database, ix, cfg.WorkspaceDir(), *t, watch.StartOptions{Confirm: confirm})
}

func runTracksWatch(cmd *cobra.Command, args []string) error {
	id, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid target id %q: %w", args[0], err)
	}
	tracksCreateFlagTarget = id
	return runTracksCreate(cmd, nil)
}

// runTracksStart is `tracks start <id>`, owner only: it makes custom track
// id a watch with its recipe confirmed (Start Watching).
func runTracksStart(cmd *cobra.Command, args []string) error {
	if err := refuseUnderAgent(tracksStartVerb); err != nil {
		return err
	}
	id, err := parseTrackID(args[0])
	if err != nil {
		return err
	}
	database, cfg, err := openTracksDBWithConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	if err := confirmWithOwner(tracksStartVerb, trackWatchConfirmDetail(database, id)); err != nil {
		return err
	}
	a, err := startTrackWatch(cmdContext(cmd), cfg, database, id, true)
	if errors.Is(err, watch.ErrEditedSinceRendered) {
		return errors.New(msgWatchNotConfirmed)
	}
	if err != nil {
		return err
	}
	if tracksStartFlagJSON {
		return writeJSON(cmd.OutOrStdout(), map[string]any{"track_id": id, "automation_id": a.ID})
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Track #%d is watched by automation #%d.\n", id, a.ID)
	return nil
}

// trackWatchConfirmDetail is the owner's confirmation window text for
// starting track id's watch: the bound recipe as it is, or the recipe Start
// would write.
// tracksCreateConfirmDetail is the confirmation window of `tracks
// create|watch`: the text the owner gave, which the watch is composed from.
func tracksCreateConfirmDetail(text string) string {
	return "Watch for:\n\n" + text + "\n\nWatchtower writes the watch's instruction from this text."
}

func trackWatchConfirmDetail(database *db.DB, id int) string {
	t, err := database.GetTrackByID(id)
	if err != nil {
		return detailUnavailable(err)
	}
	if t.AutomationID != 0 {
		a, err := database.GetAutomation(t.AutomationID)
		if err != nil {
			return detailUnavailable(err)
		}
		return fmt.Sprintf("Track #%d %q\n\n%s", t.ID, t.Text, recipeConfirmDetail(a))
	}
	data, err := watch.StartRecipe(*t)
	if err != nil {
		return detailUnavailable(err)
	}
	return fmt.Sprintf("Track #%d %q\n\n%s", t.ID, t.Text, data)
}

// The `tracks instruction` refusals.
const (
	tracksStartVerb        = "start watching a track"
	msgWatchChangedInChat  = "This watch was changed in the chat — change it there."
	msgWatchNotConfirmed   = "confirm this watch in Automations first"
	msgWatchScanningNow    = "this watch is scanning now — try again in a minute"
	msgTrackNotWatchedFmt  = "track #%d is not watched — run `watchtower tracks start %d`"
	msgWatchScanQueued     = "a scan of this watch with another Scan from is already queued for the next sync"
	msgWatchPausedFmt      = "this watch is paused — run `watchtower tracks enable %d` first"
	msgWatchStoppedFmt     = "this watch was stopped after a run that would not end — run `watchtower tracks enable %d` to turn it on again"
	tracksInstructionVerb  = "change a watch's instruction"
	tracksWatchEnableVerb  = "turn a watch on"
	tracksWatchScanTimeout = 420 * time.Second
)

// runTracksInstruction is `tracks instruction <id> --text|--text-file`,
// owner only: it rewrites the bound watch recipe's instruction line
// (watch.SetInstruction), saves it through the indexer, confirms the new
// text (the owner's press is the confirmation) and mirrors the instruction
// onto the track. Only a confirmed, template-shaped recipe is changed here.
func runTracksInstruction(cmd *cobra.Command, args []string) error {
	if err := refuseUnderAgent(tracksInstructionVerb); err != nil {
		return err
	}
	id, err := parseTrackID(args[0])
	if err != nil {
		return err
	}
	text, err := textFlagValue(tracksInstructionFlagText, tracksInstructionFlagTextFile)
	if err != nil {
		return err
	}
	text = strings.TrimSpace(text)
	if text == "" {
		return errors.New("--text or --text-file is required")
	}
	database, cfg, err := openTracksDBWithConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	t, err := database.GetTrackByID(id)
	if err != nil {
		return fmt.Errorf("track #%d not found: %w", id, err)
	}
	if t.AutomationID == 0 {
		return fmt.Errorf(msgTrackNotWatchedFmt, id, id)
	}
	ctx := cmdContext(cmd)
	ix := automations.NewIndexer(database, cfg.WorkspaceDir(), automations.RealClock{})
	scope := automations.Scope{Kind: automations.ScopePersonal}
	dir, err := automations.CanonicalDir(automations.PersonalDir(cfg.WorkspaceDir()))
	if err != nil {
		return err
	}
	a, err := database.GetAutomation(t.AutomationID)
	if err != nil {
		return err
	}
	// The file as it is now (a hand edit not indexed yet counts).
	if a, err = ix.IndexedRecipeAt(ctx, scope, dir, a.Path); err != nil {
		return err
	}
	if !a.Confirmed() {
		return errors.New(msgWatchNotConfirmed)
	}
	data, err := watch.SetInstruction([]byte(a.RecipeText), text)
	if errors.Is(err, watch.ErrNotTemplateShaped) {
		return errors.New(msgWatchChangedInChat) //nolint:staticcheck // ST1005: the text the Desktop shows
	}
	if err != nil {
		return err
	}
	detail := fmt.Sprintf("Track #%d %q\nNew instruction:\n%s\n\n%s", t.ID, t.Text, text, data)
	if err := confirmWithOwner(tracksInstructionVerb, detail); err != nil {
		return err
	}
	saved, err := ix.WriteRecipe(ctx, scope, dir, a.Path, data)
	if err != nil {
		return err
	}
	if err := database.ConfirmAutomation(saved.ID, saved.ApprovalHash, time.Now()); err != nil {
		return err
	}
	if err := database.SetWatchInstruction(t.ID, text); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Track #%d watches for: %s\n", id, text)
	return nil
}

// parseTrackID parses a positive track id.
func parseTrackID(arg string) (int, error) {
	id, err := strconv.Atoi(arg)
	if err != nil || id <= 0 {
		return 0, fmt.Errorf("invalid track id %q: must be a positive integer", arg)
	}
	return id, nil
}

// eventsScanner is the custom-track scan as track.scan calls it, keeping
// the events of every scan it ran (`tracks scan` prints them).
type eventsScanner struct {
	*customtracks.Pipeline
	events []db.TrackEvent
}

func (s *eventsScanner) ScanBound(ctx context.Context, t db.Track, o customtracks.ScanOptions) ([]db.TrackEvent, error) {
	events, err := s.Pipeline.ScanBound(ctx, t, o)
	s.events = append(s.events, events...)
	return events, err
}

// runTracksScan scans now. A track bound to a watch recipe is scanned only
// through its recipe, as one manual run inline (Run Now; --since is its Scan
// from), never with the track's own instruction: a hand-edited recipe the
// owner has not confirmed is never scanned. An unbound custom track is
// scanned the old way only while the custom tracks have not moved to watch
// recipes; after the move it is not watched. With no id: the unbound tracks
// the old way (before the move only), then every enabled, confirmed watch
// recipe, one after another.
func runTracksScan(cmd *cobra.Command, args []string) error {
	database, cfg, err := openTracksDBWithConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	applyProviderOverride(cfg)
	since := ""
	if tracksScanFlagSince != "" {
		at, err := time.Parse(time.RFC3339, tracksScanFlagSince)
		if err != nil {
			return fmt.Errorf("invalid --since %q: want an ISO8601 instant", tracksScanFlagSince)
		}
		since = at.UTC().Format(watermarkLayout)
	}
	moved, err := builtinMoved(database, customTracksID)
	if err != nil {
		return err
	}
	gen, closeGen := cliBuiltinGenerator(cfg)
	defer closeGen()
	scanner := &eventsScanner{Pipeline: customtracks.New(database, gen, cfg.Digest.Language, nil)}
	logger := log.New(cmd.ErrOrStderr(), "[tracks] ", log.LstdFlags)
	runner := newCLIBuiltinRunner(cfg, database, gen, logger, cliBuiltinPipes{watch: scanner})
	ctx, cancel := context.WithTimeout(cmdContext(cmd), tracksWatchScanTimeout)
	defer cancel()
	ctx, stop := inlineRunContext(ctx)
	defer stop()
	if len(args) == 1 {
		id, err := parseTrackID(args[0])
		if err != nil {
			return err
		}
		events, err := scanOneTrack(ctx, database, runner, scanner, moved, id, since)
		if err != nil {
			return err
		}
		enc := json.NewEncoder(cmd.OutOrStdout())
		enc.SetIndent("", "  ")
		return enc.Encode(events)
	}
	n := 0
	if !moved {
		if n, err = scanner.Run(ctx); err != nil {
			return err
		}
	}
	recipes, err := database.ListSlotRecipes(string(builtin.SlotCustomTracks))
	if err != nil {
		return err
	}
	var failed []error
	for i := range recipes {
		a := &recipes[i]
		if !a.Runnable() || ctx.Err() != nil {
			continue
		}
		if err := scanWatch(ctx, database, runner, a.ID, ""); err != nil {
			failed = append(failed, fmt.Errorf("%s: %w", a.Name, err))
		}
	}
	n += len(scanner.events)
	fmt.Fprintf(cmd.OutOrStdout(), "scanned enabled custom tracks: %d new event(s)\n", n)
	return errors.Join(failed...)
}

// watermarkLayout is the custom-track scan's watermark format.
const watermarkLayout = "2006-01-02T15:04:05Z"

// scanOneTrack is `tracks scan <id>`: the bound track through its recipe,
// an unbound one the old way before the move only; its new events.
func scanOneTrack(ctx context.Context, database *db.DB, runner *builtin.Runner, scanner *eventsScanner, moved bool, id int, since string) ([]db.TrackEvent, error) {
	t, err := database.GetTrackByID(id)
	if err != nil {
		return nil, fmt.Errorf("track #%d not found: %w", id, err)
	}
	var events []db.TrackEvent
	switch {
	case t.AutomationID != 0:
		if err := scanWatch(ctx, database, runner, t.AutomationID, since); err != nil {
			return nil, err
		}
		events = scanner.events
	case t.Origin != "custom":
		return nil, fmt.Errorf("track %d is not a custom track", id)
	case moved:
		return nil, fmt.Errorf(msgTrackNotWatchedFmt, id, id)
	case since != "":
		events, err = scanner.RunForTrackSince(ctx, id, since)
	default:
		events, err = scanner.RunForTrack(ctx, id)
	}
	if err != nil {
		return nil, fmt.Errorf("scan failed: %w", err)
	}
	if events == nil {
		events = []db.TrackEvent{}
	}
	return events, nil
}

// scanWatch runs watch recipe automationID now (RunWatchNow) with since as
// its Scan from.
func scanWatch(ctx context.Context, database *db.DB, runner *builtin.Runner, automationID int64, since string) error {
	run, err := runner.RunWatchNow(ctx, automationID, automations.BuiltinInput{Since: since})
	switch {
	case errors.Is(err, builtin.ErrRunNowQueued):
		return errors.New(msgWatchScanQueued)
	case errors.Is(err, automations.ErrRunNotClaimed):
		return errors.New(msgWatchScanningNow)
	case errors.Is(err, automations.ErrNotRunnable):
		return watchNotRunnable(database, automationID)
	case err != nil:
		return fmt.Errorf("scan failed: %w", err)
	case run.Status != db.RunSucceeded:
		return fmt.Errorf("scan failed: run #%d %s: %s", run.ID, run.Status, run.Error)
	}
	return nil
}

// watchNotRunnable says why watch recipe automationID cannot run.
func watchNotRunnable(database *db.DB, automationID int64) error {
	a, err := database.GetAutomation(automationID)
	if err != nil {
		return err
	}
	t, err := database.GetWatchTrack(automationID)
	if err != nil {
		return err
	}
	trackID := 0
	if t != nil {
		trackID = t.ID
	}
	switch {
	case !a.Confirmed():
		return errors.New(msgWatchNotConfirmed)
	case a.DisabledReason != "":
		return fmt.Errorf(msgWatchStoppedFmt, trackID)
	case !a.Enabled:
		return fmt.Errorf(msgWatchPausedFmt, trackID)
	}
	return fmt.Errorf("watch recipe %d cannot run now", automationID)
}
func runTracksEvents(cmd *cobra.Command, args []string) error {
	database, err := openTracksDB()
	if err != nil {
		return err
	}
	defer database.Close()
	id, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid track id: %w", err)
	}
	events, err := database.GetTrackEvents(id, 100)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(events)
}

// setTrackEnabled is `tracks enable|disable <id>`. A track bound to a watch
// recipe toggles the recipe's enabled (the track mirrors it): Collecting or
// Paused. Turning a watch on is the owner's, as `automations enable` is
// (D24). An unbound track toggles its own enabled, as before.
func setTrackEnabled(cmd *cobra.Command, args []string, enabled bool) error {
	database, err := openTracksDB()
	if err != nil {
		return err
	}
	defer database.Close()
	id, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid track id: %w", err)
	}
	t, err := database.GetTrackByID(id)
	if err != nil {
		return fmt.Errorf("track #%d not found: %w", id, err)
	}
	if t.AutomationID != 0 {
		if enabled {
			if err := refuseUnderAgent(tracksWatchEnableVerb); err != nil {
				return err
			}
			if err := confirmWithOwner(tracksWatchEnableVerb, trackWatchConfirmDetail(database, id)); err != nil {
				return err
			}
		}
		if err := database.SetAutomationEnabled(t.AutomationID, enabled, time.Now()); err != nil {
			return err
		}
	} else if err := database.SetTrackEnabled(id, enabled); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "track #%d enabled=%v\n", id, enabled)
	return nil
}

// printTrackLinkedLinearIssues lists the Linear issues a track links to
// (issue_slack_links, tracker 'linear'), under the same track_linking toggle.
func printTrackLinkedLinearIssues(out io.Writer, database *db.DB, cfg *config.Config, track *db.Track) {
	if scope, ok := jira.TrackerFeatureScope(cfg, "track_linking"); !ok || !jira.ScopeCovers(scope, db.TrackerLinear) {
		return
	}
	byTrack, err := database.GetLinearIssuesForTracks([]int{track.ID})
	if err != nil {
		log.Printf("warning: failed to load Linear issues for track %d: %v", track.ID, err)
		return
	}
	issues := byTrack[track.ID]
	if len(issues) == 0 {
		return
	}
	fmt.Fprintf(out, "\nLinked Linear Issues:\n")
	now := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	for _, issue := range issues {
		line := fmt.Sprintf("[%s %s] %s", issue.Key, issue.Status, issue.Title)
		if issue.AssigneeDisplayName != "" {
			line += " (" + issue.AssigneeDisplayName + ")"
		}
		if issue.DueDate != "" && issue.StatusCategory != "done" {
			if due, perr := time.Parse("2006-01-02", issue.DueDate); perr == nil && due.Before(today) {
				line += " *** OVERDUE ***"
			}
		}
		fmt.Fprintf(out, "  %s\n", line)
	}
}
