// Package ideas mines ideas and decisions from Slack digests, meeting
// transcripts, Gmail, and Jira into a durable registry (internal/db/ideas.go).
//
// The pipeline runs in two stages. Stage 1 (this file, plus email_digest.go
// and jira_digest.go) prepares stream pre-digests for the two sources with no
// existing digest pipeline of their own: one Generate call per connected
// Gmail/Jira account, over the window newer than that account's own floor,
// writing a stream_digests row per successful pass (internal/db/ideas.go's
// StreamDigest). Stage 2 (Task 8's consolidator) folds stage-1 material
// (Slack digest topics, stream_digests rows, meeting recaps) into the
// registry, preferring to attach to an existing idea/decision over minting a
// duplicate.
package ideas

import (
	"context"
	"log"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// Pipeline runs the ideas registry's mining passes (Pipeline struct shape
// copied from internal/inbox/pipeline.go).
type Pipeline struct {
	db          *db.DB
	cfg         *config.Config
	generator   digest.Generator
	logger      *log.Logger
	promptStore *prompts.Store

	// Accumulated usage across all AI calls.
	totalInputTokens  int
	totalOutputTokens int
	totalAPITokens    int
}

// New creates a new ideas pipeline.
func New(database *db.DB, cfg *config.Config, gen digest.Generator, logger *log.Logger) *Pipeline {
	return &Pipeline{
		db:        database,
		cfg:       cfg,
		generator: gen,
		logger:    logger,
	}
}

// SetPromptStore sets an optional prompt store for loading customized prompts.
func (p *Pipeline) SetPromptStore(store *prompts.Store) {
	p.promptStore = store
}

// AccumulatedUsage returns the total token usage accumulated across all
// Generate calls (input tokens, output tokens, cost in USD — always 0, the
// inbox pipeline precedent — and total API tokens).
func (p *Pipeline) AccumulatedUsage() (int, int, float64, int) {
	return p.totalInputTokens, p.totalOutputTokens, 0, p.totalAPITokens
}

// accumulateUsage folds one Generate call's token usage into the pipeline's
// running totals. usage may be nil (no-op).
func (p *Pipeline) accumulateUsage(usage *digest.Usage) {
	if usage == nil {
		return
	}
	p.totalInputTokens += usage.InputTokens
	p.totalOutputTokens += usage.OutputTokens
	p.totalAPITokens += usage.TotalAPITokens
}

// getPrompt returns a prompt template and its version, preferring an
// owner-customized version from the prompt store over the compiled default.
func (p *Pipeline) getPrompt(id string) (string, int) {
	if p.promptStore != nil {
		tmpl, version, err := p.promptStore.Get(id)
		if err == nil {
			return tmpl, version
		}
	}
	return prompts.Defaults[id], 0
}

// language returns the digest output language, defaulting via
// prompts.Directive when cfg is nil or unset.
func (p *Pipeline) language() string {
	if p.cfg == nil {
		return ""
	}
	return p.cfg.Digest.Language
}

// Run executes the ideas pipeline: the Gmail pre-digest pass, then the Jira
// pre-digest pass. Stage 2 (the consolidator, Task 8) will slot in after both
// once it exists — until then Run never proposes any idea, so proposed is
// always 0. Each pass logs and continues past a single account's failure
// (see runEmailDigests/runJiraDigests); Run itself returns the first error
// either pass produced, after giving both a chance to run.
func (p *Pipeline) Run(ctx context.Context) (proposed int, err error) {
	if p.cfg != nil && !p.cfg.Ideas.Enabled {
		return 0, nil
	}
	var firstErr error
	if err := p.runEmailDigests(ctx); err != nil {
		firstErr = err
	}
	if err := p.runJiraDigests(ctx); err != nil && firstErr == nil {
		firstErr = err
	}
	return 0, firstErr
}
