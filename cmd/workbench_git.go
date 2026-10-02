package cmd

import (
	"context"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/workbenchgit"
)

const (
	// workbenchGitReadBudget bounds status and branches: the Desktop header
	// refreshes on focus and on ref changes, so a slow repository must not
	// pile up calls.
	workbenchGitReadBudget = 5 * time.Second
	// workbenchGitWriteBudget bounds switch and create (a stash and a
	// checkout of a large tree take a while).
	workbenchGitWriteBudget = 60 * time.Second
)

var workbenchGitCmd = &cobra.Command{
	Use:   "git",
	Short: "Read the workbench folder's git branch and switch it (the Desktop's workbench header)",
	Long: "Local branches only; no fetch, pull or push. git is the developer tools' or\n" +
		"Homebrew's binary, never /usr/bin/git (which could pop the install dialog),\n" +
		"and no git process runs outside a repository. Every command exits 0 once the\n" +
		"workbench and its folder resolve; a refusal is in the output, not the exit code.",
}

var workbenchGitStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show the folder's branch, its upstream counters and uncommitted changes",
	Args:  cobra.NoArgs,
	RunE:  runWorkbenchGitStatus,
}

var workbenchGitBranchesCmd = &cobra.Command{
	Use:   "branches",
	Short: "List the local branches, newest commit first",
	Args:  cobra.NoArgs,
	RunE:  runWorkbenchGitBranches,
}

var workbenchGitSwitchCmd = &cobra.Command{
	Use:   "switch",
	Short: "Switch the folder to a local branch, behind the uncommitted-changes and agent guards",
	Long: "Refused (exit 0, `refused`) for an unknown branch, a branch checked out in another\n" +
		"worktree or an operation in progress. Uncommitted changes need --stash (they are\n" +
		"stashed under a message naming the switch and never popped afterwards); a Claude\n" +
		"Code session in the folder (--agent-running) needs --confirm-agent. Without them\n" +
		"`needs_confirmation` lists what to confirm and nothing is written. Never forces,\n" +
		"discards, resets or cleans.",
	Args: cobra.NoArgs,
	RunE: runWorkbenchGitSwitch,
}

var workbenchGitCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a branch from the current commit and switch to it (changes come along)",
	Args:  cobra.NoArgs,
	RunE:  runWorkbenchGitCreate,
}

var (
	workbenchGitFlagWorkbench    int64
	workbenchGitFlagJSON         bool
	workbenchGitFlagBranch       string
	workbenchGitFlagStash        bool
	workbenchGitFlagAgentRunning bool
	workbenchGitFlagConfirmAgent bool
	workbenchGitFlagName         string
)

func init() {
	for _, c := range []*cobra.Command{workbenchGitStatusCmd, workbenchGitBranchesCmd, workbenchGitSwitchCmd, workbenchGitCreateCmd} {
		addWorkbenchIDFlag(c, &workbenchGitFlagWorkbench, "workbench id")
		c.Flags().BoolVar(&workbenchGitFlagJSON, "json", false, "output JSON")
		workbenchGitCmd.AddCommand(c)
	}
	sw := workbenchGitSwitchCmd.Flags()
	sw.StringVar(&workbenchGitFlagBranch, "branch", "", "the local branch to switch to")
	sw.BoolVar(&workbenchGitFlagStash, "stash", false, "stash uncommitted changes (untracked files included) before switching")
	sw.BoolVar(&workbenchGitFlagAgentRunning, "agent-running", false, "a Claude Code session is working in the folder")
	sw.BoolVar(&workbenchGitFlagConfirmAgent, "confirm-agent", false, "switch even though a Claude Code session is working in the folder")
	workbenchGitCreateCmd.Flags().StringVar(&workbenchGitFlagName, "name", "", "the new branch's name")
	workbenchCmd.AddCommand(workbenchGitCmd)
}

// workbenchGitTarget resolves the command's workbench to its id and folder;
// an error (bad id, no such workbench, a missing folder) exits non-zero.
func workbenchGitTarget(cmd *cobra.Command) (int64, workbenchgit.Options, error) {
	if err := checkWorkbenchIDFlags(cmd); err != nil {
		return 0, workbenchgit.Options{}, err
	}
	id := workbenchGitFlagWorkbench
	if id <= 0 {
		return 0, workbenchgit.Options{}, fmt.Errorf("%s: a positive workbench id is required",
			workbenchFlagName(cmd.Flags().Changed(legacyWorkbenchFlag)))
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return 0, workbenchgit.Options{}, err
	}
	defer database.Close()
	p, err := workbenchWithFolder(database, id)
	if err != nil {
		return 0, workbenchgit.Options{}, err
	}
	return id, workbenchgit.Options{Folder: p.FolderPath}, nil
}

func workbenchGitContext(cmd *cobra.Command, budget time.Duration) (context.Context, context.CancelFunc) {
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	return context.WithTimeout(ctx, budget)
}

