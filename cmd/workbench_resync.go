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
	"watchtower/internal/kb"
)

var workbenchResyncCmd = &cobra.Command{
	Use:   "resync <id>",
	Short: "Bring an existing workbench up to the current setup, adding only what is missing",
	Long: "Additive only: re-installs the Claude Code integration — skill, hooks, exclude\n" +
		"lines where missing or out of date, and a fresh MCP registration (the\n" +
		"`integrate claude-code --workbench` rules: a skill you edited is left alone), then\n" +
		"indexes the folder's .md/.markdown/.txt files for search from this workbench's\n" +
		"sessions (skipped when knowledge search is off).\n" +
		"Never deletes or changes targets, their statuses, comments, sources or the\n" +
		"description, and never creates targets: it prints suggestions for\n" +
		"you to take to the agent instead.\n" +
		"Each step runs even when another failed. Without --json a failed step exits\n" +
		"non-zero; --json always exits 0 once the workbench is found, its *_ok/*_error\n" +
		"fields say which step failed (the `workbench create --json` precedent).",
	Args: cobra.ExactArgs(1),
	RunE: runWorkbenchResync,
}

func init() {
	workbenchResyncCmd.Flags().BoolVar(&workbenchFlagJSON, "json", false, "output JSON")
	workbenchCmd.AddCommand(workbenchResyncCmd)
}

// workbenchResyncJSON is `workbench resync --json`, read by the Desktop's
// Re-run Setup. Keys keep their pre-rename spelling (spec 2026-10-02 A2);
// new ones are only added.
type workbenchResyncJSON struct {
	ID int64 `json:"id"`

	IntegrationOK    bool     `json:"integration_ok"`
	IntegrationError string   `json:"integration_error"`
	Skill            string   `json:"skill"` // a devpack state: installed, updated, unchanged, drifted, foreign; "" = not installed
	HooksAdded       bool     `json:"hooks_added"`
	Excluded         []string `json:"excluded"`
	MCPRegistered    bool     `json:"mcp_registered"`
	MCPCommand       string   `json:"mcp_command"` // the manual registration when MCPRegistered is false

	// The migration of a folder set up before the Workbench rename (spec
	// 2026-10-02 §5.4). LegacySkill is a devpack state: removed, drifted or
	// foreign (both kept), unchanged (the whole old setup was left because
	// the new MCP registration did not go in), "" = there was none.
	LegacySkill           string `json:"legacy_skill"`
	LegacyMCPRemoved      bool   `json:"legacy_mcp_removed"`
	LegacyHooksReplaced   bool   `json:"legacy_hooks_replaced"`
	LegacyPermissionRules int    `json:"legacy_permission_rules"`

	// The search index of the folder's text files (PROJ-08: searchable from
	// this workbench's sessions only). IndexSkipped: knowledge search is off.
	IndexOK      bool   `json:"index_ok"`
	IndexError   string `json:"index_error"`
	Indexed      int    `json:"indexed"` // this project's index entries written or removed
	IndexSkipped bool   `json:"index_skipped"`

	Suggestions      []string `json:"suggestions"`
	SuggestionsError string   `json:"suggestions_error"` // the suggestions may be incomplete

	install    devpack.WorkbenchInstallReport // for the text report
	installErr error
}

func (r workbenchResyncJSON) failed() bool {
	return !r.IntegrationOK || !r.IndexOK || r.SuggestionsError != ""
}

func runWorkbenchResync(cmd *cobra.Command, args []string) error {
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
		return fmt.Errorf("workbench %d: %w", id, err)
	}
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	res, stepErr := resyncWorkbench(ctx, database, p, cfg.Knowledge.Enabled)
	if workbenchFlagJSON {
		return writeJSON(cmd.OutOrStdout(), res)
	}
	printResyncReport(cmd.OutOrStdout(), p, res)
	return stepErr
}

// resyncWorkbench runs the folder install and the search index, and collects
// the suggestions; the error joins every failure (each also recorded in the
// result).
func resyncWorkbench(ctx context.Context, database *db.DB, p *db.Workbench, knowledgeEnabled bool) (workbenchResyncJSON, error) {
	res := workbenchResyncJSON{ID: p.ID, Excluded: []string{}}
	var errs []error

	if err := resyncIntegration(ctx, p, &res); err != nil {
		res.IntegrationError, res.installErr = err.Error(), err
		errs = append(errs, fmt.Errorf("installing the Claude Code integration: %w", err))
	} else {
		res.IntegrationOK = true
	}

	// The folder's files are searchable at once rather than after the daemon's
	// next knowledge cycle, which skips a privacy-protected folder entirely.
	if !knowledgeEnabled {
		res.IndexOK, res.IndexSkipped = true, true
	} else if _, changed, err := kb.IndexWorkbenchDocs(ctx, database, p.ID); err != nil {
		res.IndexError = err.Error()
		errs = append(errs, fmt.Errorf("indexing the folder for search: %w", err))
	} else {
		res.IndexOK, res.Indexed = true, changed
	}

	voc, toolsKnown := resyncVocabulary(res.install)
	suggestions, err := resyncSuggestions(database, p, voc, toolsKnown)
	if note := legacyPermissionNote(res.install); note != "" {
		suggestions = append(suggestions, note)
	}
	res.Suggestions = suggestions
	if err != nil {
		res.SuggestionsError = err.Error()
		errs = append(errs, fmt.Errorf("working out suggestions: %w", err))
	}
	return res, errors.Join(errs...)
}

