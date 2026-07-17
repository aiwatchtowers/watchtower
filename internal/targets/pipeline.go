package targets

import (
	"context"
	"fmt"
	"log"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// Pipeline orchestrates target extraction, linking, and persistence.
type Pipeline struct {
	db       *db.DB
	cfg      *config.TargetsConfig
	gen      digest.Generator
	resolver *Resolver
	store    *Store
	lang     string // workspace response language (digest.language); "" falls back to the prompts default
	logger   *log.Logger
}

// New creates a new Pipeline. lang is the workspace response language
// (cfg.Digest.Language) injected into operator-facing prompts via
// prompts.Directive; an empty value falls back to prompts.DefaultLanguage.
func New(database *db.DB, cfg *config.TargetsConfig, gen digest.Generator, resolver *Resolver, lang string, logger *log.Logger) *Pipeline {
	if logger == nil {
		logger = log.Default()
	}
	return &Pipeline{
		db:       database,
		cfg:      cfg,
		gen:      gen,
		resolver: resolver,
		store:    NewStore(database),
		lang:     lang,
		logger:   logger,
	}
}

// Extract runs the AI extraction pipeline for the given request.
// It resolves URLs, loads the active target snapshot, calls the AI,
// parses the response with cap enforcement, and returns the proposed
// targets ready for user preview. Nothing is written to the DB.
func (p *Pipeline) Extract(ctx context.Context, req ExtractRequest) (*ExtractResult, error) {
	if p.cfg != nil && !p.cfg.Extract.Enabled {
		return nil, fmt.Errorf("extraction disabled")
	}

	// Apply timeout from config. A non-positive value disables the deadline
	// entirely: extraction is a user-cancellable background op (Desktop
	// capsule), not a wall-clock-bounded call — see the 2026-07-16 spec.
	// cfg == nil keeps the built-in default (also 0 → no deadline).
	timeoutSec := config.DefaultTargetsExtractTimeoutSeconds
	if p.cfg != nil {
		timeoutSec = p.cfg.Extract.TimeoutSeconds
	}
	var aiCtx context.Context
	var cancel context.CancelFunc
	if timeoutSec > 0 {
		aiCtx, cancel = context.WithTimeout(ctx, time.Duration(timeoutSec)*time.Second)
	} else {
		aiCtx, cancel = context.WithCancel(ctx)
	}
	defer cancel()

	// Detect and resolve URLs in the raw text.
	var enrichments []Enrichment
	if p.resolver != nil {
		matches := Extract(req.RawText)
		if len(matches) > 0 {
			enrichments = p.resolver.Resolve(aiCtx, matches)
		}
	}

	// Load active target snapshot (top 100 by updated_at desc then priority).
	limit := 100
	if p.cfg != nil && p.cfg.Resolver.ActiveSnapshotLimit > 0 {
		limit = p.cfg.Resolver.ActiveSnapshotLimit
	}
	snapshot, err := p.db.GetTargets(db.TargetFilter{
		Limit: limit,
	})
	if err != nil {
		p.logger.Printf("targets/pipeline: loading snapshot: %v", err)
		snapshot = nil
	}

	// Build and call the AI.
	prompt := buildExtractPrompt(req, enrichments, snapshot, time.Now())
	ctx2 := digest.WithSource(aiCtx, digest.SourceLight)

	raw, _, _, err := p.gen.Generate(ctx2, prompt, "Extract targets from the provided text.", "")
	if err != nil {
		return nil, fmt.Errorf("AI extraction call: %w", err)
	}

	// Parse with retry-once on malformed JSON.
	result, parseErr := parseExtractResponse(raw, snapshot, p.logger)
	if parseErr != nil {
		p.logger.Printf("targets/pipeline: parse error (attempt 1): %v — retrying", parseErr)
		raw2, _, _, err2 := p.gen.Generate(ctx2, prompt, "Extract targets from the provided text. Return valid JSON only.", "")
		if err2 != nil {
			return nil, fmt.Errorf("AI extraction retry call: %w", err2)
		}
		result, parseErr = parseExtractResponse(raw2, snapshot, p.logger)
		if parseErr != nil {
			return nil, fmt.Errorf("AI extraction: malformed JSON after retry: %w", parseErr)
		}
	}

	return result, nil
}

// LinkExisting runs the lighter AI call to propose parent_id and secondary links
// for an already-persisted target. Nothing is written to the DB; the caller
// applies the result after user confirmation.
func (p *Pipeline) LinkExisting(ctx context.Context, targetID int64) (*LinkResult, error) {
	target, err := p.db.GetTargetByID(int(targetID))
	if err != nil {
		return nil, fmt.Errorf("loading target %d: %w", targetID, err)
	}

	// Active snapshot for context.
	limit := 100
	if p.cfg != nil && p.cfg.Resolver.ActiveSnapshotLimit > 0 {
		limit = p.cfg.Resolver.ActiveSnapshotLimit
	}
	snapshot, err := p.db.GetTargets(db.TargetFilter{Limit: limit})
	if err != nil {
		p.logger.Printf("targets/pipeline: loading snapshot for link: %v", err)
		snapshot = nil
	}

	prompt := buildLinkPrompt(*target, snapshot)
	ctx2 := digest.WithSource(ctx, "targets.link")

	raw, _, _, err := p.gen.Generate(ctx2, prompt, "Propose links for the given target.", "")
	if err != nil {
		return nil, fmt.Errorf("AI link call: %w", err)
	}

	return parseLinkResponse(raw, snapshot)
}

// CreateFromExtraction batch-inserts proposed targets (after user confirmation)
// using a single transaction. Returns the new target IDs.
func (p *Pipeline) CreateFromExtraction(ctx context.Context, items []ProposedTarget, sourceType, sourceRef string) ([]int64, error) {
	return p.store.CreateBatch(ctx, items, sourceType, sourceRef)
}
