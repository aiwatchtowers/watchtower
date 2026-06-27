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
		events, err := p.runOne(ctx, enabled[i])
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
	obs, err := p.db.GetObserversForEntity("target", targetID)
	if err != nil {
		return nil, err
	}
	var out []db.ObserverEvent
	for i := range obs {
		if !obs[i].Enabled {
			continue
		}
		events, err := p.runOne(ctx, obs[i])
		if err != nil {
			p.logger.Printf("observers: observer %d: %v", obs[i].ID, err)
			continue
		}
		out = append(out, events...)
	}
	return out, nil
}

// runOne runs a single observer and persists its events, advancing the watermark.
func (p *Pipeline) runOne(ctx context.Context, o db.Observer) ([]db.ObserverEvent, error) {
	if o.EntityType != "target" {
		return nil, nil // v1 only handles targets
	}
	target, err := p.db.GetTargetByID(o.EntityID)
	if err != nil {
		return nil, fmt.Errorf("loading target %d: %w", o.EntityID, err)
	}

	since := o.LastRunAt
	if since == "" {
		since = time.Now().Add(-defaultLookback).UTC().Format("2006-01-02T15:04:05Z")
	}
	act, err := p.db.GetObserverActivity(since, 40)
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

	var created []db.ObserverEvent
	insertFailed := false
	for _, ev := range parsed {
		if strings.TrimSpace(ev.Summary) == "" {
			continue
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

// systemPrompt loads the registered observer.run template from the DB, falling
// back to the built-in default if the DB has no row. db.GetPrompt returns
// (*db.Prompt, error) and (nil, nil) when the id is not seeded.
func (p *Pipeline) systemPrompt() string {
	if row, err := p.db.GetPrompt(prompts.ObserverRun); err == nil && row != nil && row.Template != "" {
		return row.Template
	}
	return prompts.DefaultFor(prompts.ObserverRun)
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
