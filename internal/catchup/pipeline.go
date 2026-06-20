package catchup

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"

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

// gatheredSection is the unread set for one area, with its uncapped total.
type gatheredSection struct {
	area  string
	items []db.UnreadItem
	total int
}

// gatherResult is the full unread snapshot driving an outline pass. byRef indexes
// every gathered item by (area, id) so outline refs can be validated and labeled.
type gatherResult struct {
	sections   []gatheredSection
	byRef      map[refKey]db.UnreadItem
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

	sessionID, err := p.db.CreateCatchupSession()
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

	// Per-theme AI expand: a bounded-concurrency fan-out writes each narrative
	// independently so the UI streams themes in as they become ready. A failed
	// theme is marked and skipped; it never fails the whole run.
	p.expand(ctx, themes)

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

	byRef := make(map[refKey]db.UnreadItem)
	for _, s := range sections {
		for _, it := range s.items {
			byRef[refKey{area: s.area, id: it.ID}] = it
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
	if prefs := p.catchupPrefs(); prefs != "" {
		user = prefs + "\n" + user
	}
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
		priority := normalizePriority(ot.Priority, "medium")
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
			r.Label = refLabel(r.Area, item)
		}
		out = append(out, r)
	}
	return out
}

// expand writes each theme's narrative with a bounded-concurrency fan-out: one
// AI call per theme, at most cfg.AI.Workers in flight. Each theme is persisted
// independently (the UI streams them in via observation). A per-theme error
// marks that row gen_state='failed' and is logged; it never aborts the run.
func (p *Pipeline) expand(ctx context.Context, themes []db.CatchupTheme) {
	workers := p.cfg.AI.Workers
	if workers <= 0 {
		workers = config.DefaultAIWorkers
	}

	// Load the learned preferences once for the whole fan-out rather than per
	// theme — they are identical across themes in a run.
	prefs := p.catchupPrefs()

	sem := make(chan struct{}, workers)
	var wg sync.WaitGroup
	for _, t := range themes {
		wg.Add(1)
		go func(theme db.CatchupTheme) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			// Per-theme failure is already logged + marked gen_state='failed' by
			// expandOne; the batch never aborts on it. The CLI/UI surface the
			// failed count by reading gen_state, so the error is not lost.
			_ = p.expandOne(ctx, theme, "", prefs)
		}(t)
	}
	wg.Wait()
}

// expandOne runs the single-theme expand AI call and persists the result. On any
// error (mark expanding, AI call, parse) it sets gen_state='failed' and logs.
// An optional operator correction is appended to the prompt for regen.
func (p *Pipeline) expandOne(ctx context.Context, theme db.CatchupTheme, comment, prefs string) error {
	if err := p.db.UpdateCatchupThemeExpansion(theme.ID, theme.Narrative, theme.Priority, theme.NeedsYou, theme.SuggestedAction, "expanding"); err != nil {
		p.logf("catchup: marking theme %d expanding: %v", theme.ID, err)
	}

	sources := p.resolveExpandSources(theme)
	user := buildExpandUserMessage(theme, sources, comment)
	if prefs != "" {
		user = prefs + "\n" + user
	}
	raw, _, _, err := p.gen.Generate(digest.WithSource(ctx, "catchup.expand"), expandSystemPrompt, user, "")
	if err != nil {
		p.failTheme(theme, "expand AI call", err)
		return fmt.Errorf("catchup expand theme %d: %w", theme.ID, err)
	}
	parsed, err := parseExpand(raw)
	if err != nil {
		p.failTheme(theme, "expand parse", err)
		return fmt.Errorf("catchup expand theme %d: %w", theme.ID, err)
	}

	priority := normalizePriority(parsed.Priority, theme.Priority)
	if err := p.db.UpdateCatchupThemeExpansion(theme.ID, parsed.Narrative, priority, parsed.NeedsYou, parsed.SuggestedAction, "ready"); err != nil {
		p.logf("catchup: writing expansion for theme %d: %v", theme.ID, err)
		return fmt.Errorf("catchup write expansion theme %d: %w", theme.ID, err)
	}
	return nil
}

// failTheme marks a theme gen_state='failed' and logs the cause, best-effort.
// Existing fields are preserved (priority must stay a valid CHECK value).
func (p *Pipeline) failTheme(theme db.CatchupTheme, stage string, cause error) {
	p.logf("catchup: theme %d %s failed: %v", theme.ID, stage, cause)
	priority := normalizePriority(theme.Priority, "medium")
	if err := p.db.UpdateCatchupThemeExpansion(theme.ID, theme.Narrative, priority, theme.NeedsYou, theme.SuggestedAction, "failed"); err != nil {
		p.logf("catchup: marking theme %d failed: %v", theme.ID, err)
	}
}

