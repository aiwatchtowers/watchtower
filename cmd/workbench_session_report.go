package cmd

import (
	"context"
	"fmt"
	"io"
	"slices"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/sessionreport"
)

var workbenchSessionReportCmd = &cobra.Command{
	Use:   "session-report",
	Short: "Show what a workbench terminal session did: progress, phases, pull requests, what waits on you",
	Long: "--session S prints that session's report: its open asks, the tasks in progress, the\n" +
		"pull requests and branches of its targets, the done work by phase and the agent's\n" +
		"finish summary. It first refreshes the PR cache for the session's refs within 10 s\n" +
		"(local git merge detection, plus gh; --no-network keeps the refresh offline:\n" +
		"git only, gh never runs). --summary prints one line per\n" +
		"claude session of the workbench from the cache only, never running git or gh.\n" +
		"Exits non-zero only when the workbench or the session does not resolve; a git or gh\n" +
		"failure is reported in pr_note. The pre-rename `project session-report --project N`\n" +
		"works too.",
	Args: cobra.NoArgs,
	RunE: runWorkbenchSessionReport,
}

var (
	workbenchSessionReportFlagWorkbench int64
	workbenchSessionReportFlagSession   int64
	workbenchSessionReportFlagSummary   bool
	workbenchSessionReportFlagJSON      bool
	workbenchSessionReportFlagNoNetwork bool
)

func init() {
	c := workbenchSessionReportCmd
	addWorkbenchIDFlag(c, &workbenchSessionReportFlagWorkbench, "workbench id")
	fs := c.Flags()
	fs.Int64Var(&workbenchSessionReportFlagSession, "session", 0, "terminal session id: print its report")
	fs.BoolVar(&workbenchSessionReportFlagSummary, "summary", false, "print every claude session's row line (cache only)")
	fs.BoolVar(&workbenchSessionReportFlagJSON, "json", false, "output JSON")
	fs.BoolVar(&workbenchSessionReportFlagNoNetwork, "no-network", false, "refresh offline: local git merge detection only, never gh")
	c.MarkFlagsOneRequired("session", "summary")
	c.MarkFlagsMutuallyExclusive("session", "summary")
	workbenchCmd.AddCommand(c)
}

