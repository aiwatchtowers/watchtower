package meeting

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// ExtractedTopic is a single discussion topic parsed from user-pasted text.
type ExtractedTopic struct {
	Text     string `json:"text"`
	Priority string `json:"priority"` // high|medium|low (optional hint)
}

// ExtractTopicsResult is the AI output for discussion-topic extraction.
type ExtractTopicsResult struct {
	Topics []ExtractedTopic `json:"topics"`
	Notes  string           `json:"notes"`
}

// ExtractDiscussionTopics splits a raw blob of text (recap, pasted notes, rambling
// status update) into discrete discussion topics suitable for seeding the
// meeting_notes Discussion Topics section.
//
// eventTitle is optional context; passing "" is fine.
func (p *Pipeline) ExtractDiscussionTopics(
	ctx context.Context,
	text string,
	eventTitle string,
) (*ExtractTopicsResult, error) {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return &ExtractTopicsResult{Topics: []ExtractedTopic{}}, nil
	}

	lang := ""
	if p.cfg != nil {
		lang = p.cfg.Digest.Language
	}
	langDirective := prompts.Directive(lang)

	titleCtx := "(no event title)"
	if eventTitle != "" {
		titleCtx = eventTitle
	}

	tmpl := p.getPrompt(prompts.MeetingExtractTopics)

	// Template args: 1=eventTitle, 2=langDirective, 3=rawText
	systemPrompt := fmt.Sprintf(tmpl, titleCtx, langDirective, trimmed)
	userMessage := "Extract discussion topics from the raw text."

	aiResponse, _, _, err := p.generator.Generate(digest.WithSource(ctx, "meeting.extract_topics"), systemPrompt, userMessage, "")
	if err != nil {
		return nil, fmt.Errorf("AI generation: %w", err)
	}

	cleaned := cleanJSON(aiResponse)
	var result ExtractTopicsResult
	if err := json.Unmarshal([]byte(cleaned), &result); err != nil {
		return nil, fmt.Errorf("parsing AI response: %w (raw: %.300s)", err, aiResponse)
	}

	// Defensive: normalize priorities and drop empty topics.
	cleanedTopics := make([]ExtractedTopic, 0, len(result.Topics))
	for _, t := range result.Topics {
		txt := strings.TrimSpace(t.Text)
		if txt == "" {
			continue
		}
		pr := strings.ToLower(strings.TrimSpace(t.Priority))
		switch pr {
		case "high", "medium", "low":
		default:
			pr = ""
		}
		cleanedTopics = append(cleanedTopics, ExtractedTopic{Text: txt, Priority: pr})
	}
	result.Topics = cleanedTopics
	return &result, nil
}
