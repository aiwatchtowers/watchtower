package targets

import (
	"context"
	"encoding/json"
	"testing"

	"watchtower/internal/db"
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
