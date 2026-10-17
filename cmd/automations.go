package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// automationsFlags holds every flag of the automations subcommands. Tests
// reset it between runs (cobra keeps a flag's last value across Execute
// calls); a zero value means "not given" — except ExpectContentHash, where
// "" is a value and the flag's Changed state tells (tests reset it too).
type automationsFlags struct {
	JSON              bool
	Workbench         int64
	File              string
	Path              string
	Hash              string
	ConfirmHash       string
	ExpectContentHash string
	Against           int64
	RerunOf           int64
	Limit             int
	Kind              string
	Step              int64    // session-launched/-ended
	Session           int64    // session-launched
	Status            string   // session-ended
	Error             string   // session-ended
	Params            []string // install-template --param
}

var autoFlags automationsFlags

// defaultAutomationsListLimit is how many runs `runs` and outputs `outputs`
// show without --limit.
const defaultAutomationsListLimit = 20

var automationsCmd = &cobra.Command{
	Use:   "automations",
	Short: "Manage automations: recipes the daemon runs on a schedule or on demand",
}

func newAutomationsSubcommand(use, short string, args cobra.PositionalArgs, run func(*cobra.Command, []string) error) *cobra.Command {
	return &cobra.Command{Use: use, Short: short, Args: args, RunE: run}
}

func init() {
	rootCmd.AddCommand(automationsCmd)
	list := newAutomationsSubcommand("list", "List indexed automations", cobra.NoArgs, runAutomationsList)
	show := newAutomationsSubcommand("show <id|slug>", "Show one automation", cobra.ExactArgs(1), runAutomationsShow)
	validate := newAutomationsSubcommand("validate <file>", "Parse a recipe file without writing anything",
		cobra.ExactArgs(1), runAutomationsValidate)
	rescan := newAutomationsSubcommand("rescan", "Index the personal recipe folder (and one workbench's)",
		cobra.NoArgs, runAutomationsRescan)
	run := newAutomationsSubcommand("run <id>", "Queue a run for the daemon", cobra.ExactArgs(1), runAutomationsRun)
	dryRun := newAutomationsSubcommand("dry-run [<id>]", "Run a recipe here without committing anything",
		cobra.MaximumNArgs(1), runAutomationsDryRun)
	cancel := newAutomationsSubcommand("cancel <run-id>", "Cancel a queued or active run", cobra.ExactArgs(1),
		runAutomationsCancel)
	runs := newAutomationsSubcommand("runs <id>", "List an automation's runs", cobra.ExactArgs(1), runAutomationsRuns)
	steps := newAutomationsSubcommand("steps <run-id>", "List a run's steps", cobra.ExactArgs(1), runAutomationsSteps)
	enable := newAutomationsSubcommand("enable <id>", "Enable an automation (owner only)", cobra.ExactArgs(1), runAutomationsEnable)
	disable := newAutomationsSubcommand("disable <id>", "Disable an automation", cobra.ExactArgs(1),
		runAutomationsDisable)
	confirm := newAutomationsSubcommand("confirm <id>", "Confirm a recipe's permissions and script (owner only)",
		cobra.ExactArgs(1), runAutomationsConfirm)
	save := newAutomationsSubcommand("save", "Write a recipe file atomically and index it", cobra.NoArgs,
		runAutomationsSave)
	del := newAutomationsSubcommand("delete <id>", "Delete an automation, its recipe file and its history (owner only)",
		cobra.ExactArgs(1), runAutomationsDelete)
	outputs := newAutomationsSubcommand("outputs", "List automation outputs", cobra.NoArgs, runAutomationsOutputs)
	wake := newAutomationsSubcommand("wake", "Wake the daemon's automation scheduler and executor", cobra.NoArgs,
		runAutomationsWake)
	auto := newAutomationsSubcommand("auto <id|slug> <tool> on|off",
		"Turn a tool's auto grant on (owner only, at the current approval hash) or off", cobra.ExactArgs(3),
		runAutomationsAuto)

	for _, c := range []*cobra.Command{list, show, validate, rescan, run, dryRun, runs, steps, save, outputs, auto} {
		c.Flags().BoolVar(&autoFlags.JSON, "json", false, "output as JSON")
	}
	for _, c := range []*cobra.Command{list, show, validate, rescan, auto} {
		c.Flags().Int64Var(&autoFlags.Workbench, "workbench", 0, "workbench id (its .watchtower/automations folder)")
	}
	dryRun.Flags().StringVar(&autoFlags.File, "file", "", "a recipe file in a recipe folder (rescanned first)")
	save.Flags().StringVar(&autoFlags.File, "file", "", "the recipe text to write")
	save.Flags().StringVar(&autoFlags.Path, "path", "", "where to write it (default: the personal folder, the file's name)")
	save.Flags().StringVar(&autoFlags.ConfirmHash, "confirm-hash", "", "confirm the saved recipe at this approval hash (owner only)")
	save.Flags().StringVar(&autoFlags.ExpectContentHash, expectContentHashFlag, "",
		`refuse unless the target file's content hash is this ("" = the file must not exist)`)
	validate.Flags().Int64Var(&autoFlags.Against, "against", 0,
		"compare with this automation: its scope, widening from its current permissions")
	confirm.Flags().StringVar(&autoFlags.Hash, "hash", "", "the approval hash being confirmed (required)")
	auto.Flags().StringVar(&autoFlags.Hash, "hash", "", "the approval hash the grant binds to (required for on)")
	run.Flags().Int64Var(&autoFlags.RerunOf, "rerun-of", 0, "the run this one reruns")
	runs.Flags().IntVar(&autoFlags.Limit, "limit", 0, "how many runs (default 20)")
	outputs.Flags().IntVar(&autoFlags.Limit, "limit", 0, "how many outputs (default 20)")
	outputs.Flags().StringVar(&autoFlags.Kind, "kind", "", "only outputs of this kind (inbox, briefing, report)")
	automationsCmd.AddCommand(list, show, validate, rescan, run, dryRun, cancel, runs, steps, enable, disable,
		confirm, save, del, outputs, wake, auto)
}

