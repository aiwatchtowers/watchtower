package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/fsutil"
	"watchtower/internal/kb"
	"watchtower/internal/sessionhost"
	"watchtower/internal/workbenchfolders"
)

// `workbench folder add|remove|locate|list` (multi-folder workbench, spec
// 2026-11-18 §5, §6.1, §6.3): the only writer of workbench_folders besides
// `workbench create`. The Desktop runs them; an agent never does (it
// suggests a folder through MCP instead), so the writes refuse an agent
// caller (checkFolderWriter).
var workbenchFolderCmd = &cobra.Command{
	Use:   "folder",
	Short: "Put folders on a workbench, take them off, re-point a moved one, list them",
}

var workbenchFolderAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Put a folder on the workbench (Put on the Bench…), then install Watchtower in it",
	Long: "Refuses a missing folder (not_found), one already on this bench (already_here), one\n" +
		"on another bench (other_bench) and one inside or containing a bench folder (nested).\n" +
		"The install runs after the folder is on the bench; a failed install keeps the folder.",
	Args: cobra.NoArgs,
	RunE: runWorkbenchFolderAdd,
}

var workbenchFolderRemoveCmd = &cobra.Command{
	Use:   "remove",
	Short: "Take a folder off the workbench and remove Watchtower's install from it; your files and git are not touched",
	Args:  cobra.NoArgs,
	RunE:  runWorkbenchFolderRemove,
}

var workbenchFolderLocateCmd = &cobra.Command{
	Use:   "locate",
	Short: "Re-point a moved or deleted folder of the workbench to its new path, then reinstall",
	Args:  cobra.NoArgs,
	RunE:  runWorkbenchFolderLocate,
}

var workbenchFolderListCmd = &cobra.Command{
	Use:   "list",
	Short: "List the workbench's folders in position order",
	Args:  cobra.NoArgs,
	RunE:  runWorkbenchFolderList,
}

var (
	folderFlagWorkbench   int64
	folderFlagFolder      string
	folderFlagTo          string
	folderFlagAddedBy     string
	folderFlagWithRemoved bool
	folderFlagJSON        bool
)

func init() {
	for _, c := range []*cobra.Command{workbenchFolderAddCmd, workbenchFolderRemoveCmd, workbenchFolderLocateCmd, workbenchFolderListCmd} {
		c.Flags().Int64Var(&folderFlagWorkbench, workbenchFlag, 0, "workbench id (required)")
		c.Flags().BoolVar(&folderFlagJSON, "json", false, "output JSON")
	}
	workbenchFolderAddCmd.Flags().StringVar(&folderFlagFolder, "folder", "", "the folder's path (required; symlinks are resolved)")
	workbenchFolderAddCmd.Flags().StringVar(&folderFlagAddedBy, "added-by", workbenchfolders.AddedByOwner,
		"who put it on the bench: owner, or agent_suggestion (the owner accepted an agent's suggestion)")
	for _, c := range []*cobra.Command{workbenchFolderRemoveCmd, workbenchFolderLocateCmd} {
		c.Flags().StringVar(&folderFlagFolder, "folder", "", "the folder: its id, name or path (required)")
	}
	workbenchFolderLocateCmd.Flags().StringVar(&folderFlagTo, "to", "", "the folder's new path (required)")
	workbenchFolderListCmd.Flags().BoolVar(&folderFlagWithRemoved, "with-removed", false, "also list the folders taken off the bench")
	workbenchFolderCmd.AddCommand(workbenchFolderAddCmd, workbenchFolderRemoveCmd, workbenchFolderLocateCmd, workbenchFolderListCmd)
	workbenchCmd.AddCommand(workbenchFolderCmd)
}

// folderJSON is one folder in every `workbench folder` result.
type folderJSON struct {
	ID        int64  `json:"id"`
	Path      string `json:"path"`
	Name      string `json:"name"`
	Position  int    `json:"position"`
	Home      bool   `json:"home"`      // it is projects.folder_path
	Installed bool   `json:"installed"` // Watchtower's hooks for this workbench are in it
	Removed   bool   `json:"removed"`   // taken off the bench
}

