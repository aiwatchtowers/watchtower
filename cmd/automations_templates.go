package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/fsutil"
)

func init() {
	templates := newAutomationsSubcommand("templates", "List the template gallery", cobra.NoArgs, runAutomationsTemplates)
	install := newAutomationsSubcommand("install-template <name>",
		"Install a copy of a template, unconfirmed and disabled", cobra.ExactArgs(1), runAutomationsInstallTemplate)
	for _, c := range []*cobra.Command{templates, install} {
		c.Flags().BoolVar(&autoFlags.JSON, "json", false, "output as JSON")
	}
	install.Flags().Int64Var(&autoFlags.Workbench, "workbench", 0, "workbench id (required for a workbench template)")
	install.Flags().StringArrayVar(&autoFlags.Params, "param", nil, "KEY=VALUE for a template placeholder <KEY> (repeatable)")
	automationsCmd.AddCommand(templates, install)
}

// templateJSON is one `templates --json` entry: P3 Task 13's pinned keys
// (name … outputs) plus files and params.
type templateJSON struct {
	Name        string                      `json:"name"`
	Title       string                      `json:"title"`
	Description string                      `json:"description"`
	Scope       string                      `json:"scope"`
	TriggerText string                      `json:"trigger_text"`
	Permissions []string                    `json:"permissions"`
	Outputs     []string                    `json:"outputs"`
	Files       []string                    `json:"files"`
	Params      []automations.TemplateParam `json:"params"`
	Notes       []string                    `json:"notes"`
}

func runAutomationsTemplates(cmd *cobra.Command, _ []string) error {
	all := automations.Templates()
	out := make([]templateJSON, 0, len(all))
	for _, t := range all {
		out = append(out, templateJSON{
			Name: t.Name, Title: t.Title, Description: t.Description, Scope: string(t.Scope), TriggerText: t.TriggerText,
			Permissions: t.Permissions, Outputs: t.Outputs, Files: t.Files, Params: t.Params, Notes: t.Notes,
		})
	}
	w := cmd.OutOrStdout()
	if autoFlags.JSON {
		return writeJSON(w, out)
	}
	for _, t := range out {
		fmt.Fprintf(w, "%s — %s (%s, %s)\n  %s\n", t.Name, t.Title, t.Scope, t.TriggerText, t.Description)
		for _, p := range t.Params {
			optional := ""
			if p.HasDefault() {
				optional = " (optional: chosen from your data when left out; several values separated by commas)"
			}
			fmt.Fprintf(w, "  --param %s=…  %s, e.g. %s%s\n", p.Key, p.Label, p.Example, optional)
		}
		for _, n := range t.Notes {
			fmt.Fprintf(w, "  Note: %s\n", n)
		}
	}
	return nil
}

// installJSON is `install-template --json`: automation_id and path are the
// first installed recipe (the one P3's form opens), installed every file,
// notes the template's notes ([] when none), params each param's values as
// installed, given or chosen (#582; {} when none).
type installJSON struct {
	AutomationID int64                 `json:"automation_id"`
	Path         string                `json:"path"`
	Installed    []installedRecipeJSON `json:"installed"`
	Notes        []string              `json:"notes"`
	Params       map[string][]string   `json:"params"`
}

type installedRecipeJSON struct {
	AutomationID int64  `json:"automation_id"`
	Slug         string `json:"slug"`
	Path         string `json:"path"`
	ParseError   string `json:"parse_error"`
}