// openAutomationsCmd loads the config and opens the database with the
// owner-write busy timeout (a confirm or save must wait out the daemon's
// write lock, not fail).
func openAutomationsCmd() (*config.Config, *db.DB, error) {
	cfg, err := loadAutomationsConfig()
	if err != nil {
		return nil, nil, err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, nil, fmt.Errorf("opening database: %w", err)
	}
	if err := database.SetBusyTimeout(ownerWriteBusyTimeout); err != nil {
		database.Close()
		return nil, nil, err
	}
	return cfg, database, nil
}

// loadAutomationsConfig loads the config with the --workspace and provider
// overrides applied and the workspace validated.
func loadAutomationsConfig() (*config.Config, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, err
	}
	return cfg, nil
}

// parseAutomationID parses a positive automation or run id.
func parseAutomationID(what, arg string) (int64, error) {
	id, err := strconv.ParseInt(arg, 10, 64)
	if err != nil || id <= 0 {
		return 0, fmt.Errorf("invalid %s %q: want a positive number", what, arg)
	}
	return id, nil
}

// automationScopeOf is the recipe scope of an index row.
func automationScopeOf(a *db.Automation) automations.Scope {
	if a.Scope == string(automations.ScopeWorkbench) {
		return automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: a.ProjectID}
	}
	return automations.Scope{Kind: automations.ScopePersonal}
}

// workbenchScope is the scope of --workbench N (personal when 0) and, for a
// workbench, its recipe folder; an unknown workbench is an error.
func workbenchScope(database *db.DB, workbenchID int64) (automations.Scope, string, error) {
	if workbenchID == 0 {
		return automations.Scope{Kind: automations.ScopePersonal}, "", nil
	}
	if workbenchID < 0 {
		return automations.Scope{}, "", fmt.Errorf("invalid --workbench %d: want a positive id", workbenchID)
	}
	w, err := database.GetWorkbench(workbenchID)
	if err != nil {
		return automations.Scope{}, "", err
	}
	return automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: w.ID}, automations.WorkbenchDir(w.FolderPath), nil
}

// resolveAutomation finds an automation by slug in the scope of --workbench
// (personal by default) and, when no slug matches and arg is a number, by
// id. Slug first: an all-digit slug ("2026") is a valid recipe name, and the
// owner who typed it meant that recipe.
func resolveAutomation(database *db.DB, arg string, workbenchID int64) (*db.Automation, error) {
	scope, _, err := workbenchScope(database, workbenchID)
	if err != nil {
		return nil, err
	}
	a, err := database.GetAutomationBySlug(string(scope.Kind), scope.WorkbenchID, arg)
	if err == nil || !errors.Is(err, db.ErrAutomationNotFound) {
		return a, err
	}
	id, perr := strconv.ParseInt(arg, 10, 64)
	if perr != nil || id <= 0 {
		return nil, err
	}
	return database.GetAutomation(id)
}