type folderBenchJSON struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// folderStepJSON is the install (add, locate) or uninstall (remove) that
// runs after the write: its failure never undoes the write.
type folderStepJSON struct {
	OK    bool   `json:"ok"`
	Error string `json:"error"`
}

// folderResultJSON is `workbench folder add|remove|locate --json`. A refusal
// is ok:false with its code (exit 0, the escalate precedent); error reads
// "<code>: <sentence>" (spec D42).
type folderResultJSON struct {
	OK         bool             `json:"ok"`
	ErrorCode  string           `json:"error_code"`
	Error      string           `json:"error"`
	Folder     *folderJSON      `json:"folder,omitempty"`
	OtherBench *folderBenchJSON `json:"other_bench,omitempty"`
	Install    *folderStepJSON  `json:"install,omitempty"`
}

// folderListJSON is `workbench folder list --json`; folders is never null.
type folderListJSON struct {
	Folders []folderJSON `json:"folders"`
}

// checkFolderWriter refuses a folder write under any agent marker, a
// terminal session's included: only the owner and the Desktop put folders on
// a bench or take them off (spec §7 Writers); an agent suggests one instead.
func checkFolderWriter() error {
	for _, name := range agentEnvMarkers {
		if os.Getenv(name) != "" {
			return usageError("refusing to change a workbench's folders under an AI agent (%s is set): only the owner and the Desktop do", name)
		}
	}
	return nil
}

// folderInstall installs Watchtower in folder p.FolderPath for workbench
// p.ID: the Claude Code part and, when codex is found or already set up
// there, the codex part (`workbench resync`'s steps, PROJ-04 rules). A var
// for tests.
var folderInstall = func(ctx context.Context, p *db.Workbench) error {
	var res workbenchResyncJSON
	return errors.Join(resyncIntegration(ctx, p, &res), resyncCodex(ctx, p, &res))
}

// folderLiveSessions counts the session host's live runs of the folder's
// session rows (advisory, workbenchfolders.Remove). No host answering on
// the socket means none run. A var for tests.
var folderLiveSessions = func(cfg *config.Config, database *db.DB) workbenchfolders.LiveSessions {
	return func(ctx context.Context, folderID int64) (int, error) {
		socket, err := sessionhost.DefaultSocket()
		if err != nil {
			return 0, err //nolint:wrapcheck // advisory: any error falls back to the database count
		}
		if _, err := os.Stat(socket); errors.Is(err, fs.ErrNotExist) {
			return 0, nil
		}
		c, err := sessionhost.Dial(ctx, socket)
		if err != nil {
			return 0, err //nolint:wrapcheck // advisory, as above
		}
		defer func() { _ = c.Close() }()
		list, err := c.List(ctx)
		if err != nil {
			return 0, err //nolint:wrapcheck // advisory, as above
		}
		f, err := database.WorkbenchFolderByID(ctx, folderID)
		if err != nil {
			return 0, err //nolint:wrapcheck // advisory, as above
		}
		home, err := database.HomeFolderID(ctx, f.WorkbenchID)
		if err != nil {
			return 0, err //nolint:wrapcheck // advisory, as above
		}
		rows, err := database.QueryContext(ctx, `SELECT id FROM terminal_sessions WHERE `+workbenchfolders.SessionRowsSQL+
			` AND `+db.NotDeletingSQL, workbenchfolders.SessionRowsArgs(*f, home == f.ID)...)
		if err != nil {
			return 0, err //nolint:wrapcheck // advisory, as above
		}
		defer rows.Close()
		ofFolder := map[int64]bool{}
		for rows.Next() {
			var id int64
			if err := rows.Scan(&id); err != nil {
				return 0, err //nolint:wrapcheck // advisory, as above
			}
			ofFolder[id] = true
		}
		if err := rows.Err(); err != nil {
			return 0, err //nolint:wrapcheck // advisory, as above
		}
		scope, n := sessionhost.Scope(cfg.DBPath()), 0
		for _, info := range list {
			if info.Scope == scope && !info.Exited && ofFolder[info.Row] {
				n++
			}
		}
		return n, nil
	}
}

