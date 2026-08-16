// Package features holds the static registry of Watchtower's product
// pillars: what each one costs, which config key gates it, and which other
// features it feeds. It is read-only application data — no DB table, no
// yaml section describing features — consumed by the `features` CLI and,
// transitively, the Desktop Feature Manager. Sub-toggles under a pillar
// (e.g. memory's sources/surfaces) stay plain config keys with no cascade or
// fast-forward semantics of their own.
package features

import "watchtower/internal/config"

// Cost is a static editorial judgment of how much AI a feature spends per
// daemon cycle (heavy = many strong-tier calls), not live telemetry —
// telemetry is a v1 non-goal.
type Cost string

const (
	CostHeavy  Cost = "heavy"
	CostMedium Cost = "medium"
	CostLight  Cost = "light"
	CostNone   Cost = "none"
)

// Feature describes one entry in the registry.
type Feature struct {
	ID          string      // kebab-case, stable: "secretary-inbox"
	Title       string      // "Secretary Inbox"
	Description string      // one user-facing paragraph, English
	Tagline     string      // one benefit-first phrase, e.g. "Your team's pulse, distilled"
	Benefits    []string    // 2-3 short benefit bullets, user language, no jargon
	Icon        string      // SF Symbol name rendered by the Desktop card
	ConfigKey   string      // "" for core entries without a key
	Parent      string      // presentation nesting ("" = top-level); e.g. stream-digests -> slack-digests
	Core        bool        // no toggle, always on
	Cost        Cost        // heavy | medium | light | none
	FeedsInto   []string    // dependency edges for the cascade dialog
	SubToggles  []SubToggle // existing config keys surfaced under the pillar
	Enabled     func(*config.Config) bool
}

// SubToggle is an existing config key surfaced under a pillar's "Advanced"
// disclosure in the Desktop manager — a plain config.set write, no cascade
// or fast-forward semantics.
type SubToggle struct {
	Key         string // full config key, e.g. "memory.semantic.enabled"
	Title       string
	Description string
}

