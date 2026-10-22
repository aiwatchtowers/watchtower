// Package builtin is the engine of the built-in automations: the recipes
// Watchtower ships (embedded), the indexer that keeps one automations row per
// built-in (the shipped text or the owner's copy), and the runner that
// executes them at their slot in the daemon's sync cycle (spec 2026-10-22
// §4, §5.1–§5.2).
package builtin

import (
	"embed"
	"fmt"
	"path/filepath"
	"slices"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/features"
	"watchtower/internal/prompts"
)

//go:embed recipes/*.md
var recipeFS embed.FS

// Slot is the place in the daemon's sync cycle where a built-in runs (its
// recipe's trigger.sync).
type Slot string

// The sync slots. C3 adds custom_tracks, tracks, reactions and ideas.
const (
	SlotMorningBrief Slot = "morning_brief"
)

// ParamKind is how a card parameter is edited. C3 adds "interval" and
// "dictionary".
type ParamKind string

// The parameter kinds.
const (
	ParamHour  ParamKind = "hour"  // an hour of the day, 0–23
	ParamClock ParamKind = "clock" // a time of day, "HH:MM"
)

// Parameter is one When field on a built-in's card. It lives in the config,
// never in the recipe or its hash (spec §5.2).
type Parameter struct {
	Key   string // config key, e.g. "briefing.hour"
	Kind  ParamKind
	Label string // card label
}

// PromptRef names one prompt a built-in's recipe asks for with
// builtin.defaultPrompt(Name).
type PromptRef struct {
	Name     string // the defaultPrompt(name) argument: "brief", "plan"
	PromptID string // prompts registry id
}

// Entry is one built-in automation.
type Entry struct {
	ID         string // the builtin_id and the recipe's slug
	Name       string
	Slot       Slot
	Recipe     []byte   // the shipped recipe bytes
	FeatureIDs []string // features registry ids whose config key is the on/off truth
	Primitives []string // the engine primitives the recipe calls
	Prompts    []PromptRef
	Parameters []Parameter
	Pipelines  []string // pipeline_runs names counted in Costs before the built-in's first run
	Reads      []string // card copy
	Sends      []string // card copy
	When       func(cfg *config.Config) string
	// RunNow: the card offers Run Now and `automations run <id>` queues a
	// manual run. Every entry sets it explicitly.
	RunNow bool
	// NoRunNowNote is the CLI's refusal when RunNow is false.
	NoRunNowNote string
}

// registry is every built-in, in card order.
var registry = []Entry{
	{
		ID:         "morning-brief",
		Name:       "Morning brief",
		Slot:       SlotMorningBrief,
		Recipe:     mustRecipe("morning-brief"),
		FeatureIDs: []string{"briefing", "day-plan"},
		Primitives: []string{"brief.compose", "plan.compose"},
		Prompts: []PromptRef{
			{Name: "brief", PromptID: prompts.BriefingDaily},
			{Name: "plan", PromptID: prompts.DayPlanGenerate},
		},
		Parameters: []Parameter{
			{Key: "briefing.hour", Kind: ParamHour, Label: "Time"},
			{Key: "day_plan.working_hours_start", Kind: ParamClock, Label: "Working hours from"},
			{Key: "day_plan.working_hours_end", Kind: ParamClock, Label: "to"},
		},
		Pipelines: []string{"briefing", "day_plan"},
		Reads:     []string{"Slack digests and tracks", "Calendar", "Targets and tasks", "Jira and Linear", "Inbox items"},
		Sends:     []string{"Your day card in the Inbox"},
		When: func(cfg *config.Config) string {
			return fmt.Sprintf("Every morning at the first sync after %02d:00", briefingHour(cfg))
		},
		RunNow: true,
	},
}

func mustRecipe(id string) []byte {
	data, err := recipeFS.ReadFile("recipes/" + id + ".md")
	if err != nil {
		panic(fmt.Sprintf("built-in %s: no embedded recipe: %v", id, err))
	}
	return data
}

// briefingHour is cfg's briefing hour (the default without a config).
func briefingHour(cfg *config.Config) int {
	if cfg == nil {
		return config.DefaultBriefingHour
	}
	return cfg.Briefing.Hour
}

// All returns every built-in, in card order.
func All() []Entry { return slices.Clone(registry) }

// Lookup returns the built-in with id.
func Lookup(id string) (Entry, bool) {
	for _, e := range registry {
		if e.ID == id {
			return e, true
		}
	}
	return Entry{}, false
}

// AtSlot returns the built-ins that run at slot s, in card order.
func AtSlot(s Slot) []Entry {
	var out []Entry
	for _, e := range registry {
		if e.Slot == s {
			out = append(out, e)
		}
	}
	return out
}

// Enabled reports whether any of e's features is on in cfg — the config
// keys stay the on/off truth (spec §5.4). A feature id the registry does not
// know counts as off.
func (e Entry) Enabled(cfg *config.Config) bool {
	if cfg == nil {
		return false
	}
	for _, id := range e.FeatureIDs {
		if f, ok := features.ByID(id); ok && f.Enabled != nil && f.Enabled(cfg) {
			return true
		}
	}
	return false
}

// ShippedContentHash is the content hash of e's shipped recipe bytes.
func (e Entry) ShippedContentHash() string { return automations.ContentHash(e.Recipe) }

// DefaultPrompt is the shipped prompt name of e for the owner's role (the
// role variant when one exists); an error for a name e does not declare.
func (e Entry) DefaultPrompt(name, role string) (string, error) {
	for _, p := range e.Prompts {
		if p.Name != name {
			continue
		}
		tmpl := prompts.DefaultForRole(p.PromptID, role)
		if tmpl == "" {
			return "", fmt.Errorf("built-in %s: prompt %q (%s) has no default", e.ID, name, p.PromptID)
		}
		return tmpl, nil
	}
	return "", fmt.Errorf("built-in %s has no prompt %q", e.ID, name)
}

// OwnerCopyPath is where the owner's copy of built-in id lives:
// <workspace>/automations/.builtin/<id>.md (the Personal scanner skips the
// directory).
func OwnerCopyPath(workspaceDir, id string) string {
	return filepath.Join(automations.PersonalDir(workspaceDir), ".builtin", id+".md")
}

// scopeOf is the scope a built-in's recipe parses in.
func scopeOf(e Entry) automations.Scope {
	return automations.Scope{Kind: automations.ScopePersonal, BuiltinID: e.ID}
}

// ParseShipped parses e's shipped recipe in its built-in scope.
func ParseShipped(e Entry) (*automations.Recipe, error) {
	return automations.ParseRecipe(e.ID, e.Recipe, scopeOf(e))
}

// DefaultPromptFunc is Backends.DefaultPrompt over the registry: the shipped
// prompt name of built-in builtinID for role.
func DefaultPromptFunc(builtinID, name, role string) (string, error) {
	e, ok := Lookup(builtinID)
	if !ok {
		return "", fmt.Errorf("unknown built-in %q", builtinID)
	}
	return e.DefaultPrompt(name, role)
}
