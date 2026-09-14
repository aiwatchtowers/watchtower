package targets

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/prompts"
)

func TestGenerateNextStep_PersistsAndParses(t *testing.T) {
	gen := &mockGenerator{responses: []string{`{
		"title": "Escalate tickets #4844 and #4851 via TAM",
		"rationale": "Both have been unanswered for 3 days and block the v2 API launch.",
		"urgency": "deadline",
		"urgency_detail": "6 days",
		"actions": [
			{"label": "Message TAM", "kind": "assistant", "prompt": "Help me draft a TAM escalation"},
			{"label": "Show tickets", "kind": "open_links"},
			{"label": "Different plan", "kind": "assistant", "prompt": "Suggest a different next step for this target"}
		]
	}`}}
	p, d := makeTestPipeline(t, gen)

	id, err := d.CreateTarget(db.Target{
		Text: "Cloudflare: resolve 4 tickets", Status: "in_progress", Ownership: "mine", SourceType: "manual", Priority: "high",
		Level: "month", PeriodStart: "2026-07-01", PeriodEnd: "2026-07-31",
	})
	if err != nil {
		t.Fatalf("create target: %v", err)
	}

	ns, err := p.GenerateNextStep(context.Background(), int(id))
	if err != nil {
		t.Fatalf("GenerateNextStep: %v", err)
	}
	if ns.Title == "" || ns.Urgency != "deadline" || len(ns.Actions) != 3 {
		t.Fatalf("unexpected parsed next-step: %+v", ns)
	}

	// Persisted and re-decodable from the DB.
	tgt, err := d.GetTargetByID(int(id))
	if err != nil {
		t.Fatalf("reload target: %v", err)
	}
	if tgt.NextStep == "" || tgt.NextStepAt == "" {
		t.Fatalf("next_step not persisted: %+v", tgt)
	}
	var stored NextStep
	if err := json.Unmarshal([]byte(tgt.NextStep), &stored); err != nil {
		t.Fatalf("stored next_step is not valid JSON: %v", err)
	}
	if stored.Title != ns.Title {
		t.Fatalf("stored title %q != generated %q", stored.Title, ns.Title)
	}
}

func TestGenerateNextStep_DropsUnknownActionKinds(t *testing.T) {
	gen := &mockGenerator{responses: []string{`{
		"title": "Do the thing",
		"urgency": "weird-value",
		"actions": [
			{"label": "Good", "kind": "assistant", "prompt": "x"},
			{"label": "Bad", "kind": "todo_native"},
			{"label": "", "kind": "open_links"}
		]
	}`}}
	p, d := makeTestPipeline(t, gen)
	id, _ := d.CreateTarget(db.Target{Text: "x", Status: "todo", Ownership: "mine", Priority: "medium", SourceType: "manual", PeriodStart: "2026-07-01"})

	ns, err := p.GenerateNextStep(context.Background(), int(id))
	if err != nil {
		t.Fatalf("GenerateNextStep: %v", err)
	}
	if ns.Urgency != "normal" {
		t.Fatalf("expected urgency normalised to normal, got %q", ns.Urgency)
	}
	if len(ns.Actions) != 1 || ns.Actions[0].Kind != "assistant" {
		t.Fatalf("expected only the valid action to survive, got %+v", ns.Actions)
	}
}

func TestGenerateNextStep_EmptyTitleErrors(t *testing.T) {
	gen := &mockGenerator{responses: []string{`{"title": "  ", "actions": []}`}}
	p, d := makeTestPipeline(t, gen)
	id, _ := d.CreateTarget(db.Target{Text: "x", Status: "todo", Ownership: "mine", Priority: "medium", SourceType: "manual", PeriodStart: "2026-07-01"})

	if _, err := p.GenerateNextStep(context.Background(), int(id)); err == nil {
		t.Fatal("expected error on empty title, got nil")
	}
}

func TestGetTargetsNeedingNextStep_FiltersDoneAndFresh(t *testing.T) {
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer d.Close()

	active, _ := d.CreateTarget(db.Target{Text: "active", Status: "todo", Ownership: "mine", Priority: "medium", SourceType: "manual", PeriodStart: "2026-07-01"})
	doneID, _ := d.CreateTarget(db.Target{Text: "done", Status: "done", Ownership: "mine", Priority: "medium", SourceType: "manual", PeriodStart: "2026-07-01"})
	freshID, _ := d.CreateTarget(db.Target{Text: "fresh", Status: "todo", Ownership: "mine", Priority: "medium", SourceType: "manual", PeriodStart: "2026-07-01"})

	// Mark `fresh` as already having a current next_step (next_step_at >= updated_at).
	if err := d.SetTargetNextStep(int(freshID), `{"title":"x"}`, "2999-01-01T00:00:00Z"); err != nil {
		t.Fatalf("seed next_step: %v", err)
	}

	need, err := d.GetTargetsNeedingNextStep(0)
	if err != nil {
		t.Fatalf("GetTargetsNeedingNextStep: %v", err)
	}
	ids := map[int]bool{}
	for _, tgt := range need {
		ids[tgt.ID] = true
	}
	if !ids[int(active)] {
		t.Error("active target should need a next_step")
	}
	if ids[int(doneID)] {
		t.Error("done target should be excluded")
	}
	if ids[int(freshID)] {
		t.Error("fresh target with current next_step should be excluded")
	}
}

