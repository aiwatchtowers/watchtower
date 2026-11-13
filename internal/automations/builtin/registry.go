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
	"watchtower/internal/db"
	"watchtower/internal/features"
	"watchtower/internal/prompts"
)

//go:embed recipes/*.md
var recipeFS embed.FS

// Slot is the place in the daemon's sync cycle where a built-in runs (its
// recipe's trigger.sync); "" for a built-in that runs at no slot (Needs
// approval).
type Slot string

// The sync slots (automations.SyncSlots; SlotWaitingForMe is in waiting.go,
// SlotSlackToday in slacktoday.go).
// SlotCustomTracks holds the watch recipes (Personal), no built-in.
const (
	SlotMorningBrief Slot = "morning_brief"
	SlotCustomTracks Slot = "custom_tracks"
	SlotTracks       Slot = "tracks"
	SlotReactions    Slot = "reactions"
	SlotIdeas        Slot = "ideas"
)

// RootFolder is the slug of the Inbox's root folder: an automation with no
// route shows its artifacts there. It is "inbox", the folder a spec's
// "DefaultFolder inbox" names (Waiting for me, Mail waiting).
const RootFolder = "inbox"

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
	// WindowScope is which Slack conversations the built-in's slack.window
	// reads; every entry listing slack.window sets it (an empty scope
	// fails the call).
	WindowScope db.WindowScope
	Prompts     []PromptRef
	Parameters  []Parameter
	Pipelines   []string // pipeline_runs names counted in Costs before the built-in's first run
	Reads       []string // card copy
	Sends       []string // card copy
	// Does is the card's steps in plain words, in order.
	Does []string
	// DefaultFolder is the slug of the Inbox folder the built-in's artifacts
	// go to: RootFolder, or another folder whose route the indexer seeds
	// when the built-in has none (Sync), so the owner's later move is kept.
	DefaultFolder string
	When          func(cfg *config.Config) string
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
		Sends:         []string{"Your day card in your Inbox"},
		DefaultFolder: RootFolder,
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
		Sends:         []string{"Track cards in your Inbox"},
		DefaultFolder: RootFolder,
		When:          func(*config.Config) string { return "After every sync, while Slack Digests are on" },
		RunNow:        true,
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
		Reads:      []string{"Slack digests", "Mail and tracker digests", "Meeting recaps", "AI chats"},
		Does: []string{
			"Collects ideas and decisions that came up in your work",
			"Reads Slack digests, mail and tracker digests, meeting recaps and your AI chats, every few hours",
			"Merges repeats and keeps what is worth your attention",
		},
		Sends:         []string{"Idea cards in your Inbox; decisions go to your brief"},
		DefaultFolder: RootFolder,
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
		Sends:         []string{"A proposal in your Inbox, in Needs approval; ideas, reminders and brief notes are saved at once"},
		DefaultFolder: RootFolder,
		When:          func(*config.Config) string { return "When you react to a Slack message" },
		RunNow:        false,
		NoRunNowNote:  "Reactions run for each reaction you place",
	},
	{
		ID:         "waiting-for-me",
		Name:       "Waiting for me",
		Slot:       SlotWaitingForMe,
		Recipe:     mustRecipe("waiting-for-me"),
		FeatureIDs: []string{"secretary-inbox"},
		Primitives: []string{automations.PrimitiveAttentionWaiting},
		Reads:      []string{"The mentions, messages and tickets attention detection found"},
		Does: []string{
			"Lists the people waiting on your answer in Slack, Jira and Linear: today, this week and older",
			"Updates the list after every sync; an item leaves when you answer it in the source, mark it done or snooze it",
			"Mail is in Mail waiting",
			"Uses no AI",
		},
		Sends:         []string{"One Waiting for me list in your Inbox"},
		DefaultFolder: RootFolder,
		When:          func(*config.Config) string { return "After every sync, while attention detection is on" },
		RunNow:        true,
	},
	{
		ID:         MailWaitingID,
		Name:       "Mail waiting",
		Slot:       SlotWaitingForMe, // right after Waiting for me
		Recipe:     mustRecipe(MailWaitingID),
		FeatureIDs: []string{"secretary-inbox"},
		Primitives: []string{automations.PrimitiveAttentionWaiting},
		Reads:      []string{"The mail attention detection found"},
		Does: []string{
			"Groups the mail that waits on you by sender, the busiest first",
			"Updates the list after every sync; muted senders are left out",
			"Uses no AI",
		},
		Sends:         []string{"One Mail waiting list in your Inbox"},
		DefaultFolder: RootFolder,
		When:          func(*config.Config) string { return "After every sync, while attention detection is on" },
		RunNow:        true,
	},
	{
		ID:          SlackTodayID,
		Name:        "Slack today",
		Slot:        SlotSlackToday,
		Recipe:      mustRecipe(SlackTodayID),
		FeatureIDs:  []string{"slack-today"},
		Primitives:  []string{automations.PrimitiveSlackWindow},
		WindowScope: db.WindowScopeMemberChannels,
		Prompts:     []PromptRef{{Name: "label", PromptID: prompts.InboxSlackToday}},
		Reads:       []string{"Today's messages in your Slack channels and DMs, except channels muted for AI"},
		Does: []string{
			"Reads the new messages in your channels and DMs since its last run, today only",
			"Marks each line decided, asks you, needs someone or fyi, and leaves out what is addressed to you personally",
			"Keeps one Slack today list in your Inbox, updated at most once an hour",
		},
		Sends:         []string{"One Slack today list in your Inbox"},
		DefaultFolder: RootFolder,
		When:          func(*config.Config) string { return "After a sync, at most once an hour" },
		RunNow:        true,
	},
	{
		ID:         NeedsApprovalID,
		Name:       "Needs approval",
		Slot:       "", // no slot: the approval trigger queues its runs (Entry.Trigger)
		Recipe:     mustRecipe(NeedsApprovalID),
		FeatureIDs: []string{"approval-cards"},
		Primitives: []string{automations.PrimitiveApprovalsList},
		Reads:      []string{"The actions that wait for your approval", "Your reminders that came due"},
		Does: []string{
			"Shows every action that waits for your approval and every reminder that came due, one card each",
			"Updates the cards as soon as one changes, and takes a card away once you approve, reject, finish or snooze it",
			"Uses no AI",
		},
		Sends:         []string{"One card per approval in your Inbox, in Needs approval"},
		DefaultFolder: NeedsApprovalID,
		When:          func(*config.Config) string { return "When an action or a reminder needs you" },
		RunNow:        true,
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

// Trigger is the trigger e's recipe must keep (automations.IndexBuiltinRow):
// `sync: <slot>` for a slot built-in, `event: approval` for one with no slot
// (Needs approval, whose runs only the approval trigger queues).
func (e Entry) Trigger() automations.Trigger {
	if e.Slot == "" {
		return automations.Trigger{Kind: automations.TriggerEvent, Event: &automations.EventTrigger{Type: automations.ApprovalEvent}}
	}
	return automations.Trigger{Kind: automations.TriggerSync, Sync: string(e.Slot)}
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
