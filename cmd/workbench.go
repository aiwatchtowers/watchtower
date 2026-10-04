package cmd

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/kb"
	"watchtower/internal/tools"
	"watchtower/internal/workbenchfiles"
)

var workbenchCmd = &cobra.Command{
	Use: "workbench",
	// The pre-rename name keeps working for the Desktop builds and the
	// folders set up before the rename; cobra shows it only in this
	// command's own help, never in the root command list.
	Aliases: []string{"project"},
	Short:   "Manage workbenches: folder-bound boards (board, comments)",
	Long: "A workbench binds a folder (e.g. a repository) to a board of targets and\n" +
		"owner<->agent comments. Claude Code works on it through\n" +
		"`watchtower mcp --workbench N`, installed by `watchtower integrate claude-code --workbench N`.",
}

var workbenchCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a workbench bound to a folder",
	Long: "Binds --folder (symlinks resolved) to a new workbench. Refuses a missing directory\nor a folder already bound to a workbench. The name defaults to the folder's base name.\n" +
		"Then indexes the folder's .md/.markdown/.txt files for search from the workbench's\n" +
		"sessions (skipped when knowledge search is off; a failure is a warning, the workbench stays).",
	RunE: runWorkbenchCreate,
}

var workbenchListCmd = &cobra.Command{
	Use:   "list",
	Short: "List workbenches",
	RunE:  runWorkbenchList,
}

var workbenchShowCmd = &cobra.Command{
	Use:   "show <id>",
	Short: "Show a workbench: folder, description, archive setting, sources, target counts",
	Args:  cobra.ExactArgs(1),
	RunE:  runWorkbenchShow,
}

var workbenchBoardCmd = &cobra.Command{
	Use:   "board <id>",
	Short: "Print a workbench's target tree (status, priority; siblings by priority) with comment counters; archived targets only with --archived",
	Args:  cobra.ExactArgs(1),
	RunE:  runWorkbenchBoard,
}

var workbenchDeleteCmd = &cobra.Command{
	Use:   "delete <id>",
	Short: "Delete a workbench, its board and comments, and Watchtower's install in its folder",
	Long:  "Removes what `integrate claude-code --workbench N` installed in the folder first; a\nremoval failure is reported and the workbench is deleted anyway.",
	Args:  cobra.ExactArgs(1),
	RunE:  runWorkbenchDelete,
}

var (
	workbenchFlagJSON          bool
	workbenchCreateFlagFolder  string
	workbenchCreateFlagName    string
	workbenchBoardFlagArchived bool
)

// workbenchRemoveInstall undoes what `integrate claude-code --workbench N` put
// into the workbench's folder. integrate.go's init points it at
// removeWorkbenchInstall (devpack.RemoveWorkbench); a package var so tests can
// observe and fail it.
var workbenchRemoveInstall = func(context.Context, *config.Config, *db.Workbench) error { return nil }

func init() {
	workbenchCreateCmd.Flags().StringVar(&workbenchCreateFlagFolder, "folder", "", "workbench folder (required; symlinks are resolved)")
	workbenchCreateCmd.Flags().StringVar(&workbenchCreateFlagName, "name", "", "workbench name (default: the folder's base name)")
	for _, c := range []*cobra.Command{workbenchCreateCmd, workbenchListCmd, workbenchShowCmd, workbenchBoardCmd, workbenchDeleteCmd} {
		c.Flags().BoolVar(&workbenchFlagJSON, "json", false, "output JSON")
	}
	workbenchBoardCmd.Flags().BoolVar(&workbenchBoardFlagArchived, "archived", false, "also print archived targets (closed longer than the workbench's archive period)")
	workbenchCmd.AddCommand(workbenchCreateCmd, workbenchListCmd, workbenchShowCmd, workbenchBoardCmd, workbenchDeleteCmd)
	rootCmd.AddCommand(workbenchCmd)
}

