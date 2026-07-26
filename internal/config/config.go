// Package config manages watchtower configuration loading and management.
package config

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/spf13/viper"
)

type WorkspaceConfig struct {
	SlackToken string `mapstructure:"slack_token"`
}

type AIConfig struct {
	Model         string `mapstructure:"model"`
	ContextBudget int    `mapstructure:"context_budget"`
	Workers       int    `mapstructure:"workers"`  // max parallel LLM calls across all pipelines
	Provider      string `mapstructure:"provider"` // "claude" (default) | "codex"
}

type SyncConfig struct {
	Workers            int           `mapstructure:"workers"`
	InitialHistoryDays int           `mapstructure:"initial_history_days"`
	PollInterval       time.Duration `mapstructure:"poll_interval"`
	SyncThreads        bool          `mapstructure:"sync_threads"`
	SyncOnWake         bool          `mapstructure:"sync_on_wake"`
}

type DigestConfig struct {
	Enabled          bool          `mapstructure:"enabled"`
	MinMessages      int           `mapstructure:"min_messages"`
	Language         string        `mapstructure:"language"`
	Workers          int           `mapstructure:"workers"`
	TracksInterval   time.Duration `mapstructure:"action_items_interval"` // YAML key kept for backward compat
	BatchMaxChannels int           `mapstructure:"batch_max_channels"`
	BatchMaxMessages int           `mapstructure:"batch_max_messages"`
}

// BriefingConfig holds settings for the daily briefing pipeline.
type BriefingConfig struct {
	Enabled bool `mapstructure:"enabled"` // enable daily briefings (default: true)
	Hour    int  `mapstructure:"hour"`    // hour of day to generate (0-23, default: 8)
}

// InboxConfig holds settings for the inbox detection pipeline.
type InboxConfig struct {
	Enabled             bool `mapstructure:"enabled"`               // enable inbox detection (default: true)
	MaxItemsPerRun      int  `mapstructure:"max_items_per_run"`     // max candidates per run (default: 100)
	InitialLookbackDays int  `mapstructure:"initial_lookback_days"` // days to look back on first run (default: 7)
	MaxTriageMessages   int  `mapstructure:"max_triage_messages"`   // max stream messages scanned per triage cycle (default: 600)
	MaxAwarenessCards   int  `mapstructure:"max_awareness_cards"`   // max ambient items given a secretary card per cycle (default: 3)
}

// FeedConfig holds settings for the dashboard feed publisher (internal/feed).
type FeedConfig struct {
	Enabled            bool `mapstructure:"enabled"`              // enable feed publishing (default: true)
	MeetingLeadMinutes int  `mapstructure:"meeting_lead_minutes"` // minutes before start a meeting enters the feed (default: 30)
}

// DashboardConfig holds settings for the secretary dashboard's situation
// composer (internal/inbox/compose.go).
type DashboardConfig struct {
	StaleAfterDays    int `mapstructure:"stale_after_days"`    // days of inactivity before an open situation is marked stale (default: 7)
	MaxComposeSignals int `mapstructure:"max_compose_signals"` // max uncomposed signals considered per compose cycle (default: 200)
}

// CatchupConfig controls the on-demand unread summarizer.
type CatchupConfig struct {
	MaxAgeDays int         `mapstructure:"max_age_days"`
	Caps       CatchupCaps `mapstructure:"caps"`
}

// CatchupCaps bounds how many unread items per area feed the AI rollup.
type CatchupCaps struct {
	Digests   int `mapstructure:"digests"`
	Tracks    int `mapstructure:"tracks"`
	Inbox     int `mapstructure:"inbox"`
	Briefings int `mapstructure:"briefings"`
}

// TracksConfig holds settings for the tracks extraction pipeline.
type TracksConfig struct {
	MinMessages int `mapstructure:"min_messages"` // minimum visible messages for individual processing (default: 3)
}

// CalendarConfig holds Google Calendar integration settings.
type CalendarConfig struct {
	Enabled           bool     `mapstructure:"enabled"`            // enable calendar sync (default: false)
	SelectedCalendars []string `mapstructure:"selected_calendars"` // specific calendar IDs to sync
	SyncDaysAhead     int      `mapstructure:"sync_days_ahead"`    // days ahead to fetch (default: 2)
}

