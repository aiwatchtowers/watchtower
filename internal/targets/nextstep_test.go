package targets

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

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

	n, err := p.GenerateAllNextSteps(context.Background())
	if err != nil {
		t.Fatalf("GenerateAllNextSteps: %v", err)
	}
	if n != 2 {
		t.Fatalf("expected 2 successful generations, got %d", n)
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

	n, err := p.GenerateAllNextSteps(context.Background())
	if err != nil {
		t.Fatalf("GenerateAllNextSteps on empty DB: %v", err)
	}
	if n != 0 {
		t.Fatalf("expected 0 generations, got %d", n)
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

	n, err := p.GenerateAllNextSteps(context.Background())
	if err != nil {
		t.Fatalf("GenerateAllNextSteps: %v", err)
	}
	if n != 1 {
		t.Fatalf("expected the limit to cap the batch at 1, got %d", n)
	}
	if gen.calls() != 1 {
		t.Fatalf("expected exactly 1 AI call, got %d", gen.calls())
	}
}
