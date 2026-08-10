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
	"time"

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

	// Accumulated provenance drops across this pipeline's passes, the same
	// per-instance accumulation shape as the usage totals above:
	// slackRefsDropped counts digest-topic candidates whose message_ts
	// resolved to no live message (renderTopicUnit), refsRejected counts
	// mention refs the model cited that this run never rendered
	// (applyConsolidateOps) — both IDEA-02 drops. They were log-only before,
	// which left an owner unable to tell "no Slack ideas came out of this run"
	// apart from "every Slack idea this run had was discarded as
	// unverifiable".
	slackRefsDropped int
	refsRejected     int
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

// AccumulatedDrops returns the provenance drops accumulated across this
// pipeline's passes (IDEA-02): unverifiable Slack refs dropped at
// material-assembly time, and model-invented mention refs rejected at apply
// time. Reported by `ideas mine` on both its paths so a silent registry is
// distinguishable from a discarded one — the AccumulatedUsage precedent.
func (p *Pipeline) AccumulatedDrops() (slackRefsDropped, refsRejected int) {
	return p.slackRefsDropped, p.refsRejected
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

// logf logs through the pipeline's logger, which may be nil (a pipeline built
// without one, as several tests and the MCP path do).
func (p *Pipeline) logf(format string, args ...any) {
	if p.logger == nil {
		return
	}
	p.logger.Printf(format, args...)
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
// pre-digest pass, then the stage-2 consolidator (runConsolidate) — always,
// regardless of whether either stage-1 pass failed. A persistent single-
// account failure (a revoked Jira token, say) must never starve
// consolidation of every OTHER source's already-queued material (healthy
// accounts' stream_digests rows, Slack digest topics, meeting transcripts)
// forever — the "one account's failure never blocks the others" principle,
// and IDEA-01 already makes partial-material consolidation safe (unconsumed
// material just waits; floors stay honest). Each stage-1 pass logs and
// continues past a single account's failure (see runEmailDigests/
// runJiraDigests) and all three stages always get their turn; Run surfaces
// the first error any of them produced — a stage-1 failure if one occurred,
// otherwise the consolidator's — without swallowing it. Run returns the
// consolidator's proposed count.
func (p *Pipeline) Run(ctx context.Context) (proposed int, err error) {
	if p.cfg != nil && !p.cfg.Ideas.Enabled {
		return 0, nil
	}
	var firstErr error
	if err := p.runEmailDigests(ctx, time.Time{}); err != nil {
		firstErr = err
	}
	if err := p.runJiraDigests(ctx, time.Time{}); err != nil && firstErr == nil {
		firstErr = err
	}

	proposed, _, cerr := p.runConsolidate(ctx, time.Time{}, time.Time{})
	if cerr != nil && firstErr == nil {
		firstErr = cerr
	}
	return proposed, firstErr
}
