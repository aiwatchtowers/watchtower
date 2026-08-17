package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func writeTestConfig(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	return path
}

func TestLoad_FullConfig(t *testing.T) {
	yaml := `
active_workspace: my-company
workspaces:
  my-company:
    slack_token: "xoxp-test-token"
ai:
  model: "claude-sonnet-4-6"
  context_budget: 100000
sync:
  workers: 10
  initial_history_days: 60
  poll_interval: 30m
  sync_threads: false
  sync_on_wake: false
watch:
  channels:
    - name: "engineering"
      priority: "high"
  users:
    - name: "alice.smith"
      priority: "high"
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.Equal(t, "my-company", cfg.ActiveWorkspace)
	assert.Equal(t, "xoxp-test-token", cfg.Workspaces["my-company"].SlackToken)
	assert.Equal(t, "claude-sonnet-4-6", cfg.AI.Model)
	assert.Equal(t, 100000, cfg.AI.ContextBudget)
	assert.Equal(t, 10, cfg.Sync.Workers)
	assert.Equal(t, 60, cfg.Sync.InitialHistoryDays)
	assert.False(t, cfg.Sync.SyncThreads)
	assert.False(t, cfg.Sync.SyncOnWake)
}

func TestLoad_DefaultValues(t *testing.T) {
	path := writeTestConfig(t, "")
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.Equal(t, DefaultAIModel, cfg.AI.Model)
	assert.Equal(t, DefaultAIContextBudget, cfg.AI.ContextBudget)
	assert.Equal(t, DefaultAIWorkers, cfg.AI.Workers)
	assert.Equal(t, DefaultSyncWorkers, cfg.Sync.Workers)
	assert.Equal(t, DefaultInitialHistDays, cfg.Sync.InitialHistoryDays)
	assert.Equal(t, DefaultSyncThreads, cfg.Sync.SyncThreads)
	assert.Equal(t, DefaultSyncOnWake, cfg.Sync.SyncOnWake)

	// Catch-up gather caps feed the peel-off pool; raised so peel sees the real
	// unread backlog instead of an arbitrarily truncated slice.
	assert.Equal(t, CatchupCaps{Digests: 150, Tracks: 80, Inbox: 120, Briefings: 20}, cfg.Catchup.Caps)

	assert.Equal(t, DefaultTranscriptAudioRetentionDays, cfg.Transcripts.AudioRetentionDays)
}

func TestLoad_MissingFile(t *testing.T) {
	cfg, err := Load("/nonexistent/path/config.yaml")
	require.NoError(t, err)
	assert.Equal(t, DefaultAIModel, cfg.AI.Model)
}

func TestLoad_EnvVarOverride(t *testing.T) {
	yaml := `
active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: ""
`
	path := writeTestConfig(t, yaml)

	t.Setenv("WATCHTOWER_SLACK_TOKEN", "xoxp-from-env")

	cfg, err := Load(path)
	require.NoError(t, err)

	assert.Equal(t, "xoxp-from-env", cfg.Workspaces["test-ws"].SlackToken)
}

func TestLoad_StreamsDefaults(t *testing.T) {
	path := writeTestConfig(t, "")
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.Equal(t, DefaultStreamsEnabled, cfg.Streams.Enabled)
	assert.Equal(t, DefaultStreamsIntervalHours, cfg.Streams.IntervalHours)
}

func TestValidate_Valid(t *testing.T) {
	cfg := &Config{
		ActiveWorkspace: "test",
		Workspaces: map[string]*WorkspaceConfig{
			"test": {SlackToken: "xoxp-token"},
		},
	}
	assert.NoError(t, cfg.Validate())
}

func TestValidate_MissingActiveWorkspace(t *testing.T) {
	cfg := &Config{}
	err := cfg.Validate()
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "active_workspace is required")
}

func TestValidate_MissingWorkspaceEntry(t *testing.T) {
	cfg := &Config{
		ActiveWorkspace: "nonexistent",
		Workspaces:      map[string]*WorkspaceConfig{},
	}
	err := cfg.Validate()
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "not found")
}

func TestValidate_MissingSlackToken(t *testing.T) {
	cfg := &Config{
		ActiveWorkspace: "test",
		Workspaces: map[string]*WorkspaceConfig{
			"test": {SlackToken: ""},
		},
	}
	err := cfg.Validate()
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "slack_token is required")
}

func TestGetActiveWorkspace(t *testing.T) {
	cfg := &Config{
		ActiveWorkspace: "prod",
		Workspaces: map[string]*WorkspaceConfig{
			"prod": {SlackToken: "xoxp-prod"},
		},
	}
	ws, err := cfg.GetActiveWorkspace()
	require.NoError(t, err)
	assert.Equal(t, "xoxp-prod", ws.SlackToken)
}

func TestGetActiveWorkspace_NoActive(t *testing.T) {
	cfg := &Config{}
	_, err := cfg.GetActiveWorkspace()
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "no active workspace")
}

// TestGetActiveWorkspace_CaseInsensitiveLookup pins the fallback lookup: an
// exact-case match is preferred, but a lowercased match resolves too — the
// shape viper's Unmarshal always produces for a mixed-case workspaces key
// (insensitiviseMap lowercases nested map keys on read, unconditionally).
func TestGetActiveWorkspace_CaseInsensitiveLookup(t *testing.T) {
	cfg := &Config{
		ActiveWorkspace: "MyTeam",
		Workspaces: map[string]*WorkspaceConfig{
			"myteam": {SlackToken: "xoxp-lowercased"},
		},
	}
	ws, err := cfg.GetActiveWorkspace()
	require.NoError(t, err)
	assert.Equal(t, "xoxp-lowercased", ws.SlackToken)

	// Exact case still wins when both keys happen to exist.
	cfg.Workspaces["MyTeam"] = &WorkspaceConfig{SlackToken: "xoxp-exact"}
	ws, err = cfg.GetActiveWorkspace()
	require.NoError(t, err)
	assert.Equal(t, "xoxp-exact", ws.SlackToken)
}

// TestGetActiveWorkspace_CaseInsensitiveLookup_EndToEnd goes through the
// real Load() path (not a hand-built Config) for a mixed-case
// active_workspace/workspaces pair: viper lowercases the nested workspaces
// key on read regardless of any prior write, so before the fallback this
// case failed with "workspace not found" even on a config file MigrateFeature
// Gates never touched. WorkspaceDir must still use ActiveWorkspace's
// original casing — the lookup fallback must not leak into it.
func TestGetActiveWorkspace_CaseInsensitiveLookup_EndToEnd(t *testing.T) {
	path := writeTestConfig(t, "active_workspace: MyTeam\n"+
		"workspaces:\n"+
		"  MyTeam:\n"+
		"    slack_token: xoxb-test\n")

	cfg, err := Load(path)
	require.NoError(t, err)

	ws, err := cfg.GetActiveWorkspace()
	require.NoError(t, err)
	assert.Equal(t, "xoxb-test", ws.SlackToken)

	assert.True(t, strings.HasSuffix(cfg.WorkspaceDir(), "/MyTeam"),
		"WorkspaceDir must keep ActiveWorkspace's original casing, not the lowercased lookup key")
}

func TestDBPath(t *testing.T) {
	cfg := &Config{ActiveWorkspace: "my-company"}
	path := cfg.DBPath()
	assert.Contains(t, path, filepath.Join(".local", "share", "watchtower", "my-company", "watchtower.db"))
}

func TestLoad_PartialConfig(t *testing.T) {
	yaml := `
active_workspace: test
workspaces:
  test:
    slack_token: "xoxp-partial"
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.Equal(t, "test", cfg.ActiveWorkspace)
	assert.Equal(t, "xoxp-partial", cfg.Workspaces["test"].SlackToken)

	// Unspecified values should use defaults
	assert.Equal(t, DefaultAIModel, cfg.AI.Model)
	assert.Equal(t, DefaultSyncWorkers, cfg.Sync.Workers)
	assert.Equal(t, DefaultSyncThreads, cfg.Sync.SyncThreads)
}

