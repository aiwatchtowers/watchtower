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
	"watchtower/internal/workbenchdocs"
	"watchtower/internal/workbenchfiles"
)

var workbenchCmd = &cobra.Command{
	Use: "workbench",
	// The pre-rename name keeps working for the Desktop builds and the
	// folders set up before the rename; cobra shows it only in this
	// command's own help, never in the root command list.
	Aliases: []string{"project"},
	Short:   "Manage workbenches: folder-bound boards (board, documents, comments)",
	Long: "A workbench binds a folder (e.g. a repository) to a board of targets, attached\n" +
		"documents and owner<->agent comments. Claude Code works on it through\n" +
		"`watchtower mcp --workbench N`, installed by `watchtower integrate claude-code --workbench N`.",
}

var workbenchCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a workbench bound to a folder",
	Long: "Binds --folder (symlinks resolved) to a new workbench. Refuses a missing directory\nor a folder already bound to a workbench. The name defaults to the folder's base name.\n" +
		"Then attaches the folder's README.md and its docs/**/specs and docs/**/plans files to\n" +
		"Documents (see `workbench import-docs`); an import failure is reported, the workbench stays.\n" +
		"The attached documents are then indexed for search from the workbench's sessions\n" +
		"(skipped when knowledge search is off; a failure is a warning).",
	RunE: runWorkbenchCreate,
}

var workbenchListCmd = &cobra.Command{
	Use:   "list",
	Short: "List workbenches",
	RunE:  runWorkbenchList,
}

var workbenchShowCmd = &cobra.Command{
	Use:   "show <id>",
	Short: "Show a workbench: folder, description, sources, documents, target counts",
	Args:  cobra.ExactArgs(1),
	RunE:  runWorkbenchShow,
}

var workbenchBoardCmd = &cobra.Command{
	Use:   "board <id>",
	Short: "Print a workbench's target tree (status, priority; siblings by priority) with comment and document counters",
	Args:  cobra.ExactArgs(1),
	RunE:  runWorkbenchBoard,
}

var workbenchImportDocsCmd = &cobra.Command{
	Use:   "import-docs <id>",
	Short: "Attach the folder's README, specs and plans to the workbench's Documents",
	Long: "Mechanical, no AI: attaches README.md at the folder root and every .md/.txt file\n" +
		"directly inside a specs or plans directory under docs/ (symlinks never followed),\n" +
		"at most 50 new ones per run, README first then newest. Additive and idempotent: an\n" +
		"already attached path is never touched. Then re-indexes the attached documents for\n" +
		"search from the workbench's sessions (not on a dry run; skipped when knowledge search\n" +
		"is off; a failure is a warning).",
	Args: cobra.ExactArgs(1),
	RunE: runWorkbenchImportDocs,
}

var workbenchAttachDocCmd = &cobra.Command{
	Use:   "attach-doc <id> <path>",
	Short: "Attach a .md/.txt file inside the workbench folder to Documents, as the owner's",
	Long: "The owner's counterpart of the agent's attach_document, with the same checks: the\n" +
		"path (absolute, or relative to the folder) must resolve — symlinks followed — to a\n" +
		"regular .md/.txt file inside the workbench folder. An already attached path is left\n" +
		"untouched and reported (created=false). Writes the document row and re-indexes the\n" +
		"workbench's documents for search (skipped when knowledge search is off; a failure is a\n" +
		"warning), never the file.",
	Args: cobra.ExactArgs(2),
	RunE: runWorkbenchAttachDoc,
}

var workbenchDeleteCmd = &cobra.Command{
	Use:   "delete <id>",
	Short: "Delete a workbench, its board, documents and comments, and Watchtower's install in its folder",
	Long:  "Removes what `integrate claude-code --workbench N` installed in the folder first; a\nremoval failure is reported and the workbench is deleted anyway.",
	Args:  cobra.ExactArgs(1),
	RunE:  runWorkbenchDelete,
}

var (
	workbenchFlagJSON         bool
	workbenchCreateFlagFolder string
	workbenchCreateFlagName   string
	workbenchImportFlagDryRun bool
	workbenchAttachFlagKind   string
	workbenchAttachFlagTitle  string
	workbenchAttachFlagTarget int64
)

