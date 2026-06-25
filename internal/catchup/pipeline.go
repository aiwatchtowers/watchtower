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
	"watchtower/internal/prompts"
)

// Pipeline assembles a persisted catch-up review session: gather → peel (one
// theme skeleton per round) → expand (per-theme narrative). Themes are written
// incrementally so the UI streams them in via observation.
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

// withLanguage appends the workspace response-language directive to a base
// system prompt. Every catch-up AI call routes through this so the model
// answers in the operator's configured language instead of defaulting to
// English.
func (p *Pipeline) withLanguage(base string) string {
	return base + "\n\n" + prompts.Directive(p.cfg.Digest.Language)
}

// gatheredSection is the (capped) unread set for one area.
type gatheredSection struct {
	area  string
	items []db.UnreadItem
}

// gatherResult is the full unread snapshot driving the peel pass. byRef indexes
// every gathered item by (area, id) so peel refs can be validated and labeled.
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
// session and runs the peel loop (one theme per round, expand dispatched
// concurrently). When nothing is unread it returns (0, nil) and creates no
// session. Returns the new session id.
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

	themes, leftover, stoppedClean, err := p.peel(ctx, sessionID, g)
	if err != nil {
		// A peel round errored before any theme was found: there is nothing to
		// review. Mark the session failed so the UI can offer a retry.
		if serr := p.db.SetCatchupSessionStatus(sessionID, "failed"); serr != nil {
			p.logf("catchup: marking session %d failed: %v", sessionID, serr)
		}
		return sessionID, err
	}
	if err := p.db.SetCatchupSessionTotals(sessionID, len(themes)); err != nil {
		return sessionID, err
	}
	// On a clean exit (model said done or the pool drained) the leftover pool is
	// model-judged noise — mark it read so catch-up actually clears the backlog.
	// On an error/safety-cap exit the leftover is unprocessed, so it is left
	// untouched (still unread).
	if stoppedClean {
		p.markLeftoverRead(leftover)
	}

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
		{area: "digests", items: dItems},
		{area: "tracks", items: tItems},
		{area: "inbox", items: iItems},
		{area: "briefings", items: bItems},
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

// maxPeelRounds bounds the sequential peel loop. It is a runaway guard, not a
// theme ceiling: the loop normally stops when the model returns {"done":true}.
const maxPeelRounds = 25

// peel runs the sequential peel-off loop. Each round sends the remaining unread
// pool to the light model, which returns the single most important theme or
// {"done":true}. A returned theme's refs are validated against the pool,
// persisted as a skeleton, and its expand dispatched concurrently; the claimed
// items are removed from the pool so the next round narrows.
//
// It returns the persisted themes (in discovery order), the leftover (unclaimed)
// pool keys, and stoppedClean=true only when the loop ended via done or an empty
// pool — so the caller may mark leftover read. fatal is non-nil ONLY when a
// round errored before any theme was found, so the caller can fail the session.
// All dispatched expands are awaited before peel returns (deferred wg.Wait).
func (p *Pipeline) peel(ctx context.Context, sessionID int64, g gatherResult) (themes []db.CatchupTheme, leftover []refKey, stoppedClean bool, fatal error) {
	prefs := p.catchupPrefs()
	targets := p.targetsLine()

	claimed := make(map[refKey]bool)

	workers := p.cfg.AI.Workers
	if workers <= 0 {
		workers = config.DefaultAIWorkers
	}
	sem := make(chan struct{}, workers)
	var wg sync.WaitGroup
	defer wg.Wait()

	orderIdx := 0
	for round := 0; round < maxPeelRounds; round++ {
		sections := unclaimedSections(g.sections, claimed)
		if sectionsEmpty(sections) {
			stoppedClean = true
			break
		}

		user := buildPeelUserMessage(sections, targets)
		if prefs != "" {
			user = prefs + "\n" + user
		}
		raw, _, _, err := p.gen.Generate(digest.WithSource(ctx, "catchup.peel"), p.withLanguage(peelSystemPrompt), user, "")
		if err != nil {
			p.logf("catchup: peel round %d AI error: %v", round, err)
			if len(themes) == 0 {
				fatal = fmt.Errorf("catchup peel: %w", err)
			}
			return themes, unclaimedKeys(g, claimed), false, fatal
		}
		parsed, err := parsePeel(raw)
		if err != nil {
			p.logf("catchup: peel round %d parse error: %v", round, err)
			if len(themes) == 0 {
				fatal = err
			}
			return themes, unclaimedKeys(g, claimed), false, fatal
		}
		if parsed.Done {
			// Affirmative "only noise left" — the one signal that authorises
			// clearing the leftover pool as read.
			stoppedClean = true
			break
		}
		if parsed.Theme == nil {
			// Valid JSON but neither a theme nor done — a degenerate model
			// response (e.g. `{}`, the legacy `{"themes":[...]}` shape), NOT an
			// operator-judged "all noise" signal. Stop, keep themes so far, and
			// leave the leftover UNREAD (like an error exit). Conflating this with
			// done would silently mark the whole unread backlog read.
			p.logf("catchup: peel round %d returned neither a theme nor done; stopping without clearing leftover", round)
			break
		}

		refs := p.validatePeelRefs(parsed.Theme.Refs, g, claimed)
		if len(refs) == 0 {
			// The model produced a theme but none of its refs validated (unknown
			// or already-claimed ids) — a misfire, not "the rest is noise". Stop
			// without clearing the leftover so it stays unread (like an error exit).
			p.logf("catchup: peel round %d returned a theme with no valid refs; stopping without clearing leftover", round)
			break
		}

		refsJSON, err := json.Marshal(refs)
		if err != nil {
			return themes, unclaimedKeys(g, claimed), false, fmt.Errorf("encoding theme refs: %w", err)
		}
		t := db.CatchupTheme{
			SessionID: sessionID,
			OrderIdx:  orderIdx,
			Title:     parsed.Theme.Title,
			Priority:  normalizePriority(parsed.Theme.Priority, "medium"),
			RefsJSON:  string(refsJSON),
			GenState:  "skeleton",
		}
		id, err := p.db.InsertCatchupTheme(t)
		if err != nil {
			return themes, unclaimedKeys(g, claimed), false, fmt.Errorf("inserting peel theme: %w", err)
		}
		t.ID = id
		themes = append(themes, t)
		orderIdx++
		for _, r := range refs {
			claimed[refKey{area: r.Area, id: r.ID}] = true
		}

		// Dispatch expand concurrently so the narrative is written while the next
		// peel round runs. Per-theme failure is isolated by expandOne
		// (gen_state='failed'); it never aborts the run (CATCHUP-03).
		wg.Add(1)
		go func(theme db.CatchupTheme) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			_ = p.expandOne(ctx, theme, "", prefs)
		}(t)
	}

	return themes, unclaimedKeys(g, claimed), stoppedClean, nil
}

