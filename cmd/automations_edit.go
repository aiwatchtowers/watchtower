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
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// recipeSlugOf is the slug a recipe file's name gives (its stem).
func recipeSlugOf(path string) string { return automations.RecipeSlugOf(path) }

// validateJSON is `validate --json` — the pinned key set of plan Task 12.
type validateJSON struct {
	OK           bool     `json:"ok"`
	Errors       []string `json:"errors"`
	Slug         string   `json:"slug"`
	Name         string   `json:"name"`
	Scope        string   `json:"scope"`
	ApprovalHash string   `json:"approval_hash"`
	ContentHash  string   `json:"content_hash"`
	Permissions  []string `json:"permissions"`
	Outputs      []string `json:"outputs"`
	Widening     []string `json:"widening"`
	// FeedsSourcesToLLM is Manifest.FeedsSourcesToLLM of the validated text
	// (#559): the Save sheet warns next to "Keep auto for <tool>".
	FeedsSourcesToLLM bool `json:"feeds_sources_to_llm"`
}

// validateRecipe parses data as the recipe slug in scope. A parse error is a
// result (ok:false), not an error. widening is what the normalised
// permissions add to baseline — every one of them for a recipe validated on
// its own (nil baseline).
func validateRecipe(slug string, data []byte, contentHash string, scope automations.Scope, baseline []string) validateJSON {
	v := validateJSON{Errors: []string{}, Slug: slug, Scope: scope.String(), ContentHash: contentHash,
		Permissions: []string{}, Outputs: []string{}, Widening: []string{}}
	r, err := automations.ParseRecipe(slug, data, scope)
	if err != nil {
		v.Errors = append(v.Errors, err.Error())
		return v
	}
	m, err := automations.ParseManifest(r.Permissions, r.Outputs, scope)
	if err != nil {
		v.Errors = append(v.Errors, err.Error())
		return v
	}
	v.OK, v.Name, v.ApprovalHash = true, r.Name, automations.ApprovalHash(r)
	v.Permissions = append(v.Permissions, m.Normalized()...)
	v.Outputs = append(v.Outputs, slices.Compact(slices.Sorted(slices.Values(r.Outputs)))...)
	v.Widening = automations.Covers(baseline, v.Permissions)
	v.FeedsSourcesToLLM = m.FeedsSourcesToLLM()
	return v
}

func runAutomationsValidate(cmd *cobra.Command, args []string) error {
	_, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	scope, baseline, err := validateScope(database)
	if err != nil {
		return err
	}
	data, contentHash, err := automations.ReadRecipeFile(args[0])
	if err != nil {
		return err
	}
	v := validateRecipe(recipeSlugOf(args[0]), data, contentHash, scope, baseline)
	w := cmd.OutOrStdout()
	if autoFlags.JSON {
		return writeJSON(w, v) // ok:false exits 0: the Desktop decodes it
	}
	if !v.OK {
		return fmt.Errorf("%s: %s", args[0], strings.Join(v.Errors, "; "))
	}
	fmt.Fprintf(w, "%s: ok — %s (%s), approval hash %s\n", args[0], v.Name, v.Scope, v.ApprovalHash)
	fmt.Fprintf(w, "  permissions: %v\n  outputs:     %v\n", v.Permissions, v.Outputs)
	return nil
}

