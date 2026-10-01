package catchup

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
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
		rule, why := validateLearnRule(lr, refs)
		if why != "" {
			p.logf("catchup: skipping learned rule %+v from recap %d topic %d: %s", lr, recapID, topicIdx, why)
			continue
		}
		if err := p.db.UpsertLearnedRule(rule); err != nil {
			return 0, fmt.Errorf("persisting learned rule %s/%s: %w", rule.Pipeline, rule.ScopeKey, err)
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

// learnRulePipelines is every pipeline a catch-up rule may be addressed to.
var learnRulePipelines = map[string]bool{"inbox": true, "digest": true, "tracks": true, "briefing": true, "catchup": true}

// learnRuleTypes is every rule_type the learn prompt may emit.
var learnRuleTypes = map[string]bool{"source_mute": true, "source_boost": true}

// validateLearnRule disposes of one model-proposed rule (the model proposes,
// code disposes — the CATCHUP-04 shape): the pipeline and rule_type must be in
// their allowlists, the scope_key must name an id the scope hints actually
// supplied, in the shape the prompt prescribes ("sender:<id>"/"channel:<id>",
// prefixed with "<pipeline>:" for every pipeline but inbox), and the weight is
// clamped to [-1, 1]. It returns the rule to persist, or a non-empty reason to
// skip it.
func validateLearnRule(lr learnRule, refs []learnRef) (db.InboxLearnedRule, string) {
	pipeline := lr.Pipeline
	if pipeline == "" {
		pipeline = "inbox"
	}
	if !learnRulePipelines[pipeline] {
		return db.InboxLearnedRule{}, fmt.Sprintf("unknown pipeline %q", pipeline)
	}
	if !learnRuleTypes[lr.RuleType] {
		return db.InboxLearnedRule{}, fmt.Sprintf("unknown rule_type %q", lr.RuleType)
	}
	if math.IsNaN(lr.Weight) {
		return db.InboxLearnedRule{}, "weight is not a number"
	}
	if !scopeKeyFromRefs(lr.ScopeKey, pipeline, refs) {
		return db.InboxLearnedRule{}, fmt.Sprintf("scope_key %q names no supplied id", lr.ScopeKey)
	}
	return db.InboxLearnedRule{
		Pipeline:      pipeline,
		RuleType:      lr.RuleType,
		ScopeKey:      lr.ScopeKey,
		Weight:        math.Max(-1, math.Min(1, lr.Weight)),
		Source:        "explicit_feedback",
		EvidenceCount: 1,
	}, ""
}

// scopeKeyFromRefs reports whether key is exactly one of the scope keys the
// refs' hints allow for pipeline.
func scopeKeyFromRefs(key, pipeline string, refs []learnRef) bool {
	prefix := ""
	if pipeline != "inbox" {
		prefix = pipeline + ":"
	}
	for _, r := range refs {
		if r.ChannelID != "" && key == prefix+"channel:"+r.ChannelID {
			return true
		}
		if r.SenderID != "" && key == prefix+"sender:"+r.SenderID {
			return true
		}
	}
	return false
}
