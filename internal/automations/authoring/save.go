package authoring

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// maxDryRunSummaryBytes clips the model-supplied dry-run summary the card
// shows as "Assistant's dry-run summary" (R-P3-4).
const maxDryRunSummaryBytes = 2 * 1024

// Messages save_automation's refusals carry verbatim.
const (
	msgWorkbenchSaveLater = "Workbench automations are saved from the workbench (arrives with a later update)"
	msgRecipeTextDrifted  = "the recipe text no longer matches the reviewed one"
	msgRecipeFileChanged  = "the recipe file changed since this was proposed — ask the assistant to draft it again"
	msgRecipePathChanged  = "the recipe's location changed since this was proposed — ask the assistant to draft it again"
)

type saveArgs struct {
	RecipeText    string `json:"recipe_text" jsonschema:"the whole recipe file exactly as drafted with draft_automation"`
	Slug          string `json:"slug" jsonschema:"the recipe's slug: its file name without .md (^[a-z0-9][a-z0-9-]{0,63}$); an existing slug edits that automation"`
	WorkbenchID   int64  `json:"workbench_id,omitempty" jsonschema:"the workbench the recipe belongs to; omit for a personal recipe"`
	Reason        string `json:"reason" jsonschema:"why you propose this save, for the owner"`
	DryRunSummary string `json:"dry_run_summary,omitempty" jsonschema:"a short summary of draft_automation's dry run of this exact text (at most 2 KiB)"`
}

// savePinned is what Normalize stores in agent_actions.args_json: the call's
// args plus everything the owner's card shows and Execute checks. The keys
// path, scope, approval_hash and previous_recipe_text are read back by
// `automations show --json` (db.LatestAppliedAutomationSave).
type savePinned struct {
	saveArgs
	Scope               string          `json:"scope"`
	Path                string          `json:"path"`
	Name                string          `json:"name"`
	TriggerKind         string          `json:"trigger_kind"`
	TriggerSpec         json.RawMessage `json:"trigger_spec"`
	Permissions         []string        `json:"permissions"`
	Outputs             []string        `json:"outputs"`
	BudgetTokens        int             `json:"budget_tokens"`
	BudgetMinutes       int             `json:"budget_minutes"`
	ApprovalHash        string          `json:"approval_hash"`
	Widening            []string        `json:"widening"`
	ExistingContentHash string          `json:"existing_content_hash"`
	PreviousRecipeText  string          `json:"previous_recipe_text"`
	IsNew               bool            `json:"is_new"`
}

// SaveResult is save_automation's result once applied.
type SaveResult struct {
	AutomationID int64  `json:"automation_id"`
	Path         string `json:"path"`
	ApprovalHash string `json:"approval_hash"`
	Confirmed    bool   `json:"confirmed"`
}

// NewSaveAutomation is save_automation (spec §11): propose saving a recipe
// for the owner's Approve. AlwaysAsk — never execute trust, never an auto
// grant. Normalize pins the approval hash, the widening, the file's current
// content hash and text; Execute (only from Apply, after Approve — AGENT-07)
// writes the file only while both still hold, indexes it and confirms the
// pinned hash. Auto grants are not carried over (AUTO-03): a changed hash
// leaves them inactive.
func NewSaveAutomation(d Deps) *tools.Tool {
	return &tools.Tool{
		Name: "save_automation",
		Description: "Propose saving an automation recipe you drafted with draft_automation. The owner reviews the " +
			"trigger, permissions, outputs, budget and the change, and approves or rejects it; nothing is written " +
			"until then. On approval the recipe file is written, indexed and confirmed (it stays disabled until " +
			"the owner enables it). Pass the exact text you drafted and its dry run's summary.",
		InputSchema: saveSchema(),
		Access:      tools.AccessWrite,
		AlwaysAsk:   true,
		Surfaces:    []string{"main", tools.AutomationEditorSurface},
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			_, _, err := parseSave(d, raw)
			return err
		},
		Normalize: func(_ context.Context, _ *db.DB, raw json.RawMessage) (json.RawMessage, error) {
			return normalizeSave(d, raw)
		},
		Execute: func(ctx context.Context, _ *db.DB, call tools.Call) (any, error) {
			return executeSave(ctx, d, call.Args)
		},
	}
}

func saveSchema() *jsonschema.Schema {
	s, err := jsonschema.For[saveArgs](nil)
	if err != nil {
		panic("save_automation schema: " + err.Error())
	}
	return s
}

// parseSave checks the call's args and parses its recipe as a personal one;
// every refusal is a *tools.ValidationError (no row).
func parseSave(d Deps, raw json.RawMessage) (saveArgs, *automations.Recipe, error) {
	var a saveArgs
	if d.Enabled == nil || !d.Enabled() {
		return a, nil, &tools.ValidationError{Msg: msgFeatureOff}
	}
	if err := json.Unmarshal(raw, &a); err != nil {
		return a, nil, &tools.ValidationError{Msg: "invalid arguments"}
	}
	switch {
	case strings.TrimSpace(a.RecipeText) == "":
		return a, nil, &tools.ValidationError{Msg: "recipe_text is required"}
	case !automations.ValidSlug(a.Slug):
		return a, nil, &tools.ValidationError{Msg: "slug must match ^[a-z0-9][a-z0-9-]{0,63}$"}
	case strings.TrimSpace(a.Reason) == "":
		return a, nil, &tools.ValidationError{Msg: "reason is required"}
	case a.WorkbenchID != 0: // R-P3-5: lifted in P5 with the PROJ-03 amendment
		return a, nil, &tools.ValidationError{Msg: msgWorkbenchSaveLater}
	}
	r, err := automations.ParseRecipe(a.Slug, []byte(a.RecipeText), personalScope)
	if err != nil {
		return a, nil, &tools.ValidationError{Msg: err.Error()}
	}
	return a, r, nil
}

