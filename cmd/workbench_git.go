package cmd

import (
	"context"
	"errors"
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
		"workbench and its folder resolve; a refusal is in the output, not the exit code.\n" +
		"--folder F runs the command in the worktree of the repository that holds F (a\n" +
		"session's worktree); a folder outside the repository's worktrees is refused\n" +
		"(`folder_not_a_worktree`) — `status` reports it and shows the workbench folder.",
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
		"stashed under a message naming the switch and never popped afterwards); an agent\n" +
		"session (Claude Code or Codex) in the folder (--agent-running) needs --confirm-agent.\n" +
		"Without them `needs_confirmation` lists what to confirm and nothing is written.\n" +
		"Never forces, discards, resets or cleans.",
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
	workbenchGitFlagFolder       string
)

func init() {
	for _, c := range []*cobra.Command{workbenchGitStatusCmd, workbenchGitBranchesCmd, workbenchGitSwitchCmd, workbenchGitCreateCmd} {
		c.Flags().Int64Var(&workbenchGitFlagWorkbench, workbenchFlag, 0, "workbench id")
		c.Flags().BoolVar(&workbenchGitFlagJSON, "json", false, "output JSON")
		c.Flags().StringVar(&workbenchGitFlagFolder, "folder", "",
			"an absolute folder in one of the repository's worktrees (a session's); default the workbench folder")
		workbenchGitCmd.AddCommand(c)
	}
	sw := workbenchGitSwitchCmd.Flags()
	sw.StringVar(&workbenchGitFlagBranch, "branch", "", "the local branch to switch to")
	sw.BoolVar(&workbenchGitFlagStash, "stash", false, "stash uncommitted changes (untracked files included) before switching")
	sw.BoolVar(&workbenchGitFlagAgentRunning, "agent-running", false, "an agent session (Claude Code or Codex) is working in the folder")
	sw.BoolVar(&workbenchGitFlagConfirmAgent, "confirm-agent", false, "switch even though an agent session (Claude Code or Codex) is working in the folder")
	workbenchGitCreateCmd.Flags().StringVar(&workbenchGitFlagName, "name", "", "the new branch's name")
	workbenchCmd.AddCommand(workbenchGitCmd)
}

// workbenchGitTarget resolves the command's workbench to its id and folder,
// then --folder against the repository's worktrees (git runs only in the
// workbench folder for that); Options.Folder is the resolved root. An error
// (bad id, no such workbench, a missing workbench folder) exits non-zero;
// resolveErr is git failing to list the worktrees or the requested folder
// failing to resolve (workbenchgit.ErrFolderUnreadable), which the caller
// turns into its envelope.
func workbenchGitTarget(ctx context.Context, cmd *cobra.Command) (
	id int64, o workbenchgit.Options, folder workbenchgit.ResolvedFolder, resolveErr, err error,
) {
	id = workbenchGitFlagWorkbench
	if id <= 0 {
		return 0, o, folder, nil, fmt.Errorf("--%s: a positive workbench id is required", workbenchFlag)
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return 0, o, folder, nil, err
	}
	defer database.Close()
	p, err := workbenchWithFolder(database, id)
	if err != nil {
		return 0, o, folder, nil, err
	}
	folder, resolveErr = workbenchgit.ResolveFolder(ctx, workbenchgit.Options{Folder: p.FolderPath}, workbenchGitFlagFolder)
	return id, workbenchgit.Options{Folder: folder.Root}, folder, resolveErr, nil
}

// folderRefusal is why a branches, switch or create call may not use the
// folder asked for: a folder that could not be read, a failed worktree
// listing or a folder outside the repository's worktrees. "" = go ahead.
func folderRefusal(folder workbenchgit.ResolvedFolder, resolveErr error) (refused, detail string) {
	switch {
	case errors.Is(resolveErr, workbenchgit.ErrFolderUnreadable):
		return workbenchgit.RefusedFolderUnreadable, resolveErr.Error()
	case resolveErr != nil:
		return workbenchgit.RefusedGitFailed, "listing the worktrees: " + resolveErr.Error()
	case folder.OutsideTheRepository():
		return workbenchgit.RefusedFolderNotAWorktree, string(folder.Scope)
	}
	return "", ""
}

// resolveErrText is resolveErr as the envelope reports it: the folder's
// own "reading the folder: …" error (no git ran), or the failed listing.
func resolveErrText(resolveErr error) string {
	if errors.Is(resolveErr, workbenchgit.ErrFolderUnreadable) {
		return resolveErr.Error()
	}
	return "listing the worktrees: " + resolveErr.Error()
}

func workbenchGitContext(cmd *cobra.Command, budget time.Duration) (context.Context, context.CancelFunc) {
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	return context.WithTimeout(ctx, budget)
}

