package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/projectdocs"
)

var projectResyncCmd = &cobra.Command{
	Use:   "resync",
	Short: "Bring an existing project up to the current setup, adding only what is missing",
	Long: "Additive only: attaches the folder's documents that are not attached yet (the\n" +
		"`import-docs` rules) and re-installs the Claude Code integration — skill, hooks,\n" +
		"MCP registration, exclude lines — where it is missing or out of date (the\n" +
		"`integrate claude-code --project` rules: a skill you edited is left alone).\n" +
		"Never deletes or changes targets, their statuses, comments, attached documents,\n" +
		"sources or the description, and never creates targets: it prints suggestions for\n" +
		"you to take to the agent instead.\n" +
		"Each step runs even when the other failed. Without --json a failed step exits\n" +
		"non-zero; --json always exits 0 once the project is found, its *_ok fields say\n" +
		"which step failed (the `project create --json` precedent).",
	Args: cobra.NoArgs,
	RunE: runProjectResync,
}

var projectResyncFlagProject int64

func init() {
	projectResyncCmd.Flags().Int64Var(&projectResyncFlagProject, "project", 0, "project id (required)")
	projectResyncCmd.Flags().BoolVar(&projectFlagJSON, "json", false, "output JSON")
	projectCmd.AddCommand(projectResyncCmd)
}

// projectResyncJSON is `project resync --json`, read by the Desktop's
// Re-run setup.
type projectResyncJSON struct {
	ProjectID int64 `json:"project_id"`

	DocsOK    bool                `json:"docs_ok"`
	DocsError string              `json:"docs_error"`
	Docs      *projectdocs.Report `json:"docs,omitempty"`

	IntegrationOK    bool     `json:"integration_ok"`
	IntegrationError string   `json:"integration_error"`
	Skill            string   `json:"skill"` // a devpack state: installed, updated, unchanged, drifted, foreign
	HooksAdded       bool     `json:"hooks_added"`
	Excluded         []string `json:"excluded"`
	MCPRegistered    bool     `json:"mcp_registered"`
	MCPCommand       string   `json:"mcp_command"` // the manual registration when MCPRegistered is false

	Suggestions []string `json:"suggestions"`
}

func runProjectResync(cmd *cobra.Command, _ []string) error {
	if projectResyncFlagProject <= 0 {
		return errors.New("--project is required")
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	p, err := database.GetProject(projectResyncFlagProject)
	if err != nil {
		return fmt.Errorf("project %d: %w", projectResyncFlagProject, err)
	}
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	res, stepErr := resyncProject(ctx, database, p)
	if projectFlagJSON {
		return writeJSON(cmd.OutOrStdout(), res)
	}
	printResyncReport(cmd.OutOrStdout(), p, res)
	return stepErr
}

// resyncProject runs both steps and collects the suggestions; the error
// joins the steps' failures (already recorded in the result).
func resyncProject(ctx context.Context, database *db.DB, p *db.Project) (projectResyncJSON, error) {
	res := projectResyncJSON{ProjectID: p.ID, Excluded: []string{}}
	var errs []error

	if rep, err := projectdocs.Import(database, p, false); err != nil {
		res.DocsError = err.Error()
		errs = append(errs, fmt.Errorf("attaching documents: %w", err))
	} else {
		res.DocsOK, res.Docs = true, &rep
	}

	if err := resyncIntegration(ctx, p, &res); err != nil {
		res.IntegrationError = err.Error()
		errs = append(errs, fmt.Errorf("installing the Claude Code integration: %w", err))
	} else {
		res.IntegrationOK = true
	}

	suggestions, err := resyncSuggestions(database, p, res.Docs)
	if err != nil {
		errs = append(errs, err)
	}
	res.Suggestions = suggestions
	return res, errors.Join(errs...)
}

func resyncIntegration(ctx context.Context, p *db.Project, res *projectResyncJSON) error {
	o, err := projectInstallOptions(p)
	if err != nil {
		return err
	}
	rep, err := devpack.InstallProject(ctx, o)
	res.Skill = string(rep.Skill.State)
	res.HooksAdded = rep.HookChanged
	if rep.Excluded != nil {
		res.Excluded = rep.Excluded
	}
	res.MCPRegistered = rep.MCPRegistered
	if !rep.MCPRegistered {
		res.MCPCommand = rep.MCPCommand
	}
	return err
}

// resyncSuggestions names what the owner may want the agent to do next;
// resync itself never creates targets (the agent proposes, the owner agrees).
func resyncSuggestions(database *db.DB, p *db.Project, docs *projectdocs.Report) ([]string, error) {
	out := []string{}
	if strings.TrimSpace(p.Description) == "" {
		out = append(out, "The project has no description yet: ask Claude Code to run the watchtower-project skill's setup.")
	}
	sources, err := database.ListProjectSources(p.ID)
	if err != nil {
		return out, fmt.Errorf("listing sources: %w", err)
	}
	if len(sources) == 0 {
		out = append(out, "The project has no sources: ask Claude Code to add the Slack channels, Jira projects and Confluence spaces its docs name (add_project_source) — search and the session brief then prefer them.")
	}
	board, err := database.GetProjectBoard(p.ID)
	if err != nil {
		return out, fmt.Errorf("reading the board: %w", err)
	}
	switch {
	case len(board) == 0:
		out = append(out, "The board is empty: ask Claude Code to propose a first board — it creates targets only after you agree.")
	case docs != nil && len(docs.Imported) > 0:
		out = append(out, fmt.Sprintf("%d new document(s) were attached: ask Claude Code whether they hold open work the board is missing — it proposes targets, you decide.", len(docs.Imported)))
	}
	return out, nil
}

func printResyncReport(w io.Writer, p *db.Project, res projectResyncJSON) {
	fmt.Fprintf(w, "Project %d (%s) re-synced:\n", p.ID, p.FolderPath)
	if res.DocsOK {
		fmt.Fprint(w, "Documents: ")
		printImportReport(w, *res.Docs)
	} else {
		fmt.Fprintf(w, "Documents: FAILED — %s (retry: watchtower project import-docs %d)\n", res.DocsError, p.ID)
	}
	fmt.Fprintln(w, "Claude Code integration:")
	if res.Skill != "" {
		fmt.Fprintf(w, "  skill    %s%s\n", res.Skill, skillStateNote(devpack.State(res.Skill)))
	}
	hooks := "already present"
	if res.HooksAdded {
		hooks = "added"
	}
	fmt.Fprintf(w, "  hooks    %s\n", hooks)
	fmt.Fprintf(w, "  exclude  %d line(s) added\n", len(res.Excluded))
	if res.MCPRegistered {
		fmt.Fprintf(w, "  mcp      registered (%s, local scope)\n", devpack.ProjectMCPServerName)
	} else if res.MCPCommand != "" {
		fmt.Fprintf(w, "  mcp      NOT registered — run:\n    %s\n", res.MCPCommand)
	}
	if !res.IntegrationOK {
		fmt.Fprintf(w, "  FAILED — %s\n", res.IntegrationError)
	}
	if len(res.Suggestions) > 0 {
		fmt.Fprintln(w, "Suggestions:")
		for _, s := range res.Suggestions {
			fmt.Fprintf(w, "  - %s\n", s)
		}
	}
}