// validateScope is the scope validate parses in and the permissions its
// widening starts from: with --against, that automation's scope and the
// permissions the owner last confirmed for it (automations.ConfirmedRecipe —
// never an unconfirmed hand edit's; none known → nil, so every permission
// widens, like draft_automation/save_automation); otherwise --workbench's
// scope (personal by default) and none.
func validateScope(database *db.DB) (automations.Scope, []string, error) {
	if autoFlags.Against == 0 {
		scope, _, err := workbenchScope(database, autoFlags.Workbench)
		return scope, nil, err
	}
	if autoFlags.Workbench != 0 {
		return automations.Scope{}, nil, errors.New("--against and --workbench are mutually exclusive: --against takes the automation's scope")
	}
	if autoFlags.Against < 0 {
		return automations.Scope{}, nil, fmt.Errorf("invalid --against %d: want a positive automation id", autoFlags.Against)
	}
	a, err := database.GetAutomation(autoFlags.Against)
	if err != nil {
		return automations.Scope{}, nil, err
	}
	confirmed, err := automations.ConfirmedRecipe(database, a)
	if err != nil {
		return automations.Scope{}, nil, fmt.Errorf("automation %d: reading its confirmed text: %w", a.ID, err)
	}
	if confirmed == nil {
		return automationScopeOf(a), nil, nil
	}
	m, err := automations.ParseManifest(confirmed.Permissions, confirmed.Outputs, confirmed.Scope)
	if err != nil { // ParseRecipe validated the manifest already
		return automations.Scope{}, nil, fmt.Errorf("automation %d confirmed manifest: %w", a.ID, err)
	}
	return automationScopeOf(a), m.Normalized(), nil
}

// rescanFolderJSON is one folder of `rescan --json`.
type rescanFolderJSON struct {
	Scope            string           `json:"scope"`
	Folder           string           `json:"folder"`
	Indexed          int              `json:"indexed"`
	Unchanged        int              `json:"unchanged"`
	Removed          int              `json:"removed"`
	Skipped          []rescanSkipJSON `json:"skipped"`
	NeedConfirmation []int64          `json:"need_confirmation"`
}

type rescanSkipJSON struct {
	Path   string `json:"path"`
	Reason string `json:"reason"`
}

func newRescanFolderJSON(scope automations.Scope, folder string, r automations.RescanReport) rescanFolderJSON {
	j := rescanFolderJSON{Scope: scope.String(), Folder: folder, Indexed: r.Indexed, Unchanged: r.Unchanged,
		Removed: r.Removed, Skipped: []rescanSkipJSON{}, NeedConfirmation: []int64{}}
	for _, s := range r.Skipped {
		j.Skipped = append(j.Skipped, rescanSkipJSON{Path: s.Path, Reason: s.Reason})
	}
	j.NeedConfirmation = append(j.NeedConfirmation, r.NeedConfirmation...)
	return j
}

// runAutomationsRescan indexes the personal folder and, with --workbench, that
// workbench's folder too (spec §10: the Desktop runs it for folders the
// daemon may not read).
func runAutomationsRescan(cmd *cobra.Command, _ []string) error {
	cfg, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	folders := []struct {
		scope automations.Scope
		dir   string
	}{{automations.Scope{Kind: automations.ScopePersonal}, automations.PersonalDir(cfg.WorkspaceDir())}}
	if autoFlags.Workbench != 0 {
		scope, dir, err := workbenchScope(database, autoFlags.Workbench)
		if err != nil {
			return err
		}
		folders = append(folders, struct {
			scope automations.Scope
			dir   string
		}{scope, dir})
	}
	ix := automations.NewIndexer(database, cfg.WorkspaceDir(), automations.RealClock{})
	out := make([]rescanFolderJSON, 0, len(folders))
	for _, f := range folders {
		r, err := ix.RescanFolder(cmd.Context(), f.scope, f.dir)
		if err != nil {
			return err
		}
		out = append(out, newRescanFolderJSON(f.scope, f.dir, r))
	}
	w := cmd.OutOrStdout()
	if autoFlags.JSON {
		return writeJSON(w, out)
	}
	for _, f := range out {
		fmt.Fprintf(w, "%s (%s): %d indexed, %d unchanged, %d removed\n", f.Scope, f.Folder, f.Indexed, f.Unchanged, f.Removed)
		for _, s := range f.Skipped {
			fmt.Fprintf(w, "  skipped %s: %s\n", s.Path, s.Reason)
		}
		if len(f.NeedConfirmation) > 0 {
			fmt.Fprintf(w, "  needs your confirmation: %v\n", f.NeedConfirmation)
		}
	}
	return nil
}

// ownerOnlyAutomationHint ends the refusal of `automations enable` and
// `automations delete` under an AI agent's markers (AGENT-07, ask #293).
const ownerOnlyAutomationHint = "enable and delete are owner-only"