// GmailConfig holds Gmail integration settings.
type GmailConfig struct {
	Enabled            bool   `mapstructure:"enabled"`               // enable gmail sync (default: false)
	InitialHistoryDays int    `mapstructure:"initial_history_days"`  // days of inbox to backfill on first sync
	MaxMessagesPerSync int    `mapstructure:"max_messages_per_sync"` // per-cycle cap
	MaxBodyBytes       int    `mapstructure:"max_body_bytes"`        // truncate body_text beyond this
	AccountEmail       string `mapstructure:"account_email"`         // connected account's email, written at login; identity fallback when Slack is absent
}

// JiraFeatureToggles controls which Jira features are enabled for the user.
type JiraFeatureToggles struct {
	MyIssuesInBriefing   bool `mapstructure:"my_issues_in_briefing" json:"my_issues_in_briefing"`
	AwaitingMyInput      bool `mapstructure:"awaiting_my_input" json:"awaiting_my_input"`
	WhoPing              bool `mapstructure:"who_ping" json:"who_ping"`
	TrackJiraLinking     bool `mapstructure:"track_jira_linking" json:"track_jira_linking"`
	TeamWorkload         bool `mapstructure:"team_workload" json:"team_workload"`
	BlockerMap           bool `mapstructure:"blocker_map" json:"blocker_map"`
	IterationProgress    bool `mapstructure:"iteration_progress" json:"iteration_progress"`
	EpicProgress         bool `mapstructure:"epic_progress" json:"epic_progress"`
	WriteBackSuggestions bool `mapstructure:"write_back_suggestions" json:"write_back_suggestions"`
	ReleaseDashboard     bool `mapstructure:"release_dashboard" json:"release_dashboard"`
	WithoutJiraDetection bool `mapstructure:"without_jira_detection" json:"without_jira_detection"`
}

// JiraConfig holds Jira Cloud integration settings.
type JiraConfig struct {
	Enabled          bool               `mapstructure:"enabled"`
	CloudID          string             `mapstructure:"cloud_id"`
	SiteURL          string             `mapstructure:"site_url"`
	UserDisplayName  string             `mapstructure:"user_display_name"`
	SelectedBoards   []int              `mapstructure:"selected_boards"`
	SyncIntervalMins int                `mapstructure:"sync_interval_mins"`
	UserMap          map[string]string  `mapstructure:"user_map"`
	Features         JiraFeatureToggles `mapstructure:"features"`
}

// AnalysisConfig holds settings for the people analysis pipeline.
type AnalysisConfig struct {
	LegacyMode bool `mapstructure:"legacy_mode"` // enable legacy people analytics (default: false)
}

// TargetsExtractConfig holds settings for the targets extraction phase.
type TargetsExtractConfig struct {
	Enabled        bool   `mapstructure:"enabled"`
	MaxPerCall     int    `mapstructure:"max_per_call"`
	TimeoutSeconds int    `mapstructure:"timeout_seconds"`
	Model          string `mapstructure:"model"`
}

// TargetsResolverConfig holds settings for the targets resolver phase.
type TargetsResolverConfig struct {
	SlackEnabled        bool `mapstructure:"slack_enabled"`
	JiraEnabled         bool `mapstructure:"jira_enabled"`
	MCPTimeoutSeconds   int  `mapstructure:"mcp_timeout_seconds"`
	ActiveSnapshotLimit int  `mapstructure:"active_snapshot_limit"`
}

// TargetsConfig holds settings for the targets extraction and resolution pipeline.
type TargetsConfig struct {
	Extract  TargetsExtractConfig  `mapstructure:"extract"`
	Resolver TargetsResolverConfig `mapstructure:"resolver"`
}

// TranscriptsConfig holds settings for meeting transcript storage.
type TranscriptsConfig struct {
	AudioRetentionDays int    `mapstructure:"audio_retention_days"` // delete recording audio after N days (default 30); transcript text is kept forever
	RecordingsDir      string `mapstructure:"recordings_dir"`       // directory the Desktop recorder writes rec_* files into; empty → the default computed by Config.RecordingsDir
}