// workbenchRemoveInstall undoes what `integrate claude-code --project N` put
// into the project's folder. integrate.go's init points it at
// removeWorkbenchInstall (devpack.RemoveWorkbench); a package var so tests can
// observe and fail it.
var workbenchRemoveInstall = func(context.Context, *config.Config, *db.Workbench) error { return nil }

func init() {
	workbenchCreateCmd.Flags().StringVar(&workbenchCreateFlagFolder, "folder", "", "workbench folder (required; symlinks are resolved)")
	workbenchCreateCmd.Flags().StringVar(&workbenchCreateFlagName, "name", "", "workbench name (default: the folder's base name)")
	workbenchImportDocsCmd.Flags().BoolVar(&workbenchImportFlagDryRun, "dry-run", false, "list what would be attached, write nothing")
	workbenchAttachDocCmd.Flags().StringVar(&workbenchAttachFlagKind, "kind", "doc", "spec | plan | doc")
	workbenchAttachDocCmd.Flags().StringVar(&workbenchAttachFlagTitle, "title", "", "display title (default: the file name)")
	workbenchAttachDocCmd.Flags().Int64Var(&workbenchAttachFlagTarget, "target", 0, "the workbench target the document belongs to")
	for _, c := range []*cobra.Command{workbenchCreateCmd, workbenchListCmd, workbenchShowCmd, workbenchBoardCmd, workbenchImportDocsCmd, workbenchAttachDocCmd, workbenchDeleteCmd} {
		c.Flags().BoolVar(&workbenchFlagJSON, "json", false, "output JSON")
	}
	workbenchCmd.AddCommand(workbenchCreateCmd, workbenchListCmd, workbenchShowCmd, workbenchBoardCmd, workbenchImportDocsCmd, workbenchAttachDocCmd, workbenchDeleteCmd)
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

type workbenchDocumentJSON struct {
	ID        int64  `json:"id"`
	TargetID  *int64 `json:"target_id,omitempty"`
	RelPath   string `json:"rel_path"`
	Kind      string `json:"kind"`
	Title     string `json:"title"`
	UpdatedAt string `json:"updated_at"`
	Origin    string `json:"origin"` // agent | import | owner
}

type workbenchViewJSON struct {
	workbenchJSON
	Sources   []workbenchSourceJSON   `json:"sources"`
	Documents []workbenchDocumentJSON `json:"documents"`
	Counts    map[string]int          `json:"counts"` // targets per status
}

type boardNodeJSON struct {
	ID             int                     `json:"id"`
	Title          string                  `json:"title"`
	Intent         string                  `json:"intent"`
	Status         string                  `json:"status"`
	StatusSince    string                  `json:"status_since"` // when it entered its status (UTC); "" = unknown
	Priority       string                  `json:"priority"`
	Progress       float64                 `json:"progress"`
	Branch         string                  `json:"branch"` // the git branch carrying the work; "" = none
	PR             string                  `json:"pr"`     // the pull request, a number or URL; "" = none
	NewForAgent    int                     `json:"new_for_agent"`
	UnreadForOwner int                     `json:"unread_for_owner"`
	Documents      []workbenchDocumentJSON `json:"documents"`
	Children       []boardNodeJSON         `json:"children"`
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

func toDocumentsJSON(docs []db.WorkbenchDocument) []workbenchDocumentJSON {
	out := make([]workbenchDocumentJSON, 0, len(docs))
	for _, d := range docs {
		out = append(out, workbenchDocumentJSON{ID: d.ID, TargetID: nullableID(d.TargetID), RelPath: d.RelPath,
			Kind: d.Kind, Title: d.Title, UpdatedAt: d.UpdatedAt, Origin: d.Origin})
	}
	return out
}

func toBoardJSON(nodes []db.BoardNode) []boardNodeJSON {
	out := make([]boardNodeJSON, 0, len(nodes))
	for _, n := range nodes {
		out = append(out, boardNodeJSON{ID: n.Target.ID, Title: n.Target.Text, Intent: n.Target.Intent,
			Status: n.Target.Status, StatusSince: n.StatusSince, Priority: n.Target.Priority, Progress: n.Target.Progress,
			Branch: n.Target.Branch, PR: n.Target.PR, NewForAgent: n.NewForAgent,
			UnreadForOwner: n.UnreadForOwner, Documents: toDocumentsJSON(n.Documents), Children: toBoardJSON(n.Children)})
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
	rep, ierr := workbenchdocs.Import(database, &db.Workbench{ID: id, Name: name, FolderPath: folder}, false)
	if ierr != nil {
		// On stderr in JSON mode too: a caller that decodes only the project
		// fields still leaves the warning in its log.
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: importing the folder's documents failed: %v (retry: watchtower workbench import-docs %d)\n", ierr, id)
	}
	idx := indexWorkbenchDocs(cmd, cfg.Knowledge.Enabled, database, id)
	if workbenchFlagJSON {
		return writeJSON(cmd.OutOrStdout(), newWorkbenchCreateJSON(workbenchJSON{ID: id, Folder: folder, Name: name}, rep, ierr, idx))
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Created workbench %d %q at %s\n", id, name, folder)
	if ierr != nil {
		return nil
	}
	printImportReport(cmd.OutOrStdout(), rep)
	return nil
}

// workbenchCreateJSON is `project create --json`'s envelope. The document
// import is best-effort, so it has its own ok/error fields (the recap_ok
// precedent): the project exists either way. So is the search index.
type workbenchCreateJSON struct {
	workbenchJSON
	DocsImportOK    bool                  `json:"docs_import_ok"`
	DocsImportError string                `json:"docs_import_error"`
	DocsImport      *workbenchdocs.Report `json:"docs_import,omitempty"`
	workbenchIndexJSON
}

func newWorkbenchCreateJSON(p workbenchJSON, rep workbenchdocs.Report, err error, idx workbenchIndexJSON) workbenchCreateJSON {
	if err != nil {
		return workbenchCreateJSON{workbenchJSON: p, DocsImportError: err.Error(), workbenchIndexJSON: idx}
	}
	return workbenchCreateJSON{workbenchJSON: p, DocsImportOK: true, DocsImport: &rep, workbenchIndexJSON: idx}
}

func runWorkbenchImportDocs(cmd *cobra.Command, args []string) error {
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
	rep, err := workbenchdocs.Import(database, p, workbenchImportFlagDryRun)
	if err != nil {
		return err
	}
	if !workbenchImportFlagDryRun {
		indexWorkbenchDocs(cmd, cfg.Knowledge.Enabled, database, id)
	}
	if workbenchFlagJSON {
		return writeJSON(cmd.OutOrStdout(), rep)
	}
	printImportReport(cmd.OutOrStdout(), rep)
	return nil
}

// workbenchAttachDocJSON is `project attach-doc --json`'s envelope.
type workbenchAttachDocJSON struct {
	DocumentID int64  `json:"document_id"`
	RelPath    string `json:"rel_path"`
	Created    bool   `json:"created"`
	workbenchIndexJSON
}

func runWorkbenchAttachDoc(cmd *cobra.Command, args []string) error {
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
	rel, err := tools.ResolveWorkbenchDocumentPath(p.FolderPath, args[1])
	if err != nil {
		return err
	}
	doc := db.WorkbenchDocument{WorkbenchID: id, RelPath: rel, Kind: workbenchAttachFlagKind, Title: strings.TrimSpace(workbenchAttachFlagTitle)}
	if doc.Title == "" {
		doc.Title = strings.TrimSuffix(filepath.Base(rel), filepath.Ext(rel))
	}
	if workbenchAttachFlagTarget != 0 {
		doc.TargetID = sql.NullInt64{Int64: workbenchAttachFlagTarget, Valid: true}
	}
	docID, rel, created, err := database.AttachOwnerWorkbenchDocument(doc)
	if err != nil {
		return err
	}
	idx := indexWorkbenchDocs(cmd, cfg.Knowledge.Enabled, database, id)
	if workbenchFlagJSON {
		return writeJSON(cmd.OutOrStdout(), workbenchAttachDocJSON{DocumentID: docID, RelPath: rel, Created: created, workbenchIndexJSON: idx})
	}
	if created {
		fmt.Fprintf(cmd.OutOrStdout(), "Attached %s as document %d\n", rel, docID)
	} else {
		fmt.Fprintf(cmd.OutOrStdout(), "%s is already attached (document %d)\n", rel, docID)
	}
	return nil
}

// indexWorkbenchDocs re-indexes the project's documents for search (PROJ-08)
// after an owner-side attach or import, so they are searchable from the
// project's sessions at once. The daemon's knowledge phase never reads a
// folder under ~/Documents, ~/Desktop and the like, so for such a project
// this explicit trigger is the only one (the `project resync` precedent).
// Best-effort: the documents are attached, so a failure is never an error —
// it is a stderr warning (in JSON mode too) and the returned outcome, which
// create and attach-doc put in their JSON (resync's index_* fields).
// Skipped when knowledge search is off.
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

// workbenchIndexJSON is the search-index outcome in `create --json` and
// `attach-doc --json`, named as in `project resync --json`.
type workbenchIndexJSON struct {
	IndexOK      bool   `json:"index_ok"`
	IndexError   string `json:"index_error"`
	IndexSkipped bool   `json:"index_skipped"`
}

func printImportReport(w io.Writer, rep workbenchdocs.Report) {
	verb := "Imported"
	if rep.DryRun {
		verb = "Would import"
	}
	fmt.Fprintf(w, "%s %d document(s); %d already attached.\n", verb, len(rep.Imported), len(rep.AlreadyAttached))
	for _, rel := range rep.Imported {
		fmt.Fprintf(w, "  + %s\n", rel)
	}
	if n := len(rep.SkippedOverCap); n > 0 {
		fmt.Fprintf(w, "Skipped %d over the %d-document cap (run import-docs again to add them):\n", n, workbenchdocs.MaxImport)
		for _, rel := range rep.SkippedOverCap {
			fmt.Fprintf(w, "  - %s\n", rel)
		}
	}
	if n := len(rep.Unreadable); n > 0 {
		fmt.Fprintf(w, "Skipped %d path(s) that could not be read:\n", n)
		for _, rel := range rep.Unreadable {
			fmt.Fprintf(w, "  ! %s\n", rel)
		}
	}
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
	docs, err := database.ListWorkbenchDocuments(id)
	if err != nil {
		return workbenchViewJSON{}, err
	}
	board, err := database.GetWorkbenchBoard(id)
	if err != nil {
		return workbenchViewJSON{}, err
	}
	view := workbenchViewJSON{workbenchJSON: toWorkbenchJSON(*p), Sources: make([]workbenchSourceJSON, 0, len(sources)),
		Documents: toDocumentsJSON(docs), Counts: countBoardStatuses(board)}
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
	fmt.Fprintf(w, "Targets: %d in progress, %d in review, %d blocked, %d todo, %d done\n",
		v.Counts["in_progress"], v.Counts["in_review"], v.Counts["blocked"], v.Counts["todo"], v.Counts["done"])
	for _, s := range v.Sources {
		fmt.Fprintf(w, "Source #%d %s %s %s\n", s.ID, s.Kind, s.Ref, s.Label)
	}
	for _, d := range v.Documents {
		fmt.Fprintf(w, "Document #%d [%s] %s %s\n", d.ID, d.Kind, d.RelPath, d.Title)
	}
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
	if workbenchFlagJSON {
		return writeJSON(cmd.OutOrStdout(), toBoardJSON(board))
	}
	printBoard(cmd.OutOrStdout(), board, 0, time.Now())
	return nil
}

func printBoard(w io.Writer, nodes []db.BoardNode, depth int, now time.Time) {
	for _, n := range nodes {
		fmt.Fprintf(w, "%s#%d [%s, %s] %s%s\n", strings.Repeat("  ", depth), n.Target.ID,
			statusWithAge(n, now), n.Target.Priority, n.Target.Text, gitLinks(n.Target))
		printBoard(w, n.Children, depth+1, now)
	}
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
// decodes these exact keys (ProjectCLI.ProjectDeleted) to surface a failed folder or image cleanup.
type workbenchDeleteJSON struct {
	ID           int64  `json:"id"`
	Deleted      bool   `json:"deleted"`
	RemovalOK    bool   `json:"removal_ok"`
	RemovalError string `json:"removal_error"`
	FilesOK      bool   `json:"files_ok"` // the target images' stored copies were removed
	FilesError   string `json:"files_error"`
}