// registry is the source of truth: core entries first, then the pillars in
// spec table order. All() and Dependents() both return this order.
var registry = []Feature{
	{
		ID:          "dashboard",
		Title:       "Dashboard",
		Description: "The secretary's home screen: every situation clustered from Slack, email, Jira and calendar activity, with a secretary card and Discuss chat per situation, plus a parallel timeline of upcoming meetings. Always on — it is where the rest of Watchtower's output surfaces.",
		Tagline:     "Everything that needs you, in one place",
		Benefits: []string{
			"Situations from Slack, email, Jira and calendar merged into one view",
			"A secretary card explains why each one matters",
			"Discuss each situation directly with your secretary",
		},
		Icon: "tray",
		Core: true,
		Cost: CostNone,
	},
	{
		ID:          "targets",
		Title:       "Targets",
		Description: "The ledger of tracked commitments and follow-ups, created automatically from conversations or added by hand, with statuses and resolution history. Always on — Slack Digests, Tracks, and other pipelines write into it; only the AI-generated Next Step suggestions have their own switch.",
		Tagline:     "Nothing you committed to falls through the cracks",
		Benefits: []string{
			"Commitments and follow-ups tracked automatically from your conversations",
			"Add your own by hand any time",
			"Full status and resolution history per item",
		},
		Icon: "scope",
		Core: true,
		Cost: CostNone,
	},
	{
		ID:          "chat",
		Title:       "Secretary Chat",
		Description: "Free-form chat with the secretary about anything in your workspace — situations, targets, tracks, meetings, memory. Always available; it spends AI tokens only when you send a message, never on a cycle.",
		Tagline:     "Ask your secretary anything about your work",
		Benefits: []string{
			"Ask about any situation, target, track, meeting or memory",
			"Available whenever you need it, not on a fixed cycle",
			"Costs nothing until you actually send a message",
		},
		Icon: "bubble.left.and.bubble.right",
		Core: true,
		Cost: CostNone,
	},
	{
		ID:          "feed",
		Title:       "Feed",
		Description: "Publishes the merged event feed (situations, upcoming meetings, target updates) that powers the Dashboard timeline. Mechanical bookkeeping with no AI calls — infrastructure the Dashboard depends on, not something you would normally turn off.",
		Tagline:     "The plumbing that keeps your Dashboard current",
		Benefits: []string{
			"Merges situations, meetings and target updates into one timeline",
			"Mechanical bookkeeping with no AI cost",
			"Keeps the Dashboard's timeline always current",
		},
		Icon:      "rectangle.grid.1x2",
		ConfigKey: "feed.enabled",
		Core:      true,
		Cost:      CostNone,
		Enabled:   func(cfg *config.Config) bool { return cfg.Feed.Enabled },
	},
	{
		ID:          "secretary-inbox",
		Title:       "Secretary Inbox",
		Description: "Triages every new mention, DM and thread reply, clusters them into situations on the Dashboard and writes a secretary card per situation. Heavy AI use each cycle. Feeds Memory and the daily Briefing.",
		Tagline:     "Never lose a thread again",
		Benefits: []string{
			"Every mention, DM and reply triaged for you",
			"Related messages clustered into one situation",
			"A secretary card tells you why it matters",
		},
		Icon:      "tray",
		ConfigKey: "inbox.enabled",
		Cost:      CostHeavy,
		FeedsInto: []string{"memory", "briefing"},
		Enabled:   func(cfg *config.Config) bool { return cfg.Inbox.Enabled },
	},
	{
		ID:          "slack-digests",
		Title:       "Slack Digests",
		Description: "Summarizes Slack channel activity into per-channel digests — topics, decisions, and proposed ideas. Heavy AI use each cycle; it is the substrate several other pipelines mine, including the Secretary Inbox, Tracks, People Cards, Ideas, and the daily Briefing.",
		Tagline:     "Catch up on any channel in a minute",
		Benefits: []string{
			"Per-channel digests of topics, decisions and proposed ideas",
			"The foundation Secretary Inbox, Tracks, People Cards and Ideas all build on",
			"Read the digest instead of scrolling the whole channel",
		},
		Icon:      "doc.text.magnifyingglass",
		ConfigKey: "digest.enabled",
		Cost:      CostHeavy,
		FeedsInto: []string{"secretary-inbox", "tracks", "people-cards", "ideas", "briefing"},
		Enabled:   func(cfg *config.Config) bool { return cfg.Digest.Enabled },
	},
	{
		ID:          "stream-digests",
		Title:       "Stream Digests",
		Description: "Summarizes new Gmail threads and changed Jira issues and comments into per-account digests, and syncs the Jira comments that let mention detection fire on them. Medium AI use, independent of Slack Digests even though it is shown nested under it. Feeds Ideas and the Secretary Inbox's Jira-comment detection.",
		Tagline:     "Email and Jira, digested like Slack",
		Benefits: []string{
			"New Gmail threads and changed Jira issues summarized per account",
			"Jira comment mentions reach your inbox too",
			"Feeds the Ideas registry alongside Slack",
		},
		Icon:      "envelope.badge",
		ConfigKey: "streams.enabled",
		Parent:    "slack-digests",
		Cost:      CostMedium,
		FeedsInto: []string{"ideas", "secretary-inbox"},
		Enabled:   func(cfg *config.Config) bool { return cfg.Streams.Enabled },
	},
	{
		ID:          "tracks",
		Title:       "Tracks",
		Description: "Detects and maintains ongoing narrative tracks — multi-message threads and projects — from Slack digest activity, plus scans for custom tracks you define. Heavy AI use; it mines the Slack Digests output, so it only has material to work with once Slack Digests is also on. Feeds the daily Briefing and Memory.",
		Tagline:     "Follow the story of a project, not just its messages",
		Benefits: []string{
			"Multi-message threads and projects tracked as one ongoing narrative",
			"Define your own custom tracks to watch",
			"Feeds the daily Briefing with what moved",
		},
		Icon:      "binoculars",
		ConfigKey: "tracks.enabled",
		Cost:      CostHeavy,
		FeedsInto: []string{"briefing", "memory"},
		Enabled:   func(cfg *config.Config) bool { return cfg.Tracks.Enabled },
	},
	{
		ID:          "people-cards",
		Title:       "People Cards",
		Description: "Builds a unified profile card per person — role, communication style, working relationships — from signals Slack Digests produces. Medium AI use; like Tracks, it only has material to work with once Slack Digests is also on.",
		Tagline:     "Know who you're talking to before you reply",
		Benefits: []string{
			"One profile card per person: role, style, working relationships",
			"Built automatically from your Slack activity",
			"Context at a glance before you reply",
		},
		Icon:      "person.2",
		ConfigKey: "people.enabled",
		Cost:      CostMedium,
		Enabled:   func(cfg *config.Config) bool { return cfg.People.Enabled },
	},
	{
		ID:          "ideas",
		Title:       "Ideas & Decisions",
		Description: "Mines Slack digests, email and Jira stream digests, and meeting recaps for proposed ideas and decisions, consolidating them into the Ideas & Decisions registry for your review. Medium AI use for the consolidation step; the per-source mining it reads from rides Slack Digests and Stream Digests.",
		Tagline:     "Every idea and decision, kept in one registry",
		Benefits: []string{
			"Proposed ideas and decisions mined from Slack, email, Jira and meetings",
			"Consolidated into one registry for your review",
			"Nothing decided in passing gets forgotten",
		},
		Icon:      "lightbulb",
		ConfigKey: "ideas.enabled",
		Cost:      CostMedium,
		Enabled:   func(cfg *config.Config) bool { return cfg.Ideas.Enabled },
	},
	{
		ID:          "memory",
		Title:       "Memory",
		Description: "Builds and maintains a durable long-term memory vault — people, projects, and beliefs — from what the rest of Watchtower observes, so later answers, drafts, and briefings have real context instead of starting cold. Off by default. Medium AI use for the core pipeline; the sources and surfaces below are further switches within it. Feeds the daily Briefing and Day Plan.",
		Tagline:     "A secretary that remembers, not just reacts",
		Benefits: []string{
			"Durable memory of people, projects and beliefs",
			"Later answers and briefings start with real context, not a blank slate",
			"Feeds the daily Briefing and Day Plan once it's on",
		},
		Icon:       "archivebox",
		ConfigKey:  "memory.enabled",
		Cost:       CostMedium,
		FeedsInto:  []string{"briefing", "day-plan"},
		SubToggles: memorySubToggles,
		Enabled:    func(cfg *config.Config) bool { return cfg.Memory.Enabled },
	},
	{
		ID:          "briefing",
		Title:       "Daily Briefing",
		Description: "Generates the daily briefing that rolls up digests, tracks, targets, ideas, and — when Memory is on — belief changes into one morning read. Light AI use; it mostly assembles material the other pipelines already produced.",
		Tagline:     "Your whole day, in one morning read",
		Benefits: []string{
			"Digests, tracks, targets and ideas rolled into one briefing",
			"Ready first thing, before you open anything else",
			"Belief changes from Memory included too, once it's on",
		},
		Icon:      "sun.max",
		ConfigKey: "briefing.enabled",
		Cost:      CostLight,
		Enabled:   func(cfg *config.Config) bool { return cfg.Briefing.Enabled },
	},
	{
		ID:          "day-plan",
		Title:       "Day Plan",
		Description: "Generates an actionable daily plan — a time-blocked calendar view plus a prioritized backlog — with calendar conflict detection. Light AI use, generated once a day.",
		Tagline:     "A plan for the day, not just a calendar",
		Benefits: []string{
			"Time-blocked schedule plus a prioritized backlog",
			"Calendar conflicts flagged automatically",
			"Generated fresh once a day",
		},
		Icon:      "calendar.day.timeline.left",
		ConfigKey: "day_plan.enabled",
		Cost:      CostLight,
		Enabled:   func(cfg *config.Config) bool { return cfg.DayPlan.Enabled },
	},
	{
		ID:          "next-step",
		Title:       "Next Step Suggestions",
		Description: "Suggests the next concrete action for each open target, based on its recent activity. Medium AI use.",
		Tagline:     "Always know what to do next",
		Benefits: []string{
			"A concrete next action suggested for every open target",
			"Based on that target's own recent activity",
			"One less thing to figure out yourself",
		},
		Icon:      "arrow.turn.down.right",
		ConfigKey: "targets.next_step.enabled",
		Cost:      CostMedium,
		Enabled:   func(cfg *config.Config) bool { return cfg.Targets.NextStep.Enabled },
	},
}