func TestLoad_EnvVarOverride_AIModel(t *testing.T) {
	path := writeTestConfig(t, "")

	t.Setenv("WATCHTOWER_AI_MODEL", "claude-opus-4-6")

	cfg, err := Load(path)
	require.NoError(t, err)
	assert.Equal(t, "claude-opus-4-6", cfg.AI.Model)
}

func TestLoad_EnvVarOverride_AIWorkers(t *testing.T) {
	path := writeTestConfig(t, "")

	t.Setenv("WATCHTOWER_AI_WORKERS", "12")

	cfg, err := Load(path)
	require.NoError(t, err)
	assert.Equal(t, 12, cfg.AI.Workers)
}

func TestLoad_BackwardCompat_DigestWorkersToAIWorkers(t *testing.T) {
	yaml := `
digest:
  workers: 8
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	require.NoError(t, err)
	assert.Equal(t, 8, cfg.AI.Workers, "digest.workers should migrate to ai.workers")
}

func TestLoad_AIWorkersOverridesDigestWorkers(t *testing.T) {
	yaml := `
ai:
  workers: 10
digest:
  workers: 8
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	require.NoError(t, err)
	assert.Equal(t, 10, cfg.AI.Workers, "explicit ai.workers should take precedence")
}

func TestLoad_EnvVarOverride_Workers(t *testing.T) {
	path := writeTestConfig(t, "")

	t.Setenv("WATCHTOWER_SYNC_WORKERS", "20")

	cfg, err := Load(path)
	require.NoError(t, err)
	assert.Equal(t, 20, cfg.Sync.Workers)
}