// automationConfirmed reports whether the owner confirmed a's current
// approval hash (a parse-error row never is).
func automationConfirmed(a *db.Automation) bool {
	return a.ParseError == "" && a.ConfirmedHash != "" && a.ConfirmedHash == a.ApprovalHash
}

// automationNeedsConfirmation is the "Needs your confirmation" state of
// spec §2.5: a parsed recipe whose approval hash the owner has not confirmed.
func automationNeedsConfirmation(a *db.Automation) bool {
	return a.ParseError == "" && a.ConfirmedHash != a.ApprovalHash
}

// decodeAutomationList decodes a permissions_json/outputs_json column; the
// result is never nil (CLI JSON arrays are [] — the Desktop contract).
func decodeAutomationList(column, raw string) ([]string, error) {
	out := []string{}
	if raw == "" {
		return out, nil
	}
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return nil, fmt.Errorf("decoding %s: %w", column, err)
	}
	if out == nil {
		out = []string{}
	}
	return out, nil
}

// automationJSON is `show --json` — the pinned key set of plan Task 12
// (later phases add keys, never rename or drop one).
//
// Widening (v1 limit): the index keeps only confirmed_hash, not the
// permission list that was confirmed, so widening is [] for a confirmed
// recipe and every current normalised permission otherwise — for an edited
// recipe that lists all its permissions, not only the ones the edit added.
type automationJSON struct {
	ID                int64    `json:"id"`
	Slug              string   `json:"slug"`
	Scope             string   `json:"scope"`
	ProjectID         int64    `json:"project_id"`
	Path              string   `json:"path"`
	Name              string   `json:"name"`
	Description       string   `json:"description"`
	Script            string   `json:"script"`
	RecipeText        string   `json:"recipe_text"`
	TriggerKind       string   `json:"trigger_kind"`
	TriggerSpec       string   `json:"trigger_spec"`
	Permissions       []string `json:"permissions"`
	Outputs           []string `json:"outputs"`
	BudgetTokens      int      `json:"budget_tokens"`
	BudgetMinutes     int      `json:"budget_minutes"`
	Concurrency       int      `json:"concurrency"`
	MissedPolicy      string   `json:"missed_policy"`
	PauseTimeoutHours int      `json:"pause_timeout_hours"`
	Enabled           bool     `json:"enabled"`
	Runnable          bool     `json:"runnable"`
	NeedsConfirmation bool     `json:"needs_confirmation"`
	ParseError        string   `json:"parse_error"`
	ContentHash       string   `json:"content_hash"`
	ApprovalHash      string   `json:"approval_hash"`
	ConfirmedHash     string   `json:"confirmed_hash"`
	Widening          []string `json:"widening"`
	// Grants are the auto grants, inactive ones included (P2, spec §6.4).
	Grants []automationGrantJSON `json:"grants"`
	// AutoTools are the write tools the manifest admits, for the edit form's
	// Auto toggles (P3); never null, empty for a recipe that does not parse.
	AutoTools []automationAutoToolJSON `json:"auto_tools"`
	// LLMAutoWrites are the External tools with an auto grant, active or
	// paused, when the recipe feeds its sources to llm() — the confirmation
	// sheet's warning (#559); never null.
	LLMAutoWrites []string `json:"llm_auto_writes"`
	// The confirmation sheet's Changed block (P3, spec §12.2, D26): see
	// automationChanges and automationAuthor.
	Changes      []automationChangeJSON `json:"changes"`
	ChangesKnown bool                   `json:"changes_known"`
	ChangedBy    string                 `json:"changed_by"`
	ChangedAt    *string                `json:"changed_at"`
}

// automationChangeJSON is one hashed field that differs from the confirmed
// recipe: old and new in automations.ApprovalFields' text form (the trigger
// spec JSON without a button's label), both "" for the script.
type automationChangeJSON struct {
	Field string `json:"field"`
	Old   string `json:"old"`
	New   string `json:"new"`
}