// DayPlanConfig holds settings for the daily plan generation pipeline.
type DayPlanConfig struct {
	Enabled           bool   `yaml:"enabled" mapstructure:"enabled"`
	Hour              int    `yaml:"hour" mapstructure:"hour"`
	WorkingHoursStart string `yaml:"working_hours_start" mapstructure:"working_hours_start"`
	WorkingHoursEnd   string `yaml:"working_hours_end" mapstructure:"working_hours_end"`
	MaxTimeblocks     int    `yaml:"max_timeblocks" mapstructure:"max_timeblocks"`
	MinBacklog        int    `yaml:"min_backlog" mapstructure:"min_backlog"`
	MaxBacklog        int    `yaml:"max_backlog" mapstructure:"max_backlog"`
}

// MemoryConfig holds settings for the secretary memory consolidation
// pipeline (internal/memory).
type MemoryConfig struct {
	Enabled              bool                 `mapstructure:"enabled"`                 // enable memory consolidation (default: false — off until the feature settles)
	MaxChunkMessages     int                  `mapstructure:"max_chunk_messages"`      // max raw messages consumed per consolidation run (default: 2000)
	SeedMinMessages      int                  `mapstructure:"seed_min_messages"`       // messages in the last 30 days before a person is seeded as an entity (default: 20)
	MaxEpisodesPerWindow int                  `mapstructure:"max_episodes_per_window"` // episode cap per channel window in the extractor (default: 5)
	MaxWindowMessages    int                  `mapstructure:"max_window_messages"`     // max messages per extraction window; a busier channel forms multiple sequential windows (default: 200)
	BatchMaxChannels     int                  `mapstructure:"batch_max_channels"`      // max channel windows grouped into one extraction call (default: 20, digest-pipeline precedent)
	BatchMaxMessages     int                  `mapstructure:"batch_max_messages"`      // max total messages grouped into one extraction call (default: 1500)
	Semantic             MemorySemanticConfig `mapstructure:"semantic"`                // Phase-3 semantic tier (belief/rewrite/dedupe/evict/concept steps), dark by default
	Surfaces             MemorySurfacesConfig `mapstructure:"surfaces"`                // Phase-4 surfaces (chat/briefing/disputes/reflection), each dark by default
	Sources              MemorySourcesConfig  `mapstructure:"sources"`                 // Phase-5 slice-1 sources (gmail/actions), each dark by default
	Renders              MemoryRendersConfig  `mapstructure:"renders"`                 // Phase-5 slice-3 renders (digest_compare), dark by default
	Retrieve             MemoryRetrieveConfig `mapstructure:"retrieve"`                // Phase-5 Slice B dark retrieval-compare (recall/briefing/meeting_prep), each dark by default
	Focus                MemoryFocusConfig    `mapstructure:"focus"`                   // focus-salience Run step (fingerprint-gated memory_focus_matches rewrite + whole-vault importance sweep), dark by default
}

// MemorySemanticConfig gates and bounds the Phase-3 semantic tier: the
// strong-tier entity rewrites, belief revision, and strong world-map render,
// plus the mechanical dedupe/concept-promotion/eviction steps. Every step is a
// no-op unless Enabled is true, so phases 0–2 keep running alone by default.
// All caps are per consolidation run.
type MemorySemanticConfig struct {
	Enabled            bool `mapstructure:"enabled"`              // enable the semantic tier (default: false)
	RewriteMaxEntities int  `mapstructure:"rewrite_max_entities"` // max entity pages rewritten per run (default: 10)
	BeliefsMax         int  `mapstructure:"beliefs_max"`          // max belief ops applied per run (default: 20)
	DedupeMaxMerges    int  `mapstructure:"dedupe_max_merges"`    // max episode merges per run (default: 20)
	AgeAfterDays       int  `mapstructure:"age_after_days"`       // active short non-situation episodes whose newest event is older than this age to closed+long (default: 14)
	EvictAfterDays     int  `mapstructure:"evict_after_days"`     // closed long episodes older than this are eviction candidates (default: 45)
	EvictMax           int  `mapstructure:"evict_max"`            // max episodes evicted per run (default: 50)
	ConceptMinEpisodes int  `mapstructure:"concept_min_episodes"` // distinct-episode recurrence before a hint is promoted (default: 5)
	ConceptMaxCreate   int  `mapstructure:"concept_max_create"`   // max concept entities created per run (default: 10)
	OutputBudget       int  `mapstructure:"output_budget"`        // stop launching further strong-tier AI steps once the run's output tokens exceed this (default: 200000)
	Preferences        bool `mapstructure:"preferences"`          // Phase-5 slice-4: gate the OWNER ACTIONS block in the belief pass, forming preference beliefs from staged owner-action evidence (default: false)
}