// folderCmd is an open `workbench folder` verb: its config, database and
// bench, and done, which releases the folder lock (a write's) and closes
// the database.
type folderCmd struct {
	cfg      *config.Config
	database *db.DB
	p        *db.Workbench
	done     func()
}

// openFolderCmd checks the flags shared by every verb and opens the
// database. A write takes the folder lock first and only then reads the
// bench, so a write queued behind another sees what that one left (a
// moved home, a deleted bench). The bench must exist.
func openFolderCmd(ctx context.Context, write bool) (folderCmd, error) {
	if write {
		if err := checkFolderWriter(); err != nil {
			return folderCmd{}, err
		}
	}
	if folderFlagWorkbench <= 0 {
		return folderCmd{}, usageError("--%s takes a positive workbench id", workbenchFlag)
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return folderCmd{}, err
	}
	unlock := func() {}
	if write {
		if unlock, err = lockFolders(ctx, cfg); err != nil {
			_ = database.Close()
			return folderCmd{}, err
		}
	}
	done := func() {
		unlock()
		_ = database.Close()
	}
	p, err := database.GetWorkbench(folderFlagWorkbench)
	if err != nil {
		done()
		return folderCmd{}, err
	}
	return folderCmd{cfg: cfg, database: database, p: p, done: done}, nil
}

// folderLockWait runs just before a command waits for the folder lock; a
// seam for the tests that queue a command behind another.
var folderLockWait = func() {}

// lockFolders takes the workspace's folder-membership lock
// (workbenchfolders.LockPath): held from before a membership write's reads
// and transaction through its install or uninstall, so two changes of one
// folder never interleave their filesystem work across processes.
func lockFolders(ctx context.Context, cfg *config.Config) (func(), error) {
	folderLockWait()
	unlock, err := fsutil.LockFile(ctx, workbenchfolders.LockPath(cfg.WorkspaceDir()))
	if err != nil {
		return nil, fmt.Errorf("waiting for the workbench folders lock: %w", err)
	}
	return unlock, nil
}

func runWorkbenchFolderAdd(cmd *cobra.Command, _ []string) error {
	if strings.TrimSpace(folderFlagFolder) == "" {
		return usageError("--folder is required")
	}
	if err := workbenchfolders.CheckAddedBy(folderFlagAddedBy); err != nil {
		return folderFailed(cmd, folderCodeBadArgs, err)
	}
	ctx := cmdContext(cmd)
	fc, err := openFolderCmd(ctx, true)
	if err != nil {
		return err
	}
	defer fc.done()
	cfg, database, p := fc.cfg, fc.database, fc.p
	f, err := workbenchfolders.Add(ctx, database, p.ID, folderFlagFolder, folderFlagAddedBy, workbenchProtectedDirs())
	if err != nil {
		return folderRefused(cmd, database, err)
	}
	// After the commit (spec §6.1): the install, then the docs index.
	step := folderStep(folderInstall(ctx, folderBench(p, f)))
	if !step.OK {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: installing Watchtower in %s failed: %s (the folder stays on the bench; retry: watchtower workbench resync %d)\n",
			f.FolderPath, step.Error, p.ID)
	}
	indexWorkbenchDocs(cmd, cfg.Knowledge.Enabled, database, p.ID)
	return folderDone(cmd, database, f, step, fmt.Sprintf("Put %s on workbench %d as %s.", f.FolderPath, p.ID, f.Name))
}

