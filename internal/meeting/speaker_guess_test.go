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

// A candidate colliding with a reserved label — the owner's «Я» (any case) or
// the "Speaker N" pattern — must be dropped: confirming it would merge a
// stranger's cluster into the owner's identity and mint a voice print that
// corrupts voice matching in every future recording.
func TestGenerateSpeakerGuessesDropsReservedLabelCandidates(t *testing.T) {
	mock := &recordingMockGenerator{response: `[
		{"speaker":"Speaker 1","candidate":"Я","confidence":0.9,"evidence":"self reference"},
		{"speaker":"Speaker 1","candidate":"я","confidence":0.9,"evidence":"lowercase self"},
		{"speaker":"Speaker 1","candidate":"Speaker 3","confidence":0.9,"evidence":"renumber"},
		{"speaker":"Speaker 2","candidate":"Саша","confidence":0.8,"evidence":"named"}
	]`}
	pipe := &Pipeline{generator: mock}

	guesses, _, err := pipe.GenerateSpeakerGuesses(context.Background(), "", guessUtterances())
	if err != nil {
		t.Fatalf("GenerateSpeakerGuesses: %v", err)
	}
	if len(guesses) != 1 {
		t.Fatalf("expected only the non-reserved candidate to survive, got %+v", guesses)
	}
	if guesses[0].Speaker != "Speaker 2" || guesses[0].Candidate != "Саша" {
		t.Fatalf("unexpected surviving guess: %+v", guesses[0])
	}
}

// Event-linked path: the event's title/time/attendees fill the system-prompt
// slots — a verb/args drift in the 5-verb template would ship "%!s(MISSING)"
// (or leak "%!(EXTRA") into the prompt with every eventID:"" test green.
func TestGenerateSpeakerGuessesEventLinkedPromptFillsSlots(t *testing.T) {
	database := openTestDB(t)
	seedTestEvent(t, database)

	mock := &recordingMockGenerator{response: `[]`}
	pipe := &Pipeline{db: database, generator: mock}

	if _, _, err := pipe.GenerateSpeakerGuesses(context.Background(), "evt1", guessUtterances()); err != nil {
		t.Fatalf("GenerateSpeakerGuesses: %v", err)
	}
	if !strings.Contains(mock.lastSystemPrompt, "1:1 with Alice") {
		t.Fatalf("system prompt should contain the event title, got: %.500s", mock.lastSystemPrompt)
	}
	if !strings.Contains(mock.lastSystemPrompt, "alice@example.com") {
		t.Fatalf("system prompt should contain the attendees JSON, got: %.500s", mock.lastSystemPrompt)
	}
	if strings.Contains(mock.lastSystemPrompt, "(ad-hoc recording)") {
		t.Fatal("system prompt should not use the ad-hoc placeholder when the event exists")
	}
	if strings.Contains(mock.lastSystemPrompt, "%!") {
		t.Fatalf("system prompt has a template/args drift: %.500s", mock.lastSystemPrompt)
	}
}

// A missing event degrades to the ad-hoc placeholders — never an error.
func TestGenerateSpeakerGuessesUnknownEventFallsBackToAdHoc(t *testing.T) {
	database := openTestDB(t)

	mock := &recordingMockGenerator{response: `[]`}
	pipe := &Pipeline{db: database, generator: mock}

	if _, _, err := pipe.GenerateSpeakerGuesses(context.Background(), "ghost-evt", guessUtterances()); err != nil {
		t.Fatalf("GenerateSpeakerGuesses: %v", err)
	}
	if !strings.Contains(mock.lastSystemPrompt, "(ad-hoc recording)") {
		t.Fatalf("system prompt should fall back to the ad-hoc placeholder, got: %.500s", mock.lastSystemPrompt)
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

// truncateRunes must cut on rune boundaries (ru/uk transcripts are multibyte)
// and mark the cut; short strings pass through untouched.
func TestTruncateRunes(t *testing.T) {
	if got := truncateRunes("привет", 10); got != "привет" {
		t.Fatalf("short string must pass through, got %q", got)
	}
	if got := truncateRunes("привет мир", 6); got != "привет…" {
		t.Fatalf("expected rune-safe cut with ellipsis, got %q", got)
	}
	if got := truncateRunes("", 5); got != "" {
		t.Fatalf("empty string must stay empty, got %q", got)
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