// validatePeelRefs keeps only refs that are in the gathered snapshot and not yet
// claimed by an earlier round, filling a fallback label when the model omits one.
func (p *Pipeline) validatePeelRefs(refs []db.CatchupRef, g gatherResult, claimed map[refKey]bool) []db.CatchupRef {
	out := make([]db.CatchupRef, 0, len(refs))
	for _, r := range refs {
		k := refKey{area: r.Area, id: r.ID}
		item, ok := g.byRef[k]
		if !ok {
			p.logf("catchup: dropping peel ref to unknown item %s#%d", r.Area, r.ID)
			continue
		}
		if claimed[k] {
			p.logf("catchup: dropping peel ref to already-claimed item %s#%d", r.Area, r.ID)
			continue
		}
		if r.Label == "" {
			r.Label = refLabel(r.Area, item)
		}
		out = append(out, r)
	}
	return out
}

// unclaimedSections rebuilds per-area sections from the gathered snapshot minus
// the claimed items, preserving the original area and item order.
func unclaimedSections(src []gatheredSection, claimed map[refKey]bool) []gatheredSection {
	out := make([]gatheredSection, 0, len(src))
	for _, s := range src {
		var items []db.UnreadItem
		for _, it := range s.items {
			if !claimed[refKey{area: s.area, id: it.ID}] {
				items = append(items, it)
			}
		}
		out = append(out, gatheredSection{area: s.area, items: items})
	}
	return out
}

// sectionsEmpty reports whether every section's item list is empty.
func sectionsEmpty(sections []gatheredSection) bool {
	for _, s := range sections {
		if len(s.items) > 0 {
			return false
		}
	}
	return true
}

// unclaimedKeys returns every gathered (area,id) not yet claimed by a theme.
func unclaimedKeys(g gatherResult, claimed map[refKey]bool) []refKey {
	out := make([]refKey, 0)
	for k := range g.byRef {
		if !claimed[k] {
			out = append(out, k)
		}
	}
	return out
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
	raw, _, _, err := p.gen.Generate(digest.WithSource(ctx, "catchup.expand"), p.withLanguage(expandSystemPrompt), user, "")
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
// operator's review feedback) and formats them for the peel/expand prompts so
// the model honors accumulated preferences. Best-effort: any error yields an
// empty block so a rules-load failure never blocks a run.
func (p *Pipeline) catchupPrefs() string {
	rules, err := p.db.ListLearnedRulesByPipeline("catchup", maxCatchupPrefs)
	if err != nil {
		p.logf("catchup: learned preferences unavailable: %v", err)
		return ""
	}
	return digest.LearnedPreferencesBlock(rules)
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
		if err := p.markAreaRead(r.Area, r.ID); err != nil {
			p.logf("catchup: theme %d ack mark-read %s#%d: %v", themeID, r.Area, r.ID, err)
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

// markAreaRead marks a single source item read in its own surface. Digests
// cascade their decisions read (CATCHUP-01). Shared by Acknowledge and the peel
// leftover-noise sweep. Returns an error for an unknown area.
func (p *Pipeline) markAreaRead(area string, id int) error {
	switch area {
	case "digests":
		return p.db.MarkDigestRead(id)
	case "tracks":
		return p.db.MarkTrackRead(id)
	case "inbox":
		return p.db.MarkInboxRead(id)
	case "briefings":
		return p.db.MarkBriefingRead(id)
	default:
		return fmt.Errorf("unknown area %q", area)
	}
}

// markLeftoverRead marks the pool items the model judged noise (loop ended via
// done/empty pool) read, so catch-up actually clears the backlog. Best-effort: a
// per-item error is logged and skipped.
func (p *Pipeline) markLeftoverRead(leftover []refKey) {
	if len(leftover) > 0 {
		p.logf("catchup: marking %d leftover items read (model-judged noise)", len(leftover))
	}
	for _, k := range leftover {
		if err := p.markAreaRead(k.area, k.id); err != nil {
			p.logf("catchup: leftover mark-read %s#%d: %v", k.area, k.id, err)
		}
	}
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
