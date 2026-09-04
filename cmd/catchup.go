package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/catchup"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/ideas"
	"watchtower/internal/prompts"
)

// catchupListLimit bounds `catchup list` — recaps accumulate one per run and
// the operator only ever cares about the recent ones.
const catchupListLimit = 20

// catchupWindowLayout renders a recap window in the operator's local time.
const catchupWindowLayout = "Mon 2 Jan 15:04"

var (
	catchupRunFlagPreset  string
	catchupRunFlagFrom    string
	catchupRunFlagTo      string
	catchupRunFlagRegen   int64
	catchupRunFlagComment string
	catchupRunFlagJSON    bool

	catchupFeedbackTopic   int
	catchupFeedbackRating  string
	catchupFeedbackComment string

	catchupListFlagJSON bool
)

var catchupCmd = &cobra.Command{
	Use:   "catchup",
	Short: "Recap a window you were away for",
	Long: "Catch-Up builds one persisted recap per time window out of the summaries " +
		"Watchtower already keeps — channel digests, Gmail/Jira stream digests, meeting " +
		"recaps, the decisions ledger — plus the items that arrived for you in that " +
		"window. One \"I'm caught up\" marks the whole window read.\n\n" +
		"Subcommands:\n" +
		"  run             build a recap for a window (or --regen an existing one)\n" +
		"  ack <id>        mark the recap's whole window read\n" +
		"  feedback <id>   rate one topic (+ an optional comment that derives learned rules)\n" +
		"  list            recent recaps\n" +
		"  show <id>       print one recap as text",
}

var catchupRunCmd = &cobra.Command{
	Use:   "run",
	Short: "Build a recap for a window (default: since you were last caught up)",
	Args:  cobra.NoArgs,
	RunE:  runCatchupRun,
}

var catchupAckCmd = &cobra.Command{
	Use:   "ack <recap-id>",
	Short: "Mark the recap's whole window read",
	Args:  cobra.ExactArgs(1),
	RunE:  runCatchupAck,
}

var catchupFeedbackCmd = &cobra.Command{
	Use:   "feedback <recap-id>",
	Short: "Rate one topic of a recap (--topic N --rating up|down [--comment])",
	Args:  cobra.ExactArgs(1),
	RunE:  runCatchupFeedback,
}

var catchupListCmd = &cobra.Command{
	Use:   "list",
	Short: "List recent recaps",
	Args:  cobra.NoArgs,
	RunE:  runCatchupList,
}

var catchupShowCmd = &cobra.Command{
	Use:   "show <recap-id>",
	Short: "Print one recap as text",
	Args:  cobra.ExactArgs(1),
	RunE:  runCatchupShow,
}

func init() {
	rootCmd.AddCommand(catchupCmd)
	catchupCmd.AddCommand(catchupRunCmd, catchupAckCmd, catchupFeedbackCmd, catchupListCmd, catchupShowCmd)

	catchupRunCmd.Flags().StringVar(&catchupRunFlagPreset, "preset", "", "window preset: today, yesterday, 3d or week")
	catchupRunCmd.Flags().StringVar(&catchupRunFlagFrom, "from", "", "window start (YYYY-MM-DD or RFC 3339)")
	catchupRunCmd.Flags().StringVar(&catchupRunFlagTo, "to", "", "window end (YYYY-MM-DD or RFC 3339), defaults to now; requires --from")
	catchupRunCmd.Flags().Int64Var(&catchupRunFlagRegen, "regen", 0, "regenerate this recap's window instead of building a new one")
	catchupRunCmd.Flags().StringVar(&catchupRunFlagComment, "comment", "", "correction to apply when regenerating (--regen only)")
	catchupRunCmd.Flags().BoolVar(&catchupRunFlagJSON, "json", false, "print the recap as a JSON envelope")

	catchupFeedbackCmd.Flags().IntVar(&catchupFeedbackTopic, "topic", -1, "0-based index of the rated topic (required)")
	catchupFeedbackCmd.Flags().StringVar(&catchupFeedbackRating, "rating", "", "up or down")
	catchupFeedbackCmd.Flags().StringVar(&catchupFeedbackComment, "comment", "", "free-text reason; a comment derives targeted learned rules and may regenerate the recap")

	catchupListCmd.Flags().BoolVar(&catchupListFlagJSON, "json", false, "output the recap rows as JSON")
}

