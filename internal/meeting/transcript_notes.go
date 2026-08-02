package meeting

import (
	"context"
	"fmt"
	"strings"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// GenerateTranscriptNotes produces publishable markdown meeting notes from a
// full meeting transcript. Like GenerateTranscriptRecap, the transcript
// travels in the USER message so the generators' stdin path keeps hour-long
// transcripts clear of ARG_MAX. eventID may be "" for ad-hoc recordings.
// The pipeline does NOT persist — the CLI caller writes notes_md.
func (p *Pipeline) GenerateTranscriptNotes(ctx context.Context, eventID, transcript string) (string, *digest.Usage, error) {
	trimmed := strings.TrimSpace(transcript)
	if trimmed == "" {
		return "", nil, fmt.Errorf("transcript is empty")
	}

	title, startTime, endTime, attendees, description := "(ad-hoc recording)", "", "", "", ""
	recapBlock := "(none)"
	if eventID != "" && p.db != nil {
		if ev, err := p.db.GetCalendarEventByID(eventID); err == nil && ev != nil {
			title, startTime, endTime = ev.Title, ev.StartTime, ev.EndTime
			attendees, description = ev.Attendees, ev.Description
		}
		if recap, err := p.db.GetMeetingRecap(eventID); err == nil && recap != nil {
			recapBlock = recap.RecapJSON
		}
	}

	lang := ""
	if p.cfg != nil {
		lang = p.cfg.Digest.Language
	}

	tmpl := p.loadNotesPrompt()
	systemPrompt := fmt.Sprintf(tmpl,
		title, startTime, endTime, attendees, description,
		recapBlock,
		prompts.Directive(lang),
	)
	userMessage := "Below is the full single-track meeting transcript (speakers are not labeled). " +
		"Generate the meeting-notes markdown exactly per the system prompt.\n\n=== TRANSCRIPT ===\n" + trimmed

	aiResponse, usage, _, err := p.generator.Generate(ctx, systemPrompt, userMessage, "")
	if err != nil {
		return "", nil, fmt.Errorf("AI generation: %w", err)
	}
	notes := stripMarkdownFence(aiResponse)
	if notes == "" {
		return "", nil, fmt.Errorf("AI returned empty notes")
	}
	return notes, usage, nil
}

// stripMarkdownFence removes a single wrapping ```/```markdown code fence if
// the model added one despite instructions, and trims whitespace.
func stripMarkdownFence(s string) string {
	out := strings.TrimSpace(s)
	if !strings.HasPrefix(out, "```") {
		return out
	}
	lines := strings.Split(out, "\n")
	if len(lines) < 2 {
		return out
	}
	// Drop the opening fence line (``` or ```markdown) and a trailing fence.
	lines = lines[1:]
	if strings.TrimSpace(lines[len(lines)-1]) == "```" {
		lines = lines[:len(lines)-1]
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

func (p *Pipeline) loadNotesPrompt() string {
	if p.promptStore != nil {
		if tmpl, _, err := p.promptStore.Get(prompts.MeetingNotes); err == nil && tmpl != "" {
			return tmpl
		}
	}
	if tmpl, ok := prompts.Defaults[prompts.MeetingNotes]; ok && tmpl != "" {
		return tmpl
	}
	return defaultNotesPromptFallback
}

const defaultNotesPromptFallback = `Write publishable markdown meeting notes. Event: %s (%s-%s, attendees: %s, description: %s). Recap: %s. %s
Return ONLY markdown.`
