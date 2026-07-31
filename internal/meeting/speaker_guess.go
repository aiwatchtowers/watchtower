package meeting

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// SpeakerGuess is one LLM content-hint for an unnamed speaker cluster:
// "Speaker N looks like <candidate>". Suggestions are ephemeral — they are
// rendered as confirm chips in the Desktop transcript view and NEVER
// auto-applied; confirming one runs the manual-rename mechanics.
type SpeakerGuess struct {
	Speaker    string  `json:"speaker"`
	Candidate  string  `json:"candidate"`
	Confidence float64 `json:"confidence"`
	Evidence   string  `json:"evidence"`
}

// speakerNumberRe matches the default label of a cluster no voice print
// claimed — "Speaker 1", "Speaker 2", … Named clusters (voice-matched or
// manually renamed) never match, so only truly unnamed speakers are guessed.
var speakerNumberRe = regexp.MustCompile(`^Speaker \d+$`)

// Caps keeping the cheap-tier call bounded on hour-long meetings.
const (
	speakerGuessExcerptMaxChars   = 12000 // transcript excerpt in the user message
	speakerGuessSamplesPerSpeaker = 8     // utterance samples per unnamed speaker
	speakerGuessSampleMaxChars    = 240   // per-sample truncation
)

// GenerateSpeakerGuesses proposes names for the transcript's unnamed
// ("Speaker N") clusters from content clues (people addressing each other by
// name, self-references, role knowledge). eventID may be "" for ad-hoc
// recordings — the attendee list is then empty and the model leans on the
// transcript alone. Returns an error when every cluster is already named.
// The pipeline does NOT persist — suggestions ride the CLI envelope only.
func (p *Pipeline) GenerateSpeakerGuesses(ctx context.Context, eventID string, utterances []TranscriptUtterance) ([]SpeakerGuess, *digest.Usage, error) {
	unnamed := unnamedSpeakers(utterances)
	if len(unnamed) == 0 {
		return nil, nil, fmt.Errorf("no unnamed speakers to guess")
	}

	title, startTime, endTime, attendees := "(ad-hoc recording)", "", "", "[]"
	if eventID != "" && p.db != nil {
		if ev, err := p.db.GetCalendarEventByID(eventID); err == nil && ev != nil {
			title, startTime, endTime = ev.Title, ev.StartTime, ev.EndTime
			if strings.TrimSpace(ev.Attendees) != "" {
				attendees = ev.Attendees
			}
		}
	}

	lang := ""
	if p.cfg != nil {
		lang = p.cfg.Digest.Language
	}

	tmpl := p.loadSpeakerGuessPrompt()
	systemPrompt := fmt.Sprintf(tmpl, title, startTime, endTime, attendees, prompts.Directive(lang))
	userMessage := speakerGuessUserMessage(utterances, unnamed)

	aiResponse, usage, _, err := p.generator.Generate(
		digest.WithSource(ctx, "meeting.speaker_guess"), systemPrompt, userMessage, "")
	if err != nil {
		return nil, nil, fmt.Errorf("AI generation: %w", err)
	}

	var raw []SpeakerGuess
	if err := json.Unmarshal([]byte(cleanJSON(aiResponse)), &raw); err != nil {
		return nil, nil, fmt.Errorf("parsing AI response: %w (raw: %.300s)", err, aiResponse)
	}

	// Validation: an unknown speaker label (not in the unnamed set) or an
	// empty candidate is dropped, never a crash; confidence is clamped to
	// [0,1]. At most one suggestion per speaker — the first wins.
	known := make(map[string]bool, len(unnamed))
	for _, s := range unnamed {
		known[s] = true
	}
	seen := make(map[string]bool, len(raw))
	out := make([]SpeakerGuess, 0, len(raw))
	for _, g := range raw {
		g.Speaker = strings.TrimSpace(g.Speaker)
		g.Candidate = strings.TrimSpace(g.Candidate)
		g.Evidence = strings.TrimSpace(g.Evidence)
		if !known[g.Speaker] || g.Candidate == "" || seen[g.Speaker] {
			continue
		}
		if g.Confidence < 0 {
			g.Confidence = 0
		}
		if g.Confidence > 1 {
			g.Confidence = 1
		}
		seen[g.Speaker] = true
		out = append(out, g)
	}
	return out, usage, nil
}

// unnamedSpeakers returns the distinct "Speaker N" labels among non-deleted
// utterances, in first-appearance order.
func unnamedSpeakers(utterances []TranscriptUtterance) []string {
	var out []string
	seen := make(map[string]bool)
	for _, u := range utterances {
		if u.Deleted || seen[u.Speaker] || !speakerNumberRe.MatchString(u.Speaker) {
			continue
		}
		seen[u.Speaker] = true
		out = append(out, u.Speaker)
	}
	return out
}

// speakerGuessUserMessage assembles the transcript excerpt + per-speaker
// utterance samples. It travels in the USER message so the generators' stdin
// path keeps long transcripts clear of ARG_MAX (the recap/notes precedent).
func speakerGuessUserMessage(utterances []TranscriptUtterance, unnamed []string) string {
	var b strings.Builder
	b.WriteString("=== UNNAMED SPEAKERS ===\n")
	b.WriteString(strings.Join(unnamed, ", "))
	b.WriteString("\n\n=== UTTERANCE SAMPLES PER UNNAMED SPEAKER ===\n")
	for _, speaker := range unnamed {
		count := 0
		for _, u := range utterances {
			if u.Deleted || u.Speaker != speaker {
				continue
			}
			text := truncateRunes(u.Text, speakerGuessSampleMaxChars)
			fmt.Fprintf(&b, "[%s] %s\n", speaker, text)
			count++
			if count >= speakerGuessSamplesPerSpeaker {
				break
			}
		}
	}
	b.WriteString("\n=== TRANSCRIPT EXCERPT ===\n")
	b.WriteString(truncateRunes(RenderTranscriptSegments(utterances), speakerGuessExcerptMaxChars))
	return b.String()
}

// truncateRunes caps s at max runes (never splitting a UTF-8 sequence —
// transcripts are mostly ru/uk) and marks the cut with an ellipsis.
func truncateRunes(s string, max int) string {
	runes := []rune(s)
	if len(runes) <= max {
		return s
	}
	return string(runes[:max]) + "…"
}

func (p *Pipeline) loadSpeakerGuessPrompt() string {
	if p.promptStore != nil {
		if tmpl, _, err := p.promptStore.Get(prompts.MeetingSpeakerGuess); err == nil && tmpl != "" {
			return tmpl
		}
	}
	if tmpl, ok := prompts.Defaults[prompts.MeetingSpeakerGuess]; ok && tmpl != "" {
		return tmpl
	}
	return defaultSpeakerGuessPromptFallback
}

const defaultSpeakerGuessPromptFallback = `Identify unnamed speakers in a meeting transcript by content clues. Event: %s (%s-%s, attendees: %s). %s
Return ONLY a JSON array of {"speaker","candidate","confidence","evidence"}.`