// cliTopUp adapts the real digest + ideas pipelines to catchup.TopUp so a recap
// asked for right now sees what happened minutes ago.
type cliTopUp struct {
	digests      *digest.Pipeline
	ideas        *ideas.Pipeline
	workspaceDir string
}

func (c cliTopUp) ChannelDigests(ctx context.Context) error {
	_, _, err := c.digests.RunChannelDigestsOnly(ctx)
	return err
}

// StreamDigests runs the same pass the daemon's phaseStreamDigests runs, under
// the SAME ideas backfill lock — the two advance the shared stage-1 floors, so
// running them concurrently would let one skip material the other consumed.
// Losing the lock is reported as an error, which the pipeline records as a
// failed top-up while still building the recap (CATCHUP-03).
func (c cliTopUp) StreamDigests(ctx context.Context) error {
	release, err := ideas.AcquireBackfillLock(c.workspaceDir, "catchup")
	if err != nil {
		return fmt.Errorf("stream top-up skipped: %w", err)
	}
	defer release()
	return c.ideas.RunStreamDigests(ctx)
}

// catchupPipeline loads config + DB and constructs a pooled-generator pipeline
// with the coverage top-up wired to the real digest pipelines. It returns the
// pipeline, the database, and a cleanup func that closes the DB and the pool.
func catchupPipeline() (*catchup.Pipeline, *db.DB, func(), error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, nil, nil, err
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, nil, nil, fmt.Errorf("opening database: %w", err)
	}

	logger := log.New(os.Stderr, "", log.LstdFlags)
	gen, closeGen := cliPooledGenerator(cfg, logger)
	p := catchup.New(database, cfg, gen, logger)
	p.SetPromptStore(prompts.New(database, nil))
	digestPipe := digest.New(database, cfg, gen, logger)
	ideasPipe := ideas.New(database, cfg, gen, logger)
	ideasPipe.SetPromptStore(prompts.New(database, nil))
	p.SetTopUp(cliTopUp{digests: digestPipe, ideas: ideasPipe, workspaceDir: cfg.WorkspaceDir()})

	cleanup := func() {
		closeGen()
		_ = database.Close()
	}
	return p, database, cleanup, nil
}

// catchupRunEnvelope is `catchup run --json`'s one-object output. tldr, body
// and coverage come from the persisted row, so a failed recap still reports the
// coverage it managed to compute.
type catchupRunEnvelope struct {
	RecapID      int64            `json:"recap_id"`
	Status       string           `json:"status"`
	PeriodFrom   float64          `json:"period_from"`
	PeriodTo     float64          `json:"period_to"`
	Source       string           `json:"source"`
	Coverage     catchup.Coverage `json:"coverage"`
	RefsRejected int              `json:"refs_rejected"`
	Error        string           `json:"error"`
	TLDR         string           `json:"tldr"`
	Body         catchup.Body     `json:"body"`
}

func runCatchupRun(cmd *cobra.Command, _ []string) error {
	opts, err := catchupRunOptions()
	if err != nil {
		return err
	}

	p, database, cleanup, err := catchupPipeline()
	if err != nil {
		return err
	}
	defer cleanup()

	// A content failure is a persisted 'failed' row and a nil error; a Go error
	// means nothing was recorded, so it is checked before the status is read.
	res, err := p.Run(cmd.Context(), opts)
	if err != nil {
		return err
	}

	r, err := database.GetCatchupRecap(res.RecapID)
	if err != nil {
		return err
	}
	body, err := decodeRecapBody(r)
	if err != nil {
		return err
	}

	out := cmd.OutOrStdout()
	if !catchupRunFlagJSON {
		fmt.Fprint(out, renderRecapText(*r, body))
		return nil
	}
	var cov catchup.Coverage
	if err := json.Unmarshal([]byte(r.CoverageJSON), &cov); err != nil {
		return fmt.Errorf("decoding catchup recap %d coverage: %w", r.ID, err)
	}
	return json.NewEncoder(out).Encode(catchupRunEnvelope{
		RecapID:      r.ID,
		Status:       r.Status,
		PeriodFrom:   r.PeriodFrom,
		PeriodTo:     r.PeriodTo,
		Source:       res.Window.Source,
		Coverage:     cov,
		RefsRejected: res.RefsRejected,
		Error:        r.Error,
		TLDR:         r.TLDR,
		Body:         body,
	})
}