func runWorkbenchFolderRemove(cmd *cobra.Command, _ []string) error {
	if strings.TrimSpace(folderFlagFolder) == "" {
		return usageError("--folder is required")
	}
	ctx := cmdContext(cmd)
	fc, err := openFolderCmd(ctx, true)
	if err != nil {
		return err
	}
	defer fc.done()
	cfg, database, p := fc.cfg, fc.database, fc.p
	f, err := workbenchfolders.Resolve(ctx, database, p.ID, folderFlagFolder)
	if err != nil {
		return folderRefused(cmd, database, err)
	}
	f, err = workbenchfolders.Remove(ctx, database, f.ID, folderLiveSessions(cfg, database))
	if err != nil {
		return folderRefused(cmd, database, err)
	}
	// After the commit (spec §6.3): Watchtower's install out of the folder
	// (PROJ-02 for that folder; files and git untouched, PROJ-24), then its
	// documents out of the index.
	rerr := workbenchRemoveInstall(ctx, cfg, folderBench(p, f))
	step := folderStep(rerr)
	if rerr != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: removing Watchtower's install from %s failed: %v (the folder is off the bench anyway)\n", f.FolderPath, rerr)
	}
	for _, h := range devpack.OutsideFolderHints(rerr) {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: %s\n", h)
	}
	// The index is keyed by folder (PROJ-08): the folder's entries go, the
	// other folders' stay. Done with knowledge search off too, so nothing of
	// the folder is left behind to show when it is turned back on.
	if _, err := kb.DropWorkbenchFolderDocs(ctx, database, p.ID, f.ID); err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: dropping %s's documents from search failed: %v (the next index pass drops them)\n", f.Name, err)
	}
	return folderDone(cmd, database, f, step, fmt.Sprintf("Removed %s from workbench %d.", f.Name, p.ID))
}

func runWorkbenchFolderLocate(cmd *cobra.Command, _ []string) error {
	if strings.TrimSpace(folderFlagFolder) == "" || strings.TrimSpace(folderFlagTo) == "" {
		return usageError("--folder and --to are required")
	}
	ctx := cmdContext(cmd)
	fc, err := openFolderCmd(ctx, true)
	if err != nil {
		return err
	}
	defer fc.done()
	cfg, database, p := fc.cfg, fc.database, fc.p
	f, err := workbenchfolders.Resolve(ctx, database, p.ID, folderFlagFolder)
	if err != nil {
		return folderRefused(cmd, database, err)
	}
	f, err = workbenchfolders.Locate(ctx, database, f.ID, folderFlagTo, workbenchProtectedDirs())
	if err != nil {
		return folderRefused(cmd, database, err)
	}
	step := folderStep(folderInstall(ctx, folderBench(p, f)))
	if !step.OK {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: installing Watchtower in %s failed: %s (retry: watchtower workbench resync %d)\n",
			f.FolderPath, step.Error, p.ID)
	}
	indexWorkbenchDocs(cmd, cfg.Knowledge.Enabled, database, p.ID)
	return folderDone(cmd, database, f, step, fmt.Sprintf("Workbench %d's folder %s is now at %s.", p.ID, f.Name, f.FolderPath))
}

func runWorkbenchFolderList(cmd *cobra.Command, _ []string) error {
	fc, err := openFolderCmd(cmdContext(cmd), false)
	if err != nil {
		return err
	}
	defer fc.done()
	database, p := fc.database, fc.p
	folders, err := database.WorkbenchFolders(cmdContext(cmd), p.ID, folderFlagWithRemoved)
	if err != nil {
		return err
	}
	out := folderListJSON{Folders: []folderJSON{}}
	for _, f := range folders {
		out.Folders = append(out.Folders, toFolderJSON(p, f))
	}
	if folderFlagJSON {
		return writeJSON(cmd.OutOrStdout(), out)
	}
	printFolderList(cmd.OutOrStdout(), out.Folders)
	return nil
}