func TestValidate_NilWorkspaces(t *testing.T) {
	cfg := &Config{
		ActiveWorkspace: "test",
		Workspaces:      nil,
	}
	err := cfg.Validate()
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "not found")
}

func TestDayPlanConfig_Defaults(t *testing.T) {
	path := writeTestConfig(t, "")
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.Equal(t, DefaultDayPlanEnabled, cfg.DayPlan.Enabled)
	assert.Equal(t, DefaultDayPlanHour, cfg.DayPlan.Hour)
	assert.Equal(t, DefaultDayPlanWorkingHoursStart, cfg.DayPlan.WorkingHoursStart)
	assert.Equal(t, DefaultDayPlanWorkingHoursEnd, cfg.DayPlan.WorkingHoursEnd)
	assert.Equal(t, DefaultDayPlanMaxTimeblocks, cfg.DayPlan.MaxTimeblocks)
	assert.Equal(t, DefaultDayPlanMinBacklog, cfg.DayPlan.MinBacklog)
	assert.Equal(t, DefaultDayPlanMaxBacklog, cfg.DayPlan.MaxBacklog)
}

func TestDayPlanConfig_FromYAML(t *testing.T) {
	yaml := `
day_plan:
  enabled: false
  hour: 7
  working_hours_start: "08:00"
  working_hours_end: "18:00"
  max_timeblocks: 5
  min_backlog: 2
  max_backlog: 10
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.False(t, cfg.DayPlan.Enabled)
	assert.Equal(t, 7, cfg.DayPlan.Hour)
	assert.Equal(t, "08:00", cfg.DayPlan.WorkingHoursStart)
	assert.Equal(t, "18:00", cfg.DayPlan.WorkingHoursEnd)
	assert.Equal(t, 5, cfg.DayPlan.MaxTimeblocks)
	assert.Equal(t, 2, cfg.DayPlan.MinBacklog)
	assert.Equal(t, 10, cfg.DayPlan.MaxBacklog)
}

func TestMemoryConfig_Defaults(t *testing.T) {
	path := writeTestConfig(t, "")
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.False(t, cfg.Memory.Enabled, "memory is off by default until the feature settles")
	assert.Equal(t, 2000, cfg.Memory.MaxChunkMessages)
	assert.Equal(t, 20, cfg.Memory.SeedMinMessages)
	assert.Equal(t, 5, cfg.Memory.MaxEpisodesPerWindow)
	assert.Equal(t, 200, cfg.Memory.MaxWindowMessages)

	// Phase-3 semantic tier: dark by default, with the documented caps.
	assert.False(t, cfg.Memory.Semantic.Enabled, "semantic tier off by default")
	assert.Equal(t, 10, cfg.Memory.Semantic.RewriteMaxEntities)
	assert.Equal(t, 20, cfg.Memory.Semantic.BeliefsMax)
	assert.Equal(t, 20, cfg.Memory.Semantic.DedupeMaxMerges)
	assert.Equal(t, 45, cfg.Memory.Semantic.EvictAfterDays)
	assert.Equal(t, 50, cfg.Memory.Semantic.EvictMax)
	assert.Equal(t, 5, cfg.Memory.Semantic.ConceptMinEpisodes)
	assert.Equal(t, 10, cfg.Memory.Semantic.ConceptMaxCreate)
	assert.Equal(t, 200000, cfg.Memory.Semantic.OutputBudget)

	// Phase-4 surfaces: dark by default, independently gated.
	assert.False(t, cfg.Memory.Surfaces.Chat, "chat surface off by default")
	assert.False(t, cfg.Memory.Surfaces.Briefing, "briefing surface off by default")
	assert.False(t, cfg.Memory.Surfaces.Disputes, "disputes surface off by default")
	assert.False(t, cfg.Memory.Surfaces.Reflection, "reflection surface off by default")

	// Phase-5 slice-1 sources: dark by default, independently gated.
	assert.False(t, cfg.Memory.Sources.Gmail, "gmail source off by default")
	assert.False(t, cfg.Memory.Sources.Actions, "actions source off by default")

	// Phase-5 slice-2 sources: dark by default, independently gated.
	assert.False(t, cfg.Memory.Sources.Calendar, "calendar source off by default")
	assert.False(t, cfg.Memory.Sources.Chats, "chats source off by default")

	// Phase-5 slice-3 renders: dark by default.
	assert.False(t, cfg.Memory.Renders.DigestCompare, "digest_compare render off by default")

	// Phase-5 slice-4 gates: dark by default, independently gated.
	assert.False(t, cfg.Memory.Sources.Operational, "operational source off by default")
	assert.False(t, cfg.Memory.Surfaces.DayPlan, "day_plan surface off by default")
	assert.False(t, cfg.Memory.Surfaces.MeetingPrep, "meeting_prep surface off by default")
	assert.False(t, cfg.Memory.Semantic.Preferences, "preferences semantic gate off by default")

	// Slice B dark retrieval-compare: dark by default, independently gated.
	assert.False(t, cfg.Memory.Retrieve.RecallCompare, "recall_compare off by default")
	assert.False(t, cfg.Memory.Retrieve.BriefingCompare, "briefing_compare off by default")
	assert.False(t, cfg.Memory.Retrieve.MeetingPrepCompare, "meeting_prep_compare off by default")
}

func TestMemorySlice4Config_FromYAML(t *testing.T) {
	yaml := `
memory:
  sources:
    operational: true
  surfaces:
    day_plan: true
    meeting_prep: true
  semantic:
    preferences: true
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.True(t, cfg.Memory.Sources.Operational)
	assert.True(t, cfg.Memory.Surfaces.DayPlan)
	assert.True(t, cfg.Memory.Surfaces.MeetingPrep)
	assert.True(t, cfg.Memory.Semantic.Preferences)
}

