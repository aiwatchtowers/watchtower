package authoring

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// Draft dry-run bounds (spec §11): the dry run spends at most
// min(budget.tokens, draftMaxTokens) tokens and min(budget.minutes,
// draftMaxMinutes) minutes.
const (
	draftMaxTokens  = 50000
	draftMaxMinutes = 5
)

// draftSlug parses a draft the chat named no slug for; ParseRecipe needs a
// valid one.
const draftSlug = "draft"

// Messages the chat model sees verbatim.
const (
	msgFeatureOff        = "Automations are turned off in Settings → Features"
	msgUnconfirmedRecipe = "This recipe is not confirmed yet; only you can dry-run it, from its card in Automations"
)

// dryRunRefused is DraftDryRun.Status when the draft is an indexed
// unconfirmed recipe (D16, ask #271).
const dryRunRefused = "refused"

type draftArgs struct {
	RecipeText  string `json:"recipe_text" jsonschema:"the whole recipe file: frontmatter, description and one js block"`
	Slug        string `json:"slug,omitempty" jsonschema:"the slug of the saved automation this draft edits; omit for a new recipe"`
	WorkbenchID int64  `json:"workbench_id,omitempty" jsonschema:"the workbench the recipe belongs to; omit for a personal recipe"`
}

// DraftResult is draft_automation's result. Every slice is [] when empty,
// never null; DryRun is null only when the recipe does not parse.
type DraftResult struct {
	OK       bool          `json:"ok"`
	Errors   []string      `json:"errors"`
	Manifest DraftManifest `json:"manifest"`
	Widening []string      `json:"widening"`
	DryRun   *DraftDryRun  `json:"dry_run"`
}

// DraftManifest is what the draft declares. Trigger is a short text of the
// trigger: the cron expression, the button label, the event type, or
// "manual".
type DraftManifest struct {
	Name          string   `json:"name"`
	Slug          string   `json:"slug"`
	Scope         string   `json:"scope"`
	TriggerKind   string   `json:"trigger_kind"`
	Trigger       string   `json:"trigger"`
	Permissions   []string `json:"permissions"`
	Outputs       []string `json:"outputs"`
	BudgetTokens  int      `json:"budget_tokens"`
	BudgetMinutes int      `json:"budget_minutes"`
	ApprovalHash  string   `json:"approval_hash"`
}

// DraftDryRun is the in-memory dry run: its journal, its would-be outputs,
// the tokens it spent and how it ended.
type DraftDryRun struct {
	Steps   []DraftStep   `json:"steps"`
	Outputs []DraftOutput `json:"outputs"`
	Tokens  int64         `json:"tokens"`
	Status  string        `json:"status"`
	Error   string        `json:"error"`
}

// DraftStep is one journal step; Args and Result are clipped by the journal
// (automations.StepClipBytes each).
type DraftStep struct {
	Seq        int    `json:"seq"`
	Kind       string `json:"kind"`
	Name       string `json:"name"`
	Status     string `json:"status"`
	Args       string `json:"args"`
	Result     string `json:"result"`
	Permission string `json:"permission"`
	Error      string `json:"error"`
	Tokens     int64  `json:"tokens"`
}

// DraftOutput is one output the run would have committed.
type DraftOutput struct {
	Kind     string `json:"kind"`
	Title    string `json:"title"`
	Body     string `json:"body"`
	Priority string `json:"priority"`
}

// NewDraftAutomation is draft_automation (spec §11): validate a recipe the
// chat is writing, compute its widening, and dry-run it in memory. It writes
// nothing (AGENT-06): writes in the dry run answer {status:"dry_run"}, and the
// journal comes back in the result — clipped mail of list_emails/get_email
// steps included (D18, ask #272). A draft equal to an indexed unconfirmed
// recipe is not dry-run (D16, ask #271).
func NewDraftAutomation(d Deps) *tools.Tool {
	return &tools.Tool{
		Name: "draft_automation",
		Description: "Validate an automation recipe draft and dry-run it in memory before proposing save_automation. " +
			"Returns parse errors, the normalised manifest, the permissions the draft widens (pass slug when editing a " +
			"saved automation), and the dry run's steps, would-be outputs and tokens. Writes nothing: write tools, " +
			"state and outputs answer {status:\"dry_run\"}.",
		InputSchema: draftSchema(),
		Access:      tools.AccessRead,
		Surfaces:    []string{"main", tools.AutomationEditorSurface},
		Execute: func(ctx context.Context, _ *db.DB, call tools.Call) (any, error) {
			return draft(ctx, d, call.Args)
		},
	}
}

func draftSchema() *jsonschema.Schema {
	s, err := jsonschema.For[draftArgs](nil)
	if err != nil {
		panic("draft_automation schema: " + err.Error())
	}
	return s
}

