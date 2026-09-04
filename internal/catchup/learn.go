package catchup

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// SubmitTopicFeedback records the operator's rating (+1/-1) for one topic of a
// recap and, when a comment is present, runs the learning interpreter that
// (a) derives targeted learned-rules addressed to whichever pipeline produced
// the topic's sources and (b) regenerates the whole recap when the comment is a
// presentation correction about this document. A bare like/dislike is stored as
// a low-confidence signal only — no rule is derived and no AI call is made.
//
// It returns the id of the recap the regeneration produced, or 0 when nothing
// was regenerated.
func (p *Pipeline) SubmitTopicFeedback(ctx context.Context, recapID int64, topicIdx, rating int, comment string) (int64, error) {
	// Everything is validated before the first write, so a mistyped id or index
	// never leaves a feedback row pointing at nothing (and never reports success).
	topic, err := p.topicForFeedback(recapID, topicIdx)
	if err != nil {
		return 0, err
	}

	// The raw signal is always recorded. entity_type stays 'catchup_theme': a
	// topic is the renamed theme, and the feedback CHECK is kept as is.
	if _, err := p.db.AddFeedback(db.Feedback{
		EntityType: "catchup_theme",
		EntityID:   fmt.Sprintf("%d:%d", recapID, topicIdx),
		Rating:     rating,
		Comment:    comment,
	}); err != nil {
		return 0, err
	}

	// Bare like/dislike: signal only, no rule, no AI call.
	if strings.TrimSpace(comment) == "" {
		return 0, nil
	}

	// Enrich each ref with the real Slack ids the interpreter builds scope keys
	// from — a ref carries only a table row id, which is useless as a
	// channel/sender key. Best-effort: a failed lookup costs one ref's hints, not
	// the learning pass.
	refs := make([]learnRef, 0, len(topic.Refs))
	for _, r := range topic.Refs {
		channelID, senderID, herr := p.db.FetchItemScopeHints(r.Area, r.ID)
		if herr != nil {
			p.logf("catchup: scope hints for %s#%d (recap %d topic %d): %v", r.Area, r.ID, recapID, topicIdx, herr)
		}
		refs = append(refs, learnRef{Area: r.Area, ChannelID: channelID, SenderID: senderID, Label: r.Label})
	}

	user := buildLearnUserMessage(topic, refs, rating, comment)
	system := learnSystemPrompt + "\n\n" + prompts.Directive(p.cfg.Digest.Language)
	raw, _, _, err := p.gen.Generate(digest.WithSource(ctx, "catchup.learn"), system, user, "")
	if err != nil {
		return 0, fmt.Errorf("catchup learn: %w", err)
	}
	parsed, err := parseLearn(raw)
	if err != nil {
		return 0, err
	}

	for _, lr := range parsed.Rules {
		if lr.RuleType == "" || lr.ScopeKey == "" {
			p.logf("catchup: skipping malformed learned rule %+v from recap %d topic %d", lr, recapID, topicIdx)
			continue
		}
		pipeline := lr.Pipeline
		if pipeline == "" {
			pipeline = "inbox"
		}
		if err := p.db.UpsertLearnedRule(db.InboxLearnedRule{
			Pipeline:      pipeline,
			RuleType:      lr.RuleType,
			ScopeKey:      lr.ScopeKey,
			Weight:        lr.Weight,
			Source:        "explicit_feedback",
			EvidenceCount: 1,
		}); err != nil {
			return 0, fmt.Errorf("persisting learned rule %s/%s: %w", pipeline, lr.ScopeKey, err)
		}
	}

	// A presentation correction re-composes the same window with the comment
	// applied, so the operator sees the fix rather than only next time's rules.
	if !parsed.Regenerate {
		return 0, nil
	}
	res, err := p.Run(ctx, RunOptions{RegenOfID: recapID, Correction: comment})
	return res.RecapID, err
}

// topicForFeedback resolves the rated topic. A recap that does not exist, one
// that never finished composing, and an index outside the body are all errors:
// there is nothing to rate and nothing to learn from.
func (p *Pipeline) topicForFeedback(recapID int64, topicIdx int) (Topic, error) {
	r, err := p.db.GetCatchupRecap(recapID)
	if err != nil {
		return Topic{}, err
	}
	if r.Status != statusReady {
		return Topic{}, fmt.Errorf("catchup recap %d is %q, not ready: nothing to rate", recapID, r.Status)
	}
	var body Body
	if err := json.Unmarshal([]byte(r.BodyJSON), &body); err != nil {
		return Topic{}, fmt.Errorf("decoding catchup recap %d body: %w", recapID, err)
	}
	if topicIdx < 0 || topicIdx >= len(body.Topics) {
		return Topic{}, fmt.Errorf("catchup recap %d has %d topics: topic %d is out of range", recapID, len(body.Topics), topicIdx)
	}
	return body.Topics[topicIdx], nil
}
