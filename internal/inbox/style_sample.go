package inbox

import (
	"context"
	"fmt"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// styleSampleSystemPrompt drives the communication-style distillation.
// Package-private const (same decision as situationLearnSystemPrompt) — not
// user-editable via the prompt store.
const styleSampleSystemPrompt = `You are analyzing how one person writes on Slack, to produce a "communication style profile" that another AI will later use to draft replies in this person's voice.

Below are samples of the person's OWN messages, grouped by audience (direct messages, private channels, public channels), plus an optional analyst's note about their communication style.

Distill a compact profile covering:
- Languages they use and when (e.g. Russian with the team, English with external partners).
- Tone and formality by audience: DMs vs channels, insiders vs external partners.
- Typical phrases, openers, sign-offs, punctuation and emoji habits, typical message length.
- Things they never do (e.g. corporate pleasantries, long intros, formal sign-offs).

Write the profile as plain text (markdown allowed), addressed in second person ("You write..."), at most ~400 words. Output ONLY the profile text — no preamble, no JSON, no code fences.`

// capStyleSample keeps at most perChannel messages per channel and total
// messages overall, preserving input (newest-first) order.
func capStyleSample(msgs []db.StyleSampleMessage, perChannel, total int) []db.StyleSampleMessage {
	perCount := map[string]int{}
	out := make([]db.StyleSampleMessage, 0, total)
	for _, m := range msgs {
		if len(out) >= total {
			break
		}
		if perCount[m.ChannelID] >= perChannel {
			continue
		}
		perCount[m.ChannelID]++
		out = append(out, m)
	}
	return out
}

// GenerateStyleProfile samples the owner's sent messages (plus their own
// People card, when present), distills a communication-style profile via one
// strong-tier AI call, and persists it to workspace.style_profile. An empty
// sample or AI failure leaves the stored profile untouched.
func (p *Pipeline) GenerateStyleProfile(ctx context.Context) error {
	ws, err := p.db.GetWorkspace()
	if err != nil {
		return fmt.Errorf("style sample: workspace: %w", err)
	}
	if ws == nil || ws.CurrentUserID == "" {
		return fmt.Errorf("style sample: no current user id — run a sync first")
	}

	raw, err := p.db.ListStyleSampleMessages(ws.CurrentUserID, 1000)
	if err != nil {
		return fmt.Errorf("style sample: %w", err)
	}
	sample := capStyleSample(raw, 15, 150)
	if len(sample) == 0 {
		return fmt.Errorf("style sample: not enough messages to sample a style profile")
	}

	analystNote := ""
	if card, cErr := p.db.GetLatestPeopleCard(ws.CurrentUserID); cErr == nil && card != nil {
		analystNote = strings.TrimSpace(card.CommunicationStyle)
	}

	user := buildStyleSampleUserMessage(sample, analystNote)
	out, _, _, err := p.generator.Generate(
		digest.WithSource(ctx, "inbox.style_sample"), styleSampleSystemPrompt, user, "")
	if err != nil {
		return fmt.Errorf("style sample: %w", err)
	}
	profile := strings.TrimSpace(out)
	if profile == "" {
		return fmt.Errorf("style sample: model returned an empty profile — stored profile left untouched")
	}
	if err := p.db.SetStyleProfile(profile); err != nil {
		return fmt.Errorf("style sample: %w", err)
	}
	p.logger.Printf("inbox: style profile regenerated from %d messages", len(sample))
	return nil
}

// buildStyleSampleUserMessage renders the sampled messages grouped by
// audience, plus the optional analyst's note from the owner's People card.
func buildStyleSampleUserMessage(sample []db.StyleSampleMessage, analystNote string) string {
	groups := map[string][]db.StyleSampleMessage{}
	for _, m := range sample {
		key := "PUBLIC CHANNELS"
		switch m.ChannelType {
		case "dm", "group_dm":
			key = "DIRECT MESSAGES"
		case "private":
			key = "PRIVATE CHANNELS"
		}
		groups[key] = append(groups[key], m)
	}
	var b strings.Builder
	for _, key := range []string{"DIRECT MESSAGES", "PRIVATE CHANNELS", "PUBLIC CHANNELS"} {
		msgs := groups[key]
		if len(msgs) == 0 {
			continue
		}
		fmt.Fprintf(&b, "=== %s ===\n", key)
		for _, m := range msgs {
			text := strings.Join(strings.Fields(m.Text), " ")
			if len(text) > 300 {
				text = text[:300]
			}
			fmt.Fprintf(&b, "- [#%s] %s\n", m.ChannelName, text)
		}
		b.WriteString("\n")
	}
	if analystNote != "" {
		fmt.Fprintf(&b, "=== ANALYST'S NOTE (from a prior AI analysis of this person) ===\n%s\n", analystNote)
	}
	return b.String()
}