// catchupRunOptions turns the run flags into pipeline options. Combinations the
// pipeline could only ignore are rejected here — before the config is loaded and
// the database opened — so a mistyped window never costs an AI call.
func catchupRunOptions() (catchup.RunOptions, error) {
	if catchupRunFlagRegen < 0 {
		return catchup.RunOptions{}, fmt.Errorf("invalid --regen %d: a recap id is positive", catchupRunFlagRegen)
	}
	windowAsked := catchupRunFlagPreset != "" || catchupRunFlagFrom != "" || catchupRunFlagTo != ""
	if catchupRunFlagRegen > 0 && windowAsked {
		return catchup.RunOptions{}, fmt.Errorf("--regen reuses its source recap's window: --preset/--from/--to are not allowed with it")
	}
	if catchupRunFlagTo != "" && catchupRunFlagFrom == "" {
		return catchup.RunOptions{}, fmt.Errorf("--to requires --from")
	}
	// A correction only means something against a recap being redone; on a fresh
	// run it would be silently dropped, so it is rejected like its siblings.
	if catchupRunFlagComment != "" && catchupRunFlagRegen == 0 {
		return catchup.RunOptions{}, fmt.Errorf("--comment is a correction for --regen: pass --regen <id> with it")
	}

	opts := catchup.RunOptions{Spec: catchup.WindowSpec{Preset: catchupRunFlagPreset}}
	if catchupRunFlagFrom != "" {
		from, err := catchup.ParseWindowTime(catchupRunFlagFrom, time.Local)
		if err != nil {
			return catchup.RunOptions{}, fmt.Errorf("--from: %w", err)
		}
		opts.Spec.From = from
	}
	if catchupRunFlagTo != "" {
		to, err := catchup.ParseWindowTime(catchupRunFlagTo, time.Local)
		if err != nil {
			return catchup.RunOptions{}, fmt.Errorf("--to: %w", err)
		}
		opts.Spec.To = to
	}
	// The correction is a regen instruction: carrying it into a fresh run would
	// silently steer a recap the operator did not ask to correct.
	if catchupRunFlagRegen > 0 {
		opts.RegenOfID = catchupRunFlagRegen
		opts.Correction = catchupRunFlagComment
	}
	return opts, nil
}

func runCatchupAck(cmd *cobra.Command, args []string) error {
	recapID, err := parseRecapID(args[0])
	if err != nil {
		return err
	}
	p, _, cleanup, err := catchupPipeline()
	if err != nil {
		return err
	}
	defer cleanup()

	if err := p.Acknowledge(recapID); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Acknowledged recap %d — everything in its window is marked read.\n", recapID)
	return nil
}

func runCatchupFeedback(cmd *cobra.Command, args []string) error {
	recapID, err := parseRecapID(args[0])
	if err != nil {
		return err
	}
	if catchupFeedbackTopic < 0 {
		return fmt.Errorf("--topic is required: the 0-based index of the rated topic")
	}
	rating, err := parseRating(catchupFeedbackRating)
	if err != nil {
		return err
	}
	p, database, cleanup, err := catchupPipeline()
	if err != nil {
		return err
	}
	defer cleanup()

	// A regenerating comment can create a recap row and still fail composing it,
	// so the id is reported inside the error rather than as a success line.
	regenID, err := p.SubmitTopicFeedback(cmd.Context(), recapID, catchupFeedbackTopic, rating, catchupFeedbackComment)
	if err != nil {
		if regenID > 0 {
			return fmt.Errorf("regenerating recap %d as recap %d: %w", recapID, regenID, err)
		}
		return err
	}

	out := cmd.OutOrStdout()
	fmt.Fprintf(out, "Recorded feedback on recap %d, topic %d.\n", recapID, catchupFeedbackTopic)
	if regenID > 0 {
		fmt.Fprintln(out, catchupRegenLine(database, regenID))
	}
	return nil
}

