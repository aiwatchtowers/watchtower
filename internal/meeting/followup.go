package meeting

import (
	"context"
	"fmt"
	"strings"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// FollowupInput is the stated content a follow-up draft is rendered from —
// one chapter's extractions, or the union of all chapters for a whole-meeting
// draft. The intent-draft contract (Discuss precedent) means the model may
// render ONLY this content, never invent more.
type FollowupInput struct {
	MeetingTitle  string
	MeetingDate   string
	Participants  []string
	Decisions     []string
	ActionItems   []string
	OpenQuestions []string
}

// GenerateFollowupDraft renders a follow-up message draft in the owner's
// voice (workspace.style_profile) from the stated chapter content. Light
// tier ("meeting.followup" source). Nothing is persisted — the draft is
// ephemeral, shown in a copyable sheet, never auto-sent.
func (p *Pipeline) GenerateFollowupDraft(ctx context.Context, in FollowupInput) (string, *digest.Usage, error) {
	stated := renderFollowupContent(in)
	if stated == "" {
		return "", nil, fmt.Errorf("nothing to draft: no decisions, action items, or open questions")
	}

	style := ""
	if p.db != nil {
		style, _ = p.db.GetStyleProfile()
	}
	styleBlock := strings.TrimSpace(style)
	if styleBlock == "" {
		styleBlock = "(no stored style profile — use a neutral, concise business tone)"
	}

	lang := ""
	if p.cfg != nil {
		lang = p.cfg.Digest.Language
	}

	title := strings.TrimSpace(in.MeetingTitle)
	if title == "" {
		title = "(untitled meeting)"
	}
	participants := "(unknown)"
	if list := trimNonEmpty(in.Participants); len(list) > 0 {
		participants = strings.Join(list, ", ")
	}

	tmpl := p.loadFollowupPrompt()
	systemPrompt := fmt.Sprintf(tmpl,
		title, in.MeetingDate, participants,
		styleBlock,
		prompts.Directive(lang),
	)
	userMessage := "Render the follow-up message from this stated content, and nothing else.\n\n" +
		"=== STATED CONTENT ===\n" + stated

	aiResponse, usage, _, err := p.generator.Generate(
		digest.WithSource(ctx, "meeting.followup"), systemPrompt, userMessage, "")
	if err != nil {
		return "", nil, fmt.Errorf("AI generation: %w", err)
	}
	draft := stripMarkdownFence(aiResponse)
	if draft == "" {
		return "", nil, fmt.Errorf("AI returned an empty draft")
	}
	return draft, usage, nil
}

// renderFollowupContent formats the stated content block; "" when every
// category is empty (nothing to render → the caller errors out instead of
// letting the model invent a message).
func renderFollowupContent(in FollowupInput) string {
	var b strings.Builder
	writeGroup := func(header string, items []string) {
		items = trimNonEmpty(items)
		if len(items) == 0 {
			return
		}
		if b.Len() > 0 {
			b.WriteString("\n")
		}
		b.WriteString(header + "\n")
		for _, it := range items {
			b.WriteString("- " + it + "\n")
		}
	}
	writeGroup("Decisions:", in.Decisions)
	writeGroup("Action items:", in.ActionItems)
	writeGroup("Open questions:", in.OpenQuestions)
	return strings.TrimSpace(b.String())
}

func (p *Pipeline) loadFollowupPrompt() string {
	if p.promptStore != nil {
		if tmpl, _, err := p.promptStore.Get(prompts.MeetingFollowup); err == nil && tmpl != "" {
			return tmpl
		}
	}
	if tmpl, ok := prompts.Defaults[prompts.MeetingFollowup]; ok && tmpl != "" {
		return tmpl
	}
	return defaultFollowupPromptFallback
}

const defaultFollowupPromptFallback = `Draft a follow-up message in the owner's voice for meeting %s (%s, participants: %s). Style: %s. %s
Render ONLY the stated content from the user message; return only the message text.`
