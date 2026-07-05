package inbox

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// cardResult is the structured AI response for a single secretary card.
type cardResult struct {
	WhyMatters   string `json:"why_matters"`
	ThreadDigest string `json:"thread_digest"`
	DraftReply   string `json:"draft_reply"`
}

// runCards generates secretary cards (why-it-matters / thread digest / draft
// reply) for items surfaced by triage. Per-item Generate/parse failures are
// recorded via MarkInboxCardFailed and retried next cycle; they never fail
// the pipeline (INBOX-07). Only a ListItemsNeedingCards or SetInboxCard
// persistence failure returns an error.
func (p *Pipeline) runCards(ctx context.Context, currentUserID string) (int, error) {
	items, err := p.db.ListItemsNeedingCards(p.cfg.Inbox.MaxAwarenessCards)
	if err != nil {
		return 0, fmt.Errorf("listing items needing cards: %w", err)
	}
	if len(items) == 0 || p.generator == nil {
		return 0, nil
	}

	brief := buildSecretaryBrief(p.db, currentUserID, time.Now())
	tmpl, _ := p.getPrompt(prompts.InboxCard)

	generated := 0
	for _, it := range items {
		itemBlock := fmt.Sprintf("=== ITEM ===\ntype=%s from=%s channel=%s\nsnippet: %s\n\n=== CONVERSATION ===\n%s",
			it.TriggerType, it.SenderUserID, it.ChannelID, it.Snippet,
			p.loadContext(it.ChannelID, it.MessageTS, it.ThreadTS))
		system := fmt.Sprintf(tmpl, prompts.Directive(p.cfg.Digest.Language), brief, itemBlock)

		raw, usage, _, err := p.generator.Generate(digest.WithSource(ctx, "inbox.card"), system, "Prepare the card.", "")
		if err != nil {
			p.logger.Printf("inbox: card generation failed for item %d: %v", it.ID, err)
			_ = p.db.MarkInboxCardFailed(it.ID)
			continue
		}
		p.accumulateUsage(usage)

		jsonStr, err := prompts.ExtractJSONObject(raw)
		var card cardResult
		if err == nil {
			err = json.Unmarshal([]byte(jsonStr), &card)
		}
		if err != nil || card.WhyMatters == "" {
			p.logger.Printf("inbox: card parse failed for item %d: %v", it.ID, err)
			_ = p.db.MarkInboxCardFailed(it.ID)
			continue
		}

		if err := p.db.SetInboxCard(it.ID, card.WhyMatters, card.ThreadDigest, card.DraftReply); err != nil {
			return generated, fmt.Errorf("persisting card for item %d: %w", it.ID, err)
		}
		generated++
	}
	return generated, nil
}
