// Package automations parses, indexes, schedules and runs owner-written
// automation recipes (docs/superpowers/specs/2026-10-14-automations-design.md).
package automations

import "time"

// Every exact value of the spec's limits lives here; do not change one
// without the spec changing first.

// Recipe file.
const (
	// MaxRecipeBytes is the largest recipe file accepted (spec §2.1).
	MaxRecipeBytes = 256 * 1024
)

// Sandbox limits (spec §4, §5).
const (
	// MaxSDKResultBytes caps one SDK call's serialised result; a larger result
	// is a ResultTooLarge error, never truncated.
	MaxSDKResultBytes = 256 * 1024
	// DefaultListLimit is injected into a list tool call without a limit.
	DefaultListLimit = 50
	// MaxListLimit clamps a list tool call's limit.
	MaxListLimit = 200
	// MaxLLMInputBytes caps the input of one llm() call.
	MaxLLMInputBytes = 200 * 1024
	// MaxStateBytes caps an automation's serialised state (StateTooLarge).
	MaxStateBytes = 64 * 1024
	// MaxOutputBodyBytes caps the body of one output.* call.
	MaxOutputBodyBytes = 64 * 1024
	// MaxOutputTitleChars caps the title of one output.* call, in characters
	// (Task 7 review decision; not in the spec's list — Task 13 docs).
	MaxOutputTitleChars = 200
	// MaxLogBytes caps one log() call.
	MaxLogBytes = 4 * 1024
	// MaxLogCalls caps log() calls per run.
	MaxLogCalls = 200
	// StepClipBytes clips a step's args_json and result_summary.
	StepClipBytes = 4 * 1024
	// SummaryClipBytes clips a run's summary.
	SummaryClipBytes = 1024
	// EmailBodyClipBytes clips an email body returned by get_email.
	EmailBodyClipBytes = 32 * 1024
	// MaxEventsPerRun caps the events carried by one event run (spec §8).
	MaxEventsPerRun = 100
)

// Executor and scheduler (spec §7).
const (
	// MaxConcurrentRuns is the number of runs executing at once (waiting runs
	// do not count).
	MaxConcurrentRuns = 2
	// PollInterval is the executor's and scheduler's idle poll period.
	PollInterval = 10 * time.Second
	// ScheduleGrace is how late a schedule tick may fire and still count as on
	// time rather than missed.
	ScheduleGrace = 2 * time.Minute
)

// Recipe defaults and bounds (spec §2.3). The lower bound of concurrency and
// pause_timeout_hours is 1.
const (
	DefaultBudgetTokens      = 50000
	MinBudgetTokens          = 1000
	MaxBudgetTokens          = 2000000
	DefaultBudgetMinutes     = 5
	MinBudgetMinutes         = 1
	MaxBudgetMinutes         = 60
	DefaultConcurrency       = 1
	MaxConcurrency           = 4
	DefaultPauseTimeoutHours = 72
	MaxPauseTimeoutHours     = 168
)

// DefaultDailyBudgetTokens is the default of automations.daily_budget_tokens,
// the global per-local-day token cap across all runs (spec §7.5).
const DefaultDailyBudgetTokens = 2000000
