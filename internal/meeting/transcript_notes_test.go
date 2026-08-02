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
