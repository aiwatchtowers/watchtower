package reviewai

import (
	"context"
	"fmt"
	"strings"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
	"watchtower/internal/reviewmap"
)

// Summary is the goal-level part of an overview: the summary, the coverage
// of every intent item, the files that serve none, and (multi-batch only)
// the not-described chapters the summary could not see.
type Summary struct {
	Summary    string     `json:"summary"`
	Coverage   []Coverage `json:"coverage"`
	OutOfScope []string   `json:"out_of_scope"`
	NotCovered []string   `json:"not_covered"`
}

// SummaryInput is what the review.summary call sees: the intent items, the
// map and the chapter descriptions made so far — no diff. A chapter of the
// map with no entry in Described goes in as "not described".
type SummaryInput struct {
	Intent    []IntentItem
	Map       reviewmap.Map
	Described map[string]ChapterDesc
}

// notDescribed is every chapter of the map, "collapsed" aside, with no
// description.
func (in SummaryInput) notDescribed() map[string]bool {
	out := map[string]bool{}
	for _, ch := range in.Map.Chapters {
		if _, ok := in.Described[ch.Key]; !ok && ch.Key != collapsedKey {
			out[ch.Key] = true
		}
	}
	return out
}

// Summarize makes the summary call of a multi-batch run. No write
// transaction is open around the call.
func (p *Pipeline) Summarize(ctx context.Context, in SummaryInput) (Summary, error) {
	raw, _, _, err := p.gen.Generate(digest.WithSource(ctx, summarySource), p.getPrompt(prompts.ReviewSummary), BuildSummaryUser(in), "")
	if err != nil {
		return Summary{}, err
	}
	return ParseSummary(raw, in)
}

// BuildSummaryUser is the data of a review.summary call: the intent and
// every chapter with its description, or NOT DESCRIBED.
func BuildSummaryUser(in SummaryInput) string {
	var s strings.Builder
	s.WriteString("=== DATA ===\n\n=== INTENT ===\n")
	writeOverviewIntent(&s, in.Intent)
	s.WriteString("\n=== CHAPTERS ===\n")
	for _, ch := range in.Map.Chapters {
		writeChapterHead(&s, ch)
		d, ok := in.Described[ch.Key]
		switch {
		case ch.Key == collapsedKey:
			s.WriteString("description: files the map marks as safe to skip (generated, lockfiles and the like); not described\n")
		case !ok:
			s.WriteString("description: NOT DESCRIBED\n")
		default:
			fmt.Fprintf(&s, "description: %s\n", oneLine(d.What))
			for _, r := range d.Risks {
				fmt.Fprintf(&s, "risk: %s (%s): %s\n", r.Path, r.Level, oneLine(r.Why))
			}
		}
		s.WriteString("\n")
	}
	if in.Map.DiffTruncated {
		s.WriteString("(the diff itself was truncated; more files changed than listed)\n")
	}
	return s.String()
}

// ParseSummary validates a review.summary reply against its input: paths
// outside the map, coverage entries outside the intent and not_covered
// keys that are not a not-described chapter of the input are dropped entry
// by entry; malformed JSON or an empty summary fails with ErrParse.
func ParseSummary(raw string, in SummaryInput) (Summary, error) {
	var sum Summary
	if err := decodeReply(raw, "summary", &sum); err != nil {
		return Summary{}, err
	}
	paths := map[string]bool{}
	for _, f := range in.Map.Files {
		paths[f.Path] = true
	}
	sum, err := checkSummary("summary", sum, in.Intent, paths)
	if err != nil {
		return Summary{}, err
	}
	notDescribed := in.notDescribed()
	keys := []string{}
	for _, k := range sum.NotCovered {
		if notDescribed[k] {
			keys = append(keys, k)
			delete(notDescribed, k) // once each
		}
	}
	sum.NotCovered = keys
	return sum, nil
}

// checkSummary clips the summary (empty fails) and validates the coverage
// and out_of_scope against the intent and the known paths. NotCovered is
// left to the caller.
func checkSummary(label string, sum Summary, intent []IntentItem, paths map[string]bool) (Summary, error) {
	sum.Summary = clipRunes(strings.TrimSpace(sum.Summary), maxSummaryRunes)
	if sum.Summary == "" {
		return Summary{}, fmt.Errorf("%s reply: %w: empty summary", label, ErrParse)
	}
	sum.Coverage = parseCoverage(sum.Coverage, intent, paths)
	sum.OutOfScope = keepKnown(sum.OutOfScope, paths)
	return sum, nil
}