// automationAutoToolJSON is one entry of show's auto_tools: a write tool the
// manifest admits; always_asks marks one auto can never be turned on for (D14).
type automationAutoToolJSON struct {
	Tool       string `json:"tool"`
	AlwaysAsks bool   `json:"always_asks"`
}

// automationAutoTools lists the write tools of reg the manifest of a admits
// (Manifest.AdmitsWriteTool), sorted by name; [] when a does not parse.
func automationAutoTools(reg *tools.Registry, a *db.Automation) []automationAutoToolJSON {
	out := []automationAutoToolJSON{}
	m, err := automationManifest(a)
	if err != nil {
		return out
	}
	for _, t := range reg.All() {
		if m.AdmitsWriteTool(t) {
			out = append(out, automationAutoToolJSON{Tool: t.Name, AlwaysAsks: t.AlwaysAsk})
		}
	}
	slices.SortFunc(out, func(x, y automationAutoToolJSON) int { return strings.Compare(x.Tool, y.Tool) })
	return out
}

// automationLLMAutoWrites lists, sorted, the External tools of reg holding an
// auto grant of a (active or paused: a paused one comes back with the exact
// granted text or one click) when a's manifest feeds the owner's sources to
// llm() (Manifest.FeedsSourcesToLLM): model text written over other people's
// mail, messages or tickets may then reach that tool without a card. [] when
// a does not parse or nothing matches.
func automationLLMAutoWrites(reg *tools.Registry, a *db.Automation, grants []db.AutomationToolGrant) []string {
	out := []string{}
	m, err := automationManifest(a)
	if err != nil || !m.FeedsSourcesToLLM() {
		return out
	}
	for _, g := range grants {
		if t, ok := reg.Get(g.Tool); ok && t.External && !slices.Contains(out, g.Tool) {
			out = append(out, g.Tool)
		}
	}
	slices.Sort(out)
	return out
}

// changedByAssistant is changed_by when an applied save_automation wrote the
// recipe's current approval hash.
const changedByAssistant = "assistant"

// newAutomationJSON builds show's payload; widening is Covers(nil, current)
// for an unconfirmed recipe (see automationJSON's v1 limit).
func newAutomationJSON(database *db.DB, a *db.Automation, grants []db.AutomationToolGrant) (automationJSON, error) {
	perms, err := decodeAutomationList("permissions_json", a.PermissionsJSON)
	if err != nil {
		return automationJSON{}, fmt.Errorf("automation %d: %w", a.ID, err)
	}
	outs, err := decodeAutomationList("outputs_json", a.OutputsJSON)
	if err != nil {
		return automationJSON{}, fmt.Errorf("automation %d: %w", a.ID, err)
	}
	j := automationJSON{
		ID: a.ID, Slug: a.Slug, Scope: a.Scope, ProjectID: a.ProjectID, Path: a.Path, Name: a.Name,
		RecipeText: a.RecipeText, TriggerKind: a.TriggerKind, TriggerSpec: a.TriggerSpec,
		Permissions: perms, Outputs: outs, BudgetTokens: a.BudgetTokens, BudgetMinutes: a.BudgetMinutes,
		Concurrency: a.Concurrency, MissedPolicy: a.MissedPolicy, PauseTimeoutHours: a.PauseTimeoutHours,
		Enabled: a.Enabled, Runnable: a.Runnable(), NeedsConfirmation: automationNeedsConfirmation(a),
		ParseError: a.ParseError, ContentHash: a.ContentHash, ApprovalHash: a.ApprovalHash,
		ConfirmedHash: a.ConfirmedHash, Widening: []string{}, Grants: newAutomationGrantsJSON(grants),
		AutoTools: []automationAutoToolJSON{}, Changes: []automationChangeJSON{}, LLMAutoWrites: []string{},
	}
	if j.ChangedBy, j.ChangedAt, err = automationAuthor(database, a); err != nil {
		return automationJSON{}, err
	}
	if a.ParseError != "" {
		return j, nil
	}
	r, err := automations.ParseRecipe(a.Slug, []byte(a.RecipeText), automationScopeOf(a))
	if err != nil {
		return automationJSON{}, fmt.Errorf("automation %d: re-parsing its indexed recipe (run `watchtower automations rescan`): %w", a.ID, err)
	}
	j.Description, j.Script = r.Description, r.Script
	if !automationConfirmed(a) {
		j.Widening = automations.Covers(nil, perms)
	}
	if j.Changes, j.ChangesKnown, err = automationChanges(database, a, r); err != nil {
		return automationJSON{}, err
	}
	return j, nil
}