func runWorkbenchGitStatus(cmd *cobra.Command, _ []string) error {
	ctx, cancel := workbenchGitContext(cmd, workbenchGitReadBudget)
	defer cancel()
	id, o, folder, resolveErr, err := workbenchGitTarget(ctx, cmd)
	if err != nil {
		return err
	}
	st := workbenchgit.ReadStatus(ctx, o)
	st.WorkbenchID, st.ResolvedFolder = id, folder
	if resolveErr != nil { // the folder could not be placed: a failed read
		st.StatusOK, st.StatusError = false, resolveErrText(resolveErr)
	}
	if workbenchGitFlagJSON {
		return writeJSON(cmd.OutOrStdout(), st)
	}
	printGitStatus(cmd.OutOrStdout(), st)
	return nil
}

func runWorkbenchGitBranches(cmd *cobra.Command, _ []string) error {
	ctx, cancel := workbenchGitContext(cmd, workbenchGitReadBudget)
	defer cancel()
	id, o, folder, resolveErr, err := workbenchGitTarget(ctx, cmd)
	if err != nil {
		return err
	}
	l := workbenchgit.BranchList{Branches: []workbenchgit.Branch{}}
	if l.Refused, l.RefusedDetail = folderRefusal(folder, resolveErr); l.Refused == "" {
		l = workbenchgit.ListBranches(ctx, o)
	}
	l.WorkbenchID = id
	if workbenchGitFlagJSON {
		return writeJSON(cmd.OutOrStdout(), l)
	}
	printGitBranches(cmd.OutOrStdout(), l)
	return nil
}

func printGitBranches(w io.Writer, l workbenchgit.BranchList) {
	fmt.Fprintf(w, "workbench: %d\ngit: %t\n", l.WorkbenchID, l.Git)
	if l.Refused != "" {
		fmt.Fprintf(w, "refused: %s %s\n", l.Refused, l.RefusedDetail)
	}
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
}

func runWorkbenchGitSwitch(cmd *cobra.Command, _ []string) error {
	ctx, cancel := workbenchGitContext(cmd, workbenchGitWriteBudget)
	defer cancel()
	id, o, folder, resolveErr, err := workbenchGitTarget(ctx, cmd)
	if err != nil {
		return err
	}
	res := refusedSwitch(workbenchGitFlagBranch, folder, resolveErr)
	if res.Refused == "" {
		res = workbenchgit.Switch(ctx, o, workbenchgit.SwitchRequest{
			Branch:       workbenchGitFlagBranch,
			Stash:        workbenchGitFlagStash,
			AgentRunning: workbenchGitFlagAgentRunning,
			ConfirmAgent: workbenchGitFlagConfirmAgent,
		})
	}
	res.Status.ResolvedFolder = folder
	return writeSwitchResult(cmd.OutOrStdout(), id, res)
}

func runWorkbenchGitCreate(cmd *cobra.Command, _ []string) error {
	ctx, cancel := workbenchGitContext(cmd, workbenchGitWriteBudget)
	defer cancel()
	id, o, folder, resolveErr, err := workbenchGitTarget(ctx, cmd)
	if err != nil {
		return err
	}
	res := refusedSwitch(workbenchGitFlagName, folder, resolveErr)
	if res.Refused == "" {
		res = workbenchgit.Create(ctx, o, workbenchGitFlagName)
	}
	res.Status.ResolvedFolder = folder
	return writeSwitchResult(cmd.OutOrStdout(), id, res)
}

// refusedSwitch is the switch or create envelope refusing the folder asked
// for; Refused is "" when the folder may be used. Its status is not read:
// no git runs in a refused folder.
func refusedSwitch(branch string, folder workbenchgit.ResolvedFolder, resolveErr error) workbenchgit.SwitchResult {
	res := workbenchgit.SwitchResult{Branch: branch, NeedsConfirmation: []string{}}
	res.Refused, res.RefusedDetail = folderRefusal(folder, resolveErr)
	return res
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
		{"warning", res.Warning},
	} {
		if f.value != "" {
			fmt.Fprintf(w, "%s: %s\n", f.key, f.value)
		}
	}
	// A refused folder (or worktree listing) read no status at all.
	if res.Status.GitAvailable || res.Status.Note != "" {
		printGitStatus(w, res.Status)
	}
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
	if !st.StatusOK { // the fields below would read as a clean worktree
		fmt.Fprintf(w, "status error: %s\n", st.StatusError)
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
	fmt.Fprintf(w, "folder: %s\n", st.TopLevel)
	if st.Scope != "" && st.Scope != workbenchgit.ScopeMain {
		fmt.Fprintf(w, "folder scope: %s\n", strings.TrimSpace(string(st.Scope)+" "+st.WorktreeName))
	}
}