func runWorkbenchGitStatus(cmd *cobra.Command, _ []string) error {
	id, o, err := workbenchGitTarget(cmd)
	if err != nil {
		return err
	}
	ctx, cancel := workbenchGitContext(cmd, workbenchGitReadBudget)
	defer cancel()
	st := workbenchgit.ReadStatus(ctx, o)
	st.WorkbenchID = id
	if workbenchGitFlagJSON {
		return writeJSON(cmd.OutOrStdout(), st)
	}
	printGitStatus(cmd.OutOrStdout(), st)
	return nil
}

func runWorkbenchGitBranches(cmd *cobra.Command, _ []string) error {
	id, o, err := workbenchGitTarget(cmd)
	if err != nil {
		return err
	}
	ctx, cancel := workbenchGitContext(cmd, workbenchGitReadBudget)
	defer cancel()
	l := workbenchgit.ListBranches(ctx, o)
	l.WorkbenchID = id
	if workbenchGitFlagJSON {
		return writeJSON(cmd.OutOrStdout(), l)
	}
	w := cmd.OutOrStdout()
	fmt.Fprintf(w, "workbench: %d\ngit: %t\n", l.WorkbenchID, l.Git)
	if l.BranchesError != "" {
		fmt.Fprintf(w, "error: %s\n", l.BranchesError)
	}
	for _, b := range l.Branches {
		mark := " "
		if b.Current {
			mark = "*"
		}
		line := fmt.Sprintf("%s %s %s %s", mark, b.Name, b.Head, b.CommittedAt.Format(time.RFC3339))
		if b.Upstream != "" {
			line += fmt.Sprintf(" [%s +%d -%d]", b.Upstream, b.Ahead, b.Behind)
		}
		if b.Worktree != "" {
			line += " (checked out in " + b.Worktree + ")"
		}
		fmt.Fprintln(w, line)
	}
	return nil
}

func runWorkbenchGitSwitch(cmd *cobra.Command, _ []string) error {
	id, o, err := workbenchGitTarget(cmd)
	if err != nil {
		return err
	}
	ctx, cancel := workbenchGitContext(cmd, workbenchGitWriteBudget)
	defer cancel()
	res := workbenchgit.Switch(ctx, o, workbenchgit.SwitchRequest{
		Branch:       workbenchGitFlagBranch,
		Stash:        workbenchGitFlagStash,
		AgentRunning: workbenchGitFlagAgentRunning,
		ConfirmAgent: workbenchGitFlagConfirmAgent,
	})
	return writeSwitchResult(cmd.OutOrStdout(), id, res)
}

func runWorkbenchGitCreate(cmd *cobra.Command, _ []string) error {
	id, o, err := workbenchGitTarget(cmd)
	if err != nil {
		return err
	}
	ctx, cancel := workbenchGitContext(cmd, workbenchGitWriteBudget)
	defer cancel()
	return writeSwitchResult(cmd.OutOrStdout(), id, workbenchgit.Create(ctx, o, workbenchGitFlagName))
}

func writeSwitchResult(w io.Writer, id int64, res workbenchgit.SwitchResult) error {
	res.WorkbenchID, res.Status.WorkbenchID = id, id
	if workbenchGitFlagJSON {
		return writeJSON(w, res)
	}
	fmt.Fprintf(w, "workbench: %d\nbranch: %s\nswitched: %t\n", res.WorkbenchID, res.Branch, res.Switched)
	for _, f := range []struct{ key, value string }{
		{"already", boolField(res.Already)},
		{"created", boolField(res.Created)},
		{"needs confirmation", strings.Join(res.NeedsConfirmation, ", ")},
		{"refused", strings.TrimSpace(res.Refused + " " + res.RefusedDetail)},
		{"stashed", strings.TrimSpace(res.Stashed + " " + res.StashMessage)},
		{"stash restored", boolField(res.StashRestored)},
		{"stash error", res.StashError},
		{"error", res.Error},
	} {
		if f.value != "" {
			fmt.Fprintf(w, "%s: %s\n", f.key, f.value)
		}
	}
	printGitStatus(w, res.Status)
	return nil
}

// boolField is "true" for a set flag and "" (not printed) otherwise.
func boolField(b bool) string {
	if b {
		return "true"
	}
	return ""
}

func printGitStatus(w io.Writer, st workbenchgit.Status) {
	fmt.Fprintf(w, "git: %t\n", st.Git)
	if st.Note != "" {
		fmt.Fprintf(w, "note: %s\n", st.Note)
	}
	if !st.Git {
		return
	}
	branch := st.Branch
	if st.Detached {
		branch = "(detached at " + st.Head + ")"
	}
	fmt.Fprintf(w, "current: %s\nhead: %s\n", branch, st.Head)
	if st.Upstream != "" {
		fmt.Fprintf(w, "upstream: %s (+%d -%d)\n", st.Upstream, st.Ahead, st.Behind)
	}
	fmt.Fprintf(w, "changes: %d\n", st.Changes)
	if st.Operation != "" {
		fmt.Fprintf(w, "operation: %s\n", st.Operation)
	}
	if st.StatusError != "" {
		fmt.Fprintf(w, "status error: %s\n", st.StatusError)
	}
	fmt.Fprintf(w, "folder: %s\n", st.TopLevel)
}