// automationChanges is the Changed block's diff of a (parsed as current)
// against the text the owner confirmed (spec §12.2, D26). Confirmed: nothing
// changed, known. Never confirmed: nothing to compare, unknown ("First
// confirmation"). Otherwise the confirmed text is automations.ConfirmedRecipe's
// (the run snapshot or save_automation candidate whose approval hash is
// confirmed_hash); none leaves the diff unknown. changes is never nil.
func automationChanges(database *db.DB, a *db.Automation, current *automations.Recipe) ([]automationChangeJSON, bool, error) {
	if automationConfirmed(a) {
		return []automationChangeJSON{}, true, nil
	}
	if a.ConfirmedHash == "" {
		return []automationChangeJSON{}, false, nil
	}
	confirmed, err := automations.ConfirmedRecipe(database, a)
	if err != nil {
		return nil, false, err
	}
	if confirmed == nil {
		return []automationChangeJSON{}, false, nil
	}
	return diffApprovalFields(confirmed, current), true, nil
}

// diffApprovalFields lists the hashed fields that differ between the
// confirmed and the current recipe, in ApprovalFields' order.
func diffApprovalFields(confirmed, current *automations.Recipe) []automationChangeJSON {
	changes := []automationChangeJSON{}
	before, after := automations.ApprovalFields(confirmed), automations.ApprovalFields(current)
	for i, f := range after {
		if before[i].Value == f.Value {
			continue
		}
		c := automationChangeJSON{Field: f.Name, Old: before[i].Value, New: f.Value}
		if f.Name == "script" {
			c.Old, c.New = "", "" // the sheet says "Script changed" and shows the script itself
		}
		changes = append(changes, c)
	}
	return changes
}

// automationAuthor is the Changed block's author line: "assistant" and the
// applied_at of the newest applied save_automation that pinned a's current
// approval hash; otherwise "" and a's updated_at (no author is recorded for a
// plain `save` or a hand edit — v1 limit, spec §12.2). The time is RFC 3339
// UTC, nil when unknown.
func automationAuthor(database *db.DB, a *db.Automation) (string, *string, error) {
	if a.ApprovalHash != "" {
		save, err := database.LatestAppliedAutomationSave(a.Path, automationScopeOf(a).String(), a.ApprovalHash)
		if err != nil {
			return "", nil, err
		}
		if save != nil {
			return changedByAssistant, rfc3339UTC(save.AppliedAt), nil
		}
	}
	if a.UpdatedAt.IsZero() {
		return "", nil, nil
	}
	at := a.UpdatedAt.UTC().Format(time.RFC3339)
	return "", &at, nil
}

// rfc3339UTC normalises a stored timestamp to RFC 3339 UTC; nil when it does
// not parse (an applied row always has one).
func rfc3339UTC(s string) *string {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return nil
	}
	out := t.UTC().Format(time.RFC3339)
	return &out
}

func runAutomationsShow(cmd *cobra.Command, args []string) error {
	cfg, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	a, err := resolveAutomation(database, args[0], autoFlags.Workbench)
	if err != nil {
		return err
	}
	grants, err := database.ListAutomationToolGrants(a.ID)
	if err != nil {
		return err
	}
	j, err := newAutomationJSON(database, a, grants)
	if err != nil {
		return err
	}
	reg := buildAutomationRegistry(cfg, database)
	j.AutoTools = automationAutoTools(reg, a)
	j.LLMAutoWrites = automationLLMAutoWrites(reg, a, grants)
	w := cmd.OutOrStdout()
	if autoFlags.JSON {
		return writeJSON(w, j)
	}
	printAutomation(w, j)
	return nil
}