func TestMemorySourcesConfig_FromYAML(t *testing.T) {
	yaml := `
memory:
  sources:
    gmail: true
    actions: true
    calendar: true
    chats: true
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.True(t, cfg.Memory.Sources.Gmail)
	assert.True(t, cfg.Memory.Sources.Actions)
	assert.True(t, cfg.Memory.Sources.Calendar)
	assert.True(t, cfg.Memory.Sources.Chats)
}

func TestMemorySurfacesConfig_FromYAML(t *testing.T) {
	yaml := `
memory:
  surfaces:
    chat: true
    briefing: true
    disputes: true
    reflection: true
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.True(t, cfg.Memory.Surfaces.Chat)
	assert.True(t, cfg.Memory.Surfaces.Briefing)
	assert.True(t, cfg.Memory.Surfaces.Disputes)
	assert.True(t, cfg.Memory.Surfaces.Reflection)
}

func TestMemoryRendersConfig_FromYAML(t *testing.T) {
	yaml := `
memory:
  renders:
    digest_compare: true
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.True(t, cfg.Memory.Renders.DigestCompare)
}

func TestMemoryRetrieveConfig_FromYAML(t *testing.T) {
	yaml := `
memory:
  retrieve:
    recall_compare: true
    briefing_compare: true
    meeting_prep_compare: true
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.True(t, cfg.Memory.Retrieve.RecallCompare)
	assert.True(t, cfg.Memory.Retrieve.BriefingCompare)
	assert.True(t, cfg.Memory.Retrieve.MeetingPrepCompare)
}

