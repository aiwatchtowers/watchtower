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
		"agent session (Claude Code or Codex) of the workbench from the cache, after a\n" +
		"git-only refresh (within 3 s) of whether each task's branch is merged into its\n" +
		"parent's branch; it never runs gh.\n" +
		"Exits non-zero only when the workbench or the session does not resolve. --session\n" +
		"reports a git or gh failure in pr_note; --summary marks a row whose merged share\n" +
		"holds verdicts the refresh could not check (merged_stale) and names the failure\n" +
		"in one stderr line.",
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
	c.Flags().Int64Var(&workbenchSessionReportFlagWorkbench, workbenchFlag, 0, "workbench id")
	fs := c.Flags()
	fs.Int64Var(&workbenchSessionReportFlagSession, "session", 0, "terminal session id: print its report")
	fs.BoolVar(&workbenchSessionReportFlagSummary, "summary", false, "print every agent session's row line (cache, plus a git-only merge refresh; never gh)")
	fs.BoolVar(&workbenchSessionReportFlagJSON, "json", false, "output JSON")
	fs.BoolVar(&workbenchSessionReportFlagNoNetwork, "no-network", false, "refresh offline: local git merge detection only, never gh")
	c.MarkFlagsOneRequired("session", "summary")
	c.MarkFlagsMutuallyExclusive("session", "summary")
	workbenchCmd.AddCommand(c)
}

func runWorkbenchSessionReport(cmd *cobra.Command, _ []string) error {
	id := workbenchSessionReportFlagWorkbench
	if id <= 0 {
		return fmt.Errorf("--%s: a positive workbench id is required", workbenchFlag)
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
		rows, res, err := sessionreport.RefreshedSummaries(ctx, database, id, sessionreport.RefreshOptions{})
		if err != nil {
			return err
		}
		// stdout stays the row lines, each row's merged_stale marking a
		// merged share the refresh could not check; why (a git failure, a
		// cache write that failed) is one stderr line.
		if res.Note != "" {
			fmt.Fprintln(cmd.ErrOrStderr(), "session-report: merge states: "+res.Note)
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
	printReportHeader(w, r)
	printReportOnYou(w, r)
	printReportNow(w, r)
	printReportPRs(w, r)
	printReportDone(w, r)
	printReportLastWord(w, r.Session)
}

// printReportHeader prints the session's title line, state and size.
func printReportHeader(w io.Writer, r sessionreport.Report) {
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
	fmt.Fprintf(w, "  progress: %d / %d tasks%s\n", r.Progress.Done, r.Progress.Total, mergedPart(r.Progress.Merged))
}

// printReportOnYou prints the open asks waiting for the owner.
func printReportOnYou(w io.Writer, r sessionreport.Report) {
	fmt.Fprintln(w, "\nOn you")
	if len(r.OnYou) == 0 {
		fmt.Fprintln(w, "  Nothing — the agent is not waiting for you.")
	}
	for _, a := range r.OnYou {
		fmt.Fprintf(w, "  ask #%d [%s] %s (%s)\n", a.ID, a.Kind, a.Title, a.CreatedAt)
	}
}

// printReportNow prints the items in progress.
func printReportNow(w io.Writer, r sessionreport.Report) {
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
}

// printReportPRs prints the session's pull requests and the refresh note.
func printReportPRs(w io.Writer, r sessionreport.Report) {
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
}

// printReportDone prints the phases with their spans, then what is next.
func printReportDone(w io.Writer, r sessionreport.Report) {
	fmt.Fprintln(w, "\nDone")
	if len(r.Phases) == 0 {
		fmt.Fprintln(w, "  (no phases)")
	}
	for _, p := range r.Phases {
		line := fmt.Sprintf("  #%d %s  %d/%d%s", p.TargetID, p.Text, p.Done, p.Total, mergedPart(p.Merged))
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
}

// printReportLastWord prints the agent's finish summary, if it finished.
func printReportLastWord(w io.Writer, s sessionreport.Session) {
	fmt.Fprintln(w, "\nAgent's last word")
	if s.FinishSummary == "" {
		fmt.Fprintln(w, "  (the agent has not finished)")
		return
	}
	for line := range strings.SplitSeq(s.FinishSummary, "\n") {
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
		fmt.Fprintln(w, "No agent sessions.")
		return
	}
	for _, s := range rows {
		line := fmt.Sprintf("session %d", s.SessionID)
		if s.TargetID != nil {
			line += fmt.Sprintf("  target #%d", *s.TargetID)
		}
		line += fmt.Sprintf("  %d/%d%s", s.Done, s.Total, summaryMergedPart(s))
		if s.PRLine != "" {
			line += "  " + s.PRLine
		}
		if s.FinishedAt != "" {
			line += "  finished " + s.FinishedAt
		}
		fmt.Fprintln(w, line)
	}
}

// summaryMergedPart is a row line's merged share: mergedPart, and when the
// refresh could not check it " · N merged (unchecked)", or " · merged not
// checked" with none counted.
func summaryMergedPart(s sessionreport.Summary) string {
	switch {
	case s.Total == 0 || !s.MergedStale:
		return mergedPart(s.Merged)
	case s.Merged > 0:
		return mergedPart(s.Merged) + " (unchecked)"
	}
	return " · merged not checked"
}

// mergedPart is " · N merged" for a merged share, "" without one, so a count
// with nothing merged reads as before.
func mergedPart(n int) string {
	if n == 0 {
		return ""
	}
	return fmt.Sprintf(" · %d merged", n)
}