// MemorySurfacesConfig gates the four Phase-4 memory surfaces independently —
// each is a no-op when its flag is off, so the four have independent blast
// radii. All default false (dark by default).
type MemorySurfacesConfig struct {
	Chat        bool `mapstructure:"chat"`         // Discuss chat MEMORY block + ingestChatStatements owner-evidence minting (default: false)
	Briefing    bool `mapstructure:"briefing"`     // daily briefing "Memory revisions" journal block (default: false)
	Disputes    bool `mapstructure:"disputes"`     // inbox watchtower detector surfaces dispute_pending beliefs as dashboard situations (default: false)
	Reflection  bool `mapstructure:"reflection"`   // weekly strong-tier reflection pass over vault git history (default: false)
	DayPlan     bool `mapstructure:"day_plan"`     // Phase-5 slice-4: day plan reads open loops from memory entity mirrors (default: false)
	MeetingPrep bool `mapstructure:"meeting_prep"` // Phase-5 slice-4: meeting prep reads attendee entity pages + beliefs from memory (default: false)
}

// MemorySourcesConfig gates the two Phase-5 slice-1 memory sources
// independently — each gated path is a byte-identical no-op when its flag is
// off, and the two flags have independent blast radii from each other AND from
// Semantic.Enabled/Surfaces.*. This independence is literal: Gmail gates BOTH the
// thread->episode extractor AND sender->person seeding, and Actions runs the
// mechanical interaction ingest as its OWN Run step (not a semantic sub-step), so
// its annotations + engagement land even with the semantic tier off (the staged
// act: refs are simply unused then). All default false (dark by default).
type MemorySourcesConfig struct {
	Gmail       bool `mapstructure:"gmail"`       // Gmail thread->episode extractor + sender->person seeding (default: false)
	Actions     bool `mapstructure:"actions"`     // mechanical interaction ingest (owner-action evidence, engagement aggregates), its own Run step (default: false)
	Calendar    bool `mapstructure:"calendar"`    // Phase-5 slice-2: mechanical past-event->episode builder + recurring-series seeding (default: false)
	Chats       bool `mapstructure:"chats"`       // Phase-5 slice-2: generalizes internal-dialogs ingest to target/track Discuss chats + the "remember this" command (default: false)
	Operational bool `mapstructure:"operational"` // Phase-5 slice-4: mechanical target/track entity mirrors in the vault (target:<id>/track:<id>), its own Run step (default: false)
	Jira        bool `mapstructure:"jira"`        // mechanical jira issue->episode builder + jira: provenance scheme, its own Run step (default: false)
}

// MemoryRendersConfig gates the Phase-5 slice-3 render-inversion steps
// independently. Each is a no-op when its flag is off. All default false
// (dark by default).
type MemoryRendersConfig struct {
	DigestCompare bool `mapstructure:"digest_compare"` // dark compare-mode: render channel digests from memory episodes and diff against the legacy digest pipeline (default: false)
}

// MemoryRetrieveConfig gates the Phase-5 Slice-B dark retrieval-compare mode
// independently per surface — each is a no-op when its flag is off, mirroring
// Renders.DigestCompare's precedent. All default false (dark by default).
// Unlike Renders.DigestCompare (one daemon-tail batch job), these three run
// inline at each surface's own live call site (memory_recall's MCP handler,
// briefing's gatherMemoryRevisions, meeting-prep's gatherMemoryContext) —
// there is no cost concern requiring a daemon-cycle gate, since none of the
// three retrieval functions makes an AI call.
type MemoryRetrieveConfig struct {
	RecallCompare      bool `mapstructure:"recall_compare"`       // memory_recall MCP tool also runs RetrieveByQuery and shadow-diffs against the legacy FTS ranking (default: false)
	BriefingCompare    bool `mapstructure:"briefing_compare"`     // briefing's Memory revisions journal also runs RetrieveRevisions and shadow-diffs against the legacy notable-revision order (default: false)
	MeetingPrepCompare bool `mapstructure:"meeting_prep_compare"` // meeting-prep's attendee memory context also runs RetrieveBySubject and shadow-diffs against the legacy confidence-ordered belief selection (default: false)
}