// --- per-target attempt budget (migration 00068) ---
//
// These pin the eligibility predicate GetTargetsNeedingNextStep adds on top
// of staleness: a target that has burned 3 attempts on the current UTC
// calendar day is excluded UNLESS it was edited since its last attempt (a
// fresh problem, not a retry) or the UTC day has rolled over (the daily
// budget resets). Every fixture here seeds at least two targets so a
// single-target assertion can never pass for a global-counter implementation
// by accident — see the wave-3 guard-shape note in the task brief.

const isoUTC = "2006-01-02T15:04:05Z"

// seedAttempts sets a target's per-target attempt-budget columns directly,
// and independently its updated_at, so a test can construct the exact
// ordering the eligibility predicate cares about without going through a real
// generation cycle.
func seedAttempts(t *testing.T, d *db.DB, id int64, attempts int, attemptedAt, updatedAt string) {
	t.Helper()
	if err := d.RecordTargetNextStepAttempt(int(id), attempts, attemptedAt); err != nil {
		t.Fatalf("seed attempts for target %d: %v", id, err)
	}
	if _, err := d.Exec(`UPDATE targets SET updated_at = ? WHERE id = ?`, updatedAt, id); err != nil {
		t.Fatalf("seed updated_at for target %d: %v", id, err)
	}
}

// TestGetTargetsNeedingNextStep_AttemptBudgetPerTargetIsolation: an exhausted
// target must not block a sibling target that still has budget — a global
// counter would fail this the moment the first target burned all 3 attempts.
func TestGetTargetsNeedingNextStep_AttemptBudgetPerTargetIsolation(t *testing.T) {
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer d.Close()

	exhausted := seedActiveTarget(t, d, "exhausted")
	fresh := seedActiveTarget(t, d, "fresh")

	now := time.Now().UTC().Format(isoUTC)
	// Exhausted today, not edited since (attempted_at >= updated_at) — must
	// be excluded, but must not affect the sibling target at all.
	seedAttempts(t, d, exhausted, 3, now, now)

	need, err := d.GetTargetsNeedingNextStep(0)
	if err != nil {
		t.Fatalf("GetTargetsNeedingNextStep: %v", err)
	}
	ids := map[int]bool{}
	for _, tgt := range need {
		ids[tgt.ID] = true
	}
	if ids[int(exhausted)] {
		t.Error("target with 3 attempts today (not edited since) should be excluded")
	}
	if !ids[int(fresh)] {
		t.Error("a sibling target with budget remaining must still be selected")
	}
}

// TestGenerateNextStep_RepeatedFailuresClimbToThreeThenExcluded drives the
// counter through the REAL write path — repeated GenerateNextStep calls on
// the same target, same UTC day, with no manual seeding of
// next_step_attempts/next_step_attempted_at — rather than seedAttempts'
// direct-write shortcut. This is the one guard that can tell a working
// increment branch apart from a `nextAttemptCount` that always returns 1: a
// fixture built with seedAttempts starts the counter pre-loaded and never
// exercises the "otherwise increment" arm at all, so a mutant that always
// resets to 1 would still pass every other budget test in this file while
// leaving the daily cap a permanent no-op.
func TestGenerateNextStep_RepeatedFailuresClimbToThreeThenExcluded(t *testing.T) {
	gen := &mockGenerator{err: fmt.Errorf("simulated AI failure")}
	p, d := makeTestPipeline(t, gen)

	id := seedActiveTarget(t, d, "repeatedly failing")

	for i, want := range []int{1, 2, 3} {
		if _, err := p.GenerateNextStep(context.Background(), int(id)); err == nil {
			t.Fatalf("attempt %d: expected the simulated AI failure to surface", i+1)
		}
		tgt, err := d.GetTargetByID(int(id))
		if err != nil {
			t.Fatalf("reload after attempt %d: %v", i+1, err)
		}
		if tgt.NextStepAttempts != want {
			t.Fatalf("after attempt %d: expected next_step_attempts=%d, got %d", i+1, want, tgt.NextStepAttempts)
		}
		if tgt.NextStep != "" {
			t.Fatalf("a failed attempt must never persist a next_step, got %q", tgt.NextStep)
		}
	}

	// Only after the third real failure, same UTC day, does the eligibility
	// predicate exclude the target.
	need, err := d.GetTargetsNeedingNextStep(0)
	if err != nil {
		t.Fatalf("GetTargetsNeedingNextStep: %v", err)
	}
	for _, cand := range need {
		if cand.ID == int(id) {
			t.Fatal("a target with 3 real same-day failures must be excluded from the next batch")
		}
	}
}

