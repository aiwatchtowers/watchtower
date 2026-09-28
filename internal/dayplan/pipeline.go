package dayplan

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"strings"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// Pipeline orchestrates day-plan generation and persistence.
type Pipeline struct {
	db          *db.DB
	cfg         *config.Config
	generator   digest.Generator
	logger      *log.Logger
	promptStore *prompts.Store

	// Accumulated usage from the last Run call.
	lastInputTokens    int
	lastOutputTokens   int
	lastTotalAPITokens int
}

// New constructs a Pipeline.
func New(database *db.DB, cfg *config.Config, gen digest.Generator, logger *log.Logger) *Pipeline {
	return &Pipeline{db: database, cfg: cfg, generator: gen, logger: logger}
}

// SetPromptStore wires an optional customisable prompt store.
func (p *Pipeline) SetPromptStore(store *prompts.Store) { p.promptStore = store }

// AccumulatedUsage returns the token usage from the last Run call.
// Returns (inputTokens, outputTokens, costUSD, totalAPITokens). costUSD is
// always 0 — cost is not tracked for the day-plan pipeline.
func (p *Pipeline) AccumulatedUsage() (int, int, float64, int) {
	return p.lastInputTokens, p.lastOutputTokens, 0, p.lastTotalAPITokens
}

// Run generates or regenerates the day plan for the target date.
// It is idempotent by default: if a plan already exists and neither Force nor
// Feedback is set it returns the existing plan immediately.
func (p *Pipeline) Run(ctx context.Context, opts RunOptions) (*db.DayPlan, error) {
	if !p.cfg.DayPlan.Enabled {
		return nil, nil
	}
	if opts.Date == "" {
		opts.Date = time.Now().Format("2006-01-02")
	}

	existing, err := p.db.GetDayPlan(opts.UserID, opts.Date)
	if err != nil {
		return nil, fmt.Errorf("lookup plan: %w", err)
	}

	// Short-circuit: plan exists and caller does not want regeneration.
	if existing != nil && !opts.Force && opts.Feedback == "" {
		if p.logger != nil {
			p.logger.Printf("dayplan: plan for %s already exists, skipping", opts.Date)
		}
		return existing, nil
	}

	// ── gather context ────────────────────────────────────────────────────────

	targets, _ := p.gatherTargets()
	events, _ := p.gatherCalendarEvents(opts.Date)
	briefingData := p.gatherBriefing(opts.UserID, opts.Date)
	jiraIssues := p.gatherJira(opts.Owner)
	people := p.gatherPeople()
	prev := p.gatherPreviousPlan(opts.UserID, opts.Date)

	var prevItems []db.DayPlanItem
	if prev != nil {
		prevItems, _ = p.db.GetDayPlanItems(prev.ID)
	}

	var manual []db.DayPlanItem
	if existing != nil {
		manual, _ = p.gatherManualItems(existing.ID)
	}

	// ── build and call AI ─────────────────────────────────────────────────────

	now := opts.Now
	if now.IsZero() {
		now = time.Now()
	}

	inputs := &promptInputs{
		Date:              opts.Date,
		Weekday:           dayOfWeek(opts.Date),
		NowLocal:          now.Format("15:04"),
		UserRole:          p.userRole(opts.UserID),
		WorkingHoursStart: p.cfg.DayPlan.WorkingHoursStart,
		WorkingHoursEnd:   p.cfg.DayPlan.WorkingHoursEnd,
		CalendarEvents:    formatCalendarSection(events),
		Targets:           formatTargetsSection(targets),
		Briefing:          formatBriefingContext(briefingData),
		Jira:              formatJiraSection(jiraIssues),
		People:            formatPeopleSection(people),
		Manual:            formatManualSection(manual),
		Previous:          formatPreviousPlanSection(prev, prevItems),
		Feedback:          feedbackOrInitial(opts.Feedback),
		MemoryOpenLoops:   p.gatherMemoryOpenLoops(),
	}

	systemPrompt, promptVer := p.buildPrompt(inputs)

	// Reset per-Run accumulators before the AI call so short-circuited paths
	// (missing enabled flag, existing plan) report zero tokens.
	p.lastInputTokens = 0
	p.lastOutputTokens = 0
	p.lastTotalAPITokens = 0

	resp, usage, _, err := p.generator.Generate(
		digest.WithSource(ctx, "day_plan.generate"),
		systemPrompt, "Generate the day plan.", "")
	if err != nil {
		return nil, fmt.Errorf("ai generate: %w", err)
	}
	if usage != nil {
		p.lastInputTokens = usage.InputTokens
		p.lastOutputTokens = usage.OutputTokens
		p.lastTotalAPITokens = usage.InputTokens + usage.OutputTokens
	}

	// ── parse and validate ────────────────────────────────────────────────────

	parsed, err := parseResponse(resp)
	if err != nil {
		return nil, err
	}

	newItems, dropped, invalid := buildItems(parsed, opts.Date, events, targetsIDSet(targets), jiraKeySet(jiraIssues))
	if p.logger != nil {
		for _, d := range dropped {
			p.logger.Printf("dayplan: dropped item: %s", d)
		}
	}
	// The model proposed items and every one was dropped. That is a failed
	// attempt (charged to the daemon's budget and retried), not an empty plan
	// that would stick for the day, when any drop was a real validation
	// failure, or when the day has nothing else to show (no timed meeting for
	// syncCalendarItems to add, no manual item). A meeting-heavy day whose
	// proposals only restated or collided with the calendar is a valid
	// calendar-only plan, and a model that proposed nothing is an honest one.
	if len(newItems) == 0 && len(dropped) > 0 && (invalid > 0 || (len(manual) == 0 && !hasTimedEvent(events))) {
		return nil, fmt.Errorf("day plan for %s: all %d generated items failed validation", opts.Date, len(dropped))
	}

	// ── persist (a fresh plan either lands whole or not at all) ───────────────

	var briefingID sql.NullInt64
	if briefingData != nil {
		briefingID = sql.NullInt64{Int64: int64(briefingData.ID), Valid: true}
	}

	planRow := &db.DayPlan{
		UserID:          opts.UserID,
		PlanDate:        opts.Date,
		Status:          "active",
		GeneratedAt:     now,
		PromptVersion:   sql.NullString{String: promptVer, Valid: true},
		BriefingID:      briefingID,
		FeedbackHistory: "[]",
	}
	if existing != nil {
		planRow.ID = existing.ID
		planRow.RegenerateCount = existing.RegenerateCount
		planRow.FeedbackHistory = existing.FeedbackHistory
	}

	planID, err := p.db.UpsertDayPlan(planRow)
	if err != nil {
		return nil, fmt.Errorf("upsert plan: %w", err)
	}
	if err := p.persistItems(planID, opts.Date, newItems, events); err != nil {
		// A freshly created plan row that failed half-way would otherwise stick
		// for the whole day: the next cycle's "plan exists" short-circuit takes
		// an empty or partial plan as done. Drop it so the next run regenerates.
		// A plan that existed before this run is never deleted here.
		if existing == nil {
			if derr := p.db.DeleteDayPlan(planID); derr != nil && p.logger != nil {
				p.logger.Printf("dayplan: could not drop partial plan %d for %s: %v", planID, opts.Date, derr)
			}
		}
		return nil, err
	}

	// Increment regenerate count when this is a regeneration (with feedback or
	// forced). Bookkeeping only: the regenerated plan is already in place, so a
	// failure is logged rather than reported as a failed run.
	if opts.Feedback != "" || (existing != nil && opts.Force) {
		if err := p.db.IncrementRegenerateCount(planID, opts.Feedback); err != nil && p.logger != nil {
			p.logger.Printf("dayplan: increment regenerate count for plan %d: %v", planID, err)
		}
	}

	// DetectConflicts is implemented in T11; stub here is a no-op.
	_ = p.DetectConflicts(ctx, opts.UserID, opts.Date)

	return p.db.GetDayPlanByID(planID)
}

// hasTimedEvent reports whether events hold a non-all-day event, i.e. one
// syncCalendarItems turns into a timeblock.
func hasTimedEvent(events []db.CalendarEvent) bool {
	for _, e := range events {
		if !e.IsAllDay {
			return true
		}
	}
	return false
}

// persistItems writes a generated plan's items: the AI items, then the
// calendar timeblocks.
func (p *Pipeline) persistItems(planID int64, date string, newItems []db.DayPlanItem, events []db.CalendarEvent) error {
	if err := p.db.ReplaceAIItems(planID, newItems); err != nil {
		return fmt.Errorf("replace AI items: %w", err)
	}
	if err := p.syncCalendarItems(planID, date, events); err != nil {
		return fmt.Errorf("sync calendar items: %w", err)
	}
	return nil
}

// ── internal helpers ───────────────────────────────────────────────────────────

// normalizePriority ensures a priority string is one of the known values.
func normalizePriority(s string) string {
	switch strings.ToLower(s) {
	case "high", "medium", "low":
		return strings.ToLower(s)
	default:
		return "medium"
	}
}