func TestMemoryConfig_FromYAML(t *testing.T) {
	yaml := `
memory:
  enabled: true
  max_chunk_messages: 500
  seed_min_messages: 3
  max_episodes_per_window: 2
  max_window_messages: 50
  semantic:
    enabled: true
    rewrite_max_entities: 3
    beliefs_max: 4
    dedupe_max_merges: 5
    evict_after_days: 30
    evict_max: 7
    concept_min_episodes: 2
    concept_max_create: 6
    output_budget: 12345
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.True(t, cfg.Memory.Enabled)
	assert.Equal(t, 500, cfg.Memory.MaxChunkMessages)
	assert.Equal(t, 3, cfg.Memory.SeedMinMessages)
	assert.Equal(t, 2, cfg.Memory.MaxEpisodesPerWindow)
	assert.Equal(t, 50, cfg.Memory.MaxWindowMessages)

	assert.True(t, cfg.Memory.Semantic.Enabled)
	assert.Equal(t, 3, cfg.Memory.Semantic.RewriteMaxEntities)
	assert.Equal(t, 4, cfg.Memory.Semantic.BeliefsMax)
	assert.Equal(t, 5, cfg.Memory.Semantic.DedupeMaxMerges)
	assert.Equal(t, 30, cfg.Memory.Semantic.EvictAfterDays)
	assert.Equal(t, 7, cfg.Memory.Semantic.EvictMax)
	assert.Equal(t, 2, cfg.Memory.Semantic.ConceptMinEpisodes)
	assert.Equal(t, 6, cfg.Memory.Semantic.ConceptMaxCreate)
	assert.Equal(t, 12345, cfg.Memory.Semantic.OutputBudget)
}

func TestTargetsConfigDefaults(t *testing.T) {
	path := writeTestConfig(t, "")
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.True(t, cfg.Targets.Extract.Enabled)
	assert.Equal(t, DefaultTargetsExtractMaxPerCall, cfg.Targets.Extract.MaxPerCall)
	assert.Equal(t, DefaultTargetsExtractTimeoutSeconds, cfg.Targets.Extract.TimeoutSeconds)
	assert.Equal(t, DefaultTargetsExtractModel, cfg.Targets.Extract.Model)
	assert.True(t, cfg.Targets.Resolver.SlackEnabled)
	assert.True(t, cfg.Targets.Resolver.JiraEnabled)
	assert.Equal(t, DefaultTargetsResolverMCPTimeoutSeconds, cfg.Targets.Resolver.MCPTimeoutSeconds)
	assert.Equal(t, DefaultTargetsResolverActiveSnapshotLimit, cfg.Targets.Resolver.ActiveSnapshotLimit)
}

func TestTargetsConfigOverride(t *testing.T) {
	yaml := `
targets:
  extract:
    enabled: true
    max_per_call: 5
    timeout_seconds: 60
    model: "claude-haiku-4-5"
  resolver:
    slack_enabled: false
    jira_enabled: true
    mcp_timeout_seconds: 20
    active_snapshot_limit: 50
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.True(t, cfg.Targets.Extract.Enabled)
	assert.Equal(t, 5, cfg.Targets.Extract.MaxPerCall)
	assert.Equal(t, 60, cfg.Targets.Extract.TimeoutSeconds)
	assert.Equal(t, "claude-haiku-4-5", cfg.Targets.Extract.Model)
	assert.False(t, cfg.Targets.Resolver.SlackEnabled)
	assert.True(t, cfg.Targets.Resolver.JiraEnabled)
	assert.Equal(t, 20, cfg.Targets.Resolver.MCPTimeoutSeconds)
	assert.Equal(t, 50, cfg.Targets.Resolver.ActiveSnapshotLimit)
}

