package meeting

import (
	"context"
	"strings"
	"testing"

	"watchtower/internal/digest"
)

// recordingMockGenerator implements digest.Generator and records the last
// systemPrompt/userMessage it was called with, so tests can assert where the
// transcript travels (user message vs system prompt).
type recordingMockGenerator struct {
	response         string
	err              error
	lastSystemPrompt string
	lastUserMessage  string
}

func (m *recordingMockGenerator) Generate(_ context.Context, systemPrompt, userMessage, _ string) (string, *digest.Usage, string, error) {
	m.lastSystemPrompt = systemPrompt
	m.lastUserMessage = userMessage
	return m.response, &digest.Usage{}, "", m.err
}

const transcriptRecapMockResponse = `{"summary":"s","key_decisions":["d"],"action_items":[],"open_questions":[]}`

func TestGenerateTranscriptRecapAdHoc(t *testing.T) {
	mock := &recordingMockGenerator{response: transcriptRecapMockResponse}
	pipe := &Pipeline{generator: mock}

	transcript := "we agreed to ship v2 on friday"
	res, usage, err := pipe.GenerateTranscriptRecap(context.Background(), "", transcript)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Summary != "s" {
		t.Errorf("summary = %q, want %q", res.Summary, "s")
	}
	if len(res.KeyDecisions) != 1 || res.KeyDecisions[0] != "d" {
		t.Errorf("key_decisions = %v, want [d]", res.KeyDecisions)
	}
	if usage == nil {
		t.Error("usage is nil, want non-nil")
	}
	if !strings.Contains(mock.lastUserMessage, transcript) {
		t.Errorf("user message should contain the transcript, got: %q", mock.lastUserMessage)
	}
	if strings.Contains(mock.lastSystemPrompt, transcript) {
		t.Error("system prompt must NOT contain the transcript (it moved to the user message)")
	}
	if !strings.Contains(mock.lastSystemPrompt, "(ad-hoc recording)") {
		t.Errorf("system prompt should contain %q for the title slot, got: %.500s", "(ad-hoc recording)", mock.lastSystemPrompt)
	}
}

func TestGenerateTranscriptRecapWithEvent(t *testing.T) {
	database := openTestDB(t)
	seedTestEvent(t, database)

	mock := &recordingMockGenerator{response: transcriptRecapMockResponse}
	pipe := &Pipeline{db: database, generator: mock}

	res, usage, err := pipe.GenerateTranscriptRecap(context.Background(), "evt1", "we agreed to ship v2 on friday")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res == nil || usage == nil {
		t.Fatal("expected non-nil result and usage")
	}
	if !strings.Contains(mock.lastSystemPrompt, "1:1 with Alice") {
		t.Errorf("system prompt should contain the event title, got: %.500s", mock.lastSystemPrompt)
	}
	if strings.Contains(mock.lastSystemPrompt, "(ad-hoc recording)") {
		t.Error("system prompt should not use the ad-hoc placeholder when the event exists")
	}
}

func TestGenerateTranscriptRecapInjectsMeetingNotes(t *testing.T) {
	database := openTestDB(t)
	seedTestEvent(t, database)
	for _, note := range []struct{ typ, text string }{
		{"question", "should we delay the launch?"},
		{"note", "budget approved last week"},
	} {
		if _, err := database.Exec(`INSERT INTO meeting_notes (event_id, type, text, sort_order)
			VALUES (?, ?, ?, 0)`, "evt1", note.typ, note.text); err != nil {
			t.Fatalf("seeding meeting note: %v", err)
		}
	}

	mock := &recordingMockGenerator{response: transcriptRecapMockResponse}
	pipe := &Pipeline{db: database, generator: mock}

	_, _, err := pipe.GenerateTranscriptRecap(context.Background(), "evt1", "we agreed to ship v2 on friday")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(mock.lastSystemPrompt, "should we delay the launch?") {
		t.Errorf("system prompt should contain the seeded topic (question), got: %.800s", mock.lastSystemPrompt)
	}
	if !strings.Contains(mock.lastSystemPrompt, "budget approved last week") {
		t.Errorf("system prompt should contain the seeded freeform note, got: %.800s", mock.lastSystemPrompt)
	}
}

func TestGenerateTranscriptRecapEventMissingKeepsPlaceholder(t *testing.T) {
	database := openTestDB(t) // no event seeded — eventID points at nothing

	mock := &recordingMockGenerator{response: transcriptRecapMockResponse}
	pipe := &Pipeline{db: database, generator: mock}

	res, _, err := pipe.GenerateTranscriptRecap(context.Background(), "evt-missing", "we agreed to ship v2 on friday")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res == nil {
		t.Fatal("expected a recap result for a missing event")
	}
	if !strings.Contains(mock.lastSystemPrompt, "(ad-hoc recording)") {
		t.Errorf("system prompt should keep the %q placeholder when the event is missing, got: %.500s",
			"(ad-hoc recording)", mock.lastSystemPrompt)
	}
}

func TestGenerateTranscriptRecapEmptyTranscript(t *testing.T) {
	mock := &recordingMockGenerator{response: transcriptRecapMockResponse}
	pipe := &Pipeline{generator: mock}

	_, _, err := pipe.GenerateTranscriptRecap(context.Background(), "", "   \n\t ")
	if err == nil {
		t.Fatal("expected error for whitespace-only transcript, got nil")
	}
}

func TestGenerateTranscriptRecapBadAIJSON(t *testing.T) {
	mock := &recordingMockGenerator{response: "not json"}
	pipe := &Pipeline{generator: mock}

	_, _, err := pipe.GenerateTranscriptRecap(context.Background(), "", "real transcript text")
	if err == nil {
		t.Fatal("expected error for malformed AI JSON, got nil")
	}
}

func TestGenerateTranscriptRecapIdeasTrimmed(t *testing.T) {
	mock := &recordingMockGenerator{response: `{"summary":"s","key_decisions":[],"action_items":[],"open_questions":[],"ideas":["idea one",""]}`}
	pipe := &Pipeline{generator: mock}

	res, _, err := pipe.GenerateTranscriptRecap(context.Background(), "", "real transcript text")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(res.Ideas) != 1 || res.Ideas[0] != "idea one" {
		t.Errorf("expected 1 trimmed idea, got %v", res.Ideas)
	}
}

func TestGenerateTranscriptRecapIdeasAbsentIsEmpty(t *testing.T) {
	mock := &recordingMockGenerator{response: transcriptRecapMockResponse}
	pipe := &Pipeline{generator: mock}

	res, _, err := pipe.GenerateTranscriptRecap(context.Background(), "", "real transcript text")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(res.Ideas) != 0 {
		t.Errorf("expected no ideas when field is absent, got %v", res.Ideas)
	}
}
