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
		// Resolve the sender to a display name; UserNameByID falls back to the
		// raw ID on a miss, which is correct for non-Slack senders (Jira issue
		// keys, "watchtower"). Feeding the raw ID leaks it into the chronology.
		sender, _ := p.db.UserNameByID(it.SenderUserID)
		b.WriteString(fmt.Sprintf("from=%s channel=%s :: %s\n", sender, it.ChannelID, enrichSnippet(it.Snippet, p.db)))
		// Email signals additionally carry the full gmail body_text on this
		// (strong-tier) card stage — see spec "email AI processing" #3. Triage
		// only ever sees the Snippet (subject+preview); the full body is fed
		// here because situation cards are generated once per situation, not
		// once per message, so the cost is bounded. message_ts for an email
		// item is the Gmail message id (see gmail_detector.go), which is
		// unique per mailbox only, so the lookup must be scoped to the
		// account that synced it — inbox rows carry that account solely
		// inside their channel_id. A channel id that doesn't parse, a missing
		// row, or an empty body is not an error — the snippet-only line above
		// still carries the subject.
		if it.TriggerType == "email_received" || it.TriggerType == "email_cc" {
			if accountID, ok := db.GmailAccountIDFromChannelID(it.ChannelID); ok {
				if body, err := p.db.GetGmailBody(accountID, it.MessageTS); err == nil && body != "" {
					b.WriteString(fmt.Sprintf("body=%s\n", body))
				}
			}
		}
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
	return enrichSnippet(t.Text, database)
}
