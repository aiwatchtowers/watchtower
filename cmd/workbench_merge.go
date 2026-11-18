package cmd

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/agentkind"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/kb"
	"watchtower/internal/sessionhost"
	"watchtower/internal/sessionstart"
	"watchtower/internal/workbenchfiles"
	"watchtower/internal/workbenchfolders"
)

// `workbench merge --from B --into A` (multi-folder workbench, spec
// 2026-11-18 §6.13): the Desktop's Merge Benches…, offered when a folder put
// on bench A is on bench B. B's rows move to A in one transaction
// (workbenchfolders.Merge); after it the devpack is reinstalled with A's id
// in B's folders and its sessions' worktrees, the target images move to A's
// store and B's documents are re-indexed under A.
var workbenchMergeCmd = &cobra.Command{
	Use:   "merge",
	Short: "Merge a workbench into another: its board, asks, sessions and folders move, and it leaves the list",
	Long: "Refused (sessions_running) while an agent session of --from runs. The data moves in one\n" +
		"transaction; the reinstall in the moved folders follows it, and a failed reinstall keeps the data\n" +
		"where it moved (retry: watchtower workbench resync <into>).",
	Args: cobra.NoArgs,
	RunE: runWorkbenchMerge,
}

var workbenchSessionEnsureInstallCmd = &cobra.Command{
	Use:   "ensure-install",
	Short: "Reinstall Watchtower in a session's folder when it is installed for another (merged) workbench",
	Args:  cobra.NoArgs,
	RunE:  runWorkbenchSessionEnsureInstall,
}

var (
	mergeFlagFrom, mergeFlagInto int64
	mergeFlagJSON                bool
)

func init() {
	workbenchMergeCmd.Flags().Int64Var(&mergeFlagFrom, "from", 0, "the workbench that is merged and leaves the list (required)")
	workbenchMergeCmd.Flags().Int64Var(&mergeFlagInto, "into", 0, "the workbench it merges into (required)")
	workbenchMergeCmd.Flags().BoolVar(&mergeFlagJSON, "json", false, "output JSON")
	workbenchCmd.AddCommand(workbenchMergeCmd)
	workbenchSessionEnsureInstallCmd.Flags().Int64Var(&sessionFlagSession, "session", 0, "terminal session id")
	workbenchSessionEnsureInstallCmd.Flags().BoolVar(&sessionFlagJSON, "json", false, "output JSON")
	workbenchSessionCmd.AddCommand(workbenchSessionEnsureInstallCmd)
}

// mergeFailedJSON is one place whose reinstall failed.
type mergeFailedJSON struct {
	Path  string `json:"path"`
	Error string `json:"error"`
}

// mergeReinstallJSON is the reinstall after the merge; failed is never null.
type mergeReinstallJSON struct {
	OK     bool              `json:"ok"`
	Failed []mergeFailedJSON `json:"failed"`
}

// workbenchMergeJSON is `workbench merge --json`. A refusal is ok:false with
// its code (exit 0); error reads "<code>: <sentence>" (spec D42), running is
// sessions_running's count. moved_folders and failed are never null.
type workbenchMergeJSON struct {
	OK           bool               `json:"ok"`
	ErrorCode    string             `json:"error_code"`
	Error        string             `json:"error"`
	Running      int                `json:"running,omitempty"`
	MovedFolders []folderJSON       `json:"moved_folders"`
	Targets      int                `json:"targets"`
	Reinstall    mergeReinstallJSON `json:"reinstall"`
}

// mergeLiveSessions counts the session host's live runs of a workbench's
// agent rows (advisory, workbenchfolders.Merge). No host answering on the
// socket means none run. A var for tests.
var mergeLiveSessions = func(cfg *config.Config, database *db.DB) workbenchfolders.LiveBenchSessions {
	return func(ctx context.Context, workbenchID int64) (int, error) {
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
		rows, err := database.QueryContext(ctx, `SELECT id FROM terminal_sessions WHERE project_id = ? AND kind <> 'shell' AND `+
			db.NotDeletingSQL, workbenchID)
		if err != nil {
			return 0, err //nolint:wrapcheck // advisory, as above
		}
		defer rows.Close()
		ofBench := map[int64]bool{}
		for rows.Next() {
			var id int64
			if err := rows.Scan(&id); err != nil {
				return 0, err //nolint:wrapcheck // advisory, as above
			}
			ofBench[id] = true
		}
		if err := rows.Err(); err != nil {
			return 0, err //nolint:wrapcheck // advisory, as above
		}
		scope, n := sessionhost.Scope(cfg.DBPath()), 0
		for _, info := range list {
			if info.Scope == scope && !info.Exited && ofBench[info.Row] {
				n++
			}
		}
		return n, nil
	}
}

