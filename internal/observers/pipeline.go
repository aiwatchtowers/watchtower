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
	logger *log.Logger
}

// New constructs a Pipeline.
func New(database *db.DB, gen digest.Generator, logger *log.Logger) *Pipeline {
	if logger == nil {
		logger = log.Default()
	}
	return &Pipeline{db: database, gen: gen, logger: logger}
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

func (p *Pipeline) runForTarget(ctx context.Context, targetID int, opts runOpts) ([]db.ObserverEvent, error) {
	obs, err := p.db.GetObserversForEntity("target", targetID)
	if err != nil {
		return nil, err
	}
	var out []db.ObserverEvent
	for i := range obs {
		if !obs[i].Enabled {
			continue
		}
		events, err := p.runOne(ctx, obs[i], opts)
		if err != nil {
			p.logger.Printf("observers: observer %d: %v", obs[i].ID, err)
			continue
		}
		out = append(out, events...)
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

	user := buildObserverPrompt(o, target, act)
	ctx2 := digest.WithSource(ctx, "observer.run")
	raw, _, _, err := p.gen.Generate(ctx2, p.systemPrompt(), user, "")
	if err != nil {
		return nil, fmt.Errorf("observer AI call: %w", err)
	}
	parsed, err := parseObserverOutput(raw)
	if err != nil {
		return nil, fmt.Errorf("parsing observer output: %w", err)
	}

	// On a history backfill the scanned window overlaps activity the observer
	// already covered on earlier runs, so dedup against existing summaries.
	var seen map[string]bool
	if opts.isBackfill() {
		existing, err := p.db.GetObserverEventSummaries(o.ID, dedupSummaryLimit)
		if err != nil {
			return nil, fmt.Errorf("loading existing summaries: %w", err)
		}
		seen = make(map[string]bool, len(existing))
		for _, s := range existing {
			seen[strings.TrimSpace(s)] = true
		}
	}

	var created []db.ObserverEvent
	insertFailed := false
	for _, ev := range parsed {
		summary := strings.TrimSpace(ev.Summary)
		if summary == "" {
			continue
		}
		if seen != nil {
			if seen[summary] {
				continue
			}
			seen[summary] = true
		}
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

	if insertFailed {
		// Leave the watermark un-advanced so the next run re-queries this window
		// rather than silently dropping events that failed to persist.
		return created, fmt.Errorf("one or more observer events failed to insert for observer %d", o.ID)
	}
	if err := p.db.SetObserverLastRun(o.ID, now); err != nil {
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

	sys := p.shortlistSystemPrompt()
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

// systemPrompt loads the registered observer.run template from the DB, falling
// back to the built-in default if the DB has no row. db.GetPrompt returns
// (*db.Prompt, error) and (nil, nil) when the id is not seeded.
func (p *Pipeline) systemPrompt() string {
	if row, err := p.db.GetPrompt(prompts.ObserverRun); err == nil && row != nil && row.Template != "" {
		return row.Template
	}
	return prompts.DefaultFor(prompts.ObserverRun)
}

// shortlistSystemPrompt loads the registered observer.shortlist template, falling
// back to the built-in default.
func (p *Pipeline) shortlistSystemPrompt() string {
	if row, err := p.db.GetPrompt(prompts.ObserverShortlist); err == nil && row != nil && row.Template != "" {
		return row.Template
	}
	return prompts.DefaultFor(prompts.ObserverShortlist)
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
	raw, _, _, err := p.gen.Generate(ctx2, p.composeSystemPrompt(), user, "")
	if err != nil {
		return ComposeResult{}, fmt.Errorf("observer compose AI call: %w", err)
	}
	return parseComposeOutput(raw)
}

// composeSystemPrompt loads the registered observer.compose template from the
// DB, falling back to the built-in default.
func (p *Pipeline) composeSystemPrompt() string {
	if row, err := p.db.GetPrompt(prompts.ObserverCompose); err == nil && row != nil && row.Template != "" {
		return row.Template
	}
	return prompts.DefaultFor(prompts.ObserverCompose)
}