func printAutomation(w io.Writer, j automationJSON) {
	fmt.Fprintf(w, "#%d %s (%s) — %s\n", j.ID, j.Name, j.Slug, j.Scope)
	fmt.Fprintf(w, "  path:        %s\n", j.Path)
	if j.ParseError != "" {
		fmt.Fprintf(w, "  parse error: %s\n", j.ParseError)
	}
	fmt.Fprintf(w, "  trigger:     %s %s\n", j.TriggerKind, j.TriggerSpec)
	fmt.Fprintf(w, "  enabled:     %v, runnable: %v, needs confirmation: %v\n", j.Enabled, j.Runnable, j.NeedsConfirmation)
	fmt.Fprintf(w, "  permissions: %v\n", j.Permissions)
	fmt.Fprintf(w, "  outputs:     %v\n", j.Outputs)
	fmt.Fprintf(w, "  budget:      %d tokens, %d min\n", j.BudgetTokens, j.BudgetMinutes)
	fmt.Fprintf(w, "  approval:    %s (confirmed: %s)\n", j.ApprovalHash, orNone(j.ConfirmedHash))
	if len(j.Widening) > 0 {
		fmt.Fprintf(w, "  not confirmed yet: %v\n", j.Widening)
	}
	for _, g := range j.Grants {
		state := "auto"
		if !g.Active {
			state = "auto paused — the recipe changed"
		}
		fmt.Fprintf(w, "  grant:       %s (%s)\n", g.Tool, state)
	}
}

func orNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}

// automationsCanonicalDir is automations.CanonicalDir behind a test seam.
var automationsCanonicalDir = automations.CanonicalDir

// recipeFolderOf resolves the recipe folder file lies in — the personal folder
// or a known workbench's .watchtower/automations — and returns its scope, the
// canonical folder and the file's canonical path (how its index row keys
// it). ok is false when file lies in neither.
//
// It touches only file's own folder, the personal folder and at most one
// workbench folder: workbenches are matched lexically (their stored folder is
// already symlink-resolved), and only the one whose recipe folder spells the
// file's folder — as given or canonical — is canonicalised to confirm. A
// workbench folder may sit under a TCC-protected location (~/Documents,
// iCloud Drive, /Volumes…), and a command about another folder must not stat
// it: the prompt would be attributed to Watchtower.
func recipeFolderOf(cfg *config.Config, database *db.DB, file string) (scope automations.Scope, dir, path string, ok bool, err error) {
	dir, err = automationsCanonicalDir(filepath.Dir(file))
	if err != nil {
		return scope, "", "", false, fmt.Errorf("resolving %s: %w", file, err)
	}
	path = filepath.Join(dir, filepath.Base(file))
	personal, err := automationsCanonicalDir(automations.PersonalDir(cfg.WorkspaceDir()))
	if err != nil {
		return scope, "", "", false, fmt.Errorf("resolving the personal recipe folder: %w", err)
	}
	if dir == personal {
		return automations.Scope{Kind: automations.ScopePersonal}, dir, path, true, nil
	}
	given, err := filepath.Abs(filepath.Dir(file))
	if err != nil {
		return scope, "", "", false, fmt.Errorf("resolving %s: %w", file, err)
	}
	w, err := workbenchSpellingRecipeDir(database, given, dir)
	if err != nil || w == nil {
		return scope, dir, path, false, err
	}
	wdir, err := automationsCanonicalDir(automations.WorkbenchDir(w.FolderPath))
	if err != nil {
		return scope, "", "", false, fmt.Errorf("resolving workbench %d's recipe folder: %w", w.ID, err)
	}
	if dir != wdir {
		return scope, dir, path, false, nil
	}
	return automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: w.ID}, dir, path, true, nil
}

// workbenchSpellingRecipeDir is the workbench whose recipe folder, by its
// stored path alone, is one of dirs (nil when none) — no filesystem call.
func workbenchSpellingRecipeDir(database *db.DB, dirs ...string) (*db.Workbench, error) {
	workbenches, err := database.ListWorkbenches()
	if err != nil {
		return nil, err
	}
	for i := range workbenches {
		wdir := filepath.Clean(automations.WorkbenchDir(workbenches[i].FolderPath))
		if slices.Contains(dirs, wdir) {
			return &workbenches[i], nil
		}
	}
	return nil, nil
}

// scopeRecipeDir is scope's recipe folder as stored (not canonicalised): the
// personal folder, or the workbench's .watchtower/automations. ok is false
// for a workbench that no longer exists.
func scopeRecipeDir(cfg *config.Config, database *db.DB, scope automations.Scope) (dir string, ok bool, err error) {
	if scope.Kind != automations.ScopeWorkbench {
		return automations.PersonalDir(cfg.WorkspaceDir()), true, nil
	}
	w, err := database.GetWorkbench(scope.WorkbenchID)
	if errors.Is(err, db.ErrWorkbenchNotFound) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return automations.WorkbenchDir(w.FolderPath), true, nil
}