// memorySubToggles surfaces memory's existing semantic/sources/surfaces
// branch under the Memory pillar's "Advanced" disclosure. Dev/compare flags
// (memory.retrieve.*_compare, memory.renders.digest_compare,
// memory.focus.enabled) are deliberately not listed — they are instruments,
// not options (spec: "Sub-toggles v1").
var memorySubToggles = []SubToggle{
	{
		Key:         "memory.semantic.enabled",
		Title:       "Semantic tier",
		Description: "Strong-tier entity rewrites, belief revision, dedupe, concept promotion, and eviction on top of the raw vault.",
	},
	{
		Key:         "memory.sources.gmail",
		Title:       "Gmail source",
		Description: "Extracts memory episodes from Gmail threads and seeds senders as person entities.",
	},
	{
		Key:         "memory.sources.actions",
		Title:       "Interaction source",
		Description: "Folds owner thumbs-up/thumbs-down feedback and situation verdicts into memory as mechanical outcome evidence — no AI call.",
	},
	{
		Key:         "memory.sources.calendar",
		Title:       "Calendar source",
		Description: "Builds one episode per ended calendar event, folding in its meeting recap where one exists.",
	},
	{
		Key:         "memory.sources.chats",
		Title:       "Chats source",
		Description: "Extends memory ingestion from situation Discuss chats to Target and Track Discuss chats too.",
	},
	{
		Key:         "memory.sources.operational",
		Title:       "Targets & Tracks mirrors",
		Description: "Mirrors targets and tracks into the vault as long-lived entities, tracking their open loops.",
	},
	{
		Key:         "memory.sources.jira",
		Title:       "Jira source",
		Description: "Builds memory episodes from Jira issues, mechanically.",
	},
	{
		Key:         "memory.surfaces.chat",
		Title:       "Chat surface",
		Description: "Injects relevant memory into the Discuss chat prompt and captures your replies there as new evidence.",
	},
	{
		Key:         "memory.surfaces.briefing",
		Title:       "Briefing surface",
		Description: "Adds a Memory revisions journal to the daily briefing, noting notable belief changes.",
	},
	{
		Key:         "memory.surfaces.disputes",
		Title:       "Disputes surface",
		Description: "Surfaces contradicted beliefs as Dashboard situations so you can resolve them.",
	},
	{
		Key:         "memory.surfaces.reflection",
		Title:       "Reflection surface",
		Description: "Runs a weekly pass over the vault's history to flag beliefs that keep flip-flopping.",
	},
	{
		Key:         "memory.surfaces.day_plan",
		Title:       "Day Plan surface",
		Description: "Feeds the day plan's backlog from memory's open loops.",
	},
	{
		Key:         "memory.surfaces.meeting_prep",
		Title:       "Meeting Prep surface",
		Description: "Feeds meeting prep with attendee background and beliefs from memory.",
	},
}