func runWorkbenchMerge(cmd *cobra.Command, _ []string) error {
	if err := checkFolderWriter(); err != nil {
		return err
	}
	if mergeFlagFrom <= 0 || mergeFlagInto <= 0 {
		return usageError("--from and --into take positive workbench ids")
	}
	ctx := cmdContext(cmd)
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	// The folder lock first, the benches read under it (openFolderCmd's
	// order): a membership change queued before this one has landed.
	unlock, err := lockFolders(ctx, cfg)
	if err != nil {
		return err
	}
	defer unlock()
	from, err := database.GetWorkbench(mergeFlagFrom)
	if err != nil {
		return mergeRefused(cmd, &workbenchfolders.Refusal{Code: workbenchfolders.CodeNotFound, Detail: err.Error()})
	}
	into, err := database.GetWorkbench(mergeFlagInto)
	if err != nil {
		return mergeRefused(cmd, &workbenchfolders.Refusal{Code: workbenchfolders.CodeNotFound, Detail: err.Error()})
	}
	rep, err := workbenchfolders.Merge(ctx, database, from.ID, into.ID, mergeLiveSessions(cfg, database))
	if err != nil {
		var r *workbenchfolders.Refusal
		if errors.As(err, &r) {
			return mergeRefused(cmd, r)
		}
		return err
	}
	// After the commit (spec §6.13): the data is whole in A whatever fails
	// from here on.
	out := workbenchMergeJSON{OK: true, MovedFolders: []folderJSON{}, Targets: rep.Targets,
		Reinstall: mergeReinstallJSON{OK: true, Failed: []mergeFailedJSON{}}}
	for _, path := range mergeReinstallPlaces(rep, from.ID) {
		if rerr := mergeReinstall(ctx, cfg, from, into, path); rerr != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "warning: reinstalling Watchtower in %s failed: %v (retry: watchtower workbench resync %d)\n",
				path, rerr, into.ID)
			out.Reinstall.OK = false
			out.Reinstall.Failed = append(out.Reinstall.Failed, mergeFailedJSON{Path: path, Error: rerr.Error()})
		}
	}
	if ierr := moveTargetImages(ctx, cfg, database, from.ID, into.ID); ierr != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: moving the target images of workbench %d failed: %v (they stay where they were and still show)\n",
			from.ID, ierr)
	}
	// F20: B's documents leave the index (done with knowledge search off
	// too, as a folder remove does), then A's folders are indexed.
	if _, derr := kb.DropWorkbenchDocs(ctx, database, from.ID); derr != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: dropping workbench %d's documents from search failed: %v\n", from.ID, derr)
	}
	indexWorkbenchDocs(cmd, cfg.Knowledge.Enabled, database, into.ID)
	if into, err = database.GetWorkbench(into.ID); err != nil {
		return err
	}
	for _, f := range rep.MovedFolders {
		out.MovedFolders = append(out.MovedFolders, toFolderJSON(into, f))
	}
	if mergeFlagJSON {
		return writeJSON(cmd.OutOrStdout(), out)
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Merged workbench %d %q into %d %q: %d targets and %d folders moved.\n",
		from.ID, from.Name, into.ID, into.Name, rep.Targets, len(rep.MovedFolders))
	return nil
}

// mergeReinstallPlaces is the merge's moved folders, and each other place
// (a worktree of a moved session) that still carries the merged bench's
// install: a place that never had it is none of the merge's business.
func mergeReinstallPlaces(rep workbenchfolders.MergeReport, from int64) []string {
	folders := map[string]bool{}
	for _, f := range rep.MovedFolders {
		folders[f.FolderPath] = true
	}
	var out []string
	for _, p := range rep.Reinstall {
		if folders[p] {
			out = append(out, p)
			continue
		}
		if ids, err := devpack.InstalledWorkbenchIDs(p); err == nil && slices.Contains(ids, from) {
			out = append(out, p)
		}
	}
	return out
}

// mergeReinstall replaces the merged bench's install in path with the
// surviving bench's (PROJ-04 rules: the owner's content stays).
func mergeReinstall(ctx context.Context, cfg *config.Config, from, into *db.Workbench, path string) error {
	return errors.Join(workbenchRemoveInstall(ctx, cfg, folderBench(from, db.WorkbenchFolder{FolderPath: path})),
		folderInstall(ctx, folderBench(into, db.WorkbenchFolder{FolderPath: path})))
}

