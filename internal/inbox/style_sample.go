package inbox

import (
	"context"
	"fmt"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// SetPromptStore sets the prompt store the style-profile sampler loads its
// tuned inbox.style_sample prompt from.
func (p *Pipeline) SetPromptStore(store *prompts.Store) {
	p.promptStore = store
}

// getPrompt resolves a prompt via prompts.Resolve: the store row, else the
// registered default.
func (p *Pipeline) getPrompt(id string) string {
	tmpl, _, err := prompts.Resolve(p.promptStore, id, "")
	if err != nil {
		p.logger.Printf("inbox: %v — using the built-in default", err)
	}
	return tmpl
}

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
	owner, err := p.db.ResolveOwner()
	if err != nil {
		return fmt.Errorf("style sample: resolving owner: %w", err)
	}
	// The sample is the owner's own Slack messages (messages.user_id), so a
	// Google- or Jira-only owner has nothing to sample.
	userID := owner.SlackUserID
	if userID == "" {
		return fmt.Errorf("style sample needs a connected Slack account")
	}

	raw, err := p.db.ListStyleSampleMessages(userID, 1000)
	if err != nil {
		return fmt.Errorf("style sample: %w", err)
	}
	sample := capStyleSample(raw, 15, 150)
	if len(sample) == 0 {
		return fmt.Errorf("style sample: not enough messages to sample a style profile")
	}

	analystNote := ""
	if card, cErr := p.db.GetLatestPeopleCard(userID); cErr == nil && card != nil {
		analystNote = strings.TrimSpace(card.CommunicationStyle)
	}

	user := buildStyleSampleUserMessage(sample, analystNote)
	out, _, _, err := p.generator.Generate(
		digest.WithSource(ctx, "inbox.style_sample"), p.getPrompt(prompts.InboxStyleSample), user, "")
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