// MemoryFocusConfig gates the focus-salience Run step independently. When
// Enabled is false, focus.md (internal/memory/focus.go) is never parsed —
// but the gate-off path still runs runFocusDisable, which neutralizes any
// residual memory_focus_matches rows / boosted importance_scores left over
// from a prior enabled run whenever the stored fingerprint is non-empty; it
// is a fast no-op (no DB write at all) only once that fingerprint is already
// empty, i.e. a workspace that never had focus enabled, or one already
// neutralized by an earlier disabled run. Default false (dark by default).
type MemoryFocusConfig struct {
	Enabled bool `mapstructure:"enabled"` // enable the focus-salience Run step: fingerprint-gated memory_focus_matches rewrite + whole-vault importance sweep (default: false)
}

type Config struct {
	ActiveWorkspace string                      `mapstructure:"active_workspace"`
	Workspaces      map[string]*WorkspaceConfig `mapstructure:"workspaces"`
	AI              AIConfig                    `mapstructure:"ai"`
	Sync            SyncConfig                  `mapstructure:"sync"`
	Digest          DigestConfig                `mapstructure:"digest"`
	Briefing        BriefingConfig              `mapstructure:"briefing"`
	Inbox           InboxConfig                 `mapstructure:"inbox"`
	Feed            FeedConfig                  `mapstructure:"feed"`
	Dashboard       DashboardConfig             `mapstructure:"dashboard"`
	Tracks          TracksConfig                `mapstructure:"tracks"`
	Calendar        CalendarConfig              `mapstructure:"calendar"`
	Gmail           GmailConfig                 `mapstructure:"gmail"`
	Jira            JiraConfig                  `mapstructure:"jira"`
	Analysis        AnalysisConfig              `mapstructure:"analysis"`
	DayPlan         DayPlanConfig               `mapstructure:"day_plan"`
	Memory          MemoryConfig                `mapstructure:"memory"`
	Targets         TargetsConfig               `mapstructure:"targets"`
	Transcripts     TranscriptsConfig           `mapstructure:"transcripts"`
	Catchup         CatchupConfig               `mapstructure:"catchup"`
	DB              DBConfig                    `mapstructure:"db"`
	ClaudePath      string                      `mapstructure:"claude_path"`
	CodexPath       string                      `mapstructure:"codex_path"`
}

// DBConfig captures database-runtime state that the binary tracks across
// installs. Currently only schema_format, bumped when the migration engine
// is replaced (legacy PRAGMA → goose). The runtime triggers a one-shot
// upgrade when the on-disk value is below db.CurrentSchemaFormat.
type DBConfig struct {
	SchemaFormat int `mapstructure:"schema_format"`
}