type workbenchJSON struct {
	ID          int64  `json:"id"`
	Folder      string `json:"folder"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	CreatedAt   string `json:"created_at,omitempty"`
	UpdatedAt   string `json:"updated_at,omitempty"`
}

type workbenchSourceJSON struct {
	ID    int64  `json:"id"`
	Kind  string `json:"kind"`
	Ref   string `json:"ref"`
	Label string `json:"label"`
}

type workbenchViewJSON struct {
	workbenchJSON
	ArchiveAfterDays int                   `json:"archive_after_days"` // 0 = never (PROJ-15)
	Sources          []workbenchSourceJSON `json:"sources"`
	Counts           map[string]int        `json:"counts"` // targets per status, archived ones included
}

type boardNodeJSON struct {
	ID             int     `json:"id"`
	Title          string  `json:"title"`
	Intent         string  `json:"intent"`
	Status         string  `json:"status"`
	StatusSince    string  `json:"status_since"` // when it entered its status (UTC); "" = unknown
	Priority       string  `json:"priority"`
	Progress       float64 `json:"progress"`
	Branch         string  `json:"branch"` // the git branch carrying the work; "" = none
	PR             string  `json:"pr"`     // the pull request, a number or URL; "" = none
	NewForAgent    int     `json:"new_for_agent"`
	UnreadForOwner int     `json:"unread_for_owner"`
	Archived       bool    `json:"archived"` // listed with --archived only (PROJ-15)
	// ArchivedChildren counts the direct children left out as archived.
	ArchivedChildren int             `json:"archived_children"`
	Children         []boardNodeJSON `json:"children"`
}

func toWorkbenchJSON(p db.Workbench) workbenchJSON {
	return workbenchJSON{ID: p.ID, Folder: p.FolderPath, Name: p.Name, Description: p.Description,
		CreatedAt: p.CreatedAt, UpdatedAt: p.UpdatedAt}
}

func nullableID(n sql.NullInt64) *int64 {
	if !n.Valid {
		return nil
	}
	v := n.Int64
	return &v
}

func toBoardJSON(nodes []db.BoardNode) []boardNodeJSON {
	out := make([]boardNodeJSON, 0, len(nodes))
	for _, n := range nodes {
		out = append(out, boardNodeJSON{ID: n.Target.ID, Title: n.Target.Text, Intent: n.Target.Intent,
			Status: n.Target.Status, StatusSince: n.StatusSince, Priority: n.Target.Priority, Progress: n.Target.Progress,
			Branch: n.Target.Branch, PR: n.Target.PR, NewForAgent: n.NewForAgent,
			UnreadForOwner: n.UnreadForOwner, Archived: n.Archived, ArchivedChildren: n.ArchivedChildren,
			Children: toBoardJSON(n.Children)})
	}
	return out
}

// countBoardStatuses counts every target of the board by status.
func countBoardStatuses(nodes []db.BoardNode) map[string]int {
	counts := map[string]int{}
	var walk func([]db.BoardNode)
	walk = func(level []db.BoardNode) {
		for _, n := range level {
			counts[n.Target.Status]++
			walk(n.Children)
		}
	}
	walk(nodes)
	return counts
}

func parseWorkbenchID(arg string) (int64, error) {
	id, err := strconv.ParseInt(arg, 10, 64)
	if err != nil || id <= 0 {
		return 0, fmt.Errorf("invalid workbench id %q", arg)
	}
	return id, nil
}

// workbenchProtectedDirs lists Watchtower's own state directories, which a
// project folder may neither be, sit inside, nor contain: every workspace's
// data, the default config directory and the Desktop's Application Support.
func workbenchProtectedDirs() []string {
	var dirs []string
	if root, err := config.DataRoot(); err == nil {
		dirs = append(dirs, root)
	}
	if home, err := os.UserHomeDir(); err == nil {
		dirs = append(dirs, filepath.Join(home, ".config", "watchtower"),
			filepath.Join(home, "Library", "Application Support", "Watchtower"))
	}
	return dirs
}

func runWorkbenchCreate(cmd *cobra.Command, _ []string) error {
	if workbenchCreateFlagFolder == "" {
		return errors.New("--folder is required")
	}
	folder, err := db.ResolveWorkbenchFolder(workbenchCreateFlagFolder, workbenchProtectedDirs())
	if err != nil {
		return err
	}
	name := workbenchCreateFlagName
	if strings.TrimSpace(name) == "" {
		name = filepath.Base(folder)
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	id, err := database.CreateWorkbench(name, folder)
	if err != nil {
		return err
	}
	idx := indexWorkbenchDocs(cmd, cfg.Knowledge.Enabled, database, id)
	if workbenchFlagJSON {
		return writeJSON(cmd.OutOrStdout(), workbenchCreateJSON{workbenchJSON: workbenchJSON{ID: id, Folder: folder, Name: name}, workbenchIndexJSON: idx})
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Created workbench %d %q at %s\n", id, name, folder)
	return nil
}

// workbenchCreateJSON is `workbench create --json`'s envelope. The search
// index is best-effort, so it has its own ok/error fields (the recap_ok
// precedent): the workbench exists either way.
type workbenchCreateJSON struct {
	workbenchJSON
	workbenchIndexJSON
}

// indexWorkbenchDocs indexes the workbench folder's text files for search
// (PROJ-08) on `workbench create`, so they are searchable from the
// workbench's sessions at once. The daemon's knowledge phase never reads a
// folder under ~/Documents, ~/Desktop and the like, so for such a workbench
// this explicit trigger is the only one (the `workbench resync` precedent).
// Best-effort: the workbench exists, so a failure is never an error — it is a
// stderr warning (in JSON mode too) and the returned outcome, which create
// puts in its JSON (resync's index_* fields). Skipped when knowledge search
// is off.
func indexWorkbenchDocs(cmd *cobra.Command, knowledgeEnabled bool, database *db.DB, id int64) workbenchIndexJSON {
	if !knowledgeEnabled {
		return workbenchIndexJSON{IndexOK: true, IndexSkipped: true}
	}
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	if _, _, err := kb.IndexWorkbenchDocs(ctx, database, id); err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: indexing the workbench's documents for search failed: %v (retry: watchtower workbench resync %d)\n", err, id)
		return workbenchIndexJSON{IndexError: err.Error()}
	}
	return workbenchIndexJSON{IndexOK: true}
}

// workbenchIndexJSON is the search-index outcome in `create --json`, named as
// in `workbench resync --json`.
type workbenchIndexJSON struct {
	IndexOK      bool   `json:"index_ok"`
	IndexError   string `json:"index_error"`
	IndexSkipped bool   `json:"index_skipped"`
}

func runWorkbenchList(cmd *cobra.Command, _ []string) error {
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	workbenches, err := database.ListWorkbenches()
	if err != nil {
		return err
	}
	if workbenchFlagJSON {
		out := make([]workbenchJSON, 0, len(workbenches))
		for _, p := range workbenches {
			out = append(out, toWorkbenchJSON(p))
		}
		return writeJSON(cmd.OutOrStdout(), out)
	}
	if len(workbenches) == 0 {
		fmt.Fprintln(cmd.OutOrStdout(), "No workbenches.")
	}
	for _, p := range workbenches {
		fmt.Fprintf(cmd.OutOrStdout(), "#%d  %s  %s\n", p.ID, p.Name, p.FolderPath)
	}
	return nil
}

func runWorkbenchShow(cmd *cobra.Command, args []string) error {
	id, err := parseWorkbenchID(args[0])
	if err != nil {
		return err
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	view, err := loadWorkbenchView(database, id)
	if err != nil {
		return err
	}
	if workbenchFlagJSON {
		return writeJSON(cmd.OutOrStdout(), view)
	}
	printWorkbenchView(cmd.OutOrStdout(), view)
	return nil
}

func loadWorkbenchView(database *db.DB, id int64) (workbenchViewJSON, error) {
	p, err := database.GetWorkbench(id)
	if err != nil {
		return workbenchViewJSON{}, err
	}
	sources, err := database.ListWorkbenchSources(id)
	if err != nil {
		return workbenchViewJSON{}, err
	}
	board, err := database.GetWorkbenchBoard(id)
	if err != nil {
		return workbenchViewJSON{}, err
	}
	view := workbenchViewJSON{workbenchJSON: toWorkbenchJSON(*p), ArchiveAfterDays: p.ArchiveAfterDays,
		Sources: make([]workbenchSourceJSON, 0, len(sources)), Counts: countBoardStatuses(board)}
	for _, s := range sources {
		view.Sources = append(view.Sources, workbenchSourceJSON{ID: s.ID, Kind: s.Kind, Ref: s.Ref, Label: s.Label})
	}
	return view, nil
}

func printWorkbenchView(w io.Writer, v workbenchViewJSON) {
	fmt.Fprintf(w, "Workbench #%d %q\nFolder: %s\n", v.ID, v.Name, v.Folder)
	if v.Description != "" {
		fmt.Fprintf(w, "Description: %s\n", v.Description)
	}
	fmt.Fprintln(w, tools.BoardLanguageLine)
	fmt.Fprintf(w, "Archive after: %s\n", archiveAfterText(v.ArchiveAfterDays))
	fmt.Fprintf(w, "Targets: %d in progress, %d in review, %d blocked, %d todo, %d done\n",
		v.Counts["in_progress"], v.Counts["in_review"], v.Counts["blocked"], v.Counts["todo"], v.Counts["done"])
	for _, s := range v.Sources {
		fmt.Fprintf(w, "Source #%d %s %s %s\n", s.ID, s.Kind, s.Ref, s.Label)
	}
}

// archiveAfterText renders the archive setting: "14 days", or "never" for 0.
func archiveAfterText(days int) string {
	switch days {
	case 0:
		return "never"
	case 1:
		return "1 day"
	}
	return fmt.Sprintf("%d days", days)
}

func runWorkbenchBoard(cmd *cobra.Command, args []string) error {
	id, err := parseWorkbenchID(args[0])
	if err != nil {
		return err
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	if _, err := database.GetWorkbench(id); err != nil {
		return err
	}
	board, err := database.GetWorkbenchBoard(id)
	if err != nil {
		return err
	}
	archived := 0
	if !workbenchBoardFlagArchived {
		archived = db.CountArchived(board)
		board = db.WithoutArchived(board)
	}
	if workbenchFlagJSON {
		return writeJSON(cmd.OutOrStdout(), toBoardJSON(board))
	}
	printBoard(cmd.OutOrStdout(), board, 0, time.Now())
	printArchivedFooter(cmd.OutOrStdout(), archived)
	return nil
}

// printArchivedFooter says how many archived targets the text board left out,
// so a board whose roots are all archived does not read as empty (PROJ-15).
func printArchivedFooter(w io.Writer, archived int) {
	if archived > 0 {
		fmt.Fprintf(w, "(%d archived; --archived lists them)\n", archived)
	}
}

func printBoard(w io.Writer, nodes []db.BoardNode, depth int, now time.Time) {
	for _, n := range nodes {
		fmt.Fprintf(w, "%s#%d [%s, %s] %s%s%s\n", strings.Repeat("  ", depth), n.Target.ID,
			statusWithAge(n, now), n.Target.Priority, n.Target.Text, gitLinks(n.Target), archiveMarks(n))
		printBoard(w, n.Children, depth+1, now)
	}
}

// archiveMarks renders a board node's archive state (PROJ-15): " (archived)"
// for an archived target, " (+k archived)" for the archived children left out.
func archiveMarks(n db.BoardNode) string {
	out := ""
	if n.Archived {
		out += " (archived)"
	}
	if n.ArchivedChildren > 0 {
		out += fmt.Sprintf(" (+%d archived)", n.ArchivedChildren)
	}
	return out
}

// gitLinks renders a project target's branch and pull request, if any, as
// " (branch x, PR #12)".
func gitLinks(t db.Target) string {
	var parts []string
	if t.Branch != "" {
		parts = append(parts, "branch "+t.Branch)
	}
	if t.PR != "" {
		parts = append(parts, "PR "+t.PR)
	}
	if len(parts) == 0 {
		return ""
	}
	return " (" + strings.Join(parts, ", ") + ")"
}

// statusWithAge renders a board target's status with how long it has held
// it ("in_review 3h"), or the bare status when its history has no time.
func statusWithAge(n db.BoardNode, now time.Time) string {
	if age := statusAge(n.StatusSince, now); age != "" {
		return n.Target.Status + " " + age
	}
	return n.Target.Status
}

// statusAge is the time elapsed since the given UTC ISO-8601 time in its largest whole
// unit — "<1m", "12m", "5h", "3d" — or "" when since is empty or unparsable.
func statusAge(since string, now time.Time) string {
	at, err := time.Parse(time.RFC3339, since)
	if err != nil {
		return ""
	}
	d := now.Sub(at)
	switch {
	case d < time.Minute:
		return "<1m"
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d/time.Minute))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d/time.Hour))
	default:
		return fmt.Sprintf("%dd", int(d/(24*time.Hour)))
	}
}

func runWorkbenchDelete(cmd *cobra.Command, args []string) error {
	id, err := parseWorkbenchID(args[0])
	if err != nil {
		return err
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	p, err := database.GetWorkbench(id)
	if err != nil {
		return err
	}
	rerr := workbenchRemoveInstall(cmd.Context(), cfg, p)
	if rerr != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: removing Watchtower's install from %s failed: %v (the workbench is deleted anyway)\n",
			p.FolderPath, rerr)
	}
	if err := database.DeleteWorkbench(id); err != nil {
		return err
	}
	// The rows are gone; the target images' stored copies go next (PROJ-02).
	// A failure leaves only files no row names — reported, never undoing the
	// delete.
	ferr := workbenchfiles.New(cfg.WorkspaceDir()).RemoveWorkbench(id)
	if ferr != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: removing the workbench's stored images failed: %v (the workbench is deleted anyway)\n", ferr)
	}
	if workbenchFlagJSON {
		out := workbenchDeleteJSON{ID: id, Deleted: true, RemovalOK: rerr == nil, FilesOK: ferr == nil}
		if rerr != nil {
			out.RemovalError = rerr.Error()
		}
		if ferr != nil {
			out.FilesError = ferr.Error()
		}
		return writeJSON(cmd.OutOrStdout(), out)
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Deleted workbench %d %q.\n", id, p.Name)
	return nil
}

// discardTargetImages removes the stored copies of images (rows of a target
// already deleted) that no remaining row of project projectID names.
func discardTargetImages(cfg *config.Config, database *db.DB, projectID int64, images []db.WorkbenchTargetImage) error {
	if len(images) == 0 {
		return nil
	}
	keep, err := database.WorkbenchImagePaths(projectID)
	if err != nil {
		return err
	}
	paths := make([]string, 0, len(images))
	for _, img := range images {
		paths = append(paths, img.Path)
	}
	return workbenchfiles.New(cfg.WorkspaceDir()).Discard(paths, keep)
}

// workbenchDeleteJSON is `project delete --json`'s envelope; the Desktop
// decodes these exact keys (WorkbenchCLI.WorkbenchDeleted) to surface a failed folder or image cleanup.
type workbenchDeleteJSON struct {
	ID           int64  `json:"id"`
	Deleted      bool   `json:"deleted"`
	RemovalOK    bool   `json:"removal_ok"`
	RemovalError string `json:"removal_error"`
	FilesOK      bool   `json:"files_ok"` // the target images' stored copies were removed
	FilesError   string `json:"files_error"`
}