var personalScope = automations.Scope{Kind: automations.ScopePersonal}

// recipeTarget is the canonical folder and path of slug's personal recipe —
// the path the indexer stores in automations.path.
func recipeTarget(d Deps, slug string) (dir, path string, err error) {
	dir, err = automations.CanonicalDir(automations.PersonalDir(d.WorkspaceDir))
	if err != nil {
		return "", "", fmt.Errorf("resolving the personal recipe folder: %w", err)
	}
	return dir, filepath.Join(dir, slug+".md"), nil
}

// recipeFileNow is the file at path now: its first MaxRecipeBytes+1 bytes
// and the content hash of all of it; exists is false (hash "") when nothing
// is at path. Anything at path that is not a regular file is an error.
func recipeFileNow(path string) (data []byte, hash string, exists bool, err error) {
	if _, err := os.Lstat(path); errors.Is(err, fs.ErrNotExist) {
		return nil, "", false, nil
	} else if err != nil {
		return nil, "", false, fmt.Errorf("checking %s: %w", path, err)
	}
	data, hash, err = automations.ReadRecipeFile(path)
	if err != nil {
		return nil, "", true, err
	}
	return data, hash, true, nil
}

func normalizeSave(d Deps, raw json.RawMessage) (json.RawMessage, error) {
	a, r, err := parseSave(d, raw)
	if err != nil {
		return nil, err
	}
	_, path, err := recipeTarget(d, a.Slug)
	if err != nil {
		return nil, err
	}
	prev, hash, exists, err := recipeFileNow(path)
	if err != nil {
		return nil, &tools.ValidationError{Msg: fmt.Sprintf("cannot save over %s: %v", path, err)}
	}
	m, err := automations.ParseManifest(r.Permissions, r.Outputs, r.Scope)
	if err != nil { // ParseRecipe validated the manifest already
		return nil, &tools.ValidationError{Msg: err.Error()}
	}
	spec, err := automations.TriggerSpecJSON(r.Trigger)
	if err != nil {
		return nil, fmt.Errorf("save_automation: %w", err)
	}
	perms := nonNil(m.Normalized())
	wide, err := widening(d.DB, personalScope, a.Slug, perms)
	if err != nil {
		return nil, err
	}
	a.DryRunSummary, _ = tools.ClipUTF8Bytes(a.DryRunSummary, maxDryRunSummaryBytes)
	previous, _ := tools.ClipUTF8Bytes(string(prev), automations.MaxRecipeBytes)
	p := savePinned{
		saveArgs: a, Scope: personalScope.String(), Path: path, Name: r.Name,
		TriggerKind: string(r.Trigger.Kind), TriggerSpec: json.RawMessage(spec),
		Permissions: perms, Outputs: nonNil(m.Outputs()),
		BudgetTokens: r.Budget.Tokens, BudgetMinutes: r.Budget.Minutes,
		ApprovalHash: automations.ApprovalHash(r), Widening: wide,
		ExistingContentHash: hash, PreviousRecipeText: previous, IsNew: !exists,
	}
	return json.Marshal(p)
}

// executeSave writes the reviewed recipe, indexes it and confirms the pinned
// hash — only while the text still hashes to the pinned approval hash and the
// file on disk is the one the proposal saw. It never touches
// automation_tool_grants.
func executeSave(ctx context.Context, d Deps, raw json.RawMessage) (*SaveResult, error) {
	if d.Enabled == nil || !d.Enabled() {
		return nil, &tools.ValidationError{Msg: msgFeatureOff}
	}
	var p savePinned
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, fmt.Errorf("save_automation: stored args: %w", err)
	}
	if p.WorkbenchID != 0 {
		return nil, &tools.ValidationError{Msg: msgWorkbenchSaveLater}
	}
	r, err := automations.ParseRecipe(p.Slug, []byte(p.RecipeText), personalScope)
	if err != nil || p.ApprovalHash == "" || automations.ApprovalHash(r) != p.ApprovalHash {
		return nil, errors.New(msgRecipeTextDrifted)
	}
	dir, path, err := recipeTarget(d, p.Slug)
	if err != nil {
		return nil, err
	}
	if path != p.Path {
		return nil, errors.New(msgRecipePathChanged)
	}
	_, hash, _, err := recipeFileNow(path)
	if err != nil || hash != p.ExistingContentHash {
		return nil, errors.New(msgRecipeFileChanged)
	}
	clock := d.Clock
	if clock == nil {
		clock = automations.RealClock{}
	}
	a, err := automations.NewIndexer(d.DB, d.WorkspaceDir, clock).WriteRecipe(ctx, personalScope, dir, path, []byte(p.RecipeText))
	if err != nil {
		return nil, fmt.Errorf("save_automation: %w", err)
	}
	// A confirm that changes the hash restarts a schedule from now: no
	// catch-up for the unconfirmed window (db.ConfirmAutomation).
	if err := d.DB.ConfirmAutomation(a.ID, p.ApprovalHash, clock.Now()); err != nil {
		return nil, fmt.Errorf("saved %s but not confirmed: %w", a.Path, err)
	}
	return &SaveResult{AutomationID: a.ID, Path: a.Path, ApprovalHash: p.ApprovalHash, Confirmed: true}, nil
}
