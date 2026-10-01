package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/projectcheck"
)

const (
	// stopHookBudget bounds the Stop hook's git work, well under the hook's
	// own timeout (devpack's stopSpec), so a slow repository never holds a
	// turn's end for long. stopHookStdinWait bounds reading the hook input
	// (a run from a terminal has none).
	stopHookBudget    = 8 * time.Second
	stopHookStdinWait = 2 * time.Second
	// stopHookStdinLimit caps what the hook reads of Claude Code's input.
	stopHookStdinLimit = 1 << 20
	// stopHookMaxFindings caps the list handed back to the agent.
	stopHookMaxFindings = 20
)

var projectCheckCmd = &cobra.Command{
	Use:   "check",
	Short: "Find board drift: targets whose status disagrees with their git branch or pull request",
	Long: "Mechanical, no AI, reads only: compares each target's branch (and, with gh and\n" +
		"network allowed, its pull request) with the folder's default branch —\n" +
		"  merged_but_open    the branch/PR is merged, the target is still open\n" +
		"  done_but_unmerged  done in the last 14 days, branch not merged / PR open, no open target on it\n" +
		"  branch_missing     an in-progress/in-review target's branch exists nowhere\n" +
		"  pr_closed_unmerged the PR was closed without a merge, the target is still open\n" +
		"  stale              an in-progress target with no movement for --stale-days\n" +
		"--stop-hook is the Claude Code Stop hook installed by `integrate claude-code --project N`:\n" +
		"it reads the hook input on stdin, runs offline, and asks the agent to fix the board\n" +
		"(once per stop) when git certainly disagrees with it — never for stale or\n" +
		"done_but_unmerged. It always exits 0. The check never runs git fetch.",
	// No root schema/config pre-run: in --stop-hook mode a broken config must
	// not fail the hook (the project brief precedent); the DB is opened by
	// the command itself.
	PersistentPreRunE:  func(*cobra.Command, []string) error { return nil },
	Args:               cobra.ArbitraryArgs,
	FParseErrWhitelist: cobra.FParseErrWhitelist{UnknownFlags: true},
	RunE:               runProjectCheck,
}

var (
	projectCheckFlagProject   string
	projectCheckFlagJSON      bool
	projectCheckFlagStaleDays int
	projectCheckFlagNoNetwork bool
	projectCheckFlagStopHook  bool
)

func init() {
	projectCheckCmd.Flags().StringVar(&projectCheckFlagProject, "project", "", "project id")
	projectCheckCmd.Flags().BoolVar(&projectCheckFlagJSON, "json", false, "output JSON")
	projectCheckCmd.Flags().IntVar(&projectCheckFlagStaleDays, "stale-days", int(projectcheck.DefaultStaleAfter/(24*time.Hour)),
		"days without movement before an in-progress target counts as stale")
	projectCheckCmd.Flags().BoolVar(&projectCheckFlagNoNetwork, "no-network", false, "skip pull request states (no gh call)")
	projectCheckCmd.Flags().BoolVar(&projectCheckFlagStopHook, "stop-hook", false, "run as the Claude Code Stop hook (stdin input, always exit 0)")
	projectCmd.AddCommand(projectCheckCmd)
}

