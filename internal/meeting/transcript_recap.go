package meeting

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// GenerateTranscriptRecap produces a RecapResult from a full meeting
// transcript. Unlike GenerateRecap, the transcript travels in the USER
// message (not the system prompt) so the generators' stdin path keeps
// hour-long transcripts clear of ARG_MAX. eventID may be "" for ad-hoc
// recordings. The pipeline does NOT persist — the CLI caller writes.
func (p *Pipeline) GenerateTranscriptRecap(ctx context.Context, eventID, transcript string) (*RecapResult, *digest.Usage, error) {
	trimmed := strings.TrimSpace(transcript)
	if trimmed == "" {
		return nil, nil, fmt.Errorf("transcript is empty")
	}

	title, startTime, endTime, attendees, description := "(ad-hoc recording)", "", "", "", ""
	topicsBlock, notesBlock := "(none)", "(none)"
	if eventID != "" && p.db != nil {
		if ev, err := p.db.GetCalendarEventByID(eventID); err == nil && ev != nil {
			title, startTime, endTime = ev.Title, ev.StartTime, ev.EndTime
			attendees, description = ev.Attendees, ev.Description
		}
		// meeting_notes context — same extraction as GenerateRecap
		topicsBlock, notesBlock = p.meetingNotesBlocks(eventID)
	}

	lang := ""
	if p.cfg != nil {
		lang = p.cfg.Digest.Language
	}

	tmpl := p.loadRecapPrompt()
	systemPrompt := fmt.Sprintf(tmpl,
		title, startTime, endTime, attendees, description,
		topicsBlock, notesBlock,
		"(the full meeting transcript is provided in the user message)",
		prompts.Directive(lang),
	)
	userMessage := "Below is the full single-track meeting transcript (speakers are not labeled). " +
		"Generate the recap JSON exactly per the system prompt.\n\n=== TRANSCRIPT ===\n" + trimmed

	aiResponse, usage, _, err := p.generator.Generate(ctx, systemPrompt, userMessage, "")
	if err != nil {
		return nil, nil, fmt.Errorf("AI generation: %w", err)
	}
	var raw RecapResult
	if err := json.Unmarshal([]byte(cleanJSON(aiResponse)), &raw); err != nil {
		return nil, nil, fmt.Errorf("parsing AI response: %w (raw: %.300s)", err, aiResponse)
	}
	raw.Summary = strings.TrimSpace(raw.Summary)
	raw.KeyDecisions = trimNonEmpty(raw.KeyDecisions)
	raw.ActionItems = trimNonEmpty(raw.ActionItems)
	raw.OpenQuestions = trimNonEmpty(raw.OpenQuestions)
	return &raw, usage, nil
}
