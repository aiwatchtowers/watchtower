package inbox

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// situationCardMemberCap limits how many member signals are rendered in the
// situation-card prompt block; beyond this the block just notes how many
// more exist rather than including every one.
const situationCardMemberCap = 20

// situationCardResult is the structured AI response for one situation card.
type situationCardResult struct {
	Summary    string `json:"summary"`
	WhyMatters string `json:"why_matters"`
	Chronology string `json:"chronology"`
}

// runSituationCards generates dashboard situation cards (summary / why-it-
// matters / chronology) for situations surfaced by the composer. This mirrors
// the merged per-item runCards contract (INBOX-07) at the situation level:
// per-situation Generate/parse failures are recorded via
// MarkSituationCardFailed and retried next cycle, never failing the
// pipeline. Only a ListSituationsNeedingCards or SetSituationCard
// persistence failure returns an error.
func (p *Pipeline) runSituationCards(ctx context.Context, currentUserID string) (int, error) {
	situations, err := p.db.ListSituationsNeedingCards()
	if err != nil {
		return 0, fmt.Errorf("listing situations needing cards: %w", err)
	}
	if len(situations) == 0 || p.generator == nil {
		return 0, nil
	}

	brief := buildSecretaryBrief(p.db, currentUserID, time.Now())
	tmpl, _ := p.getPrompt(prompts.InboxSituationCard)

	generated := 0
	for _, s := range situations {
		block := p.buildSituationCardBlock(s)
		system := fmt.Sprintf(tmpl, prompts.Directive(p.cfg.Digest.Language), brief, block)

		raw, usage, _, err := p.generator.Generate(digest.WithSource(ctx, "inbox.situation_card"), system, "Prepare the situation card.", "")
		if err != nil {
			p.logger.Printf("inbox: situation card generation failed for situation %d: %v", s.ID, err)
			_ = p.db.MarkSituationCardFailed(s.ID)
			continue
		}
		p.accumulateUsage(usage)

		jsonStr, err := prompts.ExtractJSONObject(raw)
		var card situationCardResult
		if err == nil {
			err = json.Unmarshal([]byte(jsonStr), &card)
		}
		if err != nil || card.Summary == "" {
			p.logger.Printf("inbox: situation card parse failed for situation %d: %v", s.ID, err)
			_ = p.db.MarkSituationCardFailed(s.ID)
			continue
		}

		if err := p.db.SetSituationCard(s.ID, card.Summary, card.WhyMatters, card.Chronology); err != nil {
			return generated, fmt.Errorf("persisting card for situation %d: %w", s.ID, err)
		}
		generated++
	}
	return generated, nil
}

// buildSituationCardBlock renders the "SITUATION" prompt section for one
// situation: title/kind/reason, the linked target/track's display text if
// any, then member signals oldest-first, capped at situationCardMemberCap.
func (p *Pipeline) buildSituationCardBlock(s db.DashboardSituation) string {
	var b strings.Builder
	b.WriteString(fmt.Sprintf("=== SITUATION ===\ntitle=%s\nkind=%s\nreason=%s\n", s.Title, s.Kind, s.AIReason))
	if s.TargetID != nil {
		b.WriteString(fmt.Sprintf("target=%s\n", targetTitle(p.db, *s.TargetID)))
	}
	if s.TrackID != nil {
		b.WriteString(fmt.Sprintf("track=%s\n", trackTitle(p.db, *s.TrackID)))
	}

	members, _ := p.db.ListSituationSignals(s.ID)
	b.WriteString("\n=== SIGNALS ===\n")
	if len(members) == 0 {
		b.WriteString("(no signals)\n")
		return b.String()
	}
	// Keep the NEWEST situationCardMemberCap signals (still rendered
	// oldest-first within that window, since ListSituationSignals returns
	// oldest-first). Dropping the newest signals on a large situation could
	// produce a stale card — e.g. omitting a resolution — for a summary whose
	// contract is "current state first".
	shown := members
	extra := 0
	if len(members) > situationCardMemberCap {
		shown = members[len(members)-situationCardMemberCap:]
		extra = len(members) - situationCardMemberCap
	}
	for _, it := range shown {
		b.WriteString(fmt.Sprintf("from=%s channel=%s :: %s\n", it.SenderUserID, it.ChannelID, cleanSnippet(it.Snippet)))
	}
	if extra > 0 {
		b.WriteString(fmt.Sprintf("…and %d more\n", extra))
	}
	return b.String()
}

// targetTitle resolves a target's display text for the prompt, falling back
// to a bare id reference if the target can't be loaded.
func targetTitle(database *db.DB, targetID int) string {
	t, err := database.GetTargetByID(targetID)
	if err != nil || t == nil {
		return fmt.Sprintf("#%d", targetID)
	}
	return cleanSnippet(t.Text)
}
