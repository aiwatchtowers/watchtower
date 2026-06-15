package catchup

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// Pipeline assembles the catch-up rollup.
type Pipeline struct {
	db  *db.DB
	cfg *config.Config
	gen digest.Generator
}

// New constructs a catch-up Pipeline.
func New(database *db.DB, cfg *config.Config, gen digest.Generator) *Pipeline {
	return &Pipeline{db: database, cfg: cfg, gen: gen}
}

// Run gathers unread items, builds sections (ground truth), and—if anything is
// unread—asks the AI to cluster them into stories. AI failure degrades to a
// sections-only result; it never blocks the rollup.
func (p *Pipeline) Run(ctx context.Context) (*Result, error) {
	caps := p.cfg.Catchup.Caps
	maxAge := p.cfg.Catchup.MaxAgeDays

	dItems, dTotal, err := p.db.GetUnreadDigests(caps.Digests, maxAge)
	if err != nil {
		return nil, err
	}
	tItems, tTotal, err := p.db.GetUnreadTracks(caps.Tracks, maxAge)
	if err != nil {
		return nil, err
	}
	iItems, iTotal, err := p.db.GetUnreadInboxItems(caps.Inbox, maxAge)
	if err != nil {
		return nil, err
	}
	bItems, bTotal, err := p.db.GetUnreadBriefings(caps.Briefings, maxAge)
	if err != nil {
		return nil, err
	}

	sections := []Section{
		toSection("digests", dItems, dTotal),
		toSection("tracks", tItems, tTotal),
		toSection("inbox", iItems, iTotal),
		toSection("briefings", bItems, bTotal),
	}

	res := &Result{
		Sections: sections,
		Counts: Counts{
			Digests:   AreaCount{Included: len(dItems), Total: dTotal},
			Tracks:    AreaCount{Included: len(tItems), Total: tTotal},
			Inbox:     AreaCount{Included: len(iItems), Total: iTotal},
			Briefings: AreaCount{Included: len(bItems), Total: bTotal},
		},
	}
	res.Counts.TotalUnread = dTotal + tTotal + iTotal + bTotal
	res.Counts.TotalIncluded = len(dItems) + len(tItems) + len(iItems) + len(bItems)
	res.Truncated = res.Counts.TotalIncluded < res.Counts.TotalUnread

	// Nothing unread → empty result, no AI call.
	if res.Counts.TotalUnread == 0 {
		return res, nil
	}

	user := buildUserMessage(sections, p.targetsLine())
	raw, _, _, err := p.gen.Generate(ctx, systemPrompt, user, "")
	if err != nil {
		// Degrade gracefully: the AI rollup is optional; the gathered sections
		// are still ground truth and remain clearable without stories.
		return res, nil //nolint:nilerr
	}
	if ai, perr := parseAIOutput(raw); perr == nil {
		res.TLDR = ai.TLDR
		res.Stories = ai.Stories
	}
	return res, nil
}

func toSection(area string, items []db.UnreadItem, total int) Section {
	sec := Section{Area: area, Total: total, Included: len(items)}
	for _, it := range items {
		sec.Items = append(sec.Items, SectionItem{ID: it.ID, Title: it.Title, Snippet: it.Snippet})
	}
	return sec
}

// targetsLine renders a read-only summary of active targets for the tldr.
// Best-effort: any error yields an empty line and never fails the rollup.
func (p *Pipeline) targetsLine() string {
	active, overdue, err := p.db.GetTargetCounts()
	if err != nil {
		return ""
	}
	return fmt.Sprintf("%d active targets, %d overdue", active, overdue)
}

// parseAIOutput extracts the {tldr, stories} object, tolerating markdown fences.
func parseAIOutput(raw string) (aiOutput, error) {
	var out aiOutput
	s := raw
	if i := strings.Index(s, "{"); i >= 0 {
		if j := strings.LastIndex(s, "}"); j >= i {
			s = s[i : j+1]
		}
	}
	if err := json.Unmarshal([]byte(s), &out); err != nil {
		return aiOutput{}, fmt.Errorf("parsing catchup AI output: %w", err)
	}
	return out, nil
}
