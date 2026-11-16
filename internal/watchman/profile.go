package watchman

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// Profiles (spec 2026-11-16-watchman-design §8.3).
const (
	// ProfileMaxLines caps a category profile's rule lines.
	ProfileMaxLines = 20
	// profileMinPrecedents is the fewest precedents a category needs for a
	// profile; profilePrecedents is how many of the newest are read.
	profileMinPrecedents = 5
	profilePrecedents    = 60
	// profileLineRunes caps one rule line.
	profileLineRunes = 300
)

// Categories are the fixed decision categories, in display order.
var Categories = []string{"design", "scope", "ux_text", "tests", "review_code", "review_doc", "permission", "finish"}

// IsCategory reports whether s is one of the fixed categories.
func IsCategory(s string) bool { return decideCategories[s] }

type profilePrecedent struct {
	Situation  string `json:"situation"`
	Choice     string `json:"choice"`
	OwnerWords string `json:"owner_words"`
	DecidedAt  string `json:"decided_at"`
}

type profileInput struct {
	Category   string             `json:"category"`
	Precedents []profilePrecedent `json:"precedents"`
}

type profileReply struct {
	Rules []string `json:"rules"`
}

// ProfileText distils a category's precedents into the owner's rules, one
// per line (at most 20), on the strong tier. It reads nothing but its
// arguments, so the backtest can give it a leak-free slice. On a reply that
// fails validation the call's Usage is still returned.
func ProfileText(ctx context.Context, gen digest.Generator, store *prompts.Store, category string, ps []db.WatchmanPrecedent) (string, *digest.Usage, error) {
	if len(ps) == 0 {
		return "", nil, errors.New("watchman profile: no precedents")
	}
	in := profileInput{Category: category, Precedents: make([]profilePrecedent, 0, len(ps))}
	for _, p := range ps {
		in.Precedents = append(in.Precedents, profilePrecedent{
			Situation: p.Situation, Choice: p.Choice, OwnerWords: p.OwnerWords,
			DecidedAt: p.DecidedAt.UTC().Format(time.RFC3339),
		})
	}
	// json.Marshal escapes '<' and '>', so no precedent text can close the fence.
	body, err := json.Marshal(in)
	if err != nil {
		return "", nil, fmt.Errorf("watchman profile: encoding precedents: %w", err)
	}
	// Known-safe ignore: on a failed or empty store read Resolve still hands
	// back the built-in template, and ProfileText has no logger to report it to.
	tmpl, _, _ := prompts.Resolve(store, prompts.WatchmanProfile, "")
	raw, usage, _, err := gen.Generate(digest.WithSource(ctx, prompts.WatchmanProfile), tmpl,
		"=== DATA ===\n<data>\n"+string(body)+"\n</data>\n", "")
	if err != nil {
		return "", usage, fmt.Errorf("watchman profile: generating: %w", err)
	}
	text, err := parseProfile(raw)
	return text, usage, err
}

// parseProfile decodes {"rules": […]} (one surrounding code fence dropped),
// keeps the non-empty lines (newlines folded, each clipped), at most 20.
func parseProfile(raw string) (string, error) {
	var r profileReply
	if err := json.Unmarshal([]byte(trimJSONFence(strings.TrimSpace(raw))), &r); err != nil {
		return "", fmt.Errorf("watchman profile: the reply is not a JSON object: %w", err)
	}
	var lines []string
	for _, l := range r.Rules {
		l = strings.Join(strings.Fields(l), " ")
		if l == "" {
			continue
		}
		if rs := []rune(l); len(rs) > profileLineRunes {
			l = string(rs[:profileLineRunes])
		}
		lines = append(lines, l)
		if len(lines) == ProfileMaxLines {
			break
		}
	}
	if len(lines) == 0 {
		return "", errors.New("watchman profile: the reply has no rules")
	}
	return strings.Join(lines, "\n"), nil
}

// BuildProfiles rebuilds the profile of every category with at least 5
// precedents from its newest 60; a pinned entry is never replaced (the write
// checks it). A failed category does not stop the others; the errors are
// joined. Logs are the caller's: errors carry no precedent text.
func BuildProfiles(ctx context.Context, d *db.DB, workbenchID int64, gen digest.Generator, store *prompts.Store, now time.Time) error {
	existing, err := d.WatchmanProfiles(workbenchID)
	if err != nil {
		return fmt.Errorf("watchman profiles: %w", err)
	}
	pinned := map[string]bool{}
	for _, p := range existing {
		pinned[p.Key] = p.Pinned
	}
	var errs []error
	for _, c := range Categories {
		if err := ctx.Err(); err != nil {
			return errors.Join(append(errs, err)...)
		}
		if pinned[c] {
			continue // no model call for a text that would not be stored
		}
		ps, err := d.WatchmanRecentPrecedents(workbenchID, c, profilePrecedents)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if len(ps) < profileMinPrecedents {
			continue
		}
		text, _, err := ProfileText(ctx, gen, store, c, ps)
		if err != nil {
			errs = append(errs, fmt.Errorf("category %s: %w", c, err))
			continue
		}
		if _, err := d.SaveLearnedWatchmanProfile(workbenchID, c, text, now); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