// All returns every registry entry in stable order: core entries first, then
// the pillars in spec table order.
func All() []Feature {
	out := make([]Feature, len(registry))
	copy(out, registry)
	return out
}

// ByID looks up a single entry by its stable id.
func ByID(id string) (Feature, bool) {
	for _, f := range registry {
		if f.ID == id {
			return f, true
		}
	}
	return Feature{}, false
}

// Dependents returns the transitive, currently-enabled features reachable
// from id via FeedsInto edges, in registry order, excluding id itself. It is
// the input for the CLI/Desktop cascade dialog: "disabling id also affects
// these currently-live features."
//
// Traversal only continues through a node that is itself enabled: a
// disabled (or nil-Enabled) node is not currently forwarding anything to its
// own dependents, so BFS stops there instead of reporting a feature that
// would in fact be unaffected (e.g. day-plan is only reachable through
// memory — while memory is off, disabling an ancestor of memory must not
// claim day-plan as a dependent).
func Dependents(id string, cfg *config.Config) []Feature {
	start, ok := ByID(id)
	if !ok {
		return nil
	}

	visited := map[string]bool{id: true}
	included := map[string]bool{}
	queue := append([]string{}, start.FeedsInto...)

	for len(queue) > 0 {
		next := queue[0]
		queue = queue[1:]
		if visited[next] {
			continue
		}
		visited[next] = true

		f, ok := ByID(next)
		if !ok || f.Enabled == nil || !f.Enabled(cfg) {
			continue
		}
		included[next] = true
		queue = append(queue, f.FeedsInto...)
	}

	var out []Feature
	for _, f := range registry {
		if included[f.ID] {
			out = append(out, f)
		}
	}
	return out
}
