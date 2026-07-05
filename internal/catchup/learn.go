package catchup

import (
	"context"
	"fmt"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// SubmitThemeFeedback records the operator's rating (+1/-1) for a theme and, when
// a comment is present, runs the agentic learning interpreter that (a) derives
// targeted learned-rules addressed to whichever pipeline produced the theme's
// sources and (b) regenerates this theme when the comment is a presentation
// correction. A bare like/dislike (no comment) is stored as a low-confidence
// signal only — no rule is derived and no AI call is made.
func (p *Pipeline) SubmitThemeFeedback(ctx context.Context, themeID int64, rating int, comment string) error {
	// Validate the theme exists before writing anything, so a mistyped/deleted id
	// never leaves an orphan feedback row (and never reports false success).
	theme, err := p.db.GetCatchupTheme(themeID)
	if err != nil {
		return err
	}

	// Always record the raw signal.
	if _, err := p.db.AddFeedback(db.Feedback{
		EntityType: "catchup_theme",
		EntityID:   fmt.Sprint(themeID),
		Rating:     rating,
		Comment:    comment,
	}); err != nil {
		return err
	}

	// Bare like/dislike: signal only, no rule, no AI call.
	if strings.TrimSpace(comment) == "" {
		return nil
	}

	refs, err := parseRefs(theme.RefsJSON)
	if err != nil {
		p.logf("catchup: theme %d refs unparseable for learning: %v", themeID, err)
		refs = nil
	}

	// Resolve each ref's real Slack ids so the interpreter can build scope keys
	// the consuming pipelines actually match on. A ref only carries the table row
	// id, which is useless as a channel/sender key.
	lrefs := make([]learnRef, 0, len(refs))
	for _, r := range refs {
		channelID, senderID, herr := p.db.FetchItemScopeHints(r.Area, r.ID)
		if herr != nil {
			p.logf("catchup: theme %d scope hints for %s#%d: %v", themeID, r.Area, r.ID, herr)
		}
		lrefs = append(lrefs, learnRef{Area: r.Area, ChannelID: channelID, SenderID: senderID, Label: r.Label})
	}

	user := buildLearnUserMessage(*theme, lrefs, rating, comment)
	raw, _, _, err := p.gen.Generate(digest.WithSource(ctx, "catchup.learn"), p.withLanguage(learnSystemPrompt), user, "")
	if err != nil {
		return fmt.Errorf("catchup learn: %w", err)
	}
	parsed, err := parseLearn(raw)
	if err != nil {
		return err
	}

	for _, lr := range parsed.Rules {
		if lr.RuleType == "" || lr.ScopeKey == "" {
			p.logf("catchup: skipping malformed learned rule %+v from theme %d", lr, themeID)
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
			return fmt.Errorf("persisting learned rule %s/%s: %w", pipeline, lr.ScopeKey, err)
		}
	}

	// A presentation correction regenerates this theme so the operator sees the fix.
	if parsed.Regenerate {
		if err := p.RegenTheme(ctx, themeID, comment); err != nil {
			return err
		}
	}
	return nil
}