// normalizePriority returns p when it is a valid CHECK value, else fallback.
func normalizePriority(p, fallback string) string {
	switch p {
	case "high", "medium", "low":
		return p
	default:
		return fallback
	}
}

// resolveExpandSources turns a theme's snapshot refs back into source records
// (title + snippet) for the expand prompt. Refs whose items can no longer be
// resolved are skipped, so a deleted source never aborts expansion.
func (p *Pipeline) resolveExpandSources(theme db.CatchupTheme) []expandSource {
	refs, err := parseRefs(theme.RefsJSON)
	if err != nil {
		p.logf("catchup: theme %d refs unparseable: %v", theme.ID, err)
		return nil
	}
	var out []expandSource
	for _, r := range refs {
		title, snippet, err := p.db.FetchItemSnippet(r.Area, r.ID)
		if err != nil {
			p.logf("catchup: theme %d source %s#%d unavailable: %v", theme.ID, r.Area, r.ID, err)
			if r.Label != "" {
				out = append(out, expandSource{Area: r.Area, ID: r.ID, Title: r.Label})
			}
			continue
		}
		out = append(out, expandSource{Area: r.Area, ID: r.ID, Title: title, Snippet: snippet})
	}
	return out
}

// RegenTheme re-runs the expand pass for a single theme with the operator's
// comment appended as a correction, overwriting the row in place. The theme's
// review_state is preserved (regen rebuilds only the catch-up layer).
func (p *Pipeline) RegenTheme(ctx context.Context, themeID int64, comment string) error {
	theme, err := p.db.GetCatchupTheme(themeID)
	if err != nil {
		return err
	}
	// Unlike the batch fan-out, a regen is an explicit single-theme action: the
	// caller (CLI/UI) must learn if it failed, so propagate the error.
	return p.expandOne(ctx, *theme, comment, p.catchupPrefs())
}

// maxCatchupPrefs caps how many learned rules are injected into a prompt.
const maxCatchupPrefs = 20

// catchupPrefs loads the catchup-pipeline learned rules (derived from the
// operator's review feedback) and formats them for the outline/expand prompts so
// the model honors accumulated preferences. Best-effort: any error yields an
// empty block so a rules-load failure never blocks a run.
func (p *Pipeline) catchupPrefs() string {
	rules, err := p.db.ListLearnedRulesByPipeline("catchup", maxCatchupPrefs)
	if err != nil {
		p.logf("catchup: learned preferences unavailable: %v", err)
		return ""
	}
	return buildPreferencesBlock(rules)
}

// Acknowledge marks a theme reviewed and cascades mark-read over exactly the
// items captured in its snapshot refs (digests/tracks/inbox/briefings). The
// cascade is best-effort and idempotent: a per-item error is logged and skipped
// (already-read or newly-arrived items are safely untouched). After the cascade
// the theme's review_state becomes 'reviewed' and the session's reviewed_count
// is incremented.
func (p *Pipeline) Acknowledge(themeID int64) error {
	theme, err := p.db.GetCatchupTheme(themeID)
	if err != nil {
		return err
	}
	alreadyReviewed := theme.ReviewState == "reviewed"
	refs, err := parseRefs(theme.RefsJSON)
	if err != nil {
		p.logf("catchup: theme %d refs unparseable for ack: %v", themeID, err)
		refs = nil
	}

	for _, r := range refs {
		var markErr error
		switch r.Area {
		case "digests":
			markErr = p.db.MarkDigestRead(r.ID)
		case "tracks":
			markErr = p.db.MarkTrackRead(r.ID)
		case "inbox":
			markErr = p.db.MarkInboxRead(r.ID)
		case "briefings":
			markErr = p.db.MarkBriefingRead(r.ID)
		default:
			p.logf("catchup: theme %d ack skipping unknown area %q", themeID, r.Area)
			continue
		}
		if markErr != nil {
			p.logf("catchup: theme %d ack mark-read %s#%d: %v", themeID, r.Area, r.ID, markErr)
		}
	}

	if err := p.db.SetCatchupThemeReview(themeID, "reviewed", ""); err != nil {
		return err
	}
	// Only count the first transition into 'reviewed' so re-acking a theme never
	// pushes reviewed_count past total_themes (the "N of M reviewed" header).
	if !alreadyReviewed {
		if err := p.db.IncrementReviewed(theme.SessionID); err != nil {
			return err
		}
	}
	return nil
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
