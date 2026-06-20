package inbox

import (
	"fmt"
	"sort"
	"strings"

	"watchtower/internal/db"
)

const maxPrefsInPrompt = 20

// buildUserPreferencesBlock returns a formatted "=== USER PREFERENCES ===" section
// containing learned rules relevant to the given items' senders/channels, capped at maxPrefsInPrompt.
// Returns an empty string when no matching rules exist.
func buildUserPreferencesBlock(database *db.DB, items []db.InboxItem) (string, error) {
	seen := map[string]bool{}
	var scopes []string
	for _, it := range items {
		add := func(s string) {
			if !seen[s] {
				seen[s] = true
				scopes = append(scopes, s)
			}
		}
		add("sender:" + it.SenderUserID)
		add("channel:" + it.ChannelID)
	}
	// No items → no scopes → empty block (do not fall back to all inbox rules).
	if len(scopes) == 0 {
		return "", nil
	}
	return BuildPreferencesBlock(database, "inbox", scopes)
}

// BuildPreferencesBlock returns a formatted "=== USER PREFERENCES ===" section of
// learned rules addressed to the given pipeline, capped at maxPrefsInPrompt and
// ordered by absolute weight. When scopeKeys is non-empty only rules matching one
// of those scopes are included (the inbox sender/channel case); when scopeKeys is
// empty all of the pipeline's rules are included (other pipelines inject their
// full rule set). Returns an empty string when no matching rules exist. It is
// shared across pipelines so each can inject its own learned rules into its prompt.
func BuildPreferencesBlock(database *db.DB, pipeline string, scopeKeys []string) (string, error) {
	var (
		rules []db.InboxLearnedRule
		err   error
	)
	if len(scopeKeys) > 0 {
		rules, err = database.ListLearnedRulesByScope(scopeKeys, maxPrefsInPrompt)
	} else {
		rules, err = database.ListLearnedRulesByPipeline(pipeline, maxPrefsInPrompt)
	}
	if err != nil {
		return "", err
	}
	// When scoping by key, keep only the rules addressed to this pipeline so an
	// identically-scoped rule owned by another pipeline never leaks in.
	if len(scopeKeys) > 0 {
		filtered := rules[:0]
		for _, r := range rules {
			rp := r.Pipeline
			if rp == "" {
				rp = "inbox"
			}
			if rp == pipeline {
				filtered = append(filtered, r)
			}
		}
		rules = filtered
	}
	if len(rules) == 0 {
		return "", nil
	}

	sort.SliceStable(rules, func(i, j int) bool {
		return absF(rules[i].Weight) > absF(rules[j].Weight)
	})

	var mutes, boosts []string
	for _, r := range rules {
		line := fmt.Sprintf("%s (weight=%.1f, %s)", r.ScopeKey, r.Weight, r.Source)
		if r.Weight < 0 {
			mutes = append(mutes, line)
		} else {
			boosts = append(boosts, line)
		}
	}

	var b strings.Builder
	b.WriteString("=== USER PREFERENCES ===\n")
	if len(mutes) > 0 {
		b.WriteString("Mutes: " + strings.Join(mutes, "; ") + "\n")
	}
	if len(boosts) > 0 {
		b.WriteString("Boosts: " + strings.Join(boosts, "; ") + "\n")
	}
	b.WriteString("Apply these when choosing priority and selecting pinned items.\n")
	return b.String(), nil
}

func absF(f float64) float64 {
	if f < 0 {
		return -f
	}
	return f
}