func draft(ctx context.Context, d Deps, raw json.RawMessage) (*DraftResult, error) {
	if d.Enabled == nil || !d.Enabled() {
		return nil, &tools.ValidationError{Msg: msgFeatureOff}
	}
	var a draftArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, &tools.ValidationError{Msg: "invalid arguments"}
	}
	if strings.TrimSpace(a.RecipeText) == "" {
		return nil, &tools.ValidationError{Msg: "recipe_text is required"}
	}
	if a.WorkbenchID < 0 {
		return nil, &tools.ValidationError{Msg: "workbench_id must be a workbench id"}
	}
	scope := automations.Scope{Kind: automations.ScopePersonal}
	if a.WorkbenchID > 0 {
		scope = automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: a.WorkbenchID}
	}
	res := &DraftResult{
		Errors: []string{}, Widening: []string{},
		Manifest: DraftManifest{Slug: a.Slug, Scope: scope.String(), Permissions: []string{}, Outputs: []string{}},
	}
	slug := a.Slug
	if slug == "" {
		slug = draftSlug
	}
	r, err := automations.ParseRecipe(slug, []byte(a.RecipeText), scope)
	if err != nil {
		res.Errors = append(res.Errors, err.Error())
		return res, nil
	}
	m, err := automations.ParseManifest(r.Permissions, r.Outputs, r.Scope)
	if err != nil { // ParseRecipe validated the manifest already
		res.Errors = append(res.Errors, err.Error())
		return res, nil
	}
	res.OK = true
	res.Manifest = manifestOf(r, m, a.Slug)
	if res.Widening, err = widening(d.DB, scope, a.Slug, res.Manifest.Permissions); err != nil {
		return nil, err
	}
	refused, err := isUnconfirmedRecipe(d.DB, scope, res.Manifest.ApprovalHash)
	if err != nil {
		return nil, err
	}
	if refused {
		res.DryRun = &DraftDryRun{Steps: []DraftStep{}, Outputs: []DraftOutput{}, Status: dryRunRefused, Error: msgUnconfirmedRecipe}
		return res, nil
	}
	rep, err := automations.DryRunInMemory(ctx, d.backends(), r, automations.DryRunOptions{Budget: draftBudget(r.Budget)})
	if err != nil {
		return nil, fmt.Errorf("draft_automation: %w", err)
	}
	res.DryRun = dryRunOf(rep)
	return res, nil
}

// draftBudget bounds a draft's dry run by the recipe's budget and
// draftMaxTokens / draftMaxMinutes, whichever is lower.
func draftBudget(recipe automations.Budget) automations.Budget {
	return automations.Budget{Tokens: min(recipe.Tokens, draftMaxTokens), Minutes: min(recipe.Minutes, draftMaxMinutes)}
}

func manifestOf(r *automations.Recipe, m *automations.Manifest, slug string) DraftManifest {
	return DraftManifest{
		Name: r.Name, Slug: slug, Scope: r.Scope.String(),
		TriggerKind: string(r.Trigger.Kind), Trigger: triggerText(r.Trigger),
		Permissions: nonNil(m.Normalized()), Outputs: nonNil(m.Outputs()),
		BudgetTokens: r.Budget.Tokens, BudgetMinutes: r.Budget.Minutes,
		ApprovalHash: automations.ApprovalHash(r),
	}
}

func triggerText(t automations.Trigger) string {
	switch {
	case t.Kind == automations.TriggerSchedule:
		return t.Schedule
	case t.Kind == automations.TriggerButton && t.Button != nil:
		return t.Button.Label
	case t.Kind == automations.TriggerEvent && t.Event != nil:
		return t.Event.Type
	}
	return string(t.Kind)
}

// widening is what perms add over the saved automation at (scope, slug)
// (R-P3-1); with no slug, or no saved (or only a removed) automation there,
// a draft widens from nothing: every permission.
func widening(d *db.DB, scope automations.Scope, slug string, perms []string) ([]string, error) {
	if slug == "" {
		return automations.Covers(nil, perms), nil
	}
	saved, err := d.GetAutomationBySlug(string(scope.Kind), scope.WorkbenchID, slug)
	if errors.Is(err, db.ErrAutomationNotFound) {
		return automations.Covers(nil, perms), nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading the saved automation %s: %w", slug, err)
	}
	if saved.RemovedAt != nil {
		return automations.Covers(nil, perms), nil
	}
	var old []string
	if err := json.Unmarshal([]byte(saved.PermissionsJSON), &old); err != nil {
		return nil, fmt.Errorf("automation %d permissions_json: %w", saved.ID, err)
	}
	return automations.Covers(old, perms), nil
}

// isUnconfirmedRecipe reports whether hash is the approval hash of an
// indexed, not removed automation of scope the owner has not confirmed
// (D16). The hash covers the scope, so other scopes cannot match.
func isUnconfirmedRecipe(d *db.DB, scope automations.Scope, hash string) (bool, error) {
	rows, err := d.ListAutomations(db.AutomationFilter{Scope: string(scope.Kind), ProjectID: scope.WorkbenchID})
	if err != nil {
		return false, fmt.Errorf("draft_automation: %w", err)
	}
	for _, a := range rows {
		if a.RemovedAt == nil && a.ApprovalHash == hash && a.ConfirmedHash != a.ApprovalHash {
			return true, nil
		}
	}
	return false, nil
}

func dryRunOf(rep *automations.DryRunReport) *DraftDryRun {
	out := &DraftDryRun{
		Steps: make([]DraftStep, 0, len(rep.Steps)), Outputs: make([]DraftOutput, 0, len(rep.Outputs)),
		Tokens: rep.InputTokens + rep.OutputTokens, Status: rep.Status, Error: rep.Error,
	}
	for _, s := range rep.Steps {
		out.Steps = append(out.Steps, DraftStep{
			Seq: s.Seq, Kind: s.Kind, Name: s.Name, Status: s.Status, Args: s.ArgsJSON, Result: s.ResultSummary,
			Permission: s.Permission, Error: s.Error, Tokens: s.InputTokens + s.OutputTokens,
		})
	}
	for _, o := range rep.Outputs {
		out.Outputs = append(out.Outputs, DraftOutput{Kind: o.Kind, Title: o.Title, Body: o.Body, Priority: o.Priority})
	}
	return out
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}
