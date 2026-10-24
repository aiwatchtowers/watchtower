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

// The sync slots (automations.SyncSlots). SlotCustomTracks holds the watch
// recipes (Personal), no built-in.
const (
	SlotMorningBrief Slot = "morning_brief"
	SlotCustomTracks Slot = "custom_tracks"
	SlotTracks       Slot = "tracks"
	SlotReactions    Slot = "reactions"
	SlotIdeas        Slot = "ideas"
)

// ParamKind is how a card parameter is edited.
type ParamKind string

// The parameter kinds.
const (
	ParamHour     ParamKind = "hour"     // an hour of the day, 0–23
	ParamClock    ParamKind = "clock"    // a time of day, "HH:MM"
	ParamCount    ParamKind = "count"    // a whole number of items
	ParamInterval ParamKind = "interval" // a whole number of hours
	// ParamDictionary is a table the Desktop reads and edits itself: the
	// parameter's Key is the table name and its card value is "[]".
	ParamDictionary ParamKind = "dictionary"
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
	// Does is the card's steps in plain words, in order; ResultFilter is the
	// Inbox filter ("day", "tracks", "ideas", "automations") the result lands in.
	Does         []string
	ResultFilter string
	When         func(cfg *config.Config) string
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
			{Key: "day_plan.max_timeblocks", Kind: ParamCount, Label: "Time blocks at most"},
			{Key: "day_plan.min_backlog", Kind: ParamCount, Label: "Backlog items at least"},
			{Key: "day_plan.max_backlog", Kind: ParamCount, Label: "Backlog items at most"},
		},
		Pipelines: []string{"briefing", "day_plan"},
		Reads:     []string{"Slack digests and tracks", "Your calendar", "Your tasks", "Jira and Linear", "Your Inbox"},
		Does: []string{
			"Writes your brief: what changed, what is urgent, who waits on you",
			"Plans your day around your meetings from that brief, in the same run, at the first sync after your briefing hour",
			"Still makes the plan when the brief fails",
		},
		Sends:        []string{"Your day card in the Inbox, under Day"},
		ResultFilter: "day",
		When: func(cfg *config.Config) string {
			return fmt.Sprintf("Every morning at the first sync after %02d:00", briefingHour(cfg))
		},
		RunNow: true,
	},
	{
		ID:         "track-my-threads",
		Name:       "Track my threads",
		Slot:       SlotTracks,
		Recipe:     mustRecipe("track-my-threads"),
		FeatureIDs: []string{"tracks"},
		Primitives: []string{"tracks.extract"},
		Prompts:    []PromptRef{{Name: "extract", PromptID: prompts.TracksExtractBatch}},
		Pipelines:  []string{"tracks"},
		Reads:      []string{"Slack channel digests", "Your profile", "Your existing tracks"},
		Does: []string{
			"Looks through new Slack discussions for threads that involve you",
			"Reads the new channel digests with your profile and your tracks, only while Slack Digests are on",
			"Starts a track for a new thread, or adds news to one you already follow",
		},
		Sends:        []string{"Track cards in your Inbox, under Tracks"},
		ResultFilter: "tracks",
		When:         func(*config.Config) string { return "After every sync, while Slack Digests are on" },
		RunNow:       true,
	},
	{
		ID:         "idea-finder",
		Name:       "Idea finder",
		Slot:       SlotIdeas,
		Recipe:     mustRecipe("idea-finder"),
		FeatureIDs: []string{"ideas"},
		Primitives: []string{"ideas.consolidate"},
		Prompts:    []PromptRef{{Name: "consolidate", PromptID: prompts.IdeasConsolidate}},
		Parameters: []Parameter{{Key: "ideas.mine_interval_hours", Kind: ParamInterval, Label: "Every"}},
		Pipelines:  []string{"ideas"},
		Reads:      []string{"Slack digests", "Mail and tracker digests", "Meeting recaps"},
		Does: []string{
			"Collects ideas and decisions that came up in your work",
			"Reads Slack digests, mail and tracker digests and meeting recaps, every few hours",
			"Merges repeats and keeps what is worth your attention",
		},
		Sends:        []string{"Idea cards in your Inbox, under Ideas; decisions go to your brief"},
		ResultFilter: "ideas",
		When: func(cfg *config.Config) string {
			return fmt.Sprintf("Every %d hours", ideasIntervalHours(cfg))
		},
		RunNow: true,
	},
	{
		ID:         "reactions",
		Name:       "Reactions",
		Slot:       SlotReactions,
		Recipe:     mustRecipe("reactions"),
		FeatureIDs: []string{"reaction-commands"},
		Primitives: []string{"reaction.compose"},
		Prompts:    []PromptRef{{Name: "compose", PromptID: prompts.ReactionCommand}},
		Parameters: []Parameter{{Key: "reaction_command_map", Kind: ParamDictionary, Label: "Reactions"}},
		Pipelines:  []string{"reaction-commands"},
		Reads:      []string{"The message you reacted to", "Its thread"},
		Does: []string{
			"Finds the emoji you placed in your reactions list",
			"Reads the message and its thread",
			"Prepares what that emoji stands for, for example a reminder, an idea or a ticket; one run handles one reaction",
		},
		Sends:        []string{"A proposal in your Inbox, under Automations; ideas, reminders and brief notes are saved at once"},
		ResultFilter: "automations",
		When:         func(*config.Config) string { return "When you react to a Slack message" },
		RunNow:       false,
		NoRunNowNote: "Reactions run for each reaction you place",
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

// ideasIntervalHours is cfg's ideas mining interval (the default without a
// config or with a value below one hour).
func ideasIntervalHours(cfg *config.Config) int {
	if cfg == nil || cfg.Ideas.MineIntervalHours < 1 {
		return config.DefaultIdeasMineIntervalHours
	}
	return cfg.Ideas.MineIntervalHours
}

// All returns every built-in, in card order.
func All() []Entry {
	out := make([]Entry, len(registry))
	for i, e := range registry {
		out[i] = e.clone()
	}
	return out
}

// clone is e with its own copies of every slice, so a caller cannot change
// the registry through it.
func (e Entry) clone() Entry {
	e.Recipe = slices.Clone(e.Recipe)
	e.FeatureIDs = slices.Clone(e.FeatureIDs)
	e.Primitives = slices.Clone(e.Primitives)
	e.Prompts = slices.Clone(e.Prompts)
	e.Parameters = slices.Clone(e.Parameters)
	e.Pipelines = slices.Clone(e.Pipelines)
	e.Reads = slices.Clone(e.Reads)
	e.Sends = slices.Clone(e.Sends)
	e.Does = slices.Clone(e.Does)
	return e
}

// Lookup returns the built-in with id.
func Lookup(id string) (Entry, bool) {
	for _, e := range registry {
		if e.ID == id {
			return e.clone(), true
		}
	}
	return Entry{}, false
}

// AtSlot returns the built-ins that run at slot s, in card order.
func AtSlot(s Slot) []Entry {
	var out []Entry
	for _, e := range registry {
		if e.Slot == s {
			out = append(out, e.clone())
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
