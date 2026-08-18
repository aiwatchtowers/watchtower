package targets

import (
	"context"
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