// catchupRegenLine reports what the feedback-triggered regeneration produced. A
// content failure is persisted on the new row and returns no Go error, so the
// row is read back: without this the CLI would announce a clean "Regenerated as
// recap N" for a recap that failed to compose.
func catchupRegenLine(database *db.DB, regenID int64) string {
	r, err := database.GetCatchupRecap(regenID)
	switch {
	case err != nil:
		return fmt.Sprintf("Regenerated as recap %d — reading its status failed: %v", regenID, err)
	case r.Status == "failed":
		return fmt.Sprintf("Regenerated as recap %d — failed: %s", regenID, r.Error)
	default:
		return fmt.Sprintf("Regenerated as recap %d.", regenID)
	}
}

func runCatchupList(cmd *cobra.Command, _ []string) error {
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()

	recaps, err := database.ListCatchupRecaps(catchupListLimit)
	if err != nil {
		return err
	}

	out := cmd.OutOrStdout()
	if catchupListFlagJSON {
		if recaps == nil {
			recaps = []db.CatchupRecap{}
		}
		return json.NewEncoder(out).Encode(recaps)
	}
	if len(recaps) == 0 {
		fmt.Fprintln(out, "No catch-up recaps yet — `watchtower catchup run` builds one.")
		return nil
	}
	for _, r := range recaps {
		ack := "-"
		if r.AcknowledgedAt != "" {
			ack = "caught up"
		}
		fmt.Fprintf(out, "#%d  %s  %s  %s\n", r.ID, catchupWindowLabel(r.PeriodFrom, r.PeriodTo), r.Status, ack)
	}
	return nil
}

func runCatchupShow(cmd *cobra.Command, args []string) error {
	recapID, err := parseRecapID(args[0])
	if err != nil {
		return err
	}
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()

	r, err := database.GetCatchupRecap(recapID)
	if err != nil {
		return err
	}
	body, err := decodeRecapBody(r)
	if err != nil {
		return err
	}
	fmt.Fprint(cmd.OutOrStdout(), renderRecapText(*r, body))
	return nil
}

// renderRecapText renders one recap as plain text. It is what `run` prints
// without --json and what `show` prints, so both surfaces stay identical.
func renderRecapText(r db.CatchupRecap, body catchup.Body) string {
	var b strings.Builder
	header := "Catch-Up " + catchupWindowLabel(r.PeriodFrom, r.PeriodTo)
	switch r.Status {
	case "failed":
		fmt.Fprintf(&b, "%s — FAILED: %s\n", header, r.Error)
		return b.String()
	case "building":
		fmt.Fprintf(&b, "%s\n… still building\n", header)
		return b.String()
	}

	fmt.Fprintln(&b, header)
	if line := catchupCoverageLine(r.CoverageJSON); line != "" {
		fmt.Fprintln(&b, line)
	}
	// The TL;DR is the recap's answer, so it prints even when ref validation
	// dropped every section; "Quiet" is reserved for a recap that says nothing at
	// all — the same rule the Desktop document applies (CatchUpRecapDocument).
	if r.TLDR != "" {
		fmt.Fprintf(&b, "\n%s\n", r.TLDR)
	}
	if body.IsEmpty() {
		if r.TLDR == "" {
			fmt.Fprintln(&b, "\nQuiet — nothing happened in this window.")
		}
		return b.String()
	}
	renderRecapSections(&b, body)
	return b.String()
}