// TestGetTargetsNeedingNextStep_UTCDayRolloverGrantsFreshBudget: an exhausted
// target from a previous UTC calendar day is eligible again today, with a
// full fresh budget (not one straggler attempt) — nextAttemptCount must reset
// to 1, not continue counting from 3.
func TestGetTargetsNeedingNextStep_UTCDayRolloverGrantsFreshBudget(t *testing.T) {
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer d.Close()

	rolledOver := seedActiveTarget(t, d, "rolled-over")
	stillToday := seedActiveTarget(t, d, "still-exhausted-today")

	now := time.Now().UTC()
	yesterday := now.AddDate(0, 0, -1).Format(isoUTC)
	today := now.Format(isoUTC)

	// Exhausted yesterday, never edited since — the day boundary alone must
	// grant a fresh budget.
	seedAttempts(t, d, rolledOver, 3, yesterday, yesterday)
	// Exhausted today, not edited since — the negative control: must stay excluded.
	seedAttempts(t, d, stillToday, 3, today, today)

	need, err := d.GetTargetsNeedingNextStep(0)
	if err != nil {
		t.Fatalf("GetTargetsNeedingNextStep: %v", err)
	}
	ids := map[int]bool{}
	for _, tgt := range need {
		ids[tgt.ID] = true
	}
	if !ids[int(rolledOver)] {
		t.Error("a target exhausted on a previous UTC day should be eligible again today")
	}
	if ids[int(stillToday)] {
		t.Error("a target exhausted today (not edited, no rollover) should stay excluded")
	}

	// The reset must be a fresh full budget, not "one more attempt": the
	// counter itself resets to 1, so today's cycle can still make 2 more
	// attempts after this one — not immediately re-exhaust on the next try.
	reloaded, err := d.GetTargetByID(int(rolledOver))
	if err != nil {
		t.Fatalf("reload target: %v", err)
	}
	if got := nextAttemptCount(reloaded, now); got != 1 {
		t.Errorf("day rollover must reset the counter to 1, got %d", got)
	}
}

// TestGetTargetsNeedingNextStep_FreshEditGrantsBudgetSameDay: the controller's
// ruling — a target edited since its last failed attempt gets a fresh budget
// immediately, same UTC day, no rollover needed, because it is a new problem
// rather than a retry of the same failure.
func TestGetTargetsNeedingNextStep_FreshEditGrantsBudgetSameDay(t *testing.T) {
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer d.Close()

	edited := seedActiveTarget(t, d, "edited-after-exhaustion")

	now := time.Now().UTC()
	attemptedAt := now.Add(-1 * time.Hour).Format(isoUTC)
	editedAt := now.Format(isoUTC)

	// Exhausted an hour ago, then edited (updated_at moved past attempted_at)
	// — same UTC calendar day throughout, so only the fresh-edit escape can
	// explain eligibility here.
	seedAttempts(t, d, edited, 3, attemptedAt, editedAt)

	need, err := d.GetTargetsNeedingNextStep(0)
	if err != nil {
		t.Fatalf("GetTargetsNeedingNextStep: %v", err)
	}
	found := false
	for _, tgt := range need {
		if tgt.ID == int(edited) {
			found = true
		}
	}
	if !found {
		t.Error("a target edited since its last exhausted attempt must be eligible immediately")
	}

	reloaded, err := d.GetTargetByID(int(edited))
	if err != nil {
		t.Fatalf("reload target: %v", err)
	}
	if got := nextAttemptCount(reloaded, now); got != 1 {
		t.Errorf("a fresh edit must reset the counter to 1 regardless of the old attempt count, got %d", got)
	}
}

// seedChildTarget creates an active "todo" target parented under parentID —
// the fixture builder for the parent-progress budget tests below.
func seedChildTarget(t *testing.T, d *db.DB, text string, parentID int64) int64 {
	t.Helper()
	id, err := d.CreateTarget(db.Target{
		Text: text, Status: "todo", Ownership: "mine", Priority: "medium",
		SourceType: "manual", PeriodStart: "2026-07-01",
		ParentID: sql.NullInt64{Int64: parentID, Valid: true},
	})
	if err != nil {
		t.Fatalf("create child target %q under %d: %v", text, parentID, err)
	}
	return id
}

