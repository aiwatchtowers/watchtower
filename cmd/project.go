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
	"watchtower/internal/projectdocs"
	"watchtower/internal/projectfiles"
	"watchtower/internal/tools"
)

var projectCmd = &cobra.Command{
	Use:   "project",
	Short: "Manage folder-bound projects (board, documents, comments)",
	Long: "A project binds a folder (e.g. a repository) to a board of targets, attached\n" +
		"documents and owner<->agent comments. Claude Code works on it through\n" +
		"`watchtower mcp --project N`, installed by `watchtower integrate claude-code --project N`.",
}

var projectCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a project bound to a folder",
	Long: "Binds --folder (symlinks resolved) to a new project. Refuses a missing directory\nor a folder already bound to a project. The name defaults to the folder's base name.\n" +
		"Then attaches the folder's README.md and its docs/**/specs and docs/**/plans files to\n" +
		"Documents (see `project import-docs`); an import failure is reported, the project stays.",
	RunE: runProjectCreate,
}

var projectListCmd = &cobra.Command{
	Use:   "list",
	Short: "List projects",
	RunE:  runProjectList,
}

var projectShowCmd = &cobra.Command{
	Use:   "show <id>",
	Short: "Show a project: folder, description, sources, documents, target counts",
	Args:  cobra.ExactArgs(1),
	RunE:  runProjectShow,
}

var projectBoardCmd = &cobra.Command{
	Use:   "board <id>",
	Short: "Print a project's target tree (status, priority; siblings by priority) with comment and document counters",
	Args:  cobra.ExactArgs(1),
	RunE:  runProjectBoard,
}

var projectImportDocsCmd = &cobra.Command{
	Use:   "import-docs <id>",
	Short: "Attach the folder's README, specs and plans to the project's Documents",
	Long: "Mechanical, no AI: attaches README.md at the folder root and every .md/.txt file\n" +
		"directly inside a specs or plans directory under docs/ (symlinks never followed),\n" +
		"at most 50 new ones per run, README first then newest. Additive and idempotent: an\n" +
		"already attached path is never touched.",
	Args: cobra.ExactArgs(1),
	RunE: runProjectImportDocs,
}

var projectAttachDocCmd = &cobra.Command{
	Use:   "attach-doc <id> <path>",
	Short: "Attach a .md/.txt file inside the project folder to Documents, as the owner's",
	Long: "The owner's counterpart of the agent's attach_document, with the same checks: the\n" +
		"path (absolute, or relative to the folder) must resolve — symlinks followed — to a\n" +
		"regular .md/.txt file inside the project folder. An already attached path is left\n" +
		"untouched and reported (created=false). Writes only the document row, never the file.",
	Args: cobra.ExactArgs(2),
	RunE: runProjectAttachDoc,
}

var projectDeleteCmd = &cobra.Command{
	Use:   "delete <id>",
	Short: "Delete a project, its board, documents and comments, and Watchtower's install in its folder",
	Long:  "Removes what `integrate claude-code --project N` installed in the folder first; a\nremoval failure is reported and the project is deleted anyway.",
	Args:  cobra.ExactArgs(1),
	RunE:  runProjectDelete,
}

var (
	projectFlagJSON         bool
	projectCreateFlagFolder string
	projectCreateFlagName   string
	projectImportFlagDryRun bool
	projectAttachFlagKind   string
	projectAttachFlagTitle  string
	projectAttachFlagTarget int64
)

// projectRemoveInstall undoes what `integrate claude-code --project N` put
// into the project's folder. integrate.go's init points it at
// removeProjectInstall (devpack.RemoveProject); a package var so tests can
// observe and fail it.
var projectRemoveInstall = func(context.Context, *config.Config, *db.Project) error { return nil }

func init() {
	projectCreateCmd.Flags().StringVar(&projectCreateFlagFolder, "folder", "", "project folder (required; symlinks are resolved)")
	projectCreateCmd.Flags().StringVar(&projectCreateFlagName, "name", "", "project name (default: the folder's base name)")
	projectImportDocsCmd.Flags().BoolVar(&projectImportFlagDryRun, "dry-run", false, "list what would be attached, write nothing")
	projectAttachDocCmd.Flags().StringVar(&projectAttachFlagKind, "kind", "doc", "spec | plan | doc")
	projectAttachDocCmd.Flags().StringVar(&projectAttachFlagTitle, "title", "", "display title (default: the file name)")
	projectAttachDocCmd.Flags().Int64Var(&projectAttachFlagTarget, "target", 0, "the project target the document belongs to")
	for _, c := range []*cobra.Command{projectCreateCmd, projectListCmd, projectShowCmd, projectBoardCmd, projectImportDocsCmd, projectAttachDocCmd, projectDeleteCmd} {
		c.Flags().BoolVar(&projectFlagJSON, "json", false, "output JSON")
	}
	projectCmd.AddCommand(projectCreateCmd, projectListCmd, projectShowCmd, projectBoardCmd, projectImportDocsCmd, projectAttachDocCmd, projectDeleteCmd)
	rootCmd.AddCommand(projectCmd)
}