// runAutomationsInstallTemplate writes a template's recipes into the personal
// folder or the --workbench's folder and indexes them. Nothing is confirmed or
// enabled (an insert never sets either, AUTO-06), so it stays open under
// AI-agent markers like a plain save.
func runAutomationsInstallTemplate(cmd *cobra.Command, args []string) error {
	tpl, err := templateForInstall(args[0])
	if err != nil {
		return err
	}
	params, err := parseTemplateParams(autoFlags.Params)
	if err != nil {
		return err
	}
	cfg, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	if params, err = automations.FillTemplateParams(database, tpl.Name, params); err != nil {
		if errors.Is(err, automations.ErrNoActiveJiraProject) && !autoFlags.JSON {
			return fmt.Errorf("%w Connect Jira and let it sync, or pass --param PROJECT=<KEY>", err)
		}
		return err
	}
	files, err := automations.RenderTemplate(tpl.Name, params)
	if err != nil {
		return err
	}
	scope, dir, err := workbenchScope(database, autoFlags.Workbench)
	if err != nil {
		return err
	}
	if scope.Kind == automations.ScopePersonal {
		dir = automations.PersonalDir(cfg.WorkspaceDir())
	} else if err := automations.RefuseLinkedRecipeDir(dir); err != nil {
		return fmt.Errorf("not installed: %w", err)
	}
	out, err := installTemplateFiles(cmd.Context(), cfg, database, scope, dir, tpl.Files, files, cmd.ErrOrStderr())
	if err != nil {
		return err
	}
	out.Notes = tpl.Notes
	out.Params = make(map[string][]string, len(params))
	for key, value := range params {
		out.Params[key] = automations.TemplateParamValues(value)
	}
	return printInstalledTemplate(cmd.OutOrStdout(), out)
}

// templateForInstall finds the named template and checks --workbench against
// its scope.
func templateForInstall(name string) (automations.Template, error) {
	all := automations.Templates()
	i := slices.IndexFunc(all, func(t automations.Template) bool { return t.Name == name })
	if i < 0 {
		names := make([]string, 0, len(all))
		for _, t := range all {
			names = append(names, t.Name)
		}
		return automations.Template{}, fmt.Errorf("no template %q (have: %s)", name, strings.Join(names, ", "))
	}
	tpl := all[i]
	switch {
	case tpl.Scope == automations.ScopeWorkbench && autoFlags.Workbench == 0:
		return tpl, fmt.Errorf("%s is a workbench template: pass --workbench <id>", tpl.Name)
	case tpl.Scope == automations.ScopePersonal && autoFlags.Workbench != 0:
		return tpl, fmt.Errorf("%s is a personal template: it installs into the personal folder, without --workbench", tpl.Name)
	}
	return tpl, nil
}

// printInstalledTemplate writes the install result as JSON or text.
func printInstalledTemplate(w io.Writer, out installJSON) error {
	if autoFlags.JSON {
		return writeJSON(w, out)
	}
	for _, r := range out.Installed {
		fmt.Fprintf(w, "Installed %s as automation #%d (%s), off until you confirm and enable it.\n", r.Slug, r.AutomationID, r.Path)
		if r.ParseError != "" {
			fmt.Fprintf(w, "  fix before confirming: %s\n", r.ParseError)
		}
	}
	keys := slices.Sorted(maps.Keys(out.Params))
	for _, key := range keys {
		fmt.Fprintf(w, "%s: %s\n", key, strings.Join(out.Params[key], ", "))
	}
	for _, n := range out.Notes {
		fmt.Fprintf(w, "Note: %s\n", n)
	}
	return nil
}

// parseTemplateParams turns --param KEY=VALUE flags into a map; RenderTemplate
// checks keys and values.
func parseTemplateParams(flags []string) (map[string]string, error) {
	params := map[string]string{}
	for _, f := range flags {
		key, value, ok := strings.Cut(f, "=")
		if !ok || key == "" {
			return nil, fmt.Errorf("invalid --param %q: want KEY=VALUE", f)
		}
		if _, dup := params[key]; dup {
			return nil, fmt.Errorf("--param %s given twice", key)
		}
		params[key] = value
	}
	return params, nil
}

// writeTemplateFile and rescanTemplateFolder are swapped by tests to fail a
// write or the rescan.
var (
	writeTemplateFile    = fsutil.WriteFileAtomic
	rescanTemplateFolder = func(ctx context.Context, ix *automations.Indexer, scope automations.Scope, dir string) (automations.RescanReport, error) {
		return ix.RescanFolder(ctx, scope, dir)
	}
)

