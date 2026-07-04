// Package customtracks scans user-authored custom tracks (tracks with
// origin='custom') over recent cross-source activity and produces an event
// timeline (track_events) of relevant updates. Each event may carry a
// confirmable proposed action. It is the observer engine promoted into
// first-class tracks: describe → compose a watch instruction → scan → timeline.
package customtracks

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

// defaultLookback bounds the first run of a never-scanned custom track.
const defaultLookback = 7 * 24 * time.Hour

// defaultActivityLimit caps rows per source on a normal forward run.
const defaultActivityLimit = 40

// dedupSummaryLimit bounds how many existing summaries a backfill loads to dedup
// against (a backfill re-scans windows the track already covered).
const dedupSummaryLimit = 400

// History-backfill tuning (two-stage retrieval). A deep window holds far more
// activity than fits one extract call, so stage 1 filters cheap title-only
// candidates and stage 2 extracts from their full content.
const (
	maxBackfillTitles = 3000 // safety cap on titles considered (logged if hit)
	shortlistChunk    = 1000 // titles per cheap stage-1 AI call (titles are tiny)
	maxCandidates     = 60   // selected items fed to the stage-2 extract call
)

// runOpts tunes a single scan. The zero value is a normal forward run (since =
// the track's watermark, single extract call, no dedup). A history backfill sets
// sinceOverride to a deeper watermark and switches to the two-stage
// shortlist→extract path with dedup.
type runOpts struct {
	sinceOverride string // non-empty => scan from here instead of the watermark
}

func (o runOpts) isBackfill() bool { return o.sinceOverride != "" }

// Pipeline scans custom tracks and persists their events.
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

// Run scans every enabled custom track over activity since its watermark.
// Returns the number of events created. Per-track failures are logged and
// skipped.
func (p *Pipeline) Run(ctx context.Context) (int, error) {
	enabled, err := p.db.GetEnabledCustomTracks()
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
			p.logger.Printf("customtracks: track %d: %v", enabled[i].ID, err)
			continue
		}
		total += len(events)
	}
	return total, nil
}

// RunForTrack force-runs one custom track over activity since its watermark and
// returns the new events (non-nil so callers JSON-encode it as []).
func (p *Pipeline) RunForTrack(ctx context.Context, trackID int) ([]db.TrackEvent, error) {
	return p.runForTrack(ctx, trackID, runOpts{})
}

// RunForTrackSince force-runs one custom track over the explicit history window
// [since, now], deduping against events the track already produced. It backs the
// Desktop "Scan history" action. `since` is an ISO8601 watermark; use a very old
// date (e.g. the epoch) for "all history".
func (p *Pipeline) RunForTrackSince(ctx context.Context, trackID int, since string) ([]db.TrackEvent, error) {
	if strings.TrimSpace(since) == "" {
		return nil, fmt.Errorf("RunForTrackSince: empty since")
	}
	return p.runForTrack(ctx, trackID, runOpts{sinceOverride: since})
}

// runForTrack backs the user-initiated Refresh/Scan actions. It loads the track,
// requires it to be a custom track, and runs a single scan. The returned slice
// is non-nil on success so callers JSON-encode it as [].
func (p *Pipeline) runForTrack(ctx context.Context, trackID int, opts runOpts) ([]db.TrackEvent, error) {
	t, err := p.db.GetTrackByID(trackID)
	if err != nil {
		return nil, fmt.Errorf("loading track %d: %w", trackID, err)
	}
	if t.Origin != "custom" {
		return nil, fmt.Errorf("track %d is not a custom track", trackID)
	}
	events, err := p.runOne(ctx, *t, opts)
	if err != nil {
		return nil, err
	}
	if events == nil {
		events = []db.TrackEvent{}
	}
	return events, nil
}

// runOne scans a single custom track and persists its events, advancing the
// watermark.
func (p *Pipeline) runOne(ctx context.Context, t db.Track, opts runOpts) ([]db.TrackEvent, error) {
	since := opts.sinceOverride
	if since == "" {
		since = t.LastRunAt
	}
	if since == "" {
		since = time.Now().Add(-defaultLookback).UTC().Format("2006-01-02T15:04:05Z")
	}

	// Forward runs feed recent activity directly; a backfill window holds too much
	// to feed whole, so it goes through the cheap shortlist → extract retrieval.
	var act db.ScanActivity
	var err error
	if opts.isBackfill() {
		act, err = p.gatherBackfillActivity(ctx, t, since)
	} else {
		act, err = p.db.GetScanActivity(since, defaultActivityLimit)
	}
	if err != nil {
		return nil, err
	}

	now := time.Now().UTC().Format("2006-01-02T15:04:05Z")

	// No new activity since the watermark: advance it and exit without an AI call.
	if len(act.Digests) == 0 && len(act.Tracks) == 0 && len(act.Inbox) == 0 {
		return nil, p.db.SetTrackLastRun(t.ID, now)
	}

	// When a source hit the per-source cap the window was only partially read:
	// advance the watermark to the last row actually loaded, not to now, so the
	// overflow is picked up by the next run instead of being skipped forever.
	next := now
	if !opts.isBackfill() && act.CappedAt != "" {
		next = act.CappedAt
		p.logger.Printf("customtracks: track %d: activity cap (%d/source) hit; watermark advances to %s, overflow resumes next run",
			t.ID, defaultActivityLimit, next)
	}

	user := buildScanPrompt(t, act)
	ctx2 := digest.WithSource(ctx, "customtrack.run")
	sys := p.promptFor(prompts.TrackRun) + "\n\n" + prompts.Directive(p.lang)
	raw, _, _, err := p.gen.Generate(ctx2, sys, user, "")
	if err != nil {
		return nil, fmt.Errorf("custom-track AI call: %w", err)
	}
	parsed, err := parseScanOutput(raw)
	if err != nil {
		return nil, fmt.Errorf("parsing custom-track output: %w", err)
	}

	// Dedup against existing summaries: a backfill re-scans windows the track
	// already covered, and after a cap-hit forward run the next window partially
	// overlaps sources that were already consumed to now — both would otherwise
	// re-create the same events.
	existing, err := p.db.GetTrackEventSummaries(t.ID, dedupSummaryLimit)
	if err != nil {
		return nil, fmt.Errorf("loading existing summaries: %w", err)
	}
	seen := make(map[string]bool, len(existing))
	for _, s := range existing {
		seen[strings.TrimSpace(s)] = true
	}

	var created []db.TrackEvent
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
		rec := db.TrackEvent{
			TrackID: t.ID,
			Summary: ev.Summary, Detail: ev.Detail,
			SourceType: ev.SourceType, SourceID: ev.SourceID,
			SourceRefs:     encodeRefs(ev.SourceRefs),
			Decision:       rawJSONOrEmpty(ev.Decision),
			ProposedAction: action,
			ActionStatus:   status,
		}
		id, err := p.db.InsertTrackEvent(rec)
		if err != nil {
			p.logger.Printf("customtracks: insert event for track %d: %v", t.ID, err)
			insertFailed = true
			continue
		}
		rec.ID = id
		created = append(created, rec)
	}
	if deduped > 0 {
		p.logger.Printf("customtracks: track %d: %d event(s) deduped against existing summaries", t.ID, deduped)
	}

	if insertFailed {
		// Leave the watermark un-advanced so the next run re-queries this window
		// rather than silently dropping events that failed to persist.
		return created, fmt.Errorf("one or more track events failed to insert for track %d", t.ID)
	}
	if err := p.db.SetTrackLastRun(t.ID, next); err != nil {
		return created, err
	}
	return created, nil
}