// moveTargetImages moves the stored copies of the merged bench's target
// images into the surviving bench's store and re-points their rows, then
// removes the merged bench's store directory (PROJ-02: deleting the
// surviving bench later leaves nothing behind). Content-addressed: a copy
// the surviving bench already has is shared.
func moveTargetImages(ctx context.Context, cfg *config.Config, database *db.DB, from, into int64) error {
	store := workbenchfiles.New(cfg.WorkspaceDir())
	moving, err := storedImagesUnder(ctx, database, into, store.Dir(from)+string(filepath.Separator))
	if err != nil {
		return err
	}
	if len(moving) > 0 {
		if err := os.MkdirAll(store.Dir(into), 0o700); err != nil {
			return fmt.Errorf("creating %s: %w", store.Dir(into), err)
		}
	}
	for _, im := range moving {
		dst := filepath.Join(store.Dir(into), filepath.Base(im.path))
		if _, err := os.Stat(dst); errors.Is(err, fs.ErrNotExist) {
			if err := os.Rename(im.path, dst); err != nil {
				return fmt.Errorf("moving image %d: %w", im.id, err)
			}
		}
		if _, err := database.ExecContext(ctx, `UPDATE project_target_images SET path = ? WHERE id = ?`, dst, im.id); err != nil {
			return fmt.Errorf("re-pointing image %d: %w", im.id, err)
		}
	}
	return store.RemoveWorkbench(from) //nolint:wrapcheck // the store names the directory
}

// storedImage is one project_target_images row's id and stored copy.
type storedImage struct {
	id   int64
	path string
}

// storedImagesUnder is workbench wb's target images whose stored copy lies
// under dir (a path ending in the separator).
func storedImagesUnder(ctx context.Context, database *db.DB, wb int64, dir string) ([]storedImage, error) {
	rows, err := database.QueryContext(ctx, `SELECT id, path FROM project_target_images WHERE project_id = ?`, wb)
	if err != nil {
		return nil, fmt.Errorf("reading the target images: %w", err)
	}
	defer rows.Close()
	var out []storedImage
	for rows.Next() {
		var im storedImage
		if err := rows.Scan(&im.id, &im.path); err != nil {
			return nil, fmt.Errorf("reading the target images: %w", err)
		}
		if strings.HasPrefix(im.path, dir) {
			out = append(out, im)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading the target images: %w", err)
	}
	return out, nil
}

// mergeRefused reports a refusal: with --json as an ok:false result (exit
// 0), otherwise as the command's error.
func mergeRefused(cmd *cobra.Command, r *workbenchfolders.Refusal) error {
	if !mergeFlagJSON {
		return r
	}
	out := workbenchMergeJSON{ErrorCode: r.Code, Error: r.Error(), MovedFolders: []folderJSON{},
		Reinstall: mergeReinstallJSON{Failed: []mergeFailedJSON{}}}
	if r.Code == workbenchfolders.CodeSessionsRunning {
		out.Running, _ = strconv.Atoi(r.Detail)
	}
	return writeJSON(cmd.OutOrStdout(), out)
}

// sessionEnsureInstallJSON is `workbench session ensure-install --json`.
type sessionEnsureInstallJSON struct {
	OK          bool   `json:"ok"`
	Reinstalled bool   `json:"reinstalled"`
	Error       string `json:"error"`
}

// runWorkbenchSessionEnsureInstall is the launch backstop for the Desktop's
// own launches (resume, Start fresh; spec §6.13, D37):
// sessionstart.EnsureInstall in the row's folder. A failed reinstall is
// ok:false with its error; the Desktop launches anyway.
func runWorkbenchSessionEnsureInstall(cmd *cobra.Command, _ []string) error {
	if sessionFlagSession <= 0 {
		return usageError("--session: a positive terminal session id is required")
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	row, err := database.GetTerminalSession(sessionFlagSession)
	if err != nil {
		return err
	}
	out := sessionEnsureInstallJSON{OK: true}
	if row.WorkbenchID.Valid && row.Kind != "shell" {
		done, rerr := sessionstart.EnsureInstall(cmdContext(cmd), sessionStartDeps(cfg, database), row.ID, row.WorkbenchID.Int64,
			row.FolderPath, agentkind.Kind(row.Kind))
		out.Reinstalled = done
		if rerr != nil {
			out.OK, out.Error = false, rerr.Error()
		}
	}
	if sessionFlagJSON {
		return writeJSON(cmd.OutOrStdout(), out)
	}
	switch {
	case !out.OK:
		return fmt.Errorf("reinstalling Watchtower for session %d: %s", row.ID, out.Error)
	case out.Reinstalled:
		fmt.Fprintf(cmd.OutOrStdout(), "Reinstalled Watchtower for session %d.\n", row.ID)
	default:
		fmt.Fprintf(cmd.OutOrStdout(), "Session %d's folder is installed for its workbench.\n", row.ID)
	}
	return nil
}

// sessionReinstall is sessionstart.Deps.Reinstall: the install of each stale
// (gone) workbench out of dir, then the session's workbench's integration in
// (installIntegration on an existing place).
func sessionReinstall(cfg *config.Config) func(ctx context.Context, wb int64, dir string, agent agentkind.Kind, stale []int64) error {
	return func(ctx context.Context, wb int64, dir string, agent agentkind.Kind, stale []int64) error {
		var errs []error
		for _, id := range stale {
			errs = append(errs, workbenchRemoveInstall(ctx, cfg, &db.Workbench{ID: id, FolderPath: dir}))
		}
		return errors.Join(append(errs, installIntegration(ctx, wb, dir, agent, false))...)
	}
}
