package cmd

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/workbenchgit"
)

var workbenchWorktreeCmd = &cobra.Command{
	Use:   "worktree",
	Short: "Create and restore session worktrees (parallel agent sessions)",
	Long: "A session worktree is <repository>/.claude/worktrees/<name> on branch wt/<name>,\n" +
		"cut from the workbench folder's HEAD, with the .worktreeinclude paths cloned in and\n" +
		"the workbench integration installed. Removal is `workbench cleanup` (PROJ-18); forget\n" +
		"only unregisters a removed worktree's MCP entry. Every command exits 0 once the\n" +
		"workbench and its folder resolve.",
}

var (
	workbenchWorktreeFlagName   string
	workbenchWorktreeFlagPath   string
	workbenchWorktreeFlagBranch string
)

func init() {
	create := &cobra.Command{Use: "create", Short: "Create a session worktree", Args: cobra.NoArgs, RunE: runWorkbenchWorktreeCreate}
	ensure := &cobra.Command{Use: "ensure", Short: "Put a removed session worktree back from its branch", Args: cobra.NoArgs, RunE: runWorkbenchWorktreeEnsure}
	forget := &cobra.Command{Use: "forget", Short: "Unregister a removed session worktree's MCP entry (no git write)", Args: cobra.NoArgs, RunE: runWorkbenchWorktreeForget}
	for _, c := range []*cobra.Command{create, ensure, forget} {
		c.Flags().Int64Var(&workbenchGitFlagWorkbench, workbenchFlag, 0, "workbench id")
		c.Flags().BoolVar(&workbenchGitFlagJSON, "json", false, "output JSON")
		workbenchWorktreeCmd.AddCommand(c)
	}
	create.Flags().StringVar(&workbenchWorktreeFlagName, "name", "", "the worktree's name (lowercase letters, digits, dashes)")
	for _, c := range []*cobra.Command{ensure, forget} {
		c.Flags().StringVar(&workbenchWorktreeFlagPath, "path", "", "the worktree's top level")
	}
	ensure.Flags().StringVar(&workbenchWorktreeFlagBranch, "branch", "", "its wt/… branch")
	workbenchCmd.AddCommand(workbenchWorktreeCmd)
}

// worktreeEnvelope is a create/ensure result plus the integration install's
// failure: the worktree is usable without it, but its session would lack
// the hooks and board tools, so the Desktop shows it.
type worktreeEnvelope struct {
	workbenchgit.WorktreeResult
	IntegrationError string `json:"integration_error"`
}

// worktreeTarget is workbenchGitTarget for commands that take no --folder:
// the main workbench folder, or the envelope's refusal when it cannot be read.
func worktreeTarget(ctx context.Context, cmd *cobra.Command) (id int64, o workbenchgit.Options, refused, detail string, err error) {
	id, o, folder, resolveErr, err := workbenchGitTarget(ctx, cmd)
	if err != nil {
		return 0, o, "", "", err
	}
	refused, detail = folderRefusal(folder, resolveErr)
	return id, o, refused, detail, nil
}

func runWorkbenchWorktreeCreate(cmd *cobra.Command, _ []string) error {
	ctx, cancel := workbenchGitContext(cmd, workbenchGitWriteBudget)
	defer cancel()
	id, o, refused, detail, err := worktreeTarget(ctx, cmd)
	if err != nil {
		return err
	}
	var res workbenchgit.WorktreeResult
	switch taken, takenErr := heldWorktreeBranches(ctx); {
	case refused != "":
		res.Refused, res.RefusedDetail = refused, detail
	case takenErr != nil:
		// Without the held names a cleaned-up session's name could be
		// handed out again, so no worktree is made.
		res.Error = takenErr.Error()
	default:
		res = workbenchgit.CreateWorktree(ctx, o, workbenchgit.WorktreeRequest{Slug: workbenchWorktreeFlagName, Taken: taken})
	}
	return writeWorktreeEnvelope(ctx, cmd, id, res)
}

// heldWorktreeBranches is every worktree branch a session row still holds,
// in any workbench: a repository can back more than one.
func heldWorktreeBranches(ctx context.Context) ([]string, error) {
	_, database, err := openJiraCmdDB()
	if err != nil {
		return nil, err
	}
	defer database.Close()
	return database.HeldWorktreeBranches(ctx)
}