func runProjectCheck(cmd *cobra.Command, _ []string) error {
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	if projectCheckFlagStopHook {
		runStopHook(ctx, cmd.InOrStdin(), cmd.OutOrStdout(), cmd.ErrOrStderr(), projectCheckFlagProject)
		return nil
	}
	id, err := parseProjectID(strings.TrimSpace(projectCheckFlagProject))
	if err != nil {
		return fmt.Errorf("--project: %w", err)
	}
	if projectCheckFlagStaleDays <= 0 {
		return errors.New("--stale-days must be positive")
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	rep, err := checkProject(ctx, database, id, projectcheck.Options{
		StaleAfter: time.Duration(projectCheckFlagStaleDays) * 24 * time.Hour,
		Network:    !projectCheckFlagNoNetwork,
	})
	if err != nil {
		return err
	}
	if projectCheckFlagJSON {
		return writeJSON(cmd.OutOrStdout(), rep)
	}
	printCheckReport(cmd.OutOrStdout(), rep)
	return nil
}

// checkProject loads project id's board and checks it in the project's
// folder; o.Folder is filled in here.
func checkProject(ctx context.Context, database *db.DB, id int64, o projectcheck.Options) (projectcheck.Report, error) {
	p, err := database.GetProject(id)
	if err != nil {
		return projectcheck.Report{}, fmt.Errorf("project %d: %w", id, err)
	}
	if _, err := os.Stat(p.FolderPath); err != nil {
		return projectcheck.Report{}, fmt.Errorf("project %d: folder %s is missing (moved or deleted?)", id, p.FolderPath)
	}
	board, err := database.GetProjectBoard(p.ID)
	if err != nil {
		return projectcheck.Report{}, fmt.Errorf("loading board: %w", err)
	}
	o.Folder = p.FolderPath
	return projectcheck.Check(ctx, p.ID, board, o), nil
}

func printCheckReport(w io.Writer, rep projectcheck.Report) {
	head := fmt.Sprintf("Project %d board drift", rep.ProjectID)
	if rep.Base != "" {
		head += " (against " + rep.Base + ")"
	}
	fmt.Fprintln(w, head+":")
	switch {
	case len(rep.Findings) > 0:
	case rep.Incomplete:
		fmt.Fprintln(w, "  No drift found in the part checked before time ran out.")
	case rep.Base == "":
		fmt.Fprintln(w, "  Branch checks did not run (see the notes); no other drift.")
	default:
		fmt.Fprintln(w, "  No drift.")
	}
	for _, f := range rep.Findings {
		fmt.Fprintf(w, "  - [%s] %s\n", f.Kind, f.Line())
	}
	for _, n := range rep.Notes {
		fmt.Fprintf(w, "  note: %s\n", n)
	}
}

// stopHookInput is the part of Claude Code's Stop hook input we read.
type stopHookInput struct {
	StopHookActive bool `json:"stop_hook_active"`
}

// stopHookOutput blocks the stop and hands reason back to the agent.
type stopHookOutput struct {
	Decision string `json:"decision"`
	Reason   string `json:"reason"`
}

// runStopHook is the Stop hook: stdout stays empty unless the board
// contradicts git. Every failure — bad input, no config, a deleted project
// (a leftover hook of an old install), a missing folder, a slow repository,
// even a panic — lets the turn finish with exit 0; one line on stderr names
// a real failure (Claude Code shows it in its hook log, never to the model).
// stop_hook_active means Claude Code is already continuing because a Stop
// hook blocked this stop, so this one never blocks again: the agent gets one
// chance to fix the board, never an endless loop.
func runStopHook(ctx context.Context, stdin io.Reader, stdout, stderr io.Writer, rawID string) {
	defer func() {
		// A panic would exit 2, which for a Stop hook means "block and feed
		// stderr to the model" — the opposite of this hook's contract.
		if r := recover(); r != nil {
			fmt.Fprintf(stderr, "watchtower: board drift check failed: %v\n", r)
		}
	}()
	inCtx, cancelIn := context.WithTimeout(ctx, stopHookStdinWait)
	in, ok := readStopHookInput(inCtx, stdin)
	cancelIn()
	if !ok || in.StopHookActive {
		return
	}
	id, err := strconv.ParseInt(strings.TrimSpace(rawID), 10, 64)
	if err != nil || id <= 0 {
		fmt.Fprintf(stderr, "watchtower: board drift check skipped: invalid --project %q\n", rawID)
		return
	}
	// Not under the hook's own budget: db.Open may be applying a migration,
	// which our deadline must never cut off part-way (Claude Code's hook
	// timeout still bounds the whole run).
	_, database, err := openJiraCmdDB()
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: board drift check skipped: %v\n", err)
		return
	}
	defer database.Close()
	ctx, cancel := context.WithTimeout(ctx, stopHookBudget)
	defer cancel()
	rep, err := checkProject(ctx, database, id, projectcheck.Options{})
	switch {
	case errors.Is(err, db.ErrProjectNotFound):
		return // a deleted project's leftover hook: nothing to say
	case err != nil:
		fmt.Fprintf(stderr, "watchtower: board drift check skipped: %v\n", err)
		return
	case rep.Incomplete:
		fmt.Fprintf(stderr, "watchtower: board drift check ran out of time after %s; only part of the board was checked\n", stopHookBudget)
	}
	findings := rep.BlockingFindings()
	if len(findings) == 0 {
		return
	}
	_ = json.NewEncoder(stdout).Encode(stopHookOutput{Decision: "block", Reason: stopHookReason(id, findings)})
}

// readStopHookInput decodes the hook input, giving up at ctx's deadline.
func readStopHookInput(ctx context.Context, stdin io.Reader) (stopHookInput, bool) {
	type result struct {
		in stopHookInput
		ok bool
	}
	ch := make(chan result, 1)
	go func() {
		var in stopHookInput
		err := json.NewDecoder(io.LimitReader(stdin, stopHookStdinLimit)).Decode(&in)
		ch <- result{in, err == nil}
	}()
	select {
	case r := <-ch:
		return r.in, r.ok
	case <-ctx.Done():
		return stopHookInput{}, false
	}
}

func stopHookReason(id int64, findings []projectcheck.Finding) string {
	lines := []string{fmt.Sprintf("Watchtower: the board of project %d disagrees with git. Fix the board before you finish "+
		"(update_target; the watchtower-project skill's \"Keeping the board in step with git\"):", id)}
	for i, f := range findings {
		if i == stopHookMaxFindings {
			lines = append(lines, fmt.Sprintf("- … %d more (watchtower project check --project %d)", len(findings)-i, id))
			break
		}
		lines = append(lines, "- "+briefClip(f.Line(), 400))
	}
	return strings.Join(lines, "\n")
}
