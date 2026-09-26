package config

import (
	"reflect"
	"time"

	"github.com/spf13/viper"
)

const (
	DefaultActiveWorkspace = ""
	DefaultAIProvider      = "claude"
	// DefaultAIModel is retired as a live default: setup used to seed this
	// literal into config.yaml, so resolution treats a legacy ai.model equal to
	// it as "unset" (see internal/providers.ResolveModelsFor). Do not repoint it.
	DefaultAIModel         = "claude-sonnet-4-6"
	DefaultOllamaURL       = "http://localhost:11434"
	DefaultAIContextBudget = 150000
	DefaultAIWorkers       = 5
	DefaultSyncWorkers     = 1
	// DefaultInitialHistDays bounds the Slack search-sync window on a true
	// first run only (an account with no search_last_date watermark yet).
	// Once a watermark exists, catch-up depth is governed by
	// sync.maxSearchCatchUpDays instead — see internal/sync/search_sync.go.
	DefaultInitialHistDays   = 2
	DefaultPollInterval      = 15 * time.Minute
	DefaultSyncThreads       = true
	DefaultSyncOnWake        = true
	DefaultDigestEnabled     = true
	DefaultDigestMinMsgs     = 10
	DefaultDigestLang        = "Russian"
	DefaultDigestWorkers     = 5 // Deprecated: use DefaultAIWorkers. Kept for backward compat.
	DefaultTracksInterval    = 1 * time.Hour
	DefaultBriefingEnabled   = true
	DefaultBriefingHour      = 8
	DefaultInboxEnabled      = true
	DefaultInboxMaxItems     = 100
	DefaultInboxLookbackDays = 7

	// DefaultKnowledgeEnabled gates the knowledge-search index. Mechanical
	// (no AI), on by default.
	DefaultKnowledgeEnabled = true

	// Ideas & decisions registry defaults
	DefaultIdeasEnabled                 = true
	DefaultIdeasMineIntervalHours       = 6
	DefaultIdeasMaxCommentIssuesPerSync = 50
	DefaultIdeasMaxPromptChars          = 60000

	// Streams config defaults (stage-1 Gmail/Jira stream pre-digests)
	DefaultStreamsEnabled       = true
	DefaultStreamsIntervalHours = 6

	// Reaction-commands defaults (owner drives Watchtower via Slack reactions).
	// ON by default since 2026-09-26 (owner call): safe because the poll seeds
	// an account's pre-existing reaction history on its first poll instead of
	// dispatching it (internal/reactioncmd, FEAT-03). Interval 0 = no throttle,
	// poll every daemon cycle — a reaction is a command the owner is waiting
	// on, and the poll is one cheap reactions.list call; only the dispatch of
	// a NEW reaction costs an AI call.
	DefaultReactionCommandsEnabled       = true
	DefaultReactionCommandsIntervalHours = 0

	// Tracks and people pipelines
	DefaultTracksEnabled          = true
	DefaultTracksMinMsgs          = 3
	DefaultPeopleEnabled          = true
	DefaultTargetsNextStepEnabled = true
	DefaultBatchMaxChannels       = 20
	DefaultBatchMaxMessages       = 1500
	DefaultMaxBatchesPerRun       = 25  // max AI calls per digest run (budget cap)
	DefaultDigestCooldownMins     = 30  // skip channel if digested < N minutes ago with few messages
	DefaultMessageTruncateLen     = 500 // truncate individual messages longer than this (chars)

	// Tiered batching thresholds (visible message count).
	DefaultBatchHighActivityThreshold = 200 // >200 → individual batch (1 channel)
	DefaultBatchLowActivityThreshold  = 30  // <30 → triple channel limit per batch

	// Calendar defaults
	DefaultCalendarEnabled       = false
	DefaultCalendarSyncDaysAhead = 7
	DefaultCalendarHistoryDays   = 14

	// Gmail defaults
	DefaultGmailEnabled            = false
	DefaultGmailInitialHistoryDays = 7
	DefaultGmailMaxMessagesPerSync = 100
	DefaultGmailMaxBodyBytes       = 51200

	// IMAP defaults (shared by every connected email_accounts row)
	DefaultImapInitialHistoryDays = 7
	DefaultImapMaxMessagesPerSync = 100
	DefaultImapMaxBodyBytes       = 51200

	// Jira defaults
	DefaultJiraEnabled          = false
	DefaultJiraSyncIntervalMins = 15

	// DefaultJiraFeaturesRole is the default role for Jira feature toggles.
	DefaultJiraFeaturesRole = "ic"

	// DayPlan defaults
	DefaultDayPlanEnabled           = true
	DefaultDayPlanHour              = 8
	DefaultDayPlanWorkingHoursStart = "09:00"
	DefaultDayPlanWorkingHoursEnd   = "19:00"
	DefaultDayPlanMaxTimeblocks     = 3
	DefaultDayPlanMinBacklog        = 3
	DefaultDayPlanMaxBacklog        = 8

	// Targets defaults
	DefaultTargetsExtractEnabled        = true
	DefaultTargetsExtractMaxPerCall     = 10
	DefaultTargetsExtractTimeoutSeconds = 0  // 0 = no deadline; extraction is user-cancellable in the Desktop capsule
	DefaultTargetsExtractModel          = "" // empty → provider default

	DefaultTargetsResolverSlackEnabled        = true
	DefaultTargetsResolverJiraEnabled         = true
	DefaultTargetsResolverMCPTimeoutSeconds   = 10
	DefaultTargetsResolverActiveSnapshotLimit = 100

	// Meeting transcripts: delete recording audio after N days (transcript
	// text is kept forever). <= 0 disables the retention phase.
	DefaultTranscriptAudioRetentionDays = 30
)

