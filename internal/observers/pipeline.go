// Package observers runs user-editable watchers over recent cross-source
// activity and produces an activity timeline of relevant events on the watched
// entity (v1: targets). Each event may carry a confirmable proposed action.
package observers

import (
	"context"
	"fmt"
	"log"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// defaultLookback bounds the first run of a never-run observer.
const defaultLookback = 7 * 24 * time.Hour

// defaultActivityLimit caps rows per source on a normal forward run.
const defaultActivityLimit = 40

// dedupSummaryLimit bounds how many existing summaries a backfill loads to dedup
// against (a backfill re-scans windows the observer already covered).
const dedupSummaryLimit = 400

// History-backfill tuning (two-stage retrieval). A deep window holds far more
// activity than fits one extract call, so stage 1 filters cheap title-only
// candidates and stage 2 extracts from their full content.
const (
	maxBackfillTitles = 3000 // safety cap on titles considered (logged if hit)
	shortlistChunk    = 1000 // titles per cheap stage-1 AI call (titles are tiny)
	maxCandidates     = 60   // selected items fed to the stage-2 extract call
)

// runOpts tunes a single observer run. The zero value is a normal forward run
// (since = the observer's watermark, single extract call, no dedup). A history
// backfill sets sinceOverride to a deeper watermark and switches to the
// two-stage shortlist→extract path with dedup.
type runOpts struct {
	sinceOverride string // non-empty => scan from here instead of the watermark
}

func (o runOpts) isBackfill() bool { return o.sinceOverride != "" }

// Pipeline runs observers and persists their events.
type Pipeline struct {
	db     *db.DB
	gen    digest.Generator
	lang   string // workspace response language (digest.language); "" falls back to the prompts default
	logger *log.Logger
}

// New constructs a Pipeline. lang is the workspace response language
// (cfg.Digest.Language) injected into operator-facing prompts via
// prompts.Directive; an empty value falls back to prompts.DefaultLanguage.
func New(database *db.DB, gen digest.Generator, lang string, logger *log.Logger) *Pipeline {
	if logger == nil {
		logger = log.Default()
	}
	return &Pipeline{db: database, gen: gen, lang: lang, logger: logger}
}

// Run runs every enabled observer over activity since its watermark. Returns
// the number of events created. Per-observer failures are logged and skipped.
func (p *Pipeline) Run(ctx context.Context) (int, error) {
	enabled, err := p.db.GetEnabledObservers()
	if err != nil {
		return 0, err
	}
	total := 0
	for i := range enabled {
		if ctx.Err() != nil {
			return total, ctx.Err()
		}
		events, err := p.runOne(ctx, enabled[i], runOpts{})
		if err != nil {
			p.logger.Printf("observers: observer %d: %v", enabled[i].ID, err)
			continue
		}
		total += len(events)
	}
	return total, nil
}

// RunForTarget force-runs all enabled observers attached to one target and
// returns the new events.
func (p *Pipeline) RunForTarget(ctx context.Context, targetID int) ([]db.ObserverEvent, error) {
	return p.runForTarget(ctx, targetID, runOpts{})
}

// RunForTargetSince force-runs all enabled observers attached to one target over
// the explicit history window [since, now], deduping against events the observer
// already produced. It backs the Desktop "Scan history" action. `since` is an
// ISO8601 watermark; use a very old date (e.g. the epoch) for "all history".
func (p *Pipeline) RunForTargetSince(ctx context.Context, targetID int, since string) ([]db.ObserverEvent, error) {
	if strings.TrimSpace(since) == "" {
		return nil, fmt.Errorf("RunForTargetSince: empty since")
	}
	return p.runForTarget(ctx, targetID, runOpts{sinceOverride: since})
}

// runForTarget backs the user-initiated Refresh/Scan actions, so unlike the
// daemon's Run it must fail visibly: a partial failure keeps skip-and-log
// semantics, but when every enabled observer fails the whole call errors.
// The returned slice is non-nil on success so callers JSON-encode it as [].
func (p *Pipeline) runForTarget(ctx context.Context, targetID int, opts runOpts) ([]db.ObserverEvent, error) {
	obs, err := p.db.GetObserversForEntity("target", targetID)
	if err != nil {
		return nil, err
	}
	out := []db.ObserverEvent{}
	ran, failed := 0, 0
	var lastErr error
	for i := range obs {
		if !obs[i].Enabled {
			continue
		}
		ran++
		events, err := p.runOne(ctx, obs[i], opts)
		if err != nil {
			p.logger.Printf("observers: observer %d: %v", obs[i].ID, err)
			failed++
			lastErr = err
			continue
		}
		out = append(out, events...)
	}
	if ran > 0 && failed == ran {
		return nil, fmt.Errorf("all %d observer(s) failed, last: %w", ran, lastErr)
	}
	return out, nil
}

// runOne runs a single observer and persists its events, advancing the watermark.
func (p *Pipeline) runOne(ctx context.Context, o db.Observer, opts runOpts) ([]db.ObserverEvent, error) {
	if o.EntityType != "target" {
		return nil, nil // v1 only handles targets
	}
	target, err := p.db.GetTargetByID(o.EntityID)
	if err != nil {
		return nil, fmt.Errorf("loading target %d: %w", o.EntityID, err)
	}

	since := opts.sinceOverride
	if since == "" {
		since = o.LastRunAt
	}
	if since == "" {
		since = time.Now().Add(-defaultLookback).UTC().Format("2006-01-02T15:04:05Z")
	}

	// Forward runs feed recent activity directly; a backfill window holds too much
	// to feed whole, so it goes through the cheap shortlist → extract retrieval.
	var act db.ObserverActivity
	if opts.isBackfill() {
		act, err = p.gatherBackfillActivity(ctx, o, target, since)
	} else {
		act, err = p.db.GetObserverActivity(since, defaultActivityLimit)
	}
	if err != nil {
		return nil, err
	}

	now := time.Now().UTC().Format("2006-01-02T15:04:05Z")

	// No new activity since the watermark: advance it and exit without an AI call.
	if len(act.Digests) == 0 && len(act.Tracks) == 0 && len(act.Inbox) == 0 {
		return nil, p.db.SetObserverLastRun(o.ID, now)
	}

	// When a source hit the per-source cap the window was only partially read:
	// advance the watermark to the last row actually loaded, not to now, so the
	// overflow is picked up by the next run instead of being skipped forever.
	next := now
	if !opts.isBackfill() && act.CappedAt != "" {
		next = act.CappedAt
		p.logger.Printf("observers: observer %d: activity cap (%d/source) hit; watermark advances to %s, overflow resumes next run",
			o.ID, defaultActivityLimit, next)
	}

	user := buildObserverPrompt(o, target, act)
	ctx2 := digest.WithSource(ctx, "observer.run")
	sys := p.promptFor(prompts.ObserverRun) + "\n\n" + prompts.Directive(p.lang)
	raw, _, _, err := p.gen.Generate(ctx2, sys, user, "")
	if err != nil {
		return nil, fmt.Errorf("observer AI call: %w", err)
	}
	parsed, err := parseObserverOutput(raw)
	if err != nil {
		return nil, fmt.Errorf("parsing observer output: %w", err)
	}

	// Dedup against existing summaries: a backfill re-scans windows the observer
	// already covered, and after a cap-hit forward run the next window partially
	// overlaps sources that were already consumed to now — both would otherwise
	// re-create the same events.
	existing, err := p.db.GetObserverEventSummaries(o.ID, dedupSummaryLimit)
	if err != nil {
		return nil, fmt.Errorf("loading existing summaries: %w", err)
	}
	seen := make(map[string]bool, len(existing))
	for _, s := range existing {
		seen[strings.TrimSpace(s)] = true
	}

	var created []db.ObserverEvent
	insertFailed := false
	deduped := 0
	for _, ev := range parsed {
		summary := strings.TrimSpace(ev.Summary)
		if summary == "" {
			continue
		}
		if seen[summary] {
			deduped++
			continue
		}
		seen[summary] = true
		action := rawJSONOrEmpty(ev.ProposedAction)
		status := "none"
		if action != "" {
			status = "pending"
		}
		rec := db.ObserverEvent{
			ObserverID: o.ID, EntityType: "target", EntityID: o.EntityID,
			Summary: ev.Summary, Detail: ev.Detail,
			SourceType: ev.SourceType, SourceID: ev.SourceID,
			SourceRefs:     encodeRefs(ev.SourceRefs),
			Decision:       rawJSONOrEmpty(ev.Decision),
			ProposedAction: action,
			ActionStatus:   status,
		}
		id, err := p.db.InsertObserverEvent(rec)
		if err != nil {
			p.logger.Printf("observers: insert event for observer %d: %v", o.ID, err)
			insertFailed = true
			continue
		}
		rec.ID = id
		created = append(created, rec)
	}
	if deduped > 0 {
		p.logger.Printf("observers: observer %d: %d event(s) deduped against existing summaries", o.ID, deduped)
	}

	if insertFailed {
		// Leave the watermark un-advanced so the next run re-queries this window
		// rather than silently dropping events that failed to persist.
		return created, fmt.Errorf("one or more observer events failed to insert for observer %d", o.ID)
	}
	if err := p.db.SetObserverLastRun(o.ID, next); err != nil {
		return created, err
	}
	return created, nil
}

// gatherBackfillActivity runs the two-stage retrieval for a history backfill:
// stage 1 shortlists cheap title-only candidates across the whole window (in
// chunks, on the light model), stage 2 loads the full content of the selected
// items for the extract call. Returns empty activity when nothing is selected.
func (p *Pipeline) gatherBackfillActivity(ctx context.Context, o db.Observer, target *db.Target, since string) (db.ObserverActivity, error) {
	titles, err := p.db.GetObserverActivityTitles(since, maxBackfillTitles)
	if err != nil {
		return db.ObserverActivity{}, err
	}
	if len(titles) == 0 {
		return db.ObserverActivity{}, nil
	}
	if len(titles) >= maxBackfillTitles {
		p.logger.Printf("observers: observer %d: backfill considered %d titles (cap); older items skipped", o.ID, maxBackfillTitles)
	}

	// The shortlist prompt returns an ids-only JSON object, so it carries no
	// language directive — there is no operator-facing text to localise.
	sys := p.promptFor(prompts.ObserverShortlist)
	selected := map[titleRef]bool{}
	for start := 0; start < len(titles) && len(selected) < maxCandidates; start += shortlistChunk {
		if ctx.Err() != nil {
			return db.ObserverActivity{}, ctx.Err()
		}
		end := start + shortlistChunk
		if end > len(titles) {
			end = len(titles)
		}
		user := buildShortlistPrompt(o, target, titles[start:end], maxCandidates)
		ctx2 := digest.WithSource(ctx, "observer.shortlist")
		raw, _, _, err := p.gen.Generate(ctx2, sys, user, "")
		if err != nil {
			return db.ObserverActivity{}, fmt.Errorf("observer shortlist AI call: %w", err)
		}
		refs, err := parseShortlistOutput(raw)
		if err != nil {
			return db.ObserverActivity{}, fmt.Errorf("parsing shortlist output: %w", err)
		}
		for _, r := range refs {
			selected[titleRef{Kind: r.Kind, ID: r.ID}] = true
			if len(selected) >= maxCandidates {
				break
			}
		}
	}
	if len(selected) == 0 {
		return db.ObserverActivity{}, nil
	}

	var digestIDs, trackIDs, inboxIDs []int
	for r := range selected {
		switch r.Kind {
		case "digest":
			digestIDs = append(digestIDs, r.ID)
		case "track":
			trackIDs = append(trackIDs, r.ID)
		case "inbox":
			inboxIDs = append(inboxIDs, r.ID)
		}
	}
	return p.db.GetObserverActivityByIDs(digestIDs, trackIDs, inboxIDs)
}

// promptFor loads the registered template for id from the DB, falling back to
// the built-in default when the id is not seeded (db.GetPrompt returns
// (nil, nil)) or is blank. A real DB error is logged before falling back so a
// broken prompts table does not silently bypass user customization.
func (p *Pipeline) promptFor(id string) string {
	row, err := p.db.GetPrompt(id)
	if err != nil {
		p.logger.Printf("observers: loading prompt %s: %v (falling back to built-in default)", id, err)
	} else if row != nil && row.Template != "" {
		return row.Template
	}
	return prompts.DefaultFor(id)
}

// Compose drafts an observer name + watch instruction for a target from the
// operator's free-text request. It does not persist anything — the caller
// decides whether to create the observer.
func (p *Pipeline) Compose(ctx context.Context, targetID int, input string) (ComposeResult, error) {
	target, err := p.db.GetTargetByID(targetID)
	if err != nil {
		return ComposeResult{}, fmt.Errorf("loading target %d: %w", targetID, err)
	}
	user := buildComposePrompt(target, input)
	ctx2 := digest.WithSource(ctx, "observer.compose")
	sys := p.promptFor(prompts.ObserverCompose) + "\n\n" + prompts.Directive(p.lang)
	raw, _, _, err := p.gen.Generate(ctx2, sys, user, "")
	if err != nil {
		return ComposeResult{}, fmt.Errorf("observer compose AI call: %w", err)
	}
	return parseComposeOutput(raw)
}
