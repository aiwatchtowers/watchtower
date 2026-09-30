package cmd

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
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
	Long:  "Binds --folder (symlinks resolved) to a new project. Refuses a missing directory\nor a folder already bound to a project. The name defaults to the folder's base name.",
	RunE:  runProjectCreate,
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
	Short: "Print a project's target tree with comment and document counters",
	Args:  cobra.ExactArgs(1),
	RunE:  runProjectBoard,
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
)

// projectRemoveInstall undoes what `integrate claude-code --project N` put
// into the project's folder. A no-op until the install lands (Task 12 wires
// devpack.RemoveProject); a package var so tests can observe and fail it.
var projectRemoveInstall = func(context.Context, *config.Config, *db.Project) error { return nil }

func init() {
	projectCreateCmd.Flags().StringVar(&projectCreateFlagFolder, "folder", "", "project folder (required; symlinks are resolved)")
	projectCreateCmd.Flags().StringVar(&projectCreateFlagName, "name", "", "project name (default: the folder's base name)")
	for _, c := range []*cobra.Command{projectCreateCmd, projectListCmd, projectShowCmd, projectBoardCmd, projectDeleteCmd} {
		c.Flags().BoolVar(&projectFlagJSON, "json", false, "output JSON")
	}
	projectCmd.AddCommand(projectCreateCmd, projectListCmd, projectShowCmd, projectBoardCmd, projectDeleteCmd)
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
	Progress       float64               `json:"progress"`
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
			Kind: d.Kind, Title: d.Title, UpdatedAt: d.UpdatedAt})
	}
	return out
}

func toBoardJSON(nodes []db.BoardNode) []boardNodeJSON {
	out := make([]boardNodeJSON, 0, len(nodes))
	for _, n := range nodes {
		out = append(out, boardNodeJSON{ID: n.Target.ID, Title: n.Target.Text, Intent: n.Target.Intent,
			Status: n.Target.Status, Progress: n.Target.Progress, NewForAgent: n.NewForAgent,
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

func runProjectCreate(cmd *cobra.Command, _ []string) error {
	if projectCreateFlagFolder == "" {
		return errors.New("--folder is required")
	}
	folder, err := db.ResolveProjectFolder(projectCreateFlagFolder)
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
	if projectFlagJSON {
		return writeJSON(cmd.OutOrStdout(), projectJSON{ID: id, Folder: folder, Name: name})
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Created project %d %q at %s\n", id, name, folder)
	return nil
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
	fmt.Fprintf(w, "Targets: %d in progress, %d blocked, %d todo, %d done\n",
		v.Counts["in_progress"], v.Counts["blocked"], v.Counts["todo"], v.Counts["done"])
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
	printBoard(cmd.OutOrStdout(), board, 0)
	return nil
}

func printBoard(w io.Writer, nodes []db.BoardNode, depth int) {
	for _, n := range nodes {
		fmt.Fprintf(w, "%s#%d [%s] %s\n", strings.Repeat("  ", depth), n.Target.ID, n.Target.Status, n.Target.Text)
		printBoard(w, n.Children, depth+1)
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
	if projectFlagJSON {
		out := projectDeleteJSON{ID: id, Deleted: true, RemovalOK: rerr == nil}
		if rerr != nil {
			out.RemovalError = rerr.Error()
		}
		return writeJSON(cmd.OutOrStdout(), out)
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Deleted project %d %q.\n", id, p.Name)
	return nil
}

// projectDeleteJSON is `project delete --json`'s envelope; the Desktop
// decodes these exact keys to surface a failed folder cleanup.
type projectDeleteJSON struct {
	ID           int64  `json:"id"`
	Deleted      bool   `json:"deleted"`
	RemovalOK    bool   `json:"removal_ok"`
	RemovalError string `json:"removal_error"`
}
