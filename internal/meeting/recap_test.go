package meeting

import (
	"context"
	"strings"
	"testing"

	"watchtower/internal/digest"
)

// newTestPipelineForRecap builds a Pipeline with a nil DB (event/notes loading
// is non-fatal) and the provided generator. Pass nil for gen to get a
// zero-response mock.
func newTestPipelineForRecap(t *testing.T, gen digest.Generator) *Pipeline {
	t.Helper()
	if gen == nil {
		gen = &mockGenerator{response: ""}
	}
	return &Pipeline{
		generator: gen,
	}
}

func TestGenerateRecap_EmptyTextReturnsError(t *testing.T) {
	p := newTestPipelineForRecap(t, nil)
	_, err := p.GenerateRecap(context.Background(), "evt-1", "")
	if err == nil {
		t.Fatal("expected error for empty source text, got nil")
	}
}

func TestGenerateRecap_WhitespaceOnlyTextReturnsError(t *testing.T) {
	p := newTestPipelineForRecap(t, nil)
	_, err := p.GenerateRecap(context.Background(), "evt-1", "   \n\t  ")
	if err == nil {
		t.Fatal("expected error for whitespace-only source text, got nil")
	}
}

func TestGenerateRecap_HappyPath(t *testing.T) {
	aiResponse := `{
      "summary": "Talked about the launch.",
      "key_decisions": ["Ship Friday"],
      "action_items": ["Vadym to draft launch post"],
      "open_questions": ["Pricing tier?"]
    }`
	p := newTestPipelineForRecap(t, &mockGenerator{response: aiResponse})

	res, err := p.GenerateRecap(context.Background(), "evt-1", "raw notes")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Summary != "Talked about the launch." {
		t.Errorf("summary = %q", res.Summary)
	}
	if len(res.KeyDecisions) != 1 || res.KeyDecisions[0] != "Ship Friday" {
		t.Errorf("key_decisions = %v", res.KeyDecisions)
	}
	if len(res.ActionItems) != 1 {
		t.Errorf("action_items = %v", res.ActionItems)
	}
	if len(res.OpenQuestions) != 1 || res.OpenQuestions[0] != "Pricing tier?" {
		t.Errorf("open_questions = %v", res.OpenQuestions)
	}
}

func TestGenerateRecap_StripsMarkdownFences(t *testing.T) {
	aiResponse := "```json\n" + `{"summary":"x","key_decisions":[],"action_items":[],"open_questions":[]}` + "\n```"
	p := newTestPipelineForRecap(t, &mockGenerator{response: aiResponse})

	res, err := p.GenerateRecap(context.Background(), "evt-1", "raw")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Summary != "x" {
		t.Errorf("summary = %q, want %q", res.Summary, "x")
	}
}

func TestGenerateRecap_MalformedJSONErrorsWithSnippet(t *testing.T) {
	aiResponse := "not json at all, full of garbage and other text"
	p := newTestPipelineForRecap(t, &mockGenerator{response: aiResponse})

	_, err := p.GenerateRecap(context.Background(), "evt-1", "raw")
	if err == nil {
		t.Fatal("expected parse error for malformed JSON")
	}
	if !strings.Contains(err.Error(), "garbage") {
		t.Errorf("error should include raw snippet, got: %v", err)
	}
}

func TestGenerateRecap_TrimsAndDropsEmptyArrayEntries(t *testing.T) {
	aiResponse := `{
      "summary": "  hello  ",
      "key_decisions": ["", "  decision  ", " "],
      "action_items": [],
      "open_questions": []
    }`
	p := newTestPipelineForRecap(t, &mockGenerator{response: aiResponse})

	res, err := p.GenerateRecap(context.Background(), "evt-1", "raw")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Summary != "hello" {
		t.Errorf("summary not trimmed: %q", res.Summary)
	}
	if len(res.KeyDecisions) != 1 || res.KeyDecisions[0] != "decision" {
		t.Errorf("expected 1 cleaned decision, got %v", res.KeyDecisions)
	}
	if len(res.ActionItems) != 0 {
		t.Errorf("expected empty action_items, got %v", res.ActionItems)
	}
}

func TestGenerateRecap_IdeasTrimmed(t *testing.T) {
	aiResponse := `{
      "summary": "x",
      "key_decisions": [],
      "action_items": [],
      "open_questions": [],
      "ideas": ["idea one", ""]
    }`
	p := newTestPipelineForRecap(t, &mockGenerator{response: aiResponse})

	res, err := p.GenerateRecap(context.Background(), "evt-1", "raw")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(res.Ideas) != 1 || res.Ideas[0] != "idea one" {
		t.Errorf("expected 1 trimmed idea, got %v", res.Ideas)
	}
}

func TestGenerateRecap_IdeasAbsentIsEmpty(t *testing.T) {
	aiResponse := `{"summary":"x","key_decisions":[],"action_items":[],"open_questions":[]}`
	p := newTestPipelineForRecap(t, &mockGenerator{response: aiResponse})

	res, err := p.GenerateRecap(context.Background(), "evt-1", "raw")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(res.Ideas) != 0 {
		t.Errorf("expected no ideas when field is absent, got %v", res.Ideas)
	}
}

// TestGenerateRecap_UnlabeledPasteTextGetsConditionalGuidance covers the
// paste flow's own rendered prompt (GenerateRecap, unlike
// GenerateTranscriptRecap, puts the source text into the SYSTEM prompt, not
// the user message — this is the one-element trap named in the wave-5 plan:
// a labeled-transcript-only fixture across GenerateTranscriptRecap tests
// would leave the paste flow's rendered prompt entirely unasserted). Raw
// pasted notes never carry "[label]" line prefixes, so the system prompt
// must still describe the unlabeled case and must not claim speakers are
// never labeled (the stale, now-removed claim).
func TestGenerateRecap_UnlabeledPasteTextGetsConditionalGuidance(t *testing.T) {
	mock := &recordingMockGenerator{response: `{"summary":"s","key_decisions":[],"action_items":[],"open_questions":[]}`}
	pipe := &Pipeline{generator: mock}

	unlabeledPaste := "we agreed to ship v2 on friday, budget approved"
	_, err := pipe.GenerateRecap(context.Background(), "evt-1", unlabeledPaste)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if strings.Contains(mock.lastSystemPrompt, "speakers are not labeled") {
		t.Errorf("system prompt must not claim speakers are never labeled, got: %.500s", mock.lastSystemPrompt)
	}
	if !strings.Contains(mock.lastSystemPrompt, "do not invent a speaker") {
		t.Errorf("system prompt must describe the unlabeled case, got: %.500s", mock.lastSystemPrompt)
	}
	if !strings.Contains(mock.lastSystemPrompt, unlabeledPaste) {
		t.Errorf("system prompt should still carry the pasted text, got: %.500s", mock.lastSystemPrompt)
	}
}