// RoleDisplayNames maps role keys to human-readable display names.
var RoleDisplayNames = map[string]string{
	"ic":                "IC",
	"senior_ic":         "Tech Lead",
	"middle_management": "EM",
	"top_management":    "Director",
	"direction_owner":   "PM",
}

// DefaultJiraFeatures returns the default feature toggles for a given role.
func DefaultJiraFeatures(role string) JiraFeatureToggles {
	switch role {
	case "senior_ic":
		return JiraFeatureToggles{
			MyIssuesInBriefing:   true,
			AwaitingMyInput:      true,
			TrackJiraLinking:     true,
			BlockerMap:           true,
			WithoutJiraDetection: true,
		}
	case "middle_management":
		return JiraFeatureToggles{
			MyIssuesInBriefing: true,
			AwaitingMyInput:    true,
			TrackJiraLinking:   true,
			TeamWorkload:       true,
			BlockerMap:         true,
			IterationProgress:  true,
		}
	case "direction_owner":
		return JiraFeatureToggles{
			TrackJiraLinking:     true,
			BlockerMap:           true,
			IterationProgress:    true,
			EpicProgress:         true,
			WithoutJiraDetection: true,
		}
	case "top_management":
		return JiraFeatureToggles{
			TrackJiraLinking:  true,
			TeamWorkload:      true,
			BlockerMap:        true,
			IterationProgress: true,
			EpicProgress:      true,
			ReleaseDashboard:  true,
		}
	default: // "ic" and any unknown role
		return JiraFeatureToggles{
			MyIssuesInBriefing: true,
			AwaitingMyInput:    true,
			TrackJiraLinking:   true,
		}
	}
}

// setJiraFeatureDefaults registers the `jira.features.*` defaults on Load's
// viper, so an absent key means the role default rather than false. Before
// this there was no default for any of the toggles: a pristine install — one
// that never ran `jira features` — had the whole Jira feature surface off,
// and the promised "defaults based on user role" never existed at all.
//
// The IC baseline is seeded, not a per-role set, and deliberately. Load has
// no DB handle, and the role lives in user_profile.role, which is FREE TEXT
// collected from an onboarding TextField placeholdered "e.g. Engineering
// Manager". The structured RoleLevel exists only in Swift
// (WatchtowerCore/Models/UserProfile.swift) and is never persisted, so
// DefaultJiraFeatures falls to its IC branch for every real user — `jira
// features reset` has always reset to IC. Seeding the IC baseline here is
// therefore not an approximation of the role default; today it IS the role
// default, for everyone. Persisting a real role level and seeding per role
// is separate work, and until it exists a connect-time writer chasing the
// role would only be a second writer of these keys for a value that does
// not exist.
//
// Registering defaults is safe only on Load's viper, which is never written
// back: a SetDefault leaks into WriteConfigAs output, so the writer vipers
// (cmd/jira.go, cmd/features.go, cmd/config.go) must stay default-free or
// role defaults get baked into the owner's file.
func setJiraFeatureDefaults(v *viper.Viper) {
	for key, value := range jiraFeatureDefaults(DefaultJiraFeaturesRole) {
		v.SetDefault("jira.features."+key, value)
	}
}

// jiraFeatureDefaults renders a role's defaults as the `jira.features.<key>`
// viper defaults Load registers. The keys are read straight off
// JiraFeatureToggles' mapstructure tags — the same tags viper decodes back
// into the struct — so a renamed or added toggle cannot leave a default
// behind under a key nothing reads, which is the failure class this whole
// repair exists to remove. A field with no mapstructure tag is skipped
// rather than registered under an empty key.
func jiraFeatureDefaults(role string) map[string]bool {
	toggles := DefaultJiraFeatures(role)
	value := reflect.ValueOf(toggles)
	typ := value.Type()

	out := make(map[string]bool, typ.NumField())
	for i := 0; i < typ.NumField(); i++ {
		key := typ.Field(i).Tag.Get("mapstructure")
		if key == "" {
			continue
		}
		out[key] = value.Field(i).Bool()
	}
	return out
}