func TestTargetsConfigDisabled(t *testing.T) {
	yaml := `
targets:
  extract:
    enabled: false
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.False(t, cfg.Targets.Extract.Enabled)
}

func TestLoad_MultipleWorkspaces(t *testing.T) {
	yaml := `
active_workspace: prod
workspaces:
  prod:
    slack_token: "xoxp-prod"
  staging:
    slack_token: "xoxp-staging"
`
	path := writeTestConfig(t, yaml)
	cfg, err := Load(path)
	require.NoError(t, err)

	assert.Equal(t, "prod", cfg.ActiveWorkspace)
	assert.Len(t, cfg.Workspaces, 2)
	assert.Equal(t, "xoxp-prod", cfg.Workspaces["prod"].SlackToken)
	assert.Equal(t, "xoxp-staging", cfg.Workspaces["staging"].SlackToken)

	ws, err := cfg.GetActiveWorkspace()
	require.NoError(t, err)
	assert.Equal(t, "xoxp-prod", ws.SlackToken)
}

// TestConfigRecordingsDir freezes the cross-language contract with the Swift
// MeetingRecorderCenter.recordingsDirectory(): an explicit transcripts.recordings_dir
// wins verbatim, otherwise the default resolves under the same
// Library/Application Support/Watchtower/recordings location the Desktop recorder
// writes into (so the daemon orphan cleanup scans the right directory).
func TestConfigRecordingsDir(t *testing.T) {
	t.Run("override used verbatim", func(t *testing.T) {
		cfg := &Config{}
		cfg.Transcripts.RecordingsDir = "/custom/recordings/path"
		assert.Equal(t, "/custom/recordings/path", cfg.RecordingsDir())
	})

	t.Run("default under Application Support", func(t *testing.T) {
		cfg := &Config{}
		got := cfg.RecordingsDir()
		require.NotEmpty(t, got, "default recordings dir must resolve when a home directory exists")
		suffix := filepath.Join("Library", "Application Support", "Watchtower", "recordings")
		assert.True(t, strings.HasSuffix(got, suffix),
			"default must match the Swift MeetingRecorderCenter path, got %q", got)
	})
}

func TestFeatureGateDefaults(t *testing.T) {
	cfg, err := Load(filepath.Join(t.TempDir(), "absent.yaml"))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if !cfg.Tracks.Enabled {
		t.Error("tracks.enabled should default true")
	}
	if !cfg.People.Enabled {
		t.Error("people.enabled should default true")
	}
	if !cfg.Targets.NextStep.Enabled {
		t.Error("targets.next_step.enabled should default true")
	}
}