func runWorkbenchSessionReport(cmd *cobra.Command, _ []string) error {
	if err := checkWorkbenchIDFlags(cmd); err != nil {
		return err
	}
	id := workbenchSessionReportFlagWorkbench
	if id <= 0 {
		return fmt.Errorf("%s: a positive workbench id is required",
			workbenchFlagName(cmd.Flags().Changed(legacyWorkbenchFlag)))
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	// The folder may be gone: a refresh then only notes it.
	if _, err := database.GetWorkbench(id); err != nil {
		return err
	}
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	w := cmd.OutOrStdout()
	if workbenchSessionReportFlagSummary {
		rows, err := sessionreport.Summaries(ctx, database, id)
		if err != nil {
			return err
		}
		if workbenchSessionReportFlagJSON {
			return writeJSON(w, rows)
		}
		printSessionSummaries(w, rows)
		return nil
	}
	rep, err := sessionReport(ctx, database, id, workbenchSessionReportFlagSession, !workbenchSessionReportFlagNoNetwork)
	if err != nil {
		return err
	}
	if workbenchSessionReportFlagJSON {
		return writeJSON(w, rep)
	}
	printSessionReport(w, rep)
	return nil
}

// sessionReport refreshes the PR cache for session sessionID's refs, then
// builds its report; the refresh's note becomes pr_note. An unknown session
// fails before anything runs.
func sessionReport(ctx context.Context, database *db.DB, workbenchID, sessionID int64, network bool) (sessionreport.Report, error) {
	refs, err := sessionreport.SessionRefs(ctx, database, workbenchID, sessionID)
	if err != nil {
		return sessionreport.Report{}, err
	}
	res := sessionreport.Refresh(ctx, database, workbenchID, refs, sessionreport.RefreshOptions{
		Network: network, Budget: sessionreport.DefaultRefreshBudget,
	})
	return sessionreport.Build(ctx, database, workbenchID, sessionID, sessionreport.Options{PRNote: res.Note})
}

// printSessionReport prints the report's sections in the Session view's
// order: state and size, on you, now, pull requests, done, the agent's last
// word.
func printSessionReport(w io.Writer, r sessionreport.Report) {
	s := r.Session
	head := fmt.Sprintf("Session %d", s.ID)
	if s.Title != "" {
		head += " " + s.Title
	}
	if s.TargetID != nil {
		head += fmt.Sprintf(" (target #%d)", *s.TargetID)
	}
	fmt.Fprintln(w, head)
	fmt.Fprintf(w, "  state:    %s\n", sessionStateLine(s))
	fmt.Fprintf(w, "  ran:      %s -> %s\n", s.CreatedAt, s.LastActiveAt)
	if br := reportBranches(r); len(br) > 0 {
		fmt.Fprintf(w, "  branches: %s\n", strings.Join(br, ", "))
	}
	fmt.Fprintf(w, "  progress: %d / %d tasks\n", r.Progress.Done, r.Progress.Total)

	fmt.Fprintln(w, "\nOn you")
	if len(r.OnYou) == 0 {
		fmt.Fprintln(w, "  Nothing — the agent is not waiting for you.")
	}
	for _, a := range r.OnYou {
		fmt.Fprintf(w, "  ask #%d [%s] %s (%s)\n", a.ID, a.Kind, a.Title, a.CreatedAt)
	}

	fmt.Fprintln(w, "\nNow")
	if len(r.Now) == 0 {
		fmt.Fprintln(w, "  (nothing in progress)")
	}
	for _, it := range r.Now {
		line := fmt.Sprintf("  #%d [%s] %s", it.ID, it.Status, it.Text)
		if it.Branch != "" {
			line += " · " + it.Branch
		}
		if it.Since != "" {
			line += " · since " + it.Since
		}
		fmt.Fprintln(w, line)
	}

	fmt.Fprintln(w, "\nPull requests")
	if len(r.PRs) == 0 {
		fmt.Fprintln(w, "  (none)")
	}
	for _, pr := range r.PRs {
		fmt.Fprintln(w, "  "+prReportLine(pr))
	}
	if r.PRNote != "" {
		fmt.Fprintf(w, "  note: %s\n", r.PRNote)
	}

	fmt.Fprintln(w, "\nDone")
	if len(r.Phases) == 0 {
		fmt.Fprintln(w, "  (no phases)")
	}
	for _, p := range r.Phases {
		line := fmt.Sprintf("  #%d %s  %d/%d", p.TargetID, p.Text, p.Done, p.Total)
		switch {
		case p.FinishedAt != "":
			line += "  " + p.StartedAt + " -> " + p.FinishedAt
		case p.StartedAt != "":
			line += "  since " + p.StartedAt
		}
		fmt.Fprintln(w, line)
	}
	for _, it := range r.Next {
		fmt.Fprintf(w, "  Next: #%d %s\n", it.ID, it.Text)
	}

	fmt.Fprintln(w, "\nAgent's last word")
	if s.FinishSummary == "" {
		fmt.Fprintln(w, "  (the agent has not finished)")
		return
	}
	for _, line := range strings.Split(s.FinishSummary, "\n") {
		fmt.Fprintln(w, "  "+line)
	}
}

// sessionStateLine is the stored agent state as the CLI shows it: finished
// first, since finish_session outranks the hook states.
func sessionStateLine(s sessionreport.Session) string {
	if s.FinishedAt != "" {
		return "finished at " + s.FinishedAt
	}
	if s.AgentState == "" {
		return "not reported"
	}
	if s.AgentStateAt != "" {
		return s.AgentState + " since " + s.AgentStateAt
	}
	return s.AgentState
}

// reportBranches is the distinct branches the report names, in order.
func reportBranches(r sessionreport.Report) []string {
	var out []string
	add := func(b string) {
		if b != "" && !slices.Contains(out, b) {
			out = append(out, b)
		}
	}
	for _, it := range r.Now {
		add(it.Branch)
	}
	for _, pr := range r.PRs {
		if b, ok := strings.CutPrefix(pr.Ref, "branch:"); ok {
			add(b)
		}
	}
	return out
}

func prReportLine(pr sessionreport.PR) string {
	var line string
	merged := pr.State == "merged"
	if pr.PRNumber != nil {
		line = fmt.Sprintf("PR #%d %s", *pr.PRNumber, pr.State)
	} else {
		branch := strings.TrimPrefix(pr.Ref, "branch:")
		switch pr.State {
		case "merged":
			line = branch + " merged"
		case "open", "closed":
			line = fmt.Sprintf("%s %s (no PR yet)", branch, pr.State)
		case "none": // gh checked it and found no PR
			line = branch + " no PR yet"
		default:
			// Never checked: the branch may still turn out to carry a PR.
			line = branch + " not checked"
		}
	}
	// "merged" is said once, with its date beside it.
	if merged && pr.MergedAt != "" {
		line += " " + pr.MergedAt
	}
	if pr.Title != "" {
		line += " — " + pr.Title
	}
	if pr.Additions != nil && pr.Deletions != nil {
		line += fmt.Sprintf(" +%d/−%d", *pr.Additions, *pr.Deletions)
	}
	if pr.MergedAt != "" && !merged {
		line += " · merged " + pr.MergedAt
	}
	return line
}

func printSessionSummaries(w io.Writer, rows []sessionreport.Summary) {
	if len(rows) == 0 {
		fmt.Fprintln(w, "No claude sessions.")
		return
	}
	for _, s := range rows {
		line := fmt.Sprintf("session %d", s.SessionID)
		if s.TargetID != nil {
			line += fmt.Sprintf("  target #%d", *s.TargetID)
		}
		line += fmt.Sprintf("  %d/%d", s.Done, s.Total)
		if s.PRLine != "" {
			line += "  " + s.PRLine
		}
		if s.FinishedAt != "" {
			line += "  finished " + s.FinishedAt
		}
		fmt.Fprintln(w, line)
	}
}