// TestGetTargetsNeedingNextStep_ParentBudgetUnaffectedByNoOpChildEdit pins the
// wave-5 fix behind the "edited since" escape hatch: a non-leaf target's
// attempt budget must reset only when a child edit actually moves the
// computed average progress (internal/db.recomputeParentProgressOn), not on
// every write that happens to touch a child. Exercises the eligibility
// predicate two ancestor levels deep (grandparent -> parent -> children),
// since the walker rewrites every ancestor's updated_at on the way up and a
// fix scoped to only the first level would still pass a single-level check.
// A sibling target with its own budget is asserted throughout so a
// global-counter implementation cannot pass by accident.
func TestGetTargetsNeedingNextStep_ParentBudgetUnaffectedByNoOpChildEdit(t *testing.T) {
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer d.Close()

	grandparent := seedActiveTarget(t, d, "grandparent")
	parent := seedChildTarget(t, d, "parent", grandparent)
	child1 := seedChildTarget(t, d, "child1", parent)
	seedChildTarget(t, d, "child2", parent) // a second child so AVG is a real average

	sibling := seedActiveTarget(t, d, "sibling with budget")

	// Move child1 to in_progress so the ancestors start at a non-trivial
	// AVG(0.5, 0.0) = 0.25 — the no-op leg below needs something real to
	// leave unchanged.
	if err := d.UpdateTargetStatus(int(child1), "in_progress"); err != nil {
		t.Fatalf("seed child1 in_progress: %v", err)
	}

	// Exhaust today's budget on both ancestors, seeded strictly in the past
	// (not "now") so a later real progress change is guaranteed to produce a
	// strictly later updated_at regardless of clock resolution. Clamped to
	// today's UTC midnight: a plain "now - 5min" would cross into yesterday
	// during the first five minutes of a UTC day, and the eligibility
	// predicate's own day-rollover escape hatch (date(attempted_at) <
	// date('now')) would then grant a fresh budget on its own, making the
	// "before any child edit" negative assertion flip independent of this
	// fix.
	now := time.Now().UTC()
	midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	pastTime := now.Add(-5 * time.Minute)
	if pastTime.Before(midnight) {
		pastTime = midnight.Add(1 * time.Second)
	}
	past := pastTime.Format(isoUTC)
	seedAttempts(t, d, parent, 3, past, past)
	seedAttempts(t, d, grandparent, 3, past, past)

	assertEligibility := func(t *testing.T, wantParent, wantGrandparent bool, label string) {
		t.Helper()
		need, err := d.GetTargetsNeedingNextStep(0)
		if err != nil {
			t.Fatalf("%s: GetTargetsNeedingNextStep: %v", label, err)
		}
		if got := targetNeedsNextStep(need, parent); got != wantParent {
			t.Errorf("%s: parent eligibility = %v, want %v", label, got, wantParent)
		}
		if got := targetNeedsNextStep(need, grandparent); got != wantGrandparent {
			t.Errorf("%s: grandparent eligibility = %v, want %v", label, got, wantGrandparent)
		}
		if !targetNeedsNextStep(need, sibling) {
			t.Errorf("%s: sibling target with budget remaining must still be selected", label)
		}
	}

	assertEligibility(t, false, false, "before any child edit")

	// No-op leg: edit a non-progress field on child1 through UpdateTarget —
	// the average must not move, so neither ancestor's budget may reset.
	got1 := reloadTarget(t, d, child1, "before no-op edit")
	got1.Text = "child1 (renamed)"
	if err := d.UpdateTarget(*got1); err != nil {
		t.Fatalf("no-op edit on child1: %v", err)
	}
	assertEligibility(t, false, false, "after no-op child edit")

	// Real-change leg: flip child1 to done — the average moves, so both
	// ancestors get a fresh budget (their updated_at moves past the attempt).
	if err := d.UpdateTargetStatus(int(child1), "done"); err != nil {
		t.Fatalf("real-change edit on child1: %v", err)
	}
	assertEligibility(t, true, true, "after progress-moving child edit")
}

// TestGenerateNextStep_SuccessLeavesNoBudgetBlockingFutureRefresh: a
// successful generation must never leave attempt-budget state that later
// blocks a legitimate refresh once the target is edited again.
// targetNeedsNextStep reports whether id appears in a
// GetTargetsNeedingNextStep result — the repeated arrange/assert scan lifted
// out of TestGenerateNextStep_SuccessLeavesNoBudgetBlockingFutureRefresh to
// keep that test's own cyclomatic complexity down (gocyclo).
func targetNeedsNextStep(need []db.Target, id int64) bool {
	for _, cand := range need {
		if cand.ID == int(id) {
			return true
		}
	}
	return false
}

// reloadTarget re-fetches a target by id, failing the test with context on
// error — the repeated "reload and check" step split out of
// TestGenerateNextStep_SuccessLeavesNoBudgetBlockingFutureRefresh.
func reloadTarget(t *testing.T, d *db.DB, id int64, when string) *db.Target {
	t.Helper()
	tgt, err := d.GetTargetByID(int(id))
	if err != nil {
		t.Fatalf("reload %s: %v", when, err)
	}
	return tgt
}

