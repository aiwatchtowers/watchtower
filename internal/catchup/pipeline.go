package catchup

import (
	"context"
	"encoding/json"
	"fmt"
	"log"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// Pipeline assembles a persisted catch-up review session: gather → outline
// (skeletons) → expand (per-theme narrative). Themes are written incrementally
// so the UI streams them in via observation.
type Pipeline struct {
	db     *db.DB
	cfg    *config.Config
	gen    digest.Generator
	logger *log.Logger
}

// New constructs a catch-up Pipeline.
func New(database *db.DB, cfg *config.Config, gen digest.Generator, logger *log.Logger) *Pipeline {
	return &Pipeline{db: database, cfg: cfg, gen: gen, logger: logger}
}

// gatheredItem is one unread source row plus its area.
type gatheredItem struct {
	db.UnreadItem
	area string
}

// gatheredSection is the unread set for one area, with its uncapped total.
type gatheredSection struct {
	area  string
	items []db.UnreadItem
	total int
}

// gatherResult is the full unread snapshot driving an outline pass.
type gatherResult struct {
	sections   []gatheredSection
	byRef      map[refKey]gatheredItem
	totalCount int
}

type refKey struct {
	area string
	id   int
}

// Run builds a new review session over the currently-unread items. It closes any
// open session, gathers unread items, and—if anything is unread—creates a
// session, asks the AI for a theme outline, and persists skeleton themes. When
// nothing is unread it returns (0, nil) and creates no session. Returns the new
// session id.
func (p *Pipeline) Run(ctx context.Context) (int64, error) {
	if err := p.db.CloseOpenCatchupSessions(); err != nil {
		return 0, err
	}

	g, err := p.gather()
	if err != nil {
		return 0, err
	}
	// Nothing unread → no session, no AI call.
	if g.totalCount == 0 {
		return 0, nil
	}

	sessionID, err := p.db.CreateCatchupSession(p.oldestUnread(g))
	if err != nil {
		return 0, err
	}

	themes, err := p.outline(ctx, sessionID, g)
	if err != nil {
		// Outline is mandatory: without it there are no themes to review. Mark
		// the session failed so the UI can offer a retry rather than spin.
		if serr := p.db.SetCatchupSessionStatus(sessionID, "failed"); serr != nil {
			p.logf("catchup: marking session %d failed: %v", sessionID, serr)
		}
		return sessionID, err
	}
	if err := p.db.SetCatchupSessionTotals(sessionID, len(themes)); err != nil {
		return sessionID, err
	}

	// Task 5 replaces this stub with a bounded-concurrency per-theme AI expand.
	// For now, promote skeletons to ready using the outline data so the session
	// is reviewable end-to-end.
	p.expand(ctx, sessionID, themes)

	if err := p.db.SetCatchupSessionStatus(sessionID, "active"); err != nil {
		return sessionID, err
	}
	return sessionID, nil
}

// gather pulls compact unread records per area, applies caps, and indexes them
// by (area, id) so the expand phase can resolve refs back to snippets.
func (p *Pipeline) gather() (gatherResult, error) {
	caps := p.cfg.Catchup.Caps
	maxAge := p.cfg.Catchup.MaxAgeDays

	dItems, dTotal, err := p.db.GetUnreadDigests(caps.Digests, maxAge)
	if err != nil {
		return gatherResult{}, err
	}
	tItems, tTotal, err := p.db.GetUnreadTracks(caps.Tracks, maxAge)
	if err != nil {
		return gatherResult{}, err
	}
	iItems, iTotal, err := p.db.GetUnreadInboxItems(caps.Inbox, maxAge)
	if err != nil {
		return gatherResult{}, err
	}
	bItems, bTotal, err := p.db.GetUnreadBriefings(caps.Briefings, maxAge)
	if err != nil {
		return gatherResult{}, err
	}

	sections := []gatheredSection{
		{area: "digests", items: dItems, total: dTotal},
		{area: "tracks", items: tItems, total: tTotal},
		{area: "inbox", items: iItems, total: iTotal},
		{area: "briefings", items: bItems, total: bTotal},
	}

	byRef := make(map[refKey]gatheredItem)
	for _, s := range sections {
		for _, it := range s.items {
			byRef[refKey{area: s.area, id: it.ID}] = gatheredItem{UnreadItem: it, area: s.area}
		}
	}

	return gatherResult{
		sections:   sections,
		byRef:      byRef,
		totalCount: dTotal + tTotal + iTotal + bTotal,
	}, nil
}

// outline runs the cheap clustering AI call and persists skeleton themes in the
// AI's order. Refs are validated against the gathered items so the model can
// never introduce ids that are not in the input.
func (p *Pipeline) outline(ctx context.Context, sessionID int64, g gatherResult) ([]db.CatchupTheme, error) {
	user := buildOutlineUserMessage(g.sections, p.targetsLine())
	raw, _, _, err := p.gen.Generate(digest.WithSource(ctx, "catchup.outline"), outlineSystemPrompt, user, "")
	if err != nil {
		return nil, fmt.Errorf("catchup outline: %w", err)
	}
	parsed, err := parseOutline(raw)
	if err != nil {
		return nil, err
	}

	var themes []db.CatchupTheme
	for i, ot := range parsed.Themes {
		refs := p.validateRefs(ot.Refs, g)
		refsJSON, err := json.Marshal(refs)
		if err != nil {
			return nil, fmt.Errorf("encoding theme refs: %w", err)
		}
		priority := ot.Priority
		if priority != "high" && priority != "medium" && priority != "low" {
			priority = "medium"
		}
		t := db.CatchupTheme{
			SessionID: sessionID,
			OrderIdx:  i,
			Title:     ot.Title,
			Priority:  priority,
			RefsJSON:  string(refsJSON),
			GenState:  "skeleton",
		}
		id, err := p.db.InsertCatchupTheme(t)
		if err != nil {
			return nil, err
		}
		t.ID = id
		themes = append(themes, t)
	}
	return themes, nil
}

// validateRefs drops refs whose (area,id) is not in the gathered snapshot and
// fills a fallback label from the source item when the model omitted one.
func (p *Pipeline) validateRefs(refs []db.CatchupRef, g gatherResult) []db.CatchupRef {
	out := make([]db.CatchupRef, 0, len(refs))
	for _, r := range refs {
		item, ok := g.byRef[refKey{area: r.Area, id: r.ID}]
		if !ok {
			p.logf("catchup: dropping outline ref to unknown item %s#%d", r.Area, r.ID)
			continue
		}
		if r.Label == "" {
			r.Label = refLabel(r.Area, item.UnreadItem)
		}
		out = append(out, r)
	}
	return out
}

// expand promotes skeleton themes to ready. This is a stub for Task 4: it copies
// the outline data into the expanded fields without a per-theme AI call. Task 5
// replaces it with a bounded-concurrency fan-out that writes real narratives.
func (p *Pipeline) expand(_ context.Context, _ int64, themes []db.CatchupTheme) {
	for _, t := range themes {
		if err := p.db.UpdateCatchupThemeExpansion(t.ID, t.Narrative, t.Priority, t.NeedsYou, t.SuggestedAction, "ready"); err != nil {
			p.logf("catchup: promoting theme %d to ready: %v", t.ID, err)
		}
	}
}

// oldestUnread returns a display-only window-start hint. Best-effort; empty when
// no items carry a usable marker (the gather items are compact and timestamp-free
// here, so it stays empty until a later task surfaces timestamps).
func (p *Pipeline) oldestUnread(_ gatherResult) string {
	return ""
}

// targetsLine renders a read-only summary of active targets. Best-effort: any
// error yields an empty line and never fails the run.
func (p *Pipeline) targetsLine() string {
	active, overdue, err := p.db.GetTargetCounts()
	if err != nil {
		p.logf("catchup: targets line unavailable: %v", err)
		return ""
	}
	return fmt.Sprintf("%d active targets, %d overdue", active, overdue)
}

func (p *Pipeline) logf(format string, args ...any) {
	if p.logger != nil {
		p.logger.Printf(format, args...)
	}
}
