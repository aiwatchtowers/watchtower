package meeting

import (
	"context"
	"strings"
	"testing"
)

func TestGenerateTranscriptNotesEmptyTranscriptFails(t *testing.T) {
	mock := &recordingMockGenerator{response: "# Notes"}
	pipe := &Pipeline{generator: mock}

	_, _, err := pipe.GenerateTranscriptNotes(context.Background(), "", "   ")
	if err == nil || !strings.Contains(err.Error(), "empty") {
		t.Fatalf("expected empty-transcript error, got %v", err)
	}
}

func TestGenerateTranscriptNotesTranscriptInUserMessage(t *testing.T) {
	mock := &recordingMockGenerator{response: "# Weekly Sync\n\n## Summary\nShipped."}
	pipe := &Pipeline{generator: mock}

	out, _, err := pipe.GenerateTranscriptNotes(context.Background(), "", "we agreed to ship v2")
	if err != nil {
		t.Fatalf("GenerateTranscriptNotes: %v", err)
	}
	if out != "# Weekly Sync\n\n## Summary\nShipped." {
		t.Fatalf("unexpected notes output: %q", out)
	}
	if !strings.Contains(mock.lastUserMessage, "we agreed to ship v2") {
		t.Fatalf("transcript must travel in the user message (stdin path), got %q", mock.lastUserMessage)
	}
	if strings.Contains(mock.lastSystemPrompt, "we agreed to ship v2") {
		t.Fatalf("transcript must NOT be embedded in the system prompt")
	}
}

// TestGenerateTranscriptNotesUserMessageDropsStaleLabelClaim pins the
// 2026-09-13 fix (owner decision 13): the user message must no longer claim
// speakers are never labeled, even when the transcript carries diarized
// "[label]" line prefixes (RenderTranscriptSegments, internal/meeting/segments.go).
func TestGenerateTranscriptNotesUserMessageDropsStaleLabelClaim(t *testing.T) {
	mock := &recordingMockGenerator{response: "# Notes"}
	pipe := &Pipeline{generator: mock}

	labeledTranscript := "[Я] привет как дела\n[Speaker 1] нормально\n[Я] отлично"
	_, _, err := pipe.GenerateTranscriptNotes(context.Background(), "", labeledTranscript)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if strings.Contains(mock.lastUserMessage, "not labeled") {
		t.Errorf("user message must not claim speakers are not labeled, got: %q", mock.lastUserMessage)
	}
	if !strings.Contains(mock.lastUserMessage, labeledTranscript) {
		t.Errorf("user message should still carry the full labeled transcript, got: %q", mock.lastUserMessage)
	}
}

func TestGenerateTranscriptNotesStripsCodeFence(t *testing.T) {
	mock := &recordingMockGenerator{response: "```markdown\n# Notes\nbody\n```"}
	pipe := &Pipeline{generator: mock}

	out, _, err := pipe.GenerateTranscriptNotes(context.Background(), "", "hello there")
	if err != nil {
		t.Fatalf("GenerateTranscriptNotes: %v", err)
	}
	if out != "# Notes\nbody" {
		t.Fatalf("fence must be stripped, got %q", out)
	}
}
