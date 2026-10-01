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
	Use:   "resync <id>",
	Short: "Bring an existing project up to the current setup, adding only what is missing",
	Long: "Additive only: attaches the folder's documents that are not attached yet (the\n" +
		"`import-docs` rules) and re-installs the Claude Code integration — skill, hooks,\n" +
		"exclude lines where missing or out of date, and a fresh MCP registration (the\n" +
		"`integrate claude-code --project` rules: a skill you edited is left alone).\n" +
		"Never deletes or changes targets, their statuses, comments, attached documents,\n" +
		"sources or the description, and never creates targets: it prints suggestions for\n" +
		"you to take to the agent instead.\n" +
		"Each step runs even when another failed. Without --json a failed step exits\n" +
		"non-zero; --json always exits 0 once the project is found, its *_ok/*_error\n" +
		"fields say which step failed (the `project create --json` precedent).",
	Args: cobra.ExactArgs(1),
	RunE: runProjectResync,
}

func init() {
	projectResyncCmd.Flags().BoolVar(&projectFlagJSON, "json", false, "output JSON")
	projectCmd.AddCommand(projectResyncCmd)
}

// projectResyncJSON is `project resync --json`, read by the Desktop's
// Re-run Setup.
type projectResyncJSON struct {
	ID int64 `json:"id"`

	DocsOK    bool                `json:"docs_ok"`
	DocsError string              `json:"docs_error"`
	Docs      *projectdocs.Report `json:"docs,omitempty"`

	IntegrationOK    bool     `json:"integration_ok"`
	IntegrationError string   `json:"integration_error"`
	Skill            string   `json:"skill"` // a devpack state: installed, updated, unchanged, drifted, foreign; "" = not installed
	HooksAdded       bool     `json:"hooks_added"`
	Excluded         []string `json:"excluded"`
	MCPRegistered    bool     `json:"mcp_registered"`
	MCPCommand       string   `json:"mcp_command"` // the manual registration when MCPRegistered is false

	Suggestions      []string `json:"suggestions"`
	SuggestionsError string   `json:"suggestions_error"` // the suggestions may be incomplete

	install    devpack.ProjectInstallReport // for the text report
	installErr error
}

func (r projectResyncJSON) failed() bool {
	return !r.DocsOK || !r.IntegrationOK || r.SuggestionsError != ""
}

func runProjectResync(cmd *cobra.Command, args []string) error {
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
		return fmt.Errorf("project %d: %w", id, err)
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
// joins every failure (each also recorded in the result).
func resyncProject(ctx context.Context, database *db.DB, p *db.Project) (projectResyncJSON, error) {
	res := projectResyncJSON{ID: p.ID, Excluded: []string{}}
	var errs []error

	if rep, err := projectdocs.Import(database, p, false); err != nil {
		res.DocsError = err.Error()
		errs = append(errs, fmt.Errorf("attaching documents: %w", err))
	} else {
		res.DocsOK, res.Docs = true, &rep
	}

	if err := resyncIntegration(ctx, p, &res); err != nil {
		res.IntegrationError, res.installErr = err.Error(), err
		errs = append(errs, fmt.Errorf("installing the Claude Code integration: %w", err))
	} else {
		res.IntegrationOK = true
	}

	suggestions, err := resyncSuggestions(database, p, res.Docs)
	res.Suggestions = suggestions
	if err != nil {
		res.SuggestionsError = err.Error()
		errs = append(errs, fmt.Errorf("working out suggestions: %w", err))
	}
	return res, errors.Join(errs...)
}

func resyncIntegration(ctx context.Context, p *db.Project, res *projectResyncJSON) error {
	o, err := projectInstallOptions(p)
	if err != nil {
		return err
	}
	rep, err := devpack.InstallProject(ctx, o)
	res.install = rep
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
	outcome := "re-synced"
	if res.failed() {
		outcome = "re-synced with errors"
	}
	fmt.Fprintf(w, "Project %d (%s) %s:\n", p.ID, p.FolderPath, outcome)
	if res.DocsOK {
		fmt.Fprint(w, "Documents: ")
		printImportReport(w, *res.Docs)
	} else {
		fmt.Fprintf(w, "Documents: FAILED — %s (retry: watchtower project resync %d)\n", res.DocsError, p.ID)
	}
	fmt.Fprintln(w, "Claude Code integration:")
	if res.install.MCPCommand != "" { // set once the installer got past its folder checks
		printProjectInstallBody(w, res.install, res.installErr)
	}
	if !res.IntegrationOK {
		fmt.Fprintf(w, "  FAILED — %s\n", res.IntegrationError)
	}
	if len(res.Suggestions) > 0 || res.SuggestionsError != "" {
		fmt.Fprintln(w, "Suggestions:")
		for _, s := range res.Suggestions {
			fmt.Fprintf(w, "  - %s\n", s)
		}
		if res.SuggestionsError != "" {
			fmt.Fprintf(w, "  incomplete — %s\n", res.SuggestionsError)
		}
	}
}
