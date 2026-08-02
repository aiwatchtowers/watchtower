package inbox

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// situationLearnSystemPrompt drives the learning interpreter for dashboard
// situations: given a situation the operator reviewed plus their free-text
// comment and rating, derive targeted inbox learned-rules. Kept as a
// package-private const (same as catchup's learnSystemPrompt) — not
// user-editable, so it does not go through the prompts store.
const situationLearnSystemPrompt = `You are the learning interpreter for a chief-of-staff work dashboard.

The operator just reviewed ONE situation (a cluster of related Slack signals and work updates prepared by their AI secretary) and left a rating (+1 like / -1 dislike) and a free-text comment.

Your job is to turn the comment into durable, targeted learned-rules so the inbox pipeline surfaces things better next time. Be conservative: only derive a rule when the comment expresses a clear, generalizable preference (e.g. "this channel is noise", "always show me anything from Jane"). Vague approval/disapproval with no actionable signal yields no rules.

For each rule produce:
- rule_type: "source_mute" (suppress/down-rank) or "source_boost" (surface/up-rank).
- scope_key: build it ONLY from the channel_id / sender_user_id supplied with the member signals below — never invent ids. Use a BARE key, exactly "sender:<sender_user_id>" or "channel:<channel_id>". If no usable id is supplied for a target, emit no rule for it rather than guessing.
- weight: a float in [-1.0, 1.0]; negative mutes, positive boosts; magnitude = confidence.
- reason: one short sentence grounding the rule in the comment.

Respond with ONLY a JSON object, no markdown fences:
{"rules": [{"rule_type": "source_mute", "scope_key": "channel:Cxxx", "weight": -1.0, "reason": "..."}]}`

// situationLearnResult is the interpreter's output shape.
type situationLearnResult struct {
	Rules []situationLearnRule `json:"rules"`
}

type situationLearnRule struct {
	RuleType string  `json:"rule_type"`
	ScopeKey string  `json:"scope_key"`
	Weight   float64 `json:"weight"`
	Reason   string  `json:"reason"`
}

func parseSituationLearn(raw string) (situationLearnResult, error) {
	var out situationLearnResult
	s, err := prompts.ExtractJSONObject(raw)
	if err != nil {
		return out, fmt.Errorf("parsing situation learn output: %w", err)
	}
	if err := json.Unmarshal([]byte(s), &out); err != nil {
		return out, fmt.Errorf("parsing situation learn output: %w", err)
	}
	return out, nil
}

// SubmitSituationFeedback records 👍/👎 for a dashboard situation. The raw
// rating always lands in the feedback table (entity_type='situation') so the
// Desktop control can show the current state. Without a comment it otherwise
// mirrors the Desktop fast path (Swift SituationQueries.recordFeedback):
// rating -1 upserts a source_mute user_rule per distinct member-signal channel,
// rating +1 derives no rules, and no AI call is ever made (DASH-04). With a comment
// it runs the learning interpreter and persists the derived rules as
// source='user_rule' (protected from implicit overwrite, INBOX-05).
func (p *Pipeline) SubmitSituationFeedback(ctx context.Context, situationID int, rating int, comment string) error {
	situation, err := p.db.GetSituation(situationID)
	if err != nil {
		return fmt.Errorf("situation %d: %w", situationID, err)
	}
	signals, err := p.db.ListSituationSignals(situationID)
	if err != nil {
		return fmt.Errorf("situation %d signals: %w", situationID, err)
	}

	// Persist the raw rating first so the Desktop 👍/👎 control reflects it
	// even when the learning interpreter below fails.
	if _, err := p.db.AddFeedback(db.Feedback{
		EntityType: "situation",
		EntityID:   strconv.Itoa(situationID),
		Rating:     rating,
		Comment:    strings.TrimSpace(comment),
	}); err != nil {
		return fmt.Errorf("recording situation %d feedback: %w", situationID, err)
	}

	if strings.TrimSpace(comment) == "" {
		if rating >= 0 {
			return nil
		}
		seen := map[string]bool{}
		for _, sig := range signals {
			if sig.ChannelID == "" || seen[sig.ChannelID] {
				continue
			}
			seen[sig.ChannelID] = true
			if err := p.db.UpsertLearnedRule(db.InboxLearnedRule{
				RuleType:      "source_mute",
				ScopeKey:      "channel:" + sig.ChannelID,
				Weight:        -1.0,
				Source:        "user_rule",
				EvidenceCount: 1,
			}); err != nil {
				return fmt.Errorf("persisting mute rule for channel %s: %w", sig.ChannelID, err)
			}
		}
		return nil
	}

	user := buildSituationLearnUserMessage(situation, signals, rating, comment)
	raw, _, _, err := p.generator.Generate(
		digest.WithSource(ctx, "inbox.situation_learn"), situationLearnSystemPrompt, user, "")
	if err != nil {
		return fmt.Errorf("situation learn: %w", err)
	}
	parsed, err := parseSituationLearn(raw)
	if err != nil {
		return err
	}
	for _, lr := range parsed.Rules {
		if (lr.RuleType != "source_mute" && lr.RuleType != "source_boost") || lr.ScopeKey == "" {
			p.logger.Printf("inbox: skipping malformed learned rule %+v from situation %d", lr, situationID)
			continue
		}
		// The prompt asks for weight in [-1.0, 1.0], but that's only a request —
		// clamp so a malformed response can never persist a dominating rule.
		w := math.Max(-1, math.Min(1, lr.Weight))
		if err := p.db.UpsertLearnedRule(db.InboxLearnedRule{
			RuleType:      lr.RuleType,
			ScopeKey:      lr.ScopeKey,
			Weight:        w,
			Source:        "user_rule",
			EvidenceCount: 1,
		}); err != nil {
			return fmt.Errorf("persisting learned rule %s: %w", lr.ScopeKey, err)
		}
	}
	return nil
}

// buildSituationLearnUserMessage renders the situation plus its member
// signals' real Slack ids (so the interpreter can build scope keys the inbox
// pipeline actually matches on) and the operator's rating/comment.
func buildSituationLearnUserMessage(s db.DashboardSituation, signals []db.InboxItem, rating int, comment string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "SITUATION: %s\n", s.Title)
	if strings.TrimSpace(s.Summary) != "" {
		fmt.Fprintf(&b, "SUMMARY: %s\n", strings.Join(strings.Fields(s.Summary), " "))
	}
	fmt.Fprintf(&b, "PRIORITY: %s\n", s.Priority)
	b.WriteString("MEMBER SIGNALS (use the supplied ids to build scope keys):\n")
	if len(signals) == 0 {
		b.WriteString("(none)\n")
	}
	for _, sig := range signals {
		b.WriteString("-")
		if sig.ChannelID != "" {
			b.WriteString(" channel_id=" + sig.ChannelID)
		}
		if sig.SenderUserID != "" {
			b.WriteString(" sender_user_id=" + sig.SenderUserID)
		}
		fmt.Fprintf(&b, " snippet=%s\n", strings.Join(strings.Fields(sig.Snippet), " "))
	}
	verdict := "dislike"
	if rating > 0 {
		verdict = "like"
	}
	fmt.Fprintf(&b, "\nOPERATOR RATING: %s\n", verdict)
	fmt.Fprintf(&b, "OPERATOR COMMENT: %s\n", strings.TrimSpace(comment))
	return b.String()
}