// Load reads config from the given path, binds env vars, and returns the config.
func Load(configPath string) (*Config, error) {
	v := viper.New()

	// Defaults
	v.SetDefault("active_workspace", DefaultActiveWorkspace)
	v.SetDefault("ai.provider", DefaultAIProvider)
	v.SetDefault("ai.model", DefaultAIModel)
	v.SetDefault("ai.context_budget", DefaultAIContextBudget)
	v.SetDefault("ai.workers", DefaultAIWorkers)
	v.SetDefault("sync.workers", DefaultSyncWorkers)
	v.SetDefault("sync.initial_history_days", DefaultInitialHistDays)
	v.SetDefault("sync.poll_interval", DefaultPollInterval)
	v.SetDefault("sync.sync_threads", DefaultSyncThreads)
	v.SetDefault("sync.sync_on_wake", DefaultSyncOnWake)
	v.SetDefault("digest.enabled", DefaultDigestEnabled)
	v.SetDefault("digest.min_messages", DefaultDigestMinMsgs)
	v.SetDefault("digest.language", DefaultDigestLang)
	v.SetDefault("digest.workers", DefaultDigestWorkers)
	v.SetDefault("digest.action_items_interval", DefaultTracksInterval)
	v.SetDefault("digest.batch_max_channels", DefaultBatchMaxChannels)
	v.SetDefault("digest.batch_max_messages", DefaultBatchMaxMessages)
	v.RegisterAlias("digest.tracks_interval", "digest.action_items_interval")
	v.SetDefault("briefing.enabled", DefaultBriefingEnabled)
	v.SetDefault("briefing.hour", DefaultBriefingHour)
	v.SetDefault("inbox.enabled", DefaultInboxEnabled)
	v.SetDefault("inbox.max_items_per_run", DefaultInboxMaxItems)
	v.SetDefault("inbox.initial_lookback_days", DefaultInboxLookbackDays)
	v.SetDefault("inbox.max_triage_messages", DefaultInboxMaxTriageMessages)
	v.SetDefault("inbox.max_awareness_cards", DefaultInboxMaxAwarenessCards)
	v.SetDefault("feed.enabled", true)
	v.SetDefault("feed.meeting_lead_minutes", DefaultFeedMeetingLeadMinutes)
	v.SetDefault("dashboard.stale_after_days", DefaultDashboardStaleAfterDays)
	v.SetDefault("dashboard.max_compose_signals", DefaultDashboardMaxComposeSignals)
	v.SetDefault("tracks.min_messages", DefaultTracksMinMsgs)
	v.SetDefault("catchup.max_age_days", 30)
	v.SetDefault("catchup.caps.digests", 150)
	v.SetDefault("catchup.caps.tracks", 80)
	v.SetDefault("catchup.caps.inbox", 120)
	v.SetDefault("catchup.caps.briefings", 20)
	v.SetDefault("calendar.enabled", DefaultCalendarEnabled)
	v.SetDefault("calendar.sync_days_ahead", DefaultCalendarSyncDaysAhead)
	v.SetDefault("gmail.enabled", DefaultGmailEnabled)
	v.SetDefault("gmail.initial_history_days", DefaultGmailInitialHistoryDays)
	v.SetDefault("gmail.max_messages_per_sync", DefaultGmailMaxMessagesPerSync)
	v.SetDefault("gmail.max_body_bytes", DefaultGmailMaxBodyBytes)
	v.SetDefault("jira.enabled", DefaultJiraEnabled)
	v.SetDefault("jira.sync_interval_mins", DefaultJiraSyncIntervalMins)
	v.SetDefault("day_plan.enabled", DefaultDayPlanEnabled)
	v.SetDefault("day_plan.hour", DefaultDayPlanHour)
	v.SetDefault("day_plan.working_hours_start", DefaultDayPlanWorkingHoursStart)
	v.SetDefault("day_plan.working_hours_end", DefaultDayPlanWorkingHoursEnd)
	v.SetDefault("day_plan.max_timeblocks", DefaultDayPlanMaxTimeblocks)
	v.SetDefault("day_plan.min_backlog", DefaultDayPlanMinBacklog)
	v.SetDefault("day_plan.max_backlog", DefaultDayPlanMaxBacklog)
	v.SetDefault("memory.enabled", false) // off by default until the feature settles
	v.SetDefault("memory.max_chunk_messages", 2000)
	v.SetDefault("memory.seed_min_messages", 20)
	v.SetDefault("memory.max_episodes_per_window", 5)
	v.SetDefault("memory.max_window_messages", 200)
	v.SetDefault("memory.batch_max_channels", DefaultBatchMaxChannels)
	v.SetDefault("memory.batch_max_messages", DefaultBatchMaxMessages)
	v.SetDefault("memory.semantic.enabled", false) // semantic tier dark by default
	v.SetDefault("memory.semantic.rewrite_max_entities", 10)
	v.SetDefault("memory.semantic.beliefs_max", 20)
	v.SetDefault("memory.semantic.dedupe_max_merges", 20)
	v.SetDefault("memory.semantic.age_after_days", 14)
	v.SetDefault("memory.semantic.evict_after_days", 45)
	v.SetDefault("memory.semantic.evict_max", 50)
	v.SetDefault("memory.semantic.concept_min_episodes", 5)
	v.SetDefault("memory.semantic.concept_max_create", 10)
	v.SetDefault("memory.semantic.output_budget", 200000)
	v.SetDefault("memory.surfaces.chat", false) // Phase-4 surfaces dark by default
	v.SetDefault("memory.surfaces.briefing", false)
	v.SetDefault("memory.surfaces.disputes", false)
	v.SetDefault("memory.surfaces.reflection", false)
	v.SetDefault("memory.sources.gmail", false) // Phase-5 slice-1 sources dark by default
	v.SetDefault("memory.sources.actions", false)
	v.SetDefault("memory.sources.calendar", false) // Phase-5 slice-2 sources dark by default
	v.SetDefault("memory.sources.chats", false)
	v.SetDefault("memory.renders.digest_compare", false) // Phase-5 slice-3 renders dark by default
	v.SetDefault("memory.sources.operational", false)    // Phase-5 slice-4 gates dark by default
	v.SetDefault("memory.surfaces.day_plan", false)
	v.SetDefault("memory.surfaces.meeting_prep", false)
	v.SetDefault("memory.semantic.preferences", false)
	v.SetDefault("memory.retrieve.recall_compare", false) // Slice B dark retrieval-compare, dark by default
	v.SetDefault("memory.retrieve.briefing_compare", false)
	v.SetDefault("memory.retrieve.meeting_prep_compare", false)
	v.SetDefault("memory.focus.enabled", false) // focus-salience Run step dark by default
	v.SetDefault("targets.extract.enabled", DefaultTargetsExtractEnabled)
	v.SetDefault("targets.extract.max_per_call", DefaultTargetsExtractMaxPerCall)
	v.SetDefault("targets.extract.timeout_seconds", DefaultTargetsExtractTimeoutSeconds)
	v.SetDefault("targets.extract.model", DefaultTargetsExtractModel)
	v.SetDefault("targets.resolver.slack_enabled", DefaultTargetsResolverSlackEnabled)
	v.SetDefault("targets.resolver.jira_enabled", DefaultTargetsResolverJiraEnabled)
	v.SetDefault("targets.resolver.mcp_timeout_seconds", DefaultTargetsResolverMCPTimeoutSeconds)
	v.SetDefault("targets.resolver.active_snapshot_limit", DefaultTargetsResolverActiveSnapshotLimit)
	v.SetDefault("transcripts.audio_retention_days", DefaultTranscriptAudioRetentionDays)
	// db.schema_format defaults to 1 (legacy PRAGMA-based) so that any
	// existing install triggers the one-shot upgrade on first run of the
	// goose-based binary. cmd/root.go bumps it to db.CurrentSchemaFormat
	// after RunSchemaUpgrade succeeds.
	v.SetDefault("db.schema_format", 1)
	// Config file
	v.SetConfigFile(configPath)

	if err := v.ReadInConfig(); err != nil {
		// Missing config file is OK — use defaults
		var configNotFound viper.ConfigFileNotFoundError
		if !errors.As(err, &configNotFound) && !os.IsNotExist(err) {
			return nil, fmt.Errorf("reading config: %w", err)
		}
	}

	// Env var bindings
	v.SetEnvPrefix("WATCHTOWER")
	v.AutomaticEnv()
	v.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))

	// Explicit bindings for key env vars
	_ = v.BindEnv("ai.model", "WATCHTOWER_AI_MODEL")
	_ = v.BindEnv("ai.workers", "WATCHTOWER_AI_WORKERS")
	_ = v.BindEnv("sync.workers", "WATCHTOWER_SYNC_WORKERS")

	cfg := &Config{}
	if err := v.Unmarshal(cfg); err != nil {
		return nil, fmt.Errorf("unmarshaling config: %w", err)
	}

	// Backward compat: migrate digest.workers → ai.workers.
	// If user has digest.workers in config but hasn't set ai.workers explicitly,
	// use digest.workers as the pool size.
	if cfg.Digest.Workers > 0 && !v.InConfig("ai.workers") && os.Getenv("WATCHTOWER_AI_WORKERS") == "" {
		cfg.AI.Workers = cfg.Digest.Workers
	}

	// Bind workspace-level slack token from env
	if token := os.Getenv("WATCHTOWER_SLACK_TOKEN"); token != "" && cfg.ActiveWorkspace != "" {
		if cfg.Workspaces == nil {
			cfg.Workspaces = make(map[string]*WorkspaceConfig)
		}
		ws, ok := cfg.Workspaces[cfg.ActiveWorkspace]
		if !ok {
			ws = &WorkspaceConfig{}
			cfg.Workspaces[cfg.ActiveWorkspace] = ws
		}
		if ws.SlackToken == "" {
			ws.SlackToken = token
		}
	}

	return cfg, nil
}