func runWorkbenchWorktreeEnsure(cmd *cobra.Command, _ []string) error {
	ctx, cancel := workbenchGitContext(cmd, workbenchGitWriteBudget)
	defer cancel()
	id, o, refused, detail, err := worktreeTarget(ctx, cmd)
	if err != nil {
		return err
	}
	var res workbenchgit.WorktreeResult
	if refused != "" {
		res.Refused, res.RefusedDetail = refused, detail
	} else {
		res = workbenchgit.EnsureWorktree(ctx, o, workbenchWorktreeFlagPath, workbenchWorktreeFlagBranch)
		if res.Created {
			res.Cwd = sessionCwdIn(ctx, o, res.Path)
		}
	}
	return writeWorktreeEnvelope(ctx, cmd, id, res)
}

type worktreeForgetResult struct {
	WorkbenchID int64  `json:"workbench_id"`
	Forgot      bool   `json:"forgot"`
	Error       string `json:"error"`
}

func runWorkbenchWorktreeForget(cmd *cobra.Command, _ []string) error {
	ctx, cancel := workbenchGitContext(cmd, workbenchGitWriteBudget)
	defer cancel()
	id, o, refused, detail, err := worktreeTarget(ctx, cmd)
	if err != nil {
		return err
	}
	res := worktreeForgetResult{WorkbenchID: id}
	if refused != "" {
		res.Error = refused + ": " + detail
		return writeJSON(cmd.OutOrStdout(), res)
	}
	// ReadStatus is the only git call here, and it only reads.
	top := workbenchgit.ReadStatus(ctx, o).TopLevel
	root := filepath.Join(top, ".claude", "worktrees")
	if top == "" || filepath.Dir(filepath.Clean(workbenchWorktreeFlagPath)) != root {
		res.Error = "not a session worktree: " + workbenchWorktreeFlagPath
		return writeJSON(cmd.OutOrStdout(), res)
	}
	opts, err := workbenchInstallOptions(&db.Workbench{ID: id, FolderPath: sessionCwdIn(ctx, o, workbenchWorktreeFlagPath)})
	if err == nil {
		err = devpack.UnregisterWorkbenchMCP(ctx, opts)
	}
	if err != nil {
		res.Error = err.Error()
	} else {
		res.Forgot = true
	}
	return writeJSON(cmd.OutOrStdout(), res)
}

// sessionCwdIn is the worktree top joined with the main folder's path below
// its own top level (a workbench bound to a repository subfolder).
func sessionCwdIn(ctx context.Context, main workbenchgit.Options, worktreeTop string) string {
	top := workbenchgit.ReadStatus(ctx, main).TopLevel
	if top == "" {
		return worktreeTop
	}
	rel, err := filepath.Rel(top, main.Folder)
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") {
		return worktreeTop
	}
	return filepath.Join(worktreeTop, rel)
}

// installWorktreeIntegration is `integrate claude-code` (and codex's skill
// and hook trust, when codex is found) for the worktree folder, under the
// same workbench id.
func installWorktreeIntegration(ctx context.Context, id int64, folder string) error {
	o, err := workbenchSetupOptions(&db.Workbench{ID: id, FolderPath: folder})
	if err != nil {
		return err
	}
	_, err = devpack.InstallWorkbench(ctx, o)
	cfg, cfgErr := config.Load(flagConfig)
	if cfgErr != nil {
		cfg = &config.Config{}
	}
	if devpack.CodexFound(cfg, codexFindBinary) {
		ctx, cancel := codexShutdownContext(ctx)
		defer cancel()
		_, codexErr := devpack.InstallCodex(ctx, o, codexAppServerFor(ctx, cfg, o))
		err = errors.Join(err, codexErr)
	}
	return err
}

func writeWorktreeEnvelope(ctx context.Context, cmd *cobra.Command, id int64, res workbenchgit.WorktreeResult) error {
	res.WorkbenchID = id
	env := worktreeEnvelope{WorktreeResult: res}
	if res.Created && res.Cwd != "" {
		if err := installWorktreeIntegration(ctx, id, res.Cwd); err != nil {
			env.IntegrationError = err.Error()
		}
	}
	if workbenchGitFlagJSON {
		return writeJSON(cmd.OutOrStdout(), env)
	}
	fmt.Fprintf(cmd.OutOrStdout(), "path: %s\nbranch: %s\ncreated: %t\n", res.Path, res.Branch, res.Created)
	if env.IntegrationError != "" {
		fmt.Fprintf(cmd.OutOrStdout(), "integration error: %s\n", env.IntegrationError)
	}
	return nil
}
