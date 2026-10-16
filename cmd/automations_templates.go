package cmd

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
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
}

func runAutomationsTemplates(cmd *cobra.Command, _ []string) error {
	all := automations.Templates()
	out := make([]templateJSON, 0, len(all))
	for _, t := range all {
		out = append(out, templateJSON{
			Name: t.Name, Title: t.Title, Description: t.Description, Scope: string(t.Scope), TriggerText: t.TriggerText,
			Permissions: t.Permissions, Outputs: t.Outputs, Files: t.Files, Params: t.Params,
		})
	}
	w := cmd.OutOrStdout()
	if autoFlags.JSON {
		return writeJSON(w, out)
	}
	for _, t := range out {
		fmt.Fprintf(w, "%s — %s (%s, %s)\n  %s\n", t.Name, t.Title, t.Scope, t.TriggerText, t.Description)
		for _, p := range t.Params {
			fmt.Fprintf(w, "  --param %s=…  %s, e.g. %s\n", p.Key, p.Label, p.Example)
		}
	}
	return nil
}

// installJSON is `install-template --json`: automation_id and path are the
// first installed recipe (the one P3's form opens), installed every file.
type installJSON struct {
	AutomationID int64                 `json:"automation_id"`
	Path         string                `json:"path"`
	Installed    []installedRecipeJSON `json:"installed"`
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
	all := automations.Templates()
	i := slices.IndexFunc(all, func(t automations.Template) bool { return t.Name == args[0] })
	if i < 0 {
		names := make([]string, 0, len(all))
		for _, t := range all {
			names = append(names, t.Name)
		}
		return fmt.Errorf("no template %q (have: %s)", args[0], strings.Join(names, ", "))
	}
	tpl := all[i]
	switch {
	case tpl.Scope == automations.ScopeWorkbench && autoFlags.Workbench == 0:
		return fmt.Errorf("%s is a workbench template: pass --workbench <id>", tpl.Name)
	case tpl.Scope == automations.ScopePersonal && autoFlags.Workbench != 0:
		return fmt.Errorf("%s is a personal template: it installs into the personal folder, without --workbench", tpl.Name)
	}
	params, err := parseTemplateParams(autoFlags.Params)
	if err != nil {
		return err
	}
	files, err := automations.RenderTemplate(tpl.Name, params)
	if err != nil {
		return err
	}
	cfg, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	scope, dir, err := workbenchScope(database, autoFlags.Workbench)
	if err != nil {
		return err
	}
	if scope.Kind == automations.ScopePersonal {
		dir = automations.PersonalDir(cfg.WorkspaceDir())
	}
	out, err := installTemplateFiles(cmd.Context(), cfg, database, scope, dir, tpl.Files, files)
	if err != nil {
		return err
	}
	w := cmd.OutOrStdout()
	if autoFlags.JSON {
		return writeJSON(w, out)
	}
	for _, r := range out.Installed {
		fmt.Fprintf(w, "Installed %s as automation #%d (%s), off until you confirm and enable it.\n", r.Slug, r.AutomationID, r.Path)
		if r.ParseError != "" {
			fmt.Fprintf(w, "  fix before confirming: %s\n", r.ParseError)
		}
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

// installTemplateFiles refuses, before writing anything, a slug that already
// has a file in dir or an index row in scope (a removed one included); then
// writes every file atomically, rescans dir once and returns the rows.
func installTemplateFiles(ctx context.Context, cfg *config.Config, database *db.DB, scope automations.Scope, dir string,
	slugs []string, files map[string][]byte) (installJSON, error) {
	for _, slug := range slugs {
		if err := checkTemplateSlugFree(database, scope, dir, slug); err != nil {
			return installJSON{}, err
		}
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return installJSON{}, fmt.Errorf("creating %s: %w", dir, err)
	}
	for _, slug := range slugs {
		path := filepath.Join(dir, slug+".md")
		if err := fsutil.WriteFileAtomic(path, files[slug], 0o644); err != nil {
			return installJSON{}, fmt.Errorf("writing %s: %w", path, err)
		}
	}
	ix := automations.NewIndexer(database, cfg.WorkspaceDir(), automations.RealClock{})
	report, err := ix.RescanFolder(ctx, scope, dir)
	if err != nil {
		return installJSON{}, err
	}
	out := installJSON{Installed: make([]installedRecipeJSON, 0, len(slugs))}
	for _, slug := range slugs {
		for _, s := range report.Skipped {
			if filepath.Base(s.Path) == slug+".md" {
				return installJSON{}, fmt.Errorf("%s is not indexed: %s", s.Path, s.Reason)
			}
		}
		a, err := database.GetAutomationBySlug(string(scope.Kind), scope.WorkbenchID, slug)
		if err != nil {
			return installJSON{}, fmt.Errorf("%s.md is not indexed: %w", slug, err)
		}
		out.Installed = append(out.Installed, installedRecipeJSON{AutomationID: a.ID, Slug: slug, Path: a.Path, ParseError: a.ParseError})
	}
	out.AutomationID, out.Path = out.Installed[0].AutomationID, out.Installed[0].Path
	return out, nil
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