func printFolderList(w io.Writer, folders []folderJSON) {
	for _, f := range folders {
		var marks []string
		if f.Home {
			marks = append(marks, "home")
		}
		if !f.Installed && !f.Removed {
			marks = append(marks, "not installed")
		}
		if f.Removed {
			marks = append(marks, "removed")
		}
		line := fmt.Sprintf("%d  %s  %s", f.ID, f.Name, f.Path)
		if len(marks) > 0 {
			line += "  (" + strings.Join(marks, ", ") + ")"
		}
		fmt.Fprintln(w, line)
	}
}

// folderBench is p bound to folder f: what the install, the uninstall and
// the status take (the workbench id with that folder).
func folderBench(p *db.Workbench, f db.WorkbenchFolder) *db.Workbench {
	in := *p
	in.FolderPath = f.FolderPath
	return &in
}

func folderStep(err error) *folderStepJSON {
	if err != nil {
		return &folderStepJSON{Error: err.Error()}
	}
	return &folderStepJSON{OK: true}
}

func toFolderJSON(p *db.Workbench, f db.WorkbenchFolder) folderJSON {
	removed := f.RemovedAt.Valid
	installed := false
	if !removed {
		installed, _ = devpack.HasCoreStateHooks(f.FolderPath, p.ID) // unreadable settings: not installed
	}
	return folderJSON{ID: f.ID, Path: f.FolderPath, Name: f.Name, Position: f.Position,
		Home: !removed && strings.EqualFold(p.FolderPath, f.FolderPath), Installed: installed, Removed: removed}
}

// folderDone prints a write's result. The workbench is re-read: a remove or
// locate may have moved its home folder.
func folderDone(cmd *cobra.Command, database *db.DB, f db.WorkbenchFolder, step *folderStepJSON, text string) error {
	p, err := database.GetWorkbench(f.WorkbenchID)
	if err != nil {
		return err
	}
	if folderFlagJSON {
		fj := toFolderJSON(p, f)
		return writeJSON(cmd.OutOrStdout(), folderResultJSON{OK: true, Folder: &fj, Install: step})
	}
	fmt.Fprintln(cmd.OutOrStdout(), text)
	return nil
}

// The CLI's own codes beside the package's refusals: a folder no workbench
// may have (root, home, Watchtower's own data), and a flag value the verb
// does not take.
const (
	folderCodeNotAllowed = "not_allowed"
	folderCodeBadArgs    = "bad_args"
)

// folderFailed reports err under code: with --json as an ok:false result
// (exit 0) whose error reads "<code>: <message>", otherwise as a usage error.
func folderFailed(cmd *cobra.Command, code string, err error) error {
	if !folderFlagJSON {
		return usageError("%s: %v", code, err)
	}
	return writeJSON(cmd.OutOrStdout(), folderResultJSON{ErrorCode: code, Error: code + ": " + err.Error()})
}

// folderRefused reports a refusal: with --json as an ok:false result (exit
// 0), otherwise as the command's error. A folder no workbench may have is
// reported the same way (not_allowed); any other error is returned as is.
func folderRefused(cmd *cobra.Command, database *db.DB, err error) error {
	if errors.Is(err, db.ErrWorkbenchFolderNotAllowed) {
		if !folderFlagJSON {
			return err
		}
		return folderFailed(cmd, folderCodeNotAllowed, err)
	}
	var r *workbenchfolders.Refusal
	if !errors.As(err, &r) {
		return err
	}
	if !folderFlagJSON {
		return r
	}
	out := folderResultJSON{ErrorCode: r.Code, Error: r.Error()}
	if r.Folder != nil {
		if p, gerr := database.GetWorkbench(r.Folder.WorkbenchID); gerr == nil {
			fj := toFolderJSON(p, *r.Folder)
			out.Folder = &fj
		}
	}
	if r.OtherBench != nil {
		out.OtherBench = &folderBenchJSON{ID: r.OtherBench.ID, Name: r.OtherBench.Name}
	}
	return writeJSON(cmd.OutOrStdout(), out)
}