func TestGenerateNextStep_SuccessLeavesNoBudgetBlockingFutureRefresh(t *testing.T) {
	gen := &mockGenerator{responses: []string{`{"title":"Do X","actions":[]}`}}
	p, d := makeTestPipeline(t, gen)

	id := seedActiveTarget(t, d, "will succeed then be edited")

	if _, err := p.GenerateNextStep(context.Background(), int(id)); err != nil {
		t.Fatalf("GenerateNextStep: %v", err)
	}
	tgt := reloadTarget(t, d, id, "after success")
	if tgt.NextStepAttempts != 1 || tgt.NextStepAttemptedAt == "" {
		t.Fatalf("expected the successful attempt to be recorded, got %+v", tgt)
	}

	// Not stale yet (next_step_at is fresh) — must not be reselected.
	need, err := d.GetTargetsNeedingNextStep(0)
	if err != nil {
		t.Fatalf("GetTargetsNeedingNextStep: %v", err)
	}
	if targetNeedsNextStep(need, id) {
		t.Fatal("a freshly-succeeded target must not be reselected before it goes stale")
	}

	// Now simulate an owner edit: bump updated_at past both next_step_at and
	// next_step_attempted_at (a real edit would also do this via UpdateTarget).
	later := time.Now().UTC().Add(time.Minute).Format(isoUTC)
	if _, err := d.Exec(`UPDATE targets SET updated_at = ? WHERE id = ?`, later, id); err != nil {
		t.Fatalf("simulate edit: %v", err)
	}

	need, err = d.GetTargetsNeedingNextStep(0)
	if err != nil {
		t.Fatalf("GetTargetsNeedingNextStep after edit: %v", err)
	}
	if !targetNeedsNextStep(need, id) {
		t.Fatal("editing the target after a successful generation must make it eligible for refresh again")
	}

	// And a second generation succeeds again, with the counter reset to 1 —
	// the one prior success never compounds into a blocking count.
	if _, err := p.GenerateNextStep(context.Background(), int(id)); err != nil {
		t.Fatalf("second GenerateNextStep: %v", err)
	}
	tgt = reloadTarget(t, d, id, "after second success")
	if tgt.NextStepAttempts != 1 {
		t.Errorf("post-edit attempt must reset the counter to 1, got %d", tgt.NextStepAttempts)
	}
}

// TestGenerateAllNextSteps_ExhaustedTargetExcludedFromBatch: end-to-end
// through the real batch entry point — an exhausted target is skipped
// entirely (never even calls the AI), while a sibling target with budget
// remaining is still processed and succeeds. This is the two-target guard
// TestGenerateAllNextSteps_PerTargetFailureIsolation cannot provide on its
// own, since that test never exhausts anyone's budget.
func TestGenerateAllNextSteps_ExhaustedTargetExcludedFromBatch(t *testing.T) {
	gen := &mockGenerator{responses: []string{`{"title":"Do X","actions":[]}`}}
	p, d := makeTestPipeline(t, gen)

	exhausted := seedActiveTarget(t, d, "exhausted")
	fresh := seedActiveTarget(t, d, "fresh")

	now := time.Now().UTC().Format(isoUTC)
	seedAttempts(t, d, exhausted, 3, now, now)

	done, attempted, err := p.GenerateAllNextSteps(context.Background())
	if err != nil {
		t.Fatalf("GenerateAllNextSteps: %v", err)
	}
	if attempted != 1 {
		t.Fatalf("expected only the non-exhausted target to be selected, got %d", attempted)
	}
	if done != 1 {
		t.Fatalf("expected 1 successful generation, got %d", done)
	}
	if gen.calls() != 1 {
		t.Fatalf("the exhausted target must never reach the AI, got %d calls", gen.calls())
	}

	freshTgt, err := d.GetTargetByID(int(fresh))
	if err != nil {
		t.Fatalf("reload fresh target: %v", err)
	}
	if freshTgt.NextStep == "" {
		t.Error("the non-exhausted sibling should have its next_step generated")
	}
	exhaustedTgt, err := d.GetTargetByID(int(exhausted))
	if err != nil {
		t.Fatalf("reload exhausted target: %v", err)
	}
	if exhaustedTgt.NextStepAttempts != 3 {
		t.Errorf("the exhausted target's attempt count must be untouched by the batch, got %d", exhaustedTgt.NextStepAttempts)
	}
}

// TestGenerateNextStep_SystemPromptCarriesLanguageDirective enforces the
// prompts.Directive contract (F7): the next-step system prompt must carry the
// configured response language instead of silently defaulting to English.
func TestGenerateNextStep_SystemPromptCarriesLanguageDirective(t *testing.T) {
	gen := &mockGenerator{responses: []string{`{"title":"Do X","actions":[]}`}}
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer d.Close()
	p := New(d, nil, gen, nil, "Ukrainian", nil)

	id, err := d.CreateTarget(db.Target{Text: "x", Status: "todo", Ownership: "mine", Priority: "medium", SourceType: "manual", PeriodStart: "2026-07-01"})
	if err != nil {
		t.Fatalf("create target: %v", err)
	}
	if _, err := p.GenerateNextStep(context.Background(), int(id)); err != nil {
		t.Fatalf("GenerateNextStep: %v", err)
	}
	if !prompts.HasDirective(gen.lastSystem) || !strings.Contains(gen.lastSystem, "Ukrainian") {
		t.Fatalf("next-step system prompt missing language directive:\n%s", gen.lastSystem)
	}
}

// seedActiveTarget creates one active target with the given text.
func seedActiveTarget(t *testing.T, d *db.DB, text string) int64 {
	t.Helper()
	id, err := d.CreateTarget(db.Target{Text: text, Status: "todo", Ownership: "mine", Priority: "medium", SourceType: "manual", PeriodStart: "2026-07-01"})
	if err != nil {
		t.Fatalf("create target %q: %v", text, err)
	}
	return id
}