// renderRecapSections writes the four body sections, omitting the empty ones.
func renderRecapSections(b *strings.Builder, body catchup.Body) {
	if len(body.Topics) > 0 {
		fmt.Fprint(b, "\nWhat happened\n")
		for _, t := range body.Topics {
			fmt.Fprintf(b, "[%s] %s\n", t.Priority, t.Title)
			if t.Narrative != "" {
				fmt.Fprintf(b, "  %s\n", t.Narrative)
			}
			writeCatchupRefs(b, t.Refs)
		}
	}
	if len(body.Decisions) > 0 {
		fmt.Fprint(b, "\nDecisions\n")
		for _, d := range body.Decisions {
			fmt.Fprintf(b, "- %s\n", d.Text)
			writeCatchupRefs(b, d.Refs)
		}
	}
	if len(body.Meetings) > 0 {
		fmt.Fprint(b, "\nMeetings\n")
		for _, m := range body.Meetings {
			fmt.Fprintf(b, "- %s\n", m.Title)
			if m.Summary != "" {
				fmt.Fprintf(b, "  %s\n", m.Summary)
			}
			writeCatchupRefs(b, m.Refs)
		}
	}
	if len(body.NeedsYou) > 0 {
		fmt.Fprint(b, "\nFor you\n")
		for _, n := range body.NeedsYou {
			fmt.Fprintf(b, "[%s] %s\n", n.Kind, n.Text)
			writeCatchupRefs(b, n.Refs)
		}
	}
}

func writeCatchupRefs(b *strings.Builder, refs []db.CatchupRef) {
	for _, ref := range refs {
		fmt.Fprintf(b, "  · [%s#%d %s]\n", ref.Area, ref.ID, ref.Label)
	}
}

// catchupCoverageLine renders how far the summaries reached. A row carrying no
// coverage at all gets no line; a malformed record says so rather than passing
// its zeros off as a real gap.
func catchupCoverageLine(coverageJSON string) string {
	if strings.TrimSpace(coverageJSON) == "" {
		return ""
	}
	var cov catchup.Coverage
	if err := json.Unmarshal([]byte(coverageJSON), &cov); err != nil {
		return "Coverage: unreadable"
	}
	parts := []string{
		catchupCoverageReach("Slack", cov.SlackTo),
		catchupCoverageReach("Streams", cov.StreamsTo),
		fmt.Sprintf("%d meetings", cov.Meetings),
	}
	if cov.Topup != "" {
		parts = append(parts, "top-up "+cov.Topup)
	}
	return strings.Join(parts, " · ")
}

// catchupCoverageReach renders one source's reach. A zero means the window has
// no summary for that source at all, which the line says outright instead of
// printing a 1970 timestamp.
func catchupCoverageReach(name string, to float64) string {
	if to <= 0 {
		return name + ": none"
	}
	return fmt.Sprintf("%s to %s", name, time.Unix(int64(to), 0).Local().Format("15:04"))
}

func catchupWindowLabel(from, to float64) string {
	return time.Unix(int64(from), 0).Local().Format(catchupWindowLayout) +
		" → " + time.Unix(int64(to), 0).Local().Format(catchupWindowLayout)
}

// decodeRecapBody decodes a recap's persisted body.
func decodeRecapBody(r *db.CatchupRecap) (catchup.Body, error) {
	var body catchup.Body
	if strings.TrimSpace(r.BodyJSON) == "" {
		return body, nil
	}
	if err := json.Unmarshal([]byte(r.BodyJSON), &body); err != nil {
		return catchup.Body{}, fmt.Errorf("decoding catchup recap %d body: %w", r.ID, err)
	}
	return body, nil
}

func parseRecapID(s string) (int64, error) {
	id, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid recap id %q: %w", s, err)
	}
	return id, nil
}

// parseRating maps the CLI's up/down to the feedback rating (+1 / -1).
func parseRating(s string) (int, error) {
	switch s {
	case "up":
		return 1, nil
	case "down":
		return -1, nil
	default:
		return 0, fmt.Errorf("invalid --rating %q: must be up or down", s)
	}
}
