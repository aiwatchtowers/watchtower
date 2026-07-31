package meeting

import (
	"context"
	"strings"
	"testing"
)

func guessUtterances() []TranscriptUtterance {
	return []TranscriptUtterance{
		{Idx: 0, StartSec: 0, EndSec: 5, Speaker: "Я", Text: "привет всем"},
		{Idx: 1, StartSec: 5, EndSec: 10, Speaker: "Speaker 1", Text: "привет, это Саша"},
		{Idx: 2, StartSec: 10, EndSec: 15, Speaker: "Speaker 2", Text: "начнём со статуса"},
		{Idx: 3, StartSec: 15, EndSec: 20, Speaker: "Vadym", Text: "ок, поехали"},
	}
}

func TestGenerateSpeakerGuessesValidatesAndKeepsKnownSpeakers(t *testing.T) {
	mock := &recordingMockGenerator{response: `[
		{"speaker":"Speaker 1","candidate":"Саша","confidence":0.9,"evidence":"introduces himself"},
		{"speaker":"Speaker 9","candidate":"Ghost","confidence":0.8,"evidence":"unknown cluster"},
		{"speaker":"Vadym","candidate":"Vadym 2","confidence":0.8,"evidence":"already named"},
		{"speaker":"Speaker 2","candidate":"","confidence":0.5,"evidence":"empty candidate"},
		{"speaker":"Speaker 2","candidate":"Оля","confidence":1.7,"evidence":"clamped"}
	]`}
	pipe := &Pipeline{generator: mock}

	guesses, _, err := pipe.GenerateSpeakerGuesses(context.Background(), "", guessUtterances())
	if err != nil {
		t.Fatalf("GenerateSpeakerGuesses: %v", err)
	}
	if len(guesses) != 2 {
		t.Fatalf("expected 2 surviving guesses, got %d: %+v", len(guesses), guesses)
	}
	if guesses[0].Speaker != "Speaker 1" || guesses[0].Candidate != "Саша" {
		t.Fatalf("unexpected first guess: %+v", guesses[0])
	}
	if guesses[1].Speaker != "Speaker 2" || guesses[1].Candidate != "Оля" {
		t.Fatalf("unexpected second guess: %+v", guesses[1])
	}
	if guesses[1].Confidence != 1 {
		t.Fatalf("confidence must be clamped to 1, got %v", guesses[1].Confidence)
	}
}

func TestGenerateSpeakerGuessesFirstSuggestionPerSpeakerWins(t *testing.T) {
	mock := &recordingMockGenerator{response: `[
		{"speaker":"Speaker 1","candidate":"Саша","confidence":0.9,"evidence":"a"},
		{"speaker":"Speaker 1","candidate":"Петя","confidence":0.4,"evidence":"b"}
	]`}
	pipe := &Pipeline{generator: mock}

	guesses, _, err := pipe.GenerateSpeakerGuesses(context.Background(), "", guessUtterances())
	if err != nil {
		t.Fatalf("GenerateSpeakerGuesses: %v", err)
	}
	if len(guesses) != 1 || guesses[0].Candidate != "Саша" {
		t.Fatalf("expected first suggestion to win, got %+v", guesses)
	}
}

func TestGenerateSpeakerGuessesNoUnnamedSpeakersFails(t *testing.T) {
	mock := &recordingMockGenerator{response: `[]`}
	pipe := &Pipeline{generator: mock}

	utterances := []TranscriptUtterance{
		{Idx: 0, Speaker: "Я", Text: "монолог"},
		{Idx: 1, Speaker: "Vadym", Text: "ответ"},
	}
	if _, _, err := pipe.GenerateSpeakerGuesses(context.Background(), "", utterances); err == nil ||
		!strings.Contains(err.Error(), "no unnamed speakers") {
		t.Fatalf("expected no-unnamed-speakers error, got %v", err)
	}
}

// Degenerate but valid: an unnamed speaker exists only among deleted
// utterances — it must not be guessed for (its text is out of the transcript).
func TestGenerateSpeakerGuessesDeletedOnlySpeakerIsNotUnnamed(t *testing.T) {
	mock := &recordingMockGenerator{response: `[]`}
	pipe := &Pipeline{generator: mock}

	utterances := []TranscriptUtterance{
		{Idx: 0, Speaker: "Я", Text: "монолог"},
		{Idx: 1, Speaker: "Speaker 1", Text: "удалено", Deleted: true},
	}
	if _, _, err := pipe.GenerateSpeakerGuesses(context.Background(), "", utterances); err == nil ||
		!strings.Contains(err.Error(), "no unnamed speakers") {
		t.Fatalf("deleted-only cluster must not count as unnamed, got %v", err)
	}
}

func TestGenerateSpeakerGuessesEmptyModelOutputIsValid(t *testing.T) {
	mock := &recordingMockGenerator{response: "```json\n[]\n```"}
	pipe := &Pipeline{generator: mock}

	guesses, _, err := pipe.GenerateSpeakerGuesses(context.Background(), "", guessUtterances())
	if err != nil {
		t.Fatalf("GenerateSpeakerGuesses: %v", err)
	}
	if len(guesses) != 0 {
		t.Fatalf("expected no guesses, got %+v", guesses)
	}
}

func TestGenerateSpeakerGuessesMalformedResponseFails(t *testing.T) {
	mock := &recordingMockGenerator{response: `{"not":"an array"}`}
	pipe := &Pipeline{generator: mock}

	if _, _, err := pipe.GenerateSpeakerGuesses(context.Background(), "", guessUtterances()); err == nil ||
		!strings.Contains(err.Error(), "parsing AI response") {
		t.Fatalf("expected parse error, got %v", err)
	}
}

func TestGenerateSpeakerGuessesSamplesTravelInUserMessage(t *testing.T) {
	mock := &recordingMockGenerator{response: `[]`}
	pipe := &Pipeline{generator: mock}

	if _, _, err := pipe.GenerateSpeakerGuesses(context.Background(), "", guessUtterances()); err != nil {
		t.Fatalf("GenerateSpeakerGuesses: %v", err)
	}
	if !strings.Contains(mock.lastUserMessage, "Speaker 1, Speaker 2") {
		t.Fatalf("unnamed speaker list must be in the user message, got %q", mock.lastUserMessage)
	}
	if !strings.Contains(mock.lastUserMessage, "это Саша") {
		t.Fatalf("cluster samples must be in the user message (stdin path), got %q", mock.lastUserMessage)
	}
	if strings.Contains(mock.lastSystemPrompt, "это Саша") {
		t.Fatalf("transcript must NOT be embedded in the system prompt")
	}
}