// TestGenerateAllNextSteps_PerTargetFailureIsolation: one bad target must not
// abort the batch — the other targets still get their next_step persisted and
// are counted.
func TestGenerateAllNextSteps_PerTargetFailureIsolation(t *testing.T) {
	gen := &mockGenerator{
		responses:           []string{`{"title":"Do X","actions":[]}`},
		failOnUserSubstring: "FAILME",
	}
	p, d := makeTestPipeline(t, gen)

	goodA := seedActiveTarget(t, d, "alpha")
	bad := seedActiveTarget(t, d, "FAILME beta")
	goodB := seedActiveTarget(t, d, "gamma")

	n, attempted, err := p.GenerateAllNextSteps(context.Background())
	if err != nil {
		t.Fatalf("GenerateAllNextSteps: %v", err)
	}
	if n != 2 {
		t.Fatalf("expected 2 successful generations, got %d", n)
	}
	if attempted != 3 {
		t.Fatalf("expected 3 targets selected into the batch, got %d", attempted)
	}
	for _, id := range []int64{goodA, goodB} {
		tgt, err := d.GetTargetByID(int(id))
		if err != nil {
			t.Fatalf("reload target %d: %v", id, err)
		}
		if tgt.NextStep == "" {
			t.Fatalf("target %d should have next_step persisted", id)
		}
	}
	tgt, err := d.GetTargetByID(int(bad))
	if err != nil {
		t.Fatalf("reload bad target: %v", err)
	}
	if tgt.NextStep != "" {
		t.Fatalf("failed target must not get a next_step, got %q", tgt.NextStep)
	}
}

// TestGenerateAllNextSteps_ZeroTargetsCleanExit: an empty DB is a valid,
// degenerate input — (0, nil) and no AI calls.
func TestGenerateAllNextSteps_ZeroTargetsCleanExit(t *testing.T) {
	gen := &mockGenerator{responses: []string{`{"title":"never","actions":[]}`}}
	p, _ := makeTestPipeline(t, gen)

	n, attempted, err := p.GenerateAllNextSteps(context.Background())
	if err != nil {
		t.Fatalf("GenerateAllNextSteps on empty DB: %v", err)
	}
	if n != 0 {
		t.Fatalf("expected 0 generations, got %d", n)
	}
	if attempted != 0 {
		t.Fatalf("expected 0 targets attempted, got %d", attempted)
	}
	if gen.calls() != 0 {
		t.Fatalf("AI must not be called with zero targets, got %d calls", gen.calls())
	}
}

// TestGenerateAllNextSteps_RespectsActiveSnapshotLimit: the configured
// resolver.active_snapshot_limit caps how many stale targets one batch
// refreshes.
func TestGenerateAllNextSteps_RespectsActiveSnapshotLimit(t *testing.T) {
	gen := &mockGenerator{responses: []string{`{"title":"Do X","actions":[]}`}}
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer d.Close()
	cfg := &config.TargetsConfig{Resolver: config.TargetsResolverConfig{ActiveSnapshotLimit: 1}}
	p := New(d, cfg, gen, nil, "", nil)

	for _, text := range []string{"a", "b", "c"} {
		seedActiveTarget(t, d, text)
	}

	n, attempted, err := p.GenerateAllNextSteps(context.Background())
	if err != nil {
		t.Fatalf("GenerateAllNextSteps: %v", err)
	}
	if n != 1 {
		t.Fatalf("expected the limit to cap the batch at 1, got %d", n)
	}
	if attempted != 1 {
		t.Fatalf("expected the limit to cap attempted at 1, got %d", attempted)
	}
	if gen.calls() != 1 {
		t.Fatalf("expected exactly 1 AI call, got %d", gen.calls())
	}
}

// --- enriched next-step prompt (2026-08-18: the step becomes live) ---

// createChatTablesForNextStepTest creates the Swift-owned chat tables the way
// the Desktop app's GRDB ensureTable helpers do. They are absent from Go's
// goose schema, so the prompt builder must work with and without them.
func createChatTablesForNextStepTest(t *testing.T, d *db.DB) {
	t.Helper()
	stmts := []string{
		`CREATE TABLE chat_conversations (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			title TEXT NOT NULL DEFAULT '',
			session_id TEXT,
			context_type TEXT,
			context_id TEXT,
			created_at REAL NOT NULL,
			updated_at REAL NOT NULL)`,
		`CREATE TABLE chat_messages (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
			role TEXT NOT NULL,
			text TEXT NOT NULL,
			created_at REAL NOT NULL)`,
	}
	for _, s := range stmts {
		if _, err := d.Exec(s); err != nil {
			t.Fatalf("create chat table: %v", err)
		}
	}
}