// gatherBackfillActivity runs the two-stage retrieval for a history backfill:
// stage 1 shortlists cheap title-only candidates across the whole window (in
// chunks, on the light model), stage 2 loads the full content of the selected
// items for the extract call. Returns empty activity when nothing is selected.
func (p *Pipeline) gatherBackfillActivity(ctx context.Context, t db.Track, since string) (db.ScanActivity, error) {
	titles, err := p.db.GetScanActivityTitles(since, maxBackfillTitles)
	if err != nil {
		return db.ScanActivity{}, err
	}
	if len(titles) == 0 {
		return db.ScanActivity{}, nil
	}
	if len(titles) >= maxBackfillTitles {
		p.logger.Printf("customtracks: track %d: backfill considered %d titles (cap); older items skipped", t.ID, maxBackfillTitles)
	}

	// The shortlist prompt returns an ids-only JSON object, so it carries no
	// language directive — there is no operator-facing text to localise.
	sys := p.promptFor(prompts.TrackShortlist)
	selected := map[titleRef]bool{}
	for start := 0; start < len(titles) && len(selected) < maxCandidates; start += shortlistChunk {
		if ctx.Err() != nil {
			return db.ScanActivity{}, ctx.Err()
		}
		end := start + shortlistChunk
		if end > len(titles) {
			end = len(titles)
		}
		user := buildShortlistPrompt(t, titles[start:end], maxCandidates)
		ctx2 := digest.WithSource(ctx, "customtrack.shortlist")
		raw, _, _, err := p.gen.Generate(ctx2, sys, user, "")
		if err != nil {
			return db.ScanActivity{}, fmt.Errorf("custom-track shortlist AI call: %w", err)
		}
		refs, err := parseShortlistOutput(raw)
		if err != nil {
			return db.ScanActivity{}, fmt.Errorf("parsing shortlist output: %w", err)
		}
		for _, r := range refs {
			selected[titleRef{Kind: r.Kind, ID: r.ID}] = true
			if len(selected) >= maxCandidates {
				break
			}
		}
	}
	if len(selected) == 0 {
		return db.ScanActivity{}, nil
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
	return p.db.GetScanActivityByIDs(digestIDs, trackIDs, inboxIDs)
}

// promptFor loads the registered template for id from the DB, falling back to
// the built-in default when the id is not seeded (db.GetPrompt returns
// (nil, nil)) or is blank. A real DB error is logged before falling back so a
// broken prompts table does not silently bypass user customization.
func (p *Pipeline) promptFor(id string) string {
	row, err := p.db.GetPrompt(id)
	if err != nil {
		p.logger.Printf("customtracks: loading prompt %s: %v (falling back to built-in default)", id, err)
	} else if row != nil && row.Template != "" {
		return row.Template
	}
	return prompts.DefaultFor(id)
}

// Compose drafts a custom-track title + watch instruction from the operator's
// free-text request. When linkedTargetID > 0 the linked target is loaded for
// context; 0 means a standalone custom track. It does not persist anything — the
// caller decides whether to create the track.
func (p *Pipeline) Compose(ctx context.Context, linkedTargetID int, input string) (ComposeResult, error) {
	var target *db.Target
	if linkedTargetID > 0 {
		t, err := p.db.GetTargetByID(linkedTargetID)
		if err != nil {
			return ComposeResult{}, fmt.Errorf("loading target %d: %w", linkedTargetID, err)
		}
		target = t
	}
	user := buildComposePrompt(target, input)
	ctx2 := digest.WithSource(ctx, "customtrack.compose")
	sys := p.promptFor(prompts.TrackCompose) + "\n\n" + prompts.Directive(p.lang)
	raw, _, _, err := p.gen.Generate(ctx2, sys, user, "")
	if err != nil {
		return ComposeResult{}, fmt.Errorf("custom-track compose AI call: %w", err)
	}
	return parseComposeOutput(raw)
}