// ValidWorkspaceRe matches valid workspace names: alphanumeric start, followed by
// alphanumerics, hyphens, dots, or underscores.
var ValidWorkspaceRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`)

// ValidateWorkspace checks that a workspace name is set and safe for use in
// file paths. It does NOT require a Slack token or workspace config entry,
// making it suitable for commands that only need database access.
func (c *Config) ValidateWorkspace() error {
	if c.ActiveWorkspace == "" {
		return fmt.Errorf("active_workspace is required; run 'watchtower config init' first")
	}
	if !ValidWorkspaceRe.MatchString(c.ActiveWorkspace) {
		return fmt.Errorf("invalid workspace name %q: must contain only alphanumeric characters, hyphens, dots, and underscores", c.ActiveWorkspace)
	}
	return nil
}

// Validate checks that required fields are present, including Slack token.
// Use ValidateWorkspace for commands that only need database access.
func (c *Config) Validate() error {
	if err := c.ValidateWorkspace(); err != nil {
		return err
	}
	ws, err := c.GetActiveWorkspace()
	if err != nil {
		return err
	}
	if ws.SlackToken == "" {
		return fmt.Errorf("slack_token is required for workspace %q", c.ActiveWorkspace)
	}
	if !isValidSlackToken(ws.SlackToken) {
		return fmt.Errorf("slack_token for workspace %q has invalid format (expected xoxp-*, xoxb-*, xoxa-*, or xoxe.*)", c.ActiveWorkspace)
	}
	return nil
}

// isValidSlackToken checks that the token has a recognized Slack token prefix.
func isValidSlackToken(token string) bool {
	validPrefixes := []string{"xoxp-", "xoxb-", "xoxa-", "xoxe.xoxp-", "xoxe."}
	for _, p := range validPrefixes {
		if strings.HasPrefix(token, p) {
			return true
		}
	}
	return false
}

// GetActiveWorkspace returns the config for the active workspace.
func (c *Config) GetActiveWorkspace() (*WorkspaceConfig, error) {
	if c.ActiveWorkspace == "" {
		return nil, fmt.Errorf("no active workspace set")
	}
	ws, ok := c.Workspaces[c.ActiveWorkspace]
	if !ok {
		return nil, fmt.Errorf("workspace %q not found in config", c.ActiveWorkspace)
	}
	return ws, nil
}

// WorkspaceDir returns the data directory for the active workspace
// (~/.local/share/watchtower/{workspace}/).
func (c *Config) WorkspaceDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		// Fatal: storing sensitive data in a temp dir is unsafe.
		log.Fatalf("could not determine home directory: %v", err)
	}
	return filepath.Join(home, ".local", "share", "watchtower", c.ActiveWorkspace)
}

// DBPath returns the path to the SQLite database for the active workspace.
func (c *Config) DBPath() string {
	return filepath.Join(c.WorkspaceDir(), "watchtower.db")
}

// RecordingsDir returns the meeting-recording directory scanned by the daemon
// orphan cleanup: transcripts.recordings_dir when set, otherwise the Swift
// recorder's default location ($HOME/Library/Application Support/Watchtower/
// recordings, cf. MeetingRecorderCenter.recordingsDirectory). Returns "" when
// the home directory cannot be determined.
func (c *Config) RecordingsDir() string {
	if c.Transcripts.RecordingsDir != "" {
		return c.Transcripts.RecordingsDir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "Watchtower", "recordings")
}
