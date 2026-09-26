package digest

import (
	"fmt"
	"strings"

	"watchtower/internal/db"
)

// LearnedPreferencesBlock formats a pipeline's learned rules (derived from the
// operator's catch-up review feedback) into a prompt block so the pipeline honors
// accumulated preferences when it generates. Returns "" when there are no rules.
//
// Shared by every pipeline that consumes its own learned rules (catchup, digest,
// tracks, briefing); it depends only on the db rule type, so it lives in the
// digest package that all of them already import (no import cycle, no inbox
// dependency).
func LearnedPreferencesBlock(rules []db.InboxLearnedRule) string {
	if len(rules) == 0 {
		return ""
	}
	var mutes, boosts []string
	for _, r := range rules {
		line := fmt.Sprintf("%s (weight=%.1f)", r.ScopeKey, r.Weight)
		if r.Weight < 0 {
			mutes = append(mutes, line)
		} else {
			boosts = append(boosts, line)
		}
	}
	var b strings.Builder
	b.WriteString("=== LEARNED PREFERENCES (apply when clustering, ranking, and phrasing) ===\n")
	if len(mutes) > 0 {
		b.WriteString("Down-rank / suppress: " + strings.Join(mutes, "; ") + "\n")
	}
	if len(boosts) > 0 {
		b.WriteString("Surface / boost: " + strings.Join(boosts, "; ") + "\n")
	}
	return b.String()
}