// seedTargetChat inserts one conversation for the target plus the given turns
// (oldest first), spaced one minute apart ending now — no hardcoded dates.
func seedTargetChat(t *testing.T, d *db.DB, targetID int64, turns [][2]string) {
	t.Helper()
	res, err := d.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
		VALUES ('', 'target', ?, 0, 0)`, strconv.FormatInt(targetID, 10))
	if err != nil {
		t.Fatalf("insert conversation: %v", err)
	}
	convID, err := res.LastInsertId()
	if err != nil {
		t.Fatalf("conversation id: %v", err)
	}
	start := time.Now().Add(-time.Duration(len(turns)) * time.Minute)
	for i, turn := range turns {
		ts := float64(start.Add(time.Duration(i) * time.Minute).Unix())
		if _, err := d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at)
			VALUES (?, ?, ?, ?)`, convID, turn[0], turn[1], ts); err != nil {
			t.Fatalf("insert chat message: %v", err)
		}
	}
}

// notesJSON renders n notes, oldest first, stamped relative to now.
func notesJSON(t *testing.T, texts ...string) string {
	t.Helper()
	notes := make([]db.TargetNote, 0, len(texts))
	for i, text := range texts {
		notes = append(notes, db.TargetNote{
			Text:      text,
			CreatedAt: time.Now().Add(-time.Duration(len(texts)-i) * time.Hour).UTC().Format("2006-01-02T15:04:05Z"),
		})
	}
	raw, err := json.Marshal(notes)
	if err != nil {
		t.Fatalf("marshal notes: %v", err)
	}
	return string(raw)
}

// TestBuildNextStepPrompt_RendersProgressNotesAndChatExcerpt: the prompt is no
// longer blind to the work — progress, the last notes and the assistant
// conversation (system "Action applied" lines included) all reach the model.
func TestBuildNextStepPrompt_RendersProgressNotesAndChatExcerpt(t *testing.T) {
	p, d := makeTestPipeline(t, &mockGenerator{responses: []string{`{"title":"x","actions":[]}`}})
	createChatTablesForNextStepTest(t, d)

	id, err := d.CreateTarget(db.Target{
		Text: "Ship the v2 API", Status: "in_progress", Ownership: "mine", Priority: "high",
		SourceType: "manual", PeriodStart: "2026-07-01",
		Notes: notesJSON(t, "oldest note", "middle note", "newer note", "newest note"),
	})
	if err != nil {
		t.Fatalf("create target: %v", err)
	}
	// progress is derived from status on write, so set it directly.
	if _, err := d.Exec(`UPDATE targets SET progress = ? WHERE id = ?`, 0.42, id); err != nil {
		t.Fatalf("seed progress: %v", err)
	}
	seedTargetChat(t, d, id, [][2]string{
		{"user", "Collect the checklist from the channel"},
		{"assistant", "Here is the checklist I found"},
		{"system", "Action applied: added 4 sub-items. Continue with the task."},
	})

	target, err := d.GetTargetByID(int(id))
	if err != nil {
		t.Fatalf("reload target: %v", err)
	}
	prompt := p.buildNextStepPrompt(target)

	if !strings.Contains(prompt, "Progress: 42%") {
		t.Errorf("prompt missing progress percentage:\n%s", prompt)
	}
	for _, want := range []string{"newest note", "newer note", "middle note"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt missing recent note %q:\n%s", want, prompt)
		}
	}
	if strings.Contains(prompt, "oldest note") {
		t.Errorf("prompt should keep only the last %d notes:\n%s", nextStepNoteLimit, prompt)
	}
	if !strings.Contains(prompt, "Action applied: added 4 sub-items.") {
		t.Errorf("prompt missing the system action record:\n%s", prompt)
	}
	if !strings.Contains(prompt, "[user] Collect the checklist from the channel") {
		t.Errorf("prompt missing role-labelled user turn:\n%s", prompt)
	}
	if !strings.Contains(prompt, "[assistant] Here is the checklist I found") {
		t.Errorf("prompt missing role-labelled assistant turn:\n%s", prompt)
	}
	// Oldest first inside the excerpt.
	if strings.Index(prompt, "[user] Collect") > strings.Index(prompt, "Action applied:") {
		t.Errorf("chat excerpt must run oldest-first:\n%s", prompt)
	}
}