type projectJSON struct {
	ID          int64  `json:"id"`
	Folder      string `json:"folder"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	CreatedAt   string `json:"created_at,omitempty"`
	UpdatedAt   string `json:"updated_at,omitempty"`
}

type projectSourceJSON struct {
	ID    int64  `json:"id"`
	Kind  string `json:"kind"`
	Ref   string `json:"ref"`
	Label string `json:"label"`
}

type projectDocumentJSON struct {
	ID        int64  `json:"id"`
	TargetID  *int64 `json:"target_id,omitempty"`
	RelPath   string `json:"rel_path"`
	Kind      string `json:"kind"`
	Title     string `json:"title"`
	UpdatedAt string `json:"updated_at"`
	Origin    string `json:"origin"` // agent | import | owner
}

type projectViewJSON struct {
	projectJSON
	Sources   []projectSourceJSON   `json:"sources"`
	Documents []projectDocumentJSON `json:"documents"`
	Counts    map[string]int        `json:"counts"` // targets per status
}

type boardNodeJSON struct {
	ID             int                   `json:"id"`
	Title          string                `json:"title"`
	Intent         string                `json:"intent"`
	Status         string                `json:"status"`
	StatusSince    string                `json:"status_since"` // when it entered its status (UTC); "" = unknown
	Priority       string                `json:"priority"`
	Progress       float64               `json:"progress"`
	Branch         string                `json:"branch"` // the git branch carrying the work; "" = none
	PR             string                `json:"pr"`     // the pull request, a number or URL; "" = none
	NewForAgent    int                   `json:"new_for_agent"`
	UnreadForOwner int                   `json:"unread_for_owner"`
	Documents      []projectDocumentJSON `json:"documents"`
	Children       []boardNodeJSON       `json:"children"`
}

func toProjectJSON(p db.Project) projectJSON {
	return projectJSON{ID: p.ID, Folder: p.FolderPath, Name: p.Name, Description: p.Description,
		CreatedAt: p.CreatedAt, UpdatedAt: p.UpdatedAt}
}

func nullableID(n sql.NullInt64) *int64 {
	if !n.Valid {
		return nil
	}
	v := n.Int64
	return &v
}

func toDocumentsJSON(docs []db.ProjectDocument) []projectDocumentJSON {
	out := make([]projectDocumentJSON, 0, len(docs))
	for _, d := range docs {
		out = append(out, projectDocumentJSON{ID: d.ID, TargetID: nullableID(d.TargetID), RelPath: d.RelPath,
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

func parseProjectID(arg string) (int64, error) {
	id, err := strconv.ParseInt(arg, 10, 64)
	if err != nil || id <= 0 {
		return 0, fmt.Errorf("invalid project id %q", arg)
	}
	return id, nil
}

// projectProtectedDirs lists Watchtower's own state directories, which a
// project folder may neither be, sit inside, nor contain: every workspace's
// data, the default config directory and the Desktop's Application Support.
func projectProtectedDirs() []string {
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

func runProjectCreate(cmd *cobra.Command, _ []string) error {
	if projectCreateFlagFolder == "" {
		return errors.New("--folder is required")
	}
	folder, err := db.ResolveProjectFolder(projectCreateFlagFolder, projectProtectedDirs())
	if err != nil {
		return err
	}
	name := projectCreateFlagName
	if strings.TrimSpace(name) == "" {
		name = filepath.Base(folder)
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	id, err := database.CreateProject(name, folder)
	if err != nil {
		return err
	}
	rep, ierr := projectdocs.Import(database, &db.Project{ID: id, Name: name, FolderPath: folder}, false)
	if ierr != nil {
		// On stderr in JSON mode too: a caller that decodes only the project
		// fields still leaves the warning in its log.
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: importing the folder's documents failed: %v (retry: watchtower project import-docs %d)\n", ierr, id)
	}
	if projectFlagJSON {
		return writeJSON(cmd.OutOrStdout(), newProjectCreateJSON(projectJSON{ID: id, Folder: folder, Name: name}, rep, ierr))
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Created project %d %q at %s\n", id, name, folder)
	if ierr != nil {
		return nil
	}
	printImportReport(cmd.OutOrStdout(), rep)
	return nil
}

// projectCreateJSON is `project create --json`'s envelope. The document
// import is best-effort, so it has its own ok/error fields (the recap_ok
// precedent): the project exists either way.
type projectCreateJSON struct {
	projectJSON
	DocsImportOK    bool                `json:"docs_import_ok"`
	DocsImportError string              `json:"docs_import_error"`
	DocsImport      *projectdocs.Report `json:"docs_import,omitempty"`
}

func newProjectCreateJSON(p projectJSON, rep projectdocs.Report, err error) projectCreateJSON {
	if err != nil {
		return projectCreateJSON{projectJSON: p, DocsImportError: err.Error()}
	}
	return projectCreateJSON{projectJSON: p, DocsImportOK: true, DocsImport: &rep}
}

func runProjectImportDocs(cmd *cobra.Command, args []string) error {
	id, err := parseProjectID(args[0])
	if err != nil {
		return err
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	p, err := database.GetProject(id)
	if err != nil {
		return err
	}
	rep, err := projectdocs.Import(database, p, projectImportFlagDryRun)
	if err != nil {
		return err
	}
	if projectFlagJSON {
		return writeJSON(cmd.OutOrStdout(), rep)
	}
	printImportReport(cmd.OutOrStdout(), rep)
	return nil
}

// projectAttachDocJSON is `project attach-doc --json`'s envelope.
type projectAttachDocJSON struct {
	DocumentID int64  `json:"document_id"`
	RelPath    string `json:"rel_path"`
	Created    bool   `json:"created"`
}

func runProjectAttachDoc(cmd *cobra.Command, args []string) error {
	id, err := parseProjectID(args[0])
	if err != nil {
		return err
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	p, err := database.GetProject(id)
	if err != nil {
		return err
	}
	rel, err := tools.ResolveProjectDocumentPath(p.FolderPath, args[1])
	if err != nil {
		return err
	}
	doc := db.ProjectDocument{ProjectID: id, RelPath: rel, Kind: projectAttachFlagKind, Title: strings.TrimSpace(projectAttachFlagTitle)}
	if doc.Title == "" {
		doc.Title = strings.TrimSuffix(filepath.Base(rel), filepath.Ext(rel))
	}
	if projectAttachFlagTarget != 0 {
		doc.TargetID = sql.NullInt64{Int64: projectAttachFlagTarget, Valid: true}
	}
	docID, rel, created, err := database.AttachOwnerProjectDocument(doc)
	if err != nil {
		return err
	}
	if projectFlagJSON {
		return writeJSON(cmd.OutOrStdout(), projectAttachDocJSON{DocumentID: docID, RelPath: rel, Created: created})
	}
	if created {
		fmt.Fprintf(cmd.OutOrStdout(), "Attached %s as document %d\n", rel, docID)
	} else {
		fmt.Fprintf(cmd.OutOrStdout(), "%s is already attached (document %d)\n", rel, docID)
	}
	return nil
}

func printImportReport(w io.Writer, rep projectdocs.Report) {
	verb := "Imported"
	if rep.DryRun {
		verb = "Would import"
	}
	fmt.Fprintf(w, "%s %d document(s); %d already attached.\n", verb, len(rep.Imported), len(rep.AlreadyAttached))
	for _, rel := range rep.Imported {
		fmt.Fprintf(w, "  + %s\n", rel)
	}
	if n := len(rep.SkippedOverCap); n > 0 {
		fmt.Fprintf(w, "Skipped %d over the %d-document cap (run import-docs again to add them):\n", n, projectdocs.MaxImport)
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

func runProjectList(cmd *cobra.Command, _ []string) error {
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	projects, err := database.ListProjects()
	if err != nil {
		return err
	}
	if projectFlagJSON {
		out := make([]projectJSON, 0, len(projects))
		for _, p := range projects {
			out = append(out, toProjectJSON(p))
		}
		return writeJSON(cmd.OutOrStdout(), out)
	}
	if len(projects) == 0 {
		fmt.Fprintln(cmd.OutOrStdout(), "No projects.")
	}
	for _, p := range projects {
		fmt.Fprintf(cmd.OutOrStdout(), "#%d  %s  %s\n", p.ID, p.Name, p.FolderPath)
	}
	return nil
}

func runProjectShow(cmd *cobra.Command, args []string) error {
	id, err := parseProjectID(args[0])
	if err != nil {
		return err
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	view, err := loadProjectView(database, id)
	if err != nil {
		return err
	}
	if projectFlagJSON {
		return writeJSON(cmd.OutOrStdout(), view)
	}
	printProjectView(cmd.OutOrStdout(), view)
	return nil
}

func loadProjectView(database *db.DB, id int64) (projectViewJSON, error) {
	p, err := database.GetProject(id)
	if err != nil {
		return projectViewJSON{}, err
	}
	sources, err := database.ListProjectSources(id)
	if err != nil {
		return projectViewJSON{}, err
	}
	docs, err := database.ListProjectDocuments(id)
	if err != nil {
		return projectViewJSON{}, err
	}
	board, err := database.GetProjectBoard(id)
	if err != nil {
		return projectViewJSON{}, err
	}
	view := projectViewJSON{projectJSON: toProjectJSON(*p), Sources: make([]projectSourceJSON, 0, len(sources)),
		Documents: toDocumentsJSON(docs), Counts: countBoardStatuses(board)}
	for _, s := range sources {
		view.Sources = append(view.Sources, projectSourceJSON{ID: s.ID, Kind: s.Kind, Ref: s.Ref, Label: s.Label})
	}
	return view, nil
}

func printProjectView(w io.Writer, v projectViewJSON) {
	fmt.Fprintf(w, "Project #%d %q\nFolder: %s\n", v.ID, v.Name, v.Folder)
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

func runProjectBoard(cmd *cobra.Command, args []string) error {
	id, err := parseProjectID(args[0])
	if err != nil {
		return err
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	if _, err := database.GetProject(id); err != nil {
		return err
	}
	board, err := database.GetProjectBoard(id)
	if err != nil {
		return err
	}
	if projectFlagJSON {
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

func runProjectDelete(cmd *cobra.Command, args []string) error {
	id, err := parseProjectID(args[0])
	if err != nil {
		return err
	}
	cfg, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	p, err := database.GetProject(id)
	if err != nil {
		return err
	}
	rerr := projectRemoveInstall(cmd.Context(), cfg, p)
	if rerr != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: removing Watchtower's install from %s failed: %v (the project is deleted anyway)\n",
			p.FolderPath, rerr)
	}
	if err := database.DeleteProject(id); err != nil {
		return err
	}
	// The rows are gone; the target images' stored copies go next (PROJ-02).
	// A failure leaves only files no row names — reported, never undoing the
	// delete.
	ferr := projectfiles.New(cfg.WorkspaceDir()).RemoveProject(id)
	if ferr != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: removing the project's stored images failed: %v (the project is deleted anyway)\n", ferr)
	}
	if projectFlagJSON {
		out := projectDeleteJSON{ID: id, Deleted: true, RemovalOK: rerr == nil, FilesOK: ferr == nil}
		if rerr != nil {
			out.RemovalError = rerr.Error()
		}
		if ferr != nil {
			out.FilesError = ferr.Error()
		}
		return writeJSON(cmd.OutOrStdout(), out)
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Deleted project %d %q.\n", id, p.Name)
	return nil
}

// discardTargetImages removes the stored copies of images (rows of a target
// already deleted) that no remaining row of project projectID names.
func discardTargetImages(cfg *config.Config, database *db.DB, projectID int64, images []db.ProjectTargetImage) error {
	if len(images) == 0 {
		return nil
	}
	keep, err := database.ProjectImagePaths(projectID)
	if err != nil {
		return err
	}
	paths := make([]string, 0, len(images))
	for _, img := range images {
		paths = append(paths, img.Path)
	}
	return projectfiles.New(cfg.WorkspaceDir()).Discard(paths, keep)
}

// projectDeleteJSON is `project delete --json`'s envelope; the Desktop
// decodes these exact keys (ProjectCLI.ProjectDeleted) to surface a failed folder or image cleanup.
type projectDeleteJSON struct {
	ID           int64  `json:"id"`
	Deleted      bool   `json:"deleted"`
	RemovalOK    bool   `json:"removal_ok"`
	RemovalError string `json:"removal_error"`
	FilesOK      bool   `json:"files_ok"` // the target images' stored copies were removed
	FilesError   string `json:"files_error"`
}