// installTemplateFiles refuses, before writing anything, a slug that already
// has a file in dir or an index row in scope (a removed one included); then
// writes every file atomically, rescans dir once and returns the rows. On any
// failure after the first write it removes the files this call wrote and
// their index rows (none existed before), so a retry is not refused by its
// own leftovers; what it cannot remove is reported on warn.
func installTemplateFiles(ctx context.Context, cfg *config.Config, database *db.DB, scope automations.Scope, dir string,
	slugs []string, files map[string][]byte, warn io.Writer) (installJSON, error) {
	for _, slug := range slugs {
		if err := checkTemplateSlugFree(database, scope, dir, slug); err != nil {
			return installJSON{}, err
		}
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return installJSON{}, fmt.Errorf("creating %s: %w", dir, err)
	}
	canon, err := automationsCanonicalDir(dir)
	if err != nil {
		return installJSON{}, fmt.Errorf("resolving %s: %w", dir, err)
	}
	var written []string
	for _, slug := range slugs {
		path := filepath.Join(canon, slug+".md")
		if err := writeTemplateFile(path, files[slug], 0o644); err != nil {
			rollBackTemplateInstall(database, scope, written, warn)
			return installJSON{}, fmt.Errorf("writing %s: %w", path, err)
		}
		written = append(written, path)
	}
	out, err := indexTemplateFiles(ctx, cfg, database, scope, canon, written)
	if err != nil {
		rollBackTemplateInstall(database, scope, written, warn)
		return installJSON{}, fmt.Errorf("not installed: %w", err)
	}
	return out, nil
}

// indexTemplateFiles rescans dir once and returns the index row of each
// written path, in order; a file the rescan did not index is an error.
func indexTemplateFiles(ctx context.Context, cfg *config.Config, database *db.DB, scope automations.Scope, dir string,
	written []string) (installJSON, error) {
	ix := automations.NewIndexer(database, cfg.WorkspaceDir(), automations.RealClock{})
	report, err := rescanTemplateFolder(ctx, ix, scope, dir)
	if err != nil {
		return installJSON{}, err
	}
	out := installJSON{Installed: make([]installedRecipeJSON, 0, len(written))}
	for _, path := range written {
		a, err := ix.RecipeInReport(scope, report, path)
		if err != nil {
			return installJSON{}, err
		}
		out.Installed = append(out.Installed, installedRecipeJSON{AutomationID: a.ID, Slug: recipeSlugOf(path), Path: a.Path, ParseError: a.ParseError})
	}
	out.AutomationID, out.Path = out.Installed[0].AutomationID, out.Installed[0].Path
	return out, nil
}

// rollBackTemplateInstall removes the files a failed install wrote and the
// index rows a rescan made for them (only rows at those paths).
func rollBackTemplateInstall(database *db.DB, scope automations.Scope, written []string, warn io.Writer) {
	for _, path := range written {
		if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
			fmt.Fprintf(warn, "warning: could not remove %s after the failed install: %v\n", path, err)
		}
		a, err := database.GetAutomationBySlug(string(scope.Kind), scope.WorkbenchID, recipeSlugOf(path))
		switch {
		case errors.Is(err, db.ErrAutomationNotFound):
		case err != nil:
			fmt.Fprintf(warn, "warning: could not check the index row of %s after the failed install: %v\n", path, err)
		case a.Path == path:
			if err := database.DeleteAutomation(a.ID); err != nil {
				fmt.Fprintf(warn, "warning: could not delete automation #%d (%s) after the failed install: %v\n", a.ID, path, err)
			}
		}
	}
}

// checkTemplateSlugFree refuses slug when dir holds any entry named
// <slug>.md or scope has an index row for it.
func checkTemplateSlugFree(database *db.DB, scope automations.Scope, dir, slug string) error {
	path := filepath.Join(dir, slug+".md")
	if _, err := os.Lstat(path); err == nil {
		return fmt.Errorf("not installed: %s already exists; rename or delete it first", path)
	} else if !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("checking %s: %w", path, err)
	}
	a, err := database.GetAutomationBySlug(string(scope.Kind), scope.WorkbenchID, slug)
	switch {
	case err == nil:
		return fmt.Errorf("not installed: automation #%d already uses the slug %s (%s); delete it first", a.ID, slug, a.Path)
	case !errors.Is(err, db.ErrAutomationNotFound):
		return err
	}
	return nil
}