func resyncIntegration(ctx context.Context, p *db.Workbench, res *workbenchResyncJSON) error {
	o, err := workbenchInstallOptions(p)
	if err != nil {
		return err
	}
	rep, err := devpack.InstallWorkbench(ctx, o)
	res.install = rep
	res.Skill = string(rep.Skill.State)
	res.HooksAdded = rep.HookChanged
	if rep.Excluded != nil {
		res.Excluded = rep.Excluded
	}
	res.MCPRegistered = rep.MCPRegistered
	res.LegacySkill = legacySkillState(rep.LegacySkill)
	res.LegacyMCPRemoved, res.LegacyHooksReplaced = rep.LegacyMCPRemoved, rep.LegacyHooksReplaced
	res.LegacyPermissionRules = rep.LegacyPermissionRules
	if !rep.MCPRegistered {
		res.MCPCommand = rep.MCPCommand
	}
	return err
}

// resyncVocabulary is the skill and tool names the folder's Claude Code
// session has after the install: the new ones once the new server is
// registered, the old ones when a pre-rename folder was left on its old
// setup (its registration did not go in). Otherwise no server of ours is
// known to serve the folder, so toolsKnown is false and the suggestions name
// no tool.
func resyncVocabulary(rep devpack.WorkbenchInstallReport) (voc vocabulary, toolsKnown bool) {
	switch {
	case rep.MCPRegistered:
		return workbenchVocabulary, true
	case rep.LegacySkill.State == devpack.StateUnchanged: // the old setup was kept
		return legacyWorkbenchVocabulary, true
	default:
		return workbenchVocabulary, false
	}
}

// resyncSuggestions names what the owner may want the agent to do next, in
// voc (toolsKnown false: without a tool name); resync itself never creates
// targets (the agent proposes, the owner agrees).
func resyncSuggestions(database *db.DB, p *db.Workbench, voc vocabulary, toolsKnown bool) ([]string, error) {
	out := []string{}
	if strings.TrimSpace(p.Description) == "" {
		out = append(out, "The workbench has no description yet: ask Claude Code to run the "+voc.SkillName+" skill's setup.")
	}
	sources, err := database.ListWorkbenchSources(p.ID)
	if err != nil {
		return out, fmt.Errorf("listing sources: %w", err)
	}
	if len(sources) == 0 {
		tool := ""
		if toolsKnown {
			tool = " (" + voc.SourceTool + ")"
		}
		out = append(out, "The workbench has no sources: ask Claude Code to add the Slack channels, Jira projects and Confluence spaces its docs name"+
			tool+" — search and the session brief then prefer them.")
	}
	// The full board: one whose targets are all archived is not empty.
	board, err := database.GetWorkbenchBoard(p.ID)
	if err != nil {
		return out, fmt.Errorf("reading the board: %w", err)
	}
	if len(board) == 0 {
		out = append(out, "The board is empty: ask Claude Code to propose a first board — it creates targets only after you agree.")
	}
	return out, nil
}

func printResyncReport(w io.Writer, p *db.Workbench, res workbenchResyncJSON) {
	outcome := "re-synced"
	if res.failed() {
		outcome = "re-synced with errors"
	}
	fmt.Fprintf(w, "Workbench %d (%s) %s:\n", p.ID, p.FolderPath, outcome)
	switch {
	case res.IndexSkipped:
		fmt.Fprintln(w, "Search index: skipped (knowledge search is off)")
	case res.IndexOK:
		fmt.Fprintf(w, "Search index: %d file(s) (re)indexed, searchable from this workbench's sessions\n", res.Indexed)
	default:
		fmt.Fprintf(w, "Search index: FAILED — %s (retry: watchtower workbench resync %d)\n", res.IndexError, p.ID)
	}
	fmt.Fprintln(w, "Claude Code integration:")
	if res.install.MCPCommand != "" { // set once the installer got past its folder checks
		printWorkbenchInstallBody(w, res.install, res.installErr)
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