// TestBuildNextStepPrompt_ChatExcerptIsCapped: a long conversation can never
// dominate the user message — the excerpt is bounded by both the turn count and
// the character budget, and it is the NEWEST turns that survive.
func TestBuildNextStepPrompt_ChatExcerptIsCapped(t *testing.T) {
	p, d := makeTestPipeline(t, &mockGenerator{responses: []string{`{"title":"x","actions":[]}`}})
	createChatTablesForNextStepTest(t, d)

	id, err := d.CreateTarget(db.Target{
		Text: "Long chat", Status: "todo", Ownership: "mine", Priority: "medium",
		SourceType: "manual", PeriodStart: "2026-07-01",
	})
	if err != nil {
		t.Fatalf("create target: %v", err)
	}
	turns := make([][2]string, 0, 40)
	for i := 0; i < 40; i++ {
		turns = append(turns, [2]string{"user", fmt.Sprintf("turn-%02d %s", i, strings.Repeat("padding ", 60))})
	}
	seedTargetChat(t, d, id, turns)

	target, err := d.GetTargetByID(int(id))
	if err != nil {
		t.Fatalf("reload target: %v", err)
	}
	prompt := p.buildNextStepPrompt(target)

	rendered := strings.Count(prompt, "[user] turn-")
	if rendered == 0 {
		t.Fatalf("expected some turns in the excerpt:\n%s", prompt)
	}
	if rendered > nextStepChatTurnLimit {
		t.Errorf("excerpt rendered %d turns, above the %d-turn cap", rendered, nextStepChatTurnLimit)
	}
	if !strings.Contains(prompt, "turn-39") {
		t.Errorf("the newest turn must survive the cap:\n%s", prompt)
	}
	if strings.Contains(prompt, "turn-00") {
		t.Errorf("the oldest turn must be dropped by the cap:\n%s", prompt)
	}
	// The whole prompt stays close to the excerpt budget: the excerpt itself
	// must not exceed it by more than one truncated turn.
	if len(prompt) > nextStepChatCharBudget+nextStepChatTurnChars+1000 {
		t.Errorf("prompt too long (%d chars) — the char budget is not applied", len(prompt))
	}
}

// TestBuildNextStepPrompt_CyrillicExcerptGetsTheSameBudget: the budget is
// counted in runes, so a Cyrillic conversation keeps as many turns as a Latin
// one of the same visible length — a byte budget would silently halve it.
func TestBuildNextStepPrompt_CyrillicExcerptGetsTheSameBudget(t *testing.T) {
	p, d := makeTestPipeline(t, &mockGenerator{responses: []string{`{"title":"x","actions":[]}`}})
	createChatTablesForNextStepTest(t, d)

	id, err := d.CreateTarget(db.Target{
		Text: "Кириллица", Status: "todo", Ownership: "mine", Priority: "medium",
		SourceType: "manual", PeriodStart: "2026-07-01",
	})
	if err != nil {
		t.Fatalf("create target: %v", err)
	}
	turns := make([][2]string, 0, nextStepChatTurnLimit)
	for i := 0; i < nextStepChatTurnLimit; i++ {
		turns = append(turns, [2]string{"user", fmt.Sprintf("ход-%02d %s", i, strings.Repeat("текст ", 20))})
	}
	seedTargetChat(t, d, id, turns)

	target, err := d.GetTargetByID(int(id))
	if err != nil {
		t.Fatalf("reload target: %v", err)
	}
	prompt := p.buildNextStepPrompt(target)

	rendered := strings.Count(prompt, "[user] ход-")
	if rendered != nextStepChatTurnLimit {
		t.Errorf("rendered %d of %d Cyrillic turns — the budget is being counted in bytes",
			rendered, nextStepChatTurnLimit)
	}
}

// TestBuildNextStepPrompt_AbsentChatTablesStillBuilds: a CLI-only install has
// never run the Desktop app, so the Swift-owned chat tables do not exist — the
// builder degrades to no excerpt rather than failing the generation.
func TestBuildNextStepPrompt_AbsentChatTablesStillBuilds(t *testing.T) {
	gen := &mockGenerator{responses: []string{`{"title":"Do X","actions":[]}`}}
	p, d := makeTestPipeline(t, gen)

	id, err := d.CreateTarget(db.Target{
		Text: "No desktop here", Status: "todo", Ownership: "mine", Priority: "medium",
		SourceType: "manual", PeriodStart: "2026-07-01",
	})
	if err != nil {
		t.Fatalf("create target: %v", err)
	}
	// An out-of-range stored progress must clamp, not render nonsense.
	if _, err := d.Exec(`UPDATE targets SET progress = ? WHERE id = ?`, 1.4, id); err != nil {
		t.Fatalf("seed progress: %v", err)
	}
	target, err := d.GetTargetByID(int(id))
	if err != nil {
		t.Fatalf("reload target: %v", err)
	}

	prompt := p.buildNextStepPrompt(target)
	if !strings.Contains(prompt, "TARGET: No desktop here") {
		t.Fatalf("prompt not built without the chat tables:\n%s", prompt)
	}
	if !strings.Contains(prompt, "Progress: 100%") {
		t.Errorf("progress missing or unclamped:\n%s", prompt)
	}
	if strings.Contains(prompt, "Recent assistant conversation") {
		t.Errorf("no chat tables must mean no excerpt section:\n%s", prompt)
	}
	// And the generation itself still works end to end.
	if _, err := p.GenerateNextStep(context.Background(), int(id)); err != nil {
		t.Fatalf("GenerateNextStep without chat tables: %v", err)
	}
}

// TestNextStepSystemPrompt_ForbidsRepeatingADoneStep pins the rule added for
// the live-step work: history showing the step was carried out must push the
// model to what comes next.
func TestNextStepSystemPrompt_ForbidsRepeatingADoneStep(t *testing.T) {
	if !strings.Contains(nextStepSystemPrompt, "never repeat a step that is done") {
		t.Errorf("system prompt lost the already-carried-out rule:\n%s", nextStepSystemPrompt)
	}
}