// refuseOwnerOnlyAutomationVerb refuses an owner-only automations verb under
// any AGENT-07 marker, before anything is read or written (ask #293).
func refuseOwnerOnlyAutomationVerb(verb string) error {
	if err := refuseUnderAgent(verb); err != nil {
		return fmt.Errorf("%w; %s", err, ownerOnlyAutomationHint)
	}
	return nil
}

// runAutomationsEnable is owner-only (AGENT-07, ask #293): an agent must not
// switch on the schedule of a recipe it may have written. Disable stays open.
func runAutomationsEnable(cmd *cobra.Command, args []string) error {
	if err := refuseOwnerOnlyAutomationVerb("enable an automation"); err != nil {
		return err
	}
	return setAutomationsEnabled(cmd, args[0], true)
}

func runAutomationsDisable(cmd *cobra.Command, args []string) error {
	return setAutomationsEnabled(cmd, args[0], false)
}

func setAutomationsEnabled(cmd *cobra.Command, arg string, on bool) error {
	id, err := parseAutomationID("automation id", arg)
	if err != nil {
		return err
	}
	_, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	if err := database.SetAutomationEnabled(id, on, time.Now()); err != nil {
		return err
	}
	state := "disabled"
	if on {
		state = "enabled"
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Automation #%d %s.\n", id, state)
	return nil
}

// runAutomationsConfirm records the owner's confirmation of the recipe at
// --hash (spec §2.5 (c)). Refused under an AI agent's markers (AGENT-07): an
// agent must not confirm the manifest it may have written.
func runAutomationsConfirm(cmd *cobra.Command, args []string) error {
	if err := refuseUnderAgent("confirm an automation"); err != nil {
		return err
	}
	id, err := parseAutomationID("automation id", args[0])
	if err != nil {
		return err
	}
	if autoFlags.Hash == "" {
		return errors.New("--hash is required: the approval hash you reviewed (see `watchtower automations show`)")
	}
	_, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	if err := database.ConfirmAutomation(id, autoFlags.Hash, time.Now()); err != nil {
		if errors.Is(err, db.ErrHashMismatch) {
			return fmt.Errorf("%w — the recipe changed since you reviewed it; check it again with `watchtower automations show %d`", err, id)
		}
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Automation #%d confirmed.\n", id)
	return nil
}

// saveJSON is `save --json` — the pinned key set of plan Task 12.
type saveJSON struct {
	AutomationID int64  `json:"automation_id"`
	Path         string `json:"path"`
	ApprovalHash string `json:"approval_hash"`
	Confirmed    bool   `json:"confirmed"`
}

// saveTarget is where `save` writes: a <slug>.md in a recipe folder.
type saveTarget struct {
	scope     automations.Scope
	dir, path string
	slug      string
}

// resolveSaveTarget checks that target (--path, or the personal folder plus
// the --file's name) is <slug>.md in the personal folder or a known
// workbench's .watchtower/automations folder.
func resolveSaveTarget(cfg *config.Config, database *db.DB, file, target string) (saveTarget, error) {
	if target == "" {
		target = filepath.Join(automations.PersonalDir(cfg.WorkspaceDir()), filepath.Base(file))
	}
	slug := recipeSlugOf(target)
	if filepath.Ext(target) != ".md" || !automations.ValidSlug(slug) {
		return saveTarget{}, fmt.Errorf("cannot save to %s: a recipe file is named <slug>.md, slug matching ^[a-z0-9][a-z0-9-]{0,63}$ (pass --path)", target)
	}
	scope, dir, path, ok, err := recipeFolderOf(cfg, database, target)
	if err != nil {
		return saveTarget{}, err
	}
	if !ok {
		return saveTarget{}, fmt.Errorf("cannot save to %s: a recipe lives in the personal folder (%s) or a workbench's .watchtower/automations folder",
			target, automations.PersonalDir(cfg.WorkspaceDir()))
	}
	if scope.Kind == automations.ScopeWorkbench {
		w, err := database.GetWorkbench(scope.WorkbenchID)
		if err != nil {
			return saveTarget{}, err
		}
		if err := automations.RefuseLinkedRecipeDir(automations.WorkbenchDir(w.FolderPath)); err != nil {
			return saveTarget{}, fmt.Errorf("cannot save to %s: %w", target, err)
		}
	}
	return saveTarget{scope: scope, dir: dir, path: path, slug: slug}, nil
}

// runAutomationsSave writes --file's recipe atomically to its recipe folder
// (automations.Indexer.WriteRecipe — the one path P3's save_automation and P6's
// install-template reuse), indexes the folder and, with --confirm-hash,
// confirms it. --confirm-hash is refused under an AI agent's markers
// (AGENT-07) before anything is written, and a hash that is not the saved
// recipe's is refused before the write too.
func runAutomationsSave(cmd *cobra.Command, _ []string) error {
	if autoFlags.ConfirmHash != "" {
		if err := refuseUnderAgent("confirm an automation"); err != nil {
			return err
		}
	}
	if autoFlags.File == "" {
		return errors.New("--file is required: the recipe text to save")
	}
	cfg, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	data, _, err := automations.ReadRecipeFile(autoFlags.File)
	if err != nil {
		return err
	}
	t, err := resolveSaveTarget(cfg, database, autoFlags.File, autoFlags.Path)
	if err != nil {
		return err
	}
	if err := checkConfirmHash(t, data, autoFlags.ConfirmHash); err != nil {
		return err
	}
	if cmd.Flags().Changed(expectContentHashFlag) {
		if err := checkExpectedContentHash(t.path, autoFlags.ExpectContentHash); err != nil {
			return err
		}
	}
	a, err := writeAndIndexRecipe(cmd.Context(), cfg, database, t, data)
	if err != nil {
		return err
	}
	out := saveJSON{AutomationID: a.ID, Path: a.Path, ApprovalHash: a.ApprovalHash}
	if autoFlags.ConfirmHash != "" {
		if err := database.ConfirmAutomation(a.ID, autoFlags.ConfirmHash, time.Now()); err != nil {
			return fmt.Errorf("saved %s but not confirmed: %w", a.Path, err)
		}
		out.Confirmed = true
	}
	w := cmd.OutOrStdout()
	if autoFlags.JSON {
		return writeJSON(w, out)
	}
	fmt.Fprintf(w, "Saved %s as automation #%d (confirmed: %v).\n", out.Path, out.AutomationID, out.Confirmed)
	return nil
}

// checkConfirmHash refuses, before anything is written, a --confirm-hash
// that the recipe being saved would not carry.
func checkConfirmHash(t saveTarget, data []byte, hash string) error {
	if hash == "" {
		return nil
	}
	r, err := automations.ParseRecipe(t.slug, data, t.scope)
	if err != nil {
		return fmt.Errorf("not saved: cannot confirm a recipe that does not parse: %w", err)
	}
	if got := automations.ApprovalHash(r); got != hash {
		return fmt.Errorf("not saved: the recipe's approval hash is %s, not %s — review it again: %w", got, hash, db.ErrHashMismatch)
	}
	return nil
}

// expectContentHashFlag is save's --expect-content-hash: the content hash of
// the file the Desktop loaded ("" = it had no file), so a recipe changed on
// disk since is refused instead of overwritten.
const expectContentHashFlag = "expect-content-hash"

// checkExpectedContentHash refuses, before anything is written, a save over
// a target whose current content hash is not want ("" = the target must not
// exist; anything at the path, even a symlink, is a change).
func checkExpectedContentHash(path, want string) error {
	changed := fmt.Errorf("not saved: the recipe changed on disk since you opened it (%s) — reload it and review again", path)
	_, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		if want != "" {
			return changed
		}
		return nil
	}
	if err != nil {
		return fmt.Errorf("checking %s: %w", path, err)
	}
	if want == "" {
		return changed
	}
	_, got, err := automations.ReadRecipeFile(path)
	if err != nil {
		return fmt.Errorf("not saved: %w", err)
	}
	if got != want {
		return changed
	}
	return nil
}

// writeAndIndexRecipe writes data to t atomically, rescans t's folder and
// returns the file's index row; a file the indexer skipped is an error
// carrying its reason (automations.Indexer.WriteRecipe).
func writeAndIndexRecipe(ctx context.Context, cfg *config.Config, database *db.DB, t saveTarget, data []byte) (*db.Automation, error) {
	ix := automations.NewIndexer(database, cfg.WorkspaceDir(), automations.RealClock{})
	return ix.WriteRecipe(ctx, t.scope, t.dir, t.path, data)
}

// indexedRecipeAt rescans dir under scope and returns the index row of the
// recipe file at path (canonical), or an error naming why it is not indexed.
func indexedRecipeAt(ctx context.Context, cfg *config.Config, database *db.DB, scope automations.Scope, dir, path string) (*db.Automation, error) {
	ix := automations.NewIndexer(database, cfg.WorkspaceDir(), automations.RealClock{})
	return ix.IndexedRecipeAt(ctx, scope, dir, path)
}

// runAutomationsDelete removes an automation's index row — which cascades
// its runs, steps, state and outputs (spec §2.5, §10) — and then its recipe
// file (only a regular file in its own recipe folder). The row delete is one
// statement that holds only while no run is running or waiting (cancel the run
// first), and the file is removed only after it succeeded. P1 has no pending
// proposals or grants, so nothing else is withdrawn. Owner-only (AGENT-07,
// ask #293): refused under an agent's markers before anything is read.
func runAutomationsDelete(cmd *cobra.Command, args []string) error {
	if err := refuseOwnerOnlyAutomationVerb("delete an automation"); err != nil {
		return err
	}
	id, err := parseAutomationID("automation id", args[0])
	if err != nil {
		return err
	}
	cfg, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	a, err := database.GetAutomation(id)
	if err != nil {
		return err
	}
	removable, err := recipeFileRemovable(cfg, database, a)
	if err != nil {
		return err
	}
	if err := database.DeleteIdleAutomation(id); err != nil {
		if errors.Is(err, db.ErrAutomationActive) {
			return fmt.Errorf("%w — cancel it first (`watchtower automations cancel <run-id>`)", err)
		}
		return err
	}
	w := cmd.OutOrStdout()
	if !removable {
		fmt.Fprintf(w, "Deleted automation #%d; its recipe file was not removed (none, or not a regular file in its recipe folder: %s).\n", id, a.Path)
		return nil
	}
	if err := os.Remove(a.Path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("deleted automation %d, but not its recipe file (the next rescan indexes it again, unconfirmed): %w", id, err)
	}
	fmt.Fprintf(w, "Deleted automation #%d and %s.\n", id, a.Path)
	return nil
}

// recipeFileRemovable reports whether delete may remove a's recipe file: a
// regular file at a's path inside a's own recipe folder. Anything else — no
// file, a symlink or special file put in its place, a path no longer inside
// its recipe folder, a workbench that is gone — is left alone and the row is
// still deleted. Only a's own recipe folder is touched (never another
// workbench's: it may sit under a TCC-protected location).
func recipeFileRemovable(cfg *config.Config, database *db.DB, a *db.Automation) (bool, error) {
	folder, ok, err := scopeRecipeDir(cfg, database, automationScopeOf(a))
	if err != nil || !ok {
		return false, err
	}
	want, err := automationsCanonicalDir(folder)
	if err != nil {
		return false, fmt.Errorf("resolving %s: %w", folder, err)
	}
	dir, err := automationsCanonicalDir(filepath.Dir(a.Path))
	if err != nil {
		return false, fmt.Errorf("resolving %s: %w", a.Path, err)
	}
	if dir != want || filepath.Join(dir, filepath.Base(a.Path)) != a.Path {
		return false, nil
	}
	info, err := os.Lstat(a.Path)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("checking %s: %w", a.Path, err)
	}
	return info.Mode().IsRegular(), nil
}
