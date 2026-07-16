package memory

import (
	"context"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// extractSource is the WithSource tag that routes extractor calls to the
// cheap model tier (see internal/digest/models.go and internal/codex/models.go).
const extractSource = "memory.extract_episodes"

// extractBatchSource is the WithSource tag for the multi-channel batched
// extractor call (see extractBatch).
const extractBatchSource = "memory.extract_episodes_batch"

// seedWindowDays is the activity lookback for mechanical entity seeding
// (people/channels active in the last 30 days, per the design spec).
const seedWindowDays = 30

// RunStats counts what one consolidation run did.
type RunStats struct {
	OwnerEditsCommitted bool        // MEM-03: a dirty worktree was committed as owner-edit first
	Reconciled          Stats       // index mutations from the reconcile pass
	Seeded              int         // skeleton entity pages created
	Ingested            IngestStats // situation → episode mirror counts
	Messages            int         // raw messages loaded into extraction windows
	Windows             int         // channel windows built from those messages
	WindowsFailed       int         // windows whose extraction failed (watermark frozen for them)
	Episodes            int         // episode nodes written by the extractor
	RefsRejected        int         // provenance refs dropped by MEM-01 validation
	Malformed           int         // shape-degenerate extractor episodes (parsed but zero refs)

	// Semantic tier (Phase 3, all zero unless memory.semantic.enabled).
	Deduped           int // episodes merged into their older twin (DedupeEpisodes)
	Promoted          int // concept entities created from recurring hints (PromoteConcepts)
	Rewritten         int // entity pages rewritten by the strong tier (RewriteEntityPages)
	RewriteFailed     int // entity rewrites attempted but not applied (generate/parse/order failures)
	BeliefOps         int // belief ops applied by the belief pass (ReviseBeliefs)
	BeliefOpsRejected int // belief ops the rank math refused (MEM-06/08)
	Aged              int // raw non-situation episodes aged to closed+long (AgeEpisodes)
	Evicted           int // closed long episodes rolled up and tombstoned (EvictEpisodes)

	// Phase-4 surfaces (zero unless the matching memory.surfaces.* gate is on).
	ChatTurnsIngested int // owner Discuss turns staged as belief evidence (ingestChatStatements)
}

// Pipeline is the memory consolidation daemon phase: reconcile → seed →
// ingest → extract (chunked per channel window) → mechanical map.md render,
// with pipeline_runs/pipeline_steps accounting.
type Pipeline struct {
	db        *db.DB
	vault     *Vault
	generator digest.Generator
	cfg       config.MemoryConfig
	logf      func(string, ...any)
	// checkMsg is the MEM-01 provenance lookup — the database in production,
	// an erroring fake in tests exercising the lookup-failure freeze.
	checkMsg messageChecker
	// promptStore optionally serves user-customized templates for the
	// extractor prompt (same seam as the inbox pipeline); nil falls back to
	// the built-in default.
	promptStore *prompts.Store

	// chat holds the owner Discuss turns ingestChatStatements staged for THIS
	// run's belief pass (nil unless memory.surfaces.chat staged some). Set at the
	// head of runSemantic, read by ReviseBeliefs, cleared after the belief pass.
	chat *stagedChat

	// Source labels the pipeline_runs row ("cli" or "daemon"). NewPipeline
	// defaults it to "cli"; the daemon overrides it.
	Source string
	// Language is the response language for extractor output, set from
	// cfg.Digest.Language at construction (cmd wiring). Empty falls back to
	// prompts.DefaultLanguage via prompts.Directive.
	Language string
}

// SetPromptStore sets an optional prompt store for loading customized prompts.
func (p *Pipeline) SetPromptStore(store *prompts.Store) {
	p.promptStore = store
}

// getPrompt loads a template from the prompt store, falling back to the
// built-in default (same shape as the inbox pipeline's seam).
func (p *Pipeline) getPrompt(id string) string {
	if p.promptStore != nil {
		if tmpl, _, err := p.promptStore.Get(id); err == nil {
			return tmpl
		}
	}
	return prompts.Defaults[id]
}

// NewPipeline creates a memory consolidation pipeline. generator may be nil
// (extraction is skipped); logf may be nil (logging is dropped).
func NewPipeline(database *db.DB, vault *Vault, gen digest.Generator, cfg config.MemoryConfig, logf func(string, ...any)) *Pipeline {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	return &Pipeline{db: database, vault: vault, generator: gen, cfg: cfg, logf: logf, checkMsg: database, Source: "cli"}
}

// Run executes one consolidation pass. Order per the design spec:
//
//  1. Owner edits committed first (MEM-03), then Reconcile so the index
//     absorbs the owner's changes before any machine write of this run.
//  2. Mechanical entity seeding.
//  3. Situations → episode nodes.
//  4. Episode extraction from raw text, chunked per channel window; the
//     watermark advances only behind fully committed windows (MEM-04).
//  5. Semantic tier (dedupe → concept promotion → page rewrite → belief pass →
//     eviction), gated by memory.semantic.enabled and isolated per step.
//  6. Mechanical index.md render + map.md render (strong when the semantic tier
//     is on and within budget, mechanical fallback otherwise).
//  7. pipeline_runs finalization.
//
// Failure semantics: errors in steps 1–3 are fatal (the run stops, already
// committed work stays); a per-window AI failure in step 4 freezes the
// watermark for that window but never fails the run (window isolation,
// catchup-style) — it is recorded in the window's pipeline_steps row; a
// semantic step failure in step 5 is logged and skipped and never fails the run
// or moves a watermark. A disabled config is a full no-op: nothing written, no
// pipeline_runs row.
func (p *Pipeline) Run(ctx context.Context) (RunStats, error) {
	var stats RunStats
	if !p.cfg.Enabled {
		return stats, nil
	}

	// Cross-process exclusion: the daemon phase and CLI consolidate/seed/
	// reindex all write the same vault + watermark, so only one may run at a
	// time. Contention returns ErrLocked before anything is written or
	// recorded (the CLI prints it, the daemon logs and skips the cycle).
	unlock, err := p.vault.Lock()
	if err != nil {
		return stats, err
	}
	defer unlock()

	runID, err := p.db.CreatePipelineRun("memory", p.Source, "auto")
	if err != nil {
		p.logf("memory: create pipeline run: %v", err) // accounting only — the run proceeds unrecorded
	}
	acc := &usageAccumulator{}
	wmBefore, err := p.db.MemoryWatermark()
	if err != nil {
		return stats, p.fatal(runID, acc, &stats, wmBefore, err)
	}

	// (1) MEM-03: manual vault changes become their own owner-edit commit
	// before any machine write; Reconcile runs after so the index absorbs them.
	stats.OwnerEditsCommitted, err = p.vault.CommitOwnerEdits()
	if err != nil {
		return stats, p.fatal(runID, acc, &stats, wmBefore, fmt.Errorf("memory: owner edits: %w", err))
	}
	stats.Reconciled, err = Reconcile(p.vault, p.db, p.logf)
	if err != nil {
		return stats, p.fatal(runID, acc, &stats, wmBefore, err)
	}

	// (2) Mechanical entity seeding (no AI).
	stats.Seeded, err = SeedEntities(p.vault, p.db, SeedConfig{MinMessages: p.cfg.SeedMinMessages, WindowDays: seedWindowDays})
	if err != nil {
		return stats, p.fatal(runID, acc, &stats, wmBefore, err)
	}

	// (3) Situations → episode nodes (mechanical).
	stats.Ingested, err = IngestSituations(p.vault, p.db, p.checkMsg, p.logf)
	if err != nil {
		return stats, p.fatal(runID, acc, &stats, wmBefore, err)
	}

	// (4) Episode extraction from raw text.
	batchSteps, err := p.runExtract(ctx, runID, acc, &stats)
	if err != nil {
		return stats, p.fatal(runID, acc, &stats, wmBefore, err)
	}

	// (5) Semantic tier (Phase 3) — dark behind memory.semantic.enabled. Each
	// step is isolated (a failure is logged and never fails the run) and never
	// advances any watermark (compose/card precedent); the strong-tier AI steps
	// stop launching once the run's accumulated output tokens exceed the budget.
	semanticEnabled := p.cfg.Semantic.Enabled
	if semanticEnabled {
		p.runSemantic(ctx, runID, batchSteps, acc, &stats)
	}

	// (6) Renders. index.md is the mechanical full listing (always, when memory
	// is enabled); map.md is the strong-tier hot summary when the semantic tier
	// is on and within budget, else a mechanical fallback so MCP always has a
	// map.md to read. Both are derived state — non-fatal and re-rendered next run.
	if err := p.renderIndex(runID); err != nil {
		p.logf("memory: render index: %v", err)
	}
	strongMap := semanticEnabled && !p.outputBudgetExceeded(acc)
	mapUsage, err := p.renderMap(ctx, runID, strongMap)
	if err != nil {
		p.logf("memory: render map: %v", err)
	}
	acc.add(mapUsage)

	wmAfter, err := p.db.MemoryWatermark()
	if err != nil {
		p.logf("memory: read watermark after run: %v", err)
		wmAfter = wmBefore
	}
	p.completeRun(runID, acc, stats.Episodes, wmBefore, wmAfter, nil)
	p.logf("memory: run done: seeded %d, ingested %+v, %d episodes from %d/%d windows (%d messages, %d refs rejected, %d malformed, %d quarantined); semantic: %d deduped, %d promoted, %d rewritten (%d failed), %d belief-ops (%d rejected), %d aged, %d evicted; surfaces: %d chat-turns",
		stats.Seeded, stats.Ingested, stats.Episodes, stats.Windows-stats.WindowsFailed, stats.Windows, stats.Messages, stats.RefsRejected, stats.Malformed, stats.Reconciled.Quarantined,
		stats.Deduped, stats.Promoted, stats.Rewritten, stats.RewriteFailed, stats.BeliefOps, stats.BeliefOpsRejected, stats.Aged, stats.Evicted, stats.ChatTurnsIngested)
	return stats, nil
}

// semanticEvictScoreThreshold is the retention-score cutoff below which a cold
// closed long episode is evicted into a rollup. Like the retention constants
// (evict.go) it lives in code, not config — one auditable place for the math.
const semanticEvictScoreThreshold = 0.5

// runSemantic executes the Phase-3 semantic tier in the spec order:
// dedupe → concept promotion → page rewrite → belief pass → aging → eviction.
// The mechanical steps (dedupe/promote/age/evict) always run; the two strong-
// tier AI steps (rewrite/beliefs) are skipped once the run's output-token budget
// is spent — a budget-skipped step still records a pipeline_steps row with
// status 'skipped' (the status column is free text; 'skipped' is the cheapest
// honest representation of "would have run, budget denied it"). Every step
// records its own row and is failure-isolated: a step error is logged and the
// next step still runs. No step advances a watermark. Config bounds are floor-
// guarded (an explicit 0 falls back to the default rather than disabling the
// bound). batchSteps is the count of extraction batch rows already recorded —
// the fallback base for step numbering when the DB read fails.
func (p *Pipeline) runSemantic(ctx context.Context, runID int64, batchSteps int, acc *usageAccumulator, stats *RunStats) {
	step := p.nextSemanticStep(runID, batchSteps)

	// Phase-4 chat surface (dark unless memory.surfaces.chat): stage owner Discuss
	// turns as owner-rank belief evidence BEFORE the belief pass. No AI call of its
	// own. The floor advances only after the belief pass commits (below), so a
	// failed or budget-skipped pass re-scans the same turns next run.
	var chatFloorBefore, chatNewFloor int64
	p.chat = nil
	defer func() { p.chat = nil }()
	if p.cfg.Surfaces.Chat {
		start := time.Now()
		floor, ferr := p.db.MemoryChatTurnFloor()
		if ferr != nil {
			p.logf("memory: chat ingest: read floor: %v", ferr)
			p.recordSemanticStep(runID, &step, "chat-ingest", "error", nil, start)
		} else {
			staged, nf, ierr := p.ingestChatStatements(floor)
			chatFloorBefore, chatNewFloor = floor, nf
			if ierr != nil {
				p.logf("memory: chat ingest: %v", ierr)
				chatNewFloor = floor // do not advance on error
			} else {
				p.chat = staged
				if staged != nil {
					stats.ChatTurnsIngested += len(staged.statements)
				}
			}
			p.recordSemanticStep(runID, &step, "chat-ingest", stepStatus(ierr), nil, start)
		}
	}

	// Mechanical: episode dedupe.
	start := time.Now()
	deduped, err := DedupeEpisodes(p.vault, p.db, orDefault(p.cfg.Semantic.DedupeMaxMerges, 20), p.logf)
	stats.Deduped += deduped
	p.recordSemanticStep(runID, &step, "dedupe", stepStatus(err), nil, start)
	if err != nil {
		p.logf("memory: dedupe: %v", err)
	}

	// Mechanical: concept-entity promotion from recurring hints.
	start = time.Now()
	promoted, err := PromoteConcepts(p.vault, p.db, orDefault(p.cfg.Semantic.ConceptMinEpisodes, 5), orDefault(p.cfg.Semantic.ConceptMaxCreate, 10))
	stats.Promoted += promoted
	p.recordSemanticStep(runID, &step, "promote", stepStatus(err), nil, start)
	if err != nil {
		p.logf("memory: promote concepts: %v", err)
	}

	// Strong tier: entity page rewrites (budget-gated). The rewritten subjects
	// scope the belief pass.
	now := time.Now()
	var rewritten []string
	if p.outputBudgetExceeded(acc) {
		p.logf("memory: rewrite skipped: output budget exceeded")
		p.recordSemanticStep(runID, &step, "rewrite", "skipped", nil, now)
	} else {
		start = time.Now()
		var (
			usage  *digest.Usage
			failed int
		)
		rewritten, failed, usage, err = p.RewriteEntityPages(ctx, orDefault(p.cfg.Semantic.RewriteMaxEntities, 10), now)
		acc.add(usage)
		stats.Rewritten += len(rewritten)
		stats.RewriteFailed += failed
		p.recordSemanticStep(runID, &step, "rewrite", stepStatus(err), usage, start)
		if err != nil {
			p.logf("memory: rewrite entity pages: %v", err)
		}
	}

	// Strong tier: belief revision over the rewritten subjects + shaken beliefs
	// (budget-gated). beliefsConsumed reports whether the pass actually ran to a
	// clean commit — the gate on advancing the chat-turn floor (below), so a
	// budget-skip or a belief-pass error re-stages the same owner turns next run.
	beliefsConsumed := false
	if p.outputBudgetExceeded(acc) {
		p.logf("memory: belief pass skipped: output budget exceeded")
		p.recordSemanticStep(runID, &step, "beliefs", "skipped", nil, time.Now())
	} else {
		start = time.Now()
		touched, rejected, usage, berr := p.ReviseBeliefs(ctx, rewritten, orDefault(p.cfg.Semantic.BeliefsMax, 20), now)
		acc.add(usage)
		stats.BeliefOps += touched
		stats.BeliefOpsRejected += rejected
		p.recordSemanticStep(runID, &step, "beliefs", stepStatus(berr), usage, start)
		if berr != nil {
			p.logf("memory: revise beliefs: %v", berr)
		} else {
			beliefsConsumed = true
		}
	}

	// Phase-4 chat floor: advance only after the belief pass consumed the staged
	// owner turns (mirrors the ingest-floor "advance after success" discipline).
	if p.cfg.Surfaces.Chat && beliefsConsumed && chatNewFloor > chatFloorBefore {
		if err := p.db.SetMemoryChatTurnFloor(chatNewFloor); err != nil {
			p.logf("memory: chat ingest: advance floor: %v", err)
		}
	}

	// Mechanical: age raw non-situation episodes past their prime to closed+long
	// (they are otherwise never closed) so eviction can roll them up. Runs
	// BEFORE eviction deliberately: an episode whose newest event already
	// exceeds the eviction window (e.g. first run over an old backlog) is aged
	// and then evicted in the SAME run — cold content goes straight to its
	// rollup with provenance preserved (MEM-07), no one-run grace period.
	start = time.Now()
	aged, err := AgeEpisodes(p.vault, p.db, orDefault(p.cfg.Semantic.AgeAfterDays, 14), time.Now(), p.logf)
	stats.Aged += aged
	p.recordSemanticStep(runID, &step, "age", stepStatus(err), nil, start)
	if err != nil {
		p.logf("memory: age episodes: %v", err)
	}

	// Mechanical: retention scoring + eviction into rollups.
	start = time.Now()
	evicted, err := EvictEpisodes(p.vault, p.db, orDefault(p.cfg.Semantic.EvictAfterDays, 45), semanticEvictScoreThreshold, orDefault(p.cfg.Semantic.EvictMax, 50), p.logf)
	stats.Evicted += evicted
	p.recordSemanticStep(runID, &step, "evict", stepStatus(err), nil, start)
	if err != nil {
		p.logf("memory: evict episodes: %v", err)
	}
}

// outputBudgetExceeded reports whether the run's accumulated output tokens have
// passed the semantic output budget, after which no further strong-tier AI step
// is launched this run (output tokens dominate strong-tier cost). The budget is
// floor-guarded: an explicit non-positive config value falls back to the default
// bound rather than disabling it.
func (p *Pipeline) outputBudgetExceeded(acc *usageAccumulator) bool {
	return acc.output > orDefault(p.cfg.Semantic.OutputBudget, 200000)
}

// nextSemanticStep returns the pipeline_steps step number the semantic phase
// should start at — one past the extraction batch rows already recorded — so the
// semantic rows sort after extraction under GetPipelineSteps' ORDER BY step. On
// a DB read failure it falls back to lastKnown+1 (the in-run extraction batch
// count) rather than 1, which would collide with the first extraction row.
func (p *Pipeline) nextSemanticStep(runID int64, lastKnown int) int {
	if runID == 0 {
		return 1
	}
	steps, err := p.db.GetPipelineSteps(runID)
	if err != nil {
		p.logf("memory: read pipeline steps for semantic numbering: %v", err)
		return lastKnown + 1
	}
	return len(steps) + 1
}

// stepStatus maps a step error to its pipeline_steps status column.
func stepStatus(err error) string {
	if err != nil {
		return "error"
	}
	return "done"
}

// recordSemanticStep writes one pipeline_steps row for a semantic step, labeling
// it by name in channel_name (semantic steps have no channel). *step is bumped
// so the next row sorts after this one.
func (p *Pipeline) recordSemanticStep(runID int64, step *int, name, status string, usage *digest.Usage, start time.Time) {
	if runID == 0 {
		return
	}
	var u digest.Usage
	if usage != nil {
		u = *usage
	}
	if err := p.db.InsertPipelineStep(db.PipelineStep{
		RunID: runID, Step: *step, Status: status, ChannelName: name,
		InputTokens: u.InputTokens, OutputTokens: u.OutputTokens, TotalAPITokens: u.TotalAPITokens,
		DurationSeconds: time.Since(start).Seconds(),
	}); err != nil {
		p.logf("memory: record semantic step %s: %v", name, err)
	}
	*step++
}

// fatal finalizes the pipeline_runs row for a run-stopping error and returns
// that error for Run to propagate.
func (p *Pipeline) fatal(runID int64, acc *usageAccumulator, stats *RunStats, wm float64, err error) error {
	p.completeRun(runID, acc, stats.Episodes, wm, wm, err)
	return err
}

// usageAccumulator folds per-call digest.Usage values into run totals.
type usageAccumulator struct {
	input, output, totalAPI int
	model                   string
}

func (a *usageAccumulator) add(u *digest.Usage) {
	if u == nil {
		return
	}
	a.input += u.InputTokens
	a.output += u.OutputTokens
	a.totalAPI += u.TotalAPITokens
	if u.Model != "" {
		a.model = u.Model
	}
}

// completeRun finalizes the pipeline_runs row. The runs schema records cache
// reads and cache creation separately (migration 00017), but digest.Usage
// only exposes the combined API total, so the cache-side residual (total API
// tokens minus prompt tokens) is recorded under cache_read_tokens and
// cache_creation_tokens stays 0 until Usage grows the split.
func (p *Pipeline) completeRun(runID int64, acc *usageAccumulator, items int, pFrom, pTo float64, runErr error) {
	if runID == 0 {
		return
	}
	errMsg := ""
	if runErr != nil {
		errMsg = runErr.Error()
	}
	if err := p.db.CompletePipelineRun(runID, items, acc.input, acc.output, 0, acc.totalAPI, &pFrom, &pTo, errMsg); err != nil {
		p.logf("memory: complete pipeline run: %v", err)
		return
	}
	cacheRead := acc.totalAPI - acc.input
	if cacheRead < 0 {
		cacheRead = 0
	}
	model := acc.model
	if model == "" {
		model = "auto"
	}
	if _, err := p.db.Exec(`UPDATE pipeline_runs SET model = ?, cache_read_tokens = ? WHERE id = ?`,
		model, cacheRead, runID); err != nil {
		p.logf("memory: record run model/cache tokens: %v", err)
	}
}

// runWindow is one per-channel extraction window plus the ts_unix of each of
// its messages (parallel to Messages, ascending) for watermark math.
type runWindow struct {
	channelWindow
	tsUnix []float64
}

// runExtract is consolidation step 4: load raw messages above the watermark
// (capped at MaxChunkMessages — the rest stays as debt for the next run),
// group them into per-channel windows, and extract episodes window by window.
//
// v1 simplifications (Phase 3 territory, deliberate):
//   - windows already covered by a situation episode are NOT skipped —
//     extraction dedupe against situation coverage is left to Phase 3;
//   - channelWindow.RunningSummary is left empty (the digests table stores it
//     as a JSON blob, not the one-liner the prompt wants).
//
// Only a message-load failure is returned; per-window failures freeze the
// watermark (MEM-04, see safeWatermark) and are noted in the window's
// pipeline_steps row while the run continues with the next channel. Returns the
// number of batch pipeline_steps rows recorded, so the semantic phase can number
// its own rows after them even when the DB read for numbering later fails.
func (p *Pipeline) runExtract(ctx context.Context, runID int64, acc *usageAccumulator, stats *RunStats) (int, error) {
	if p.generator == nil {
		p.logf("memory: no generator configured, skipping episode extraction")
		return 0, nil
	}
	wm, err := p.db.MemoryWatermark()
	if err != nil {
		return 0, err
	}
	msgs, err := p.db.ListMemoryExtractMessages(wm, p.cfg.MaxChunkMessages)
	if err != nil {
		return 0, err
	}
	if len(msgs) == 0 {
		return 0, nil
	}

	// Floor-guards: a non-positive config value means "unset", so the hard
	// default applies (e.g. an explicit max_window_messages: 0 must not
	// silently disable the poison-window bound).
	windows := buildWindows(msgs, orDefault(p.cfg.MaxWindowMessages, 200))
	stats.Messages = len(msgs)
	stats.Windows = len(windows)
	done := make([]bool, len(windows))
	current := wm

	batches := groupWindowsIntoBatches(windows,
		orDefault(p.cfg.BatchMaxChannels, 20), orDefault(p.cfg.BatchMaxMessages, 1500))

	recorded := 0
	for bi, idxs := range batches {
		if ctx.Err() != nil {
			p.logf("memory: extraction interrupted, %d windows left for the next run", remainingWindows(batches[bi:]))
			break
		}
		start := time.Now()
		episodes, rejected, malformed, usage, werr := p.extractBatch(ctx, runID, windows, idxs)
		acc.add(usage)
		stats.Malformed += malformed
		status := "done"
		if werr != nil {
			// Batch isolation: a failure freezes the watermark at the last
			// safe point for every channel in this batch (coarser than v1's
			// per-channel isolation — a batch groups several quiet channels
			// into one AI call, so one bad reply re-extracts all of them next
			// run, same "isolated, catch-up-style" spirit as MEM-04, at
			// batch instead of per-channel granularity).
			status = "error"
			stats.WindowsFailed += len(idxs)
			p.logf("memory: extract batch [%s]: %v", batchChannelNames(windows, idxs), werr)
		} else {
			for _, i := range idxs {
				done[i] = true
			}
			stats.Episodes += episodes
			stats.RefsRejected += rejected
			current = p.advanceWatermark(windows, done, current)
		}
		p.recordBatchStep(runID, bi+1, len(batches), status, windows, idxs, usage, start)
		recorded++
	}
	return recorded, nil
}

// orDefault floor-guards a config value: non-positive means "unset", so def
// applies.
func orDefault(v, def int) int {
	if v <= 0 {
		return def
	}
	return v
}

// remainingWindows counts the windows across the given batches, for the
// interruption log line.
func remainingWindows(batches [][]int) int {
	n := 0
	for _, b := range batches {
		n += len(b)
	}
	return n
}

// advanceWatermark moves the extraction watermark to the highest safe point
// behind the committed windows and returns the possibly-updated value.
// MEM-04: the watermark moves only after a batch's vault commit succeeded,
// and never past a message that belongs to a failed or still-pending window.
func (p *Pipeline) advanceWatermark(windows []runWindow, done []bool, current float64) float64 {
	safe, ok := safeWatermark(windows, done)
	if !ok || safe <= current {
		return current
	}
	if err := p.db.SetMemoryWatermark(safe); err != nil {
		p.logf("memory: set watermark: %v", err)
		return current
	}
	return safe
}

// recordBatchStep writes one pipeline_steps row for a batch (skipped when the
// run itself could not be recorded). Token usage is recorded once per batch —
// the API call is per-batch, not per-channel, and splitting it across
// channels would be a fabricated attribution. channel_id is only meaningful
// for a singleton batch (the common case when batching is disabled or a
// channel is too busy to share a call) and stays empty for a genuine
// multi-channel batch.
func (p *Pipeline) recordBatchStep(runID int64, step, total int, status string, windows []runWindow, idxs []int, usage *digest.Usage, start time.Time) {
	if runID == 0 {
		return
	}
	var u digest.Usage
	if usage != nil {
		u = *usage
	}
	pFrom, pTo := batchPeriod(windows, idxs)
	var channelID string
	if len(idxs) == 1 {
		channelID = windows[idxs[0]].ChannelID
	}
	if err := p.db.InsertPipelineStep(db.PipelineStep{
		RunID: runID, Step: step, Total: total, Status: status,
		ChannelID: channelID, ChannelName: batchChannelNames(windows, idxs),
		InputTokens: u.InputTokens, OutputTokens: u.OutputTokens, TotalAPITokens: u.TotalAPITokens,
		MessageCount: batchMessageCount(windows, idxs), PeriodFrom: &pFrom, PeriodTo: &pTo,
		DurationSeconds: time.Since(start).Seconds(),
	}); err != nil {
		p.logf("memory: record pipeline step: %v", err)
	}
}

// groupWindowsIntoBatches groups per-channel windows (already built by
// buildWindows) into batches of up to maxChannels windows / maxMessages total
// messages, so quiet channels/DMs share one AI call instead of each paying
// for its own round-trip (mirrors internal/digest's groupIntoBatches). A
// window whose own message count already meets or exceeds maxMessages still
// gets a batch of its own — the cap only stops MORE windows from joining it.
// Returns index slices into windows, preserving windows' existing order.
func groupWindowsIntoBatches(windows []runWindow, maxChannels, maxMessages int) [][]int {
	if len(windows) == 0 {
		return nil
	}
	if maxChannels <= 0 {
		all := make([]int, len(windows))
		for i := range windows {
			all[i] = i
		}
		return [][]int{all}
	}
	var batches [][]int
	var current []int
	currentMsgs := 0
	for i, w := range windows {
		n := len(w.Messages)
		if len(current) > 0 && (len(current) >= maxChannels || (maxMessages > 0 && currentMsgs+n > maxMessages)) {
			batches = append(batches, current)
			current = nil
			currentMsgs = 0
		}
		current = append(current, i)
		currentMsgs += n
	}
	if len(current) > 0 {
		batches = append(batches, current)
	}
	return batches
}

// batchChannelNames renders a batch's channel names for logging and the
// pipeline_steps channel_name column, capped so a large batch cannot blow up
// a log line or DB column.
func batchChannelNames(windows []runWindow, idxs []int) string {
	names := make([]string, len(idxs))
	for i, idx := range idxs {
		names[i] = windows[idx].ChannelName
	}
	joined := strings.Join(names, ", ")
	const maxLen = 200
	if r := []rune(joined); len(r) > maxLen {
		joined = string(r[:maxLen]) + "…"
	}
	return joined
}

// batchMessageCount sums the message count across a batch's windows.
func batchMessageCount(windows []runWindow, idxs []int) int {
	n := 0
	for _, idx := range idxs {
		n += len(windows[idx].Messages)
	}
	return n
}

// batchPeriod returns the min/max ts across a batch's windows for the
// pipeline_steps period_from/period_to columns.
func batchPeriod(windows []runWindow, idxs []int) (from, to float64) {
	from, to = math.Inf(1), math.Inf(-1)
	for _, idx := range idxs {
		ts := windows[idx].tsUnix
		if ts[0] < from {
			from = ts[0]
		}
		if last := ts[len(ts)-1]; last > to {
			to = last
		}
	}
	return from, to
}

// buildWindows groups the (globally ts-ordered) messages into per-channel
// windows, then orders the windows by their FIRST message ts so the watermark
// can trail completed windows (see safeWatermark): the bound that caps every
// advance is the earliest first-ts among still-pending windows, so processing
// windows in ascending first-ts order lifts that bound as early-starting
// windows complete. Ordering by last ts instead parks a long-spanning window
// (early first message, late last message) at the END of the run, and its
// early first-ts clamps the bound at the run's start — no per-batch advance
// ever fires and an interrupted run loses every committed batch's progress
// together (the 2026-07 E2E watermark-loss incident, see
// docs/specs/memory-e2e-report.md "Second issue found").
//
// maxPerWindow bounds one window's message count (memory.max_window_messages)
// so a single busy channel cannot form one giant prompt that blows the model
// context and permanently fails as a poison window: a channel with more
// messages forms multiple sequential windows in the same run. safeWatermark
// stays correct across them — a later window of the channel starts at or
// after the earlier one's last ts, so an earlier failed window's first ts
// lower-bounds the freeze and later successes can never advance past it.
// maxPerWindow <= 0 means unbounded (used by tests only; config defaults it).
func buildWindows(msgs []db.MemoryExtractMessage, maxPerWindow int) []runWindow {
	index := make(map[string]int)
	var windows []runWindow
	for _, m := range msgs {
		i, ok := index[m.ChannelID]
		if ok && maxPerWindow > 0 && len(windows[i].Messages) >= maxPerWindow {
			ok = false // window full — start the channel's next sequential window
		}
		if !ok {
			i = len(windows)
			index[m.ChannelID] = i
			windows = append(windows, runWindow{channelWindow: channelWindow{ChannelID: m.ChannelID, ChannelName: m.ChannelName}})
		}
		windows[i].Messages = append(windows[i].Messages, extractMsg{TS: m.TS, Author: m.Author, Text: m.Text})
		windows[i].tsUnix = append(windows[i].tsUnix, m.TSUnix)
	}
	// Stable: same-channel windows keep their chronological order even when
	// first-ts ties (e.g. a same-second split).
	sort.SliceStable(windows, func(a, b int) bool {
		return windows[a].tsUnix[0] < windows[b].tsUnix[0]
	})
	return windows
}

// safeWatermark returns the highest message ts the watermark may advance to:
// every loaded message at or below it belongs to a successfully committed
// window, so advancing there never skips an unprocessed message even when
// windows overlap in time (MEM-04 freeze discipline, same spirit as
// INBOX-09). ok is false when no advance is possible.
func safeWatermark(windows []runWindow, done []bool) (ts float64, ok bool) {
	// bound = the smallest ts still owned by a failed or pending window; the
	// watermark must stay strictly below it.
	bound := math.Inf(1)
	for i, w := range windows {
		if !done[i] && w.tsUnix[0] < bound {
			bound = w.tsUnix[0]
		}
	}
	best := math.Inf(-1)
	for i, w := range windows {
		if !done[i] {
			continue
		}
		for j := len(w.tsUnix) - 1; j >= 0; j-- {
			if w.tsUnix[j] < bound {
				if w.tsUnix[j] > best {
					best = w.tsUnix[j]
					ok = true
				}
				break
			}
		}
	}
	return best, ok
}

// extractBatch runs the extraction call for a batch of one or more channel
// windows and commits the resulting episode nodes (plus back-links on hinted
// entity pages) as one vault commit. A batch of exactly one window uses the
// single-channel prompt/template (memory.extract_episodes, unchanged from
// v1); a batch of several quiet channels uses the multi-channel variant
// (memory.extract_episodes_batch — digest-pipeline precedent, see
// buildBatchExtractPrompt). Both share the same JSON schema — refs already
// carry channel_id per MEM-01, so no schema change was needed for batching.
// Returns episodes written, MEM-01-rejected ref count, and shape-degenerate
// (zero-ref) episode count. Any error means NONE of the batch's windows were
// committed (batch isolation, see runExtract).
func (p *Pipeline) extractBatch(ctx context.Context, runID int64, windows []runWindow, idxs []int) (episodes, rejected, malformed int, usage *digest.Usage, err error) {
	label := batchChannelNames(windows, idxs)
	system, user, source := p.batchPrompts(windows, idxs)
	var raw string
	raw, usage, _, err = p.generator.Generate(digest.WithSource(ctx, source), system, user, "")
	if err != nil {
		return 0, 0, 0, usage, fmt.Errorf("generate: %w", err)
	}
	eps, err := parseExtract(raw)
	if err != nil {
		return 0, 0, 0, usage, err
	}
	maxTotal := p.cfg.MaxEpisodesPerWindow * len(idxs)
	if maxTotal > 0 && len(eps) > maxTotal {
		eps = eps[:maxTotal]
	}
	// Success must key off affirmative shape: ANY schema-degenerate episode
	// (zero refs, or refs spanning more than one channel — see splitMalformed)
	// fails the WHOLE batch, not just the episodes affected. A batch groups
	// several channels behind one call, so a single degenerate episode is the
	// only signal available that the reply drifted — there is no way to tell
	// "this channel's share of the reply is untrustworthy" from "the others
	// are fine" without risking a channel's degenerate output being silently
	// dropped while its neighbors' episodes commit and its watermark still
	// advances. Failing the batch trades a coarser retry (the whole batch,
	// not just the bad channel) for zero silent data loss — the same
	// preference MEM-04 already makes for a single-channel window. A
	// genuinely empty [] stays a clean no-episode batch.
	valid, malformed := splitMalformed(eps)
	if malformed > 0 {
		return 0, 0, malformed, usage, fmt.Errorf("memory: extract returned %d episode(s) with zero or cross-channel refs — schema-degenerate reply", malformed)
	}
	kept, rejected, err := validateRefs(p.checkMsg, valid)
	if err != nil {
		// Lookup failure, not an invalid ref: the check could not run, so
		// the batch fails and is re-extracted next run (MEM-01/MEM-04).
		return 0, 0, malformed, usage, err
	}
	if rejected > 0 {
		p.logf("memory: extract [%s]: refs_rejected=%d (MEM-01)", label, rejected)
	}
	if len(kept) == 0 {
		return 0, rejected, malformed, usage, nil // routine chatter — still a fully processed batch
	}

	nodes, ids := p.buildEpisodeNodes(label, kept)

	msg := CommitMsg{
		Op:      "extract",
		Summary: fmt.Sprintf("%d episodes from [%s]", len(kept), label),
		Cause:   fmt.Sprintf("run:%d", runID),
		NodeIDs: ids,
	}
	if _, err := p.vault.WriteNodes(nodes, msg); err != nil {
		return 0, rejected, malformed, usage, err
	}
	now := time.Now().UTC().Format(time.RFC3339)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, n, now); err != nil {
			// The vault commit stands; the index is derived and the next
			// Reconcile repairs it, so this does not fail the batch.
			p.logf("memory: index %s after extract: %v", n.ID, err)
		}
	}
	return len(kept), rejected, malformed, usage, nil
}

// batchPrompts renders the extraction prompt for a batch: a single window
// uses the single-channel prompt/template (memory.extract_episodes, unchanged
// from v1); several quiet channels share the multi-channel variant
// (memory.extract_episodes_batch). Returns the WithSource routing tag
// alongside the rendered prompt pair.
func (p *Pipeline) batchPrompts(windows []runWindow, idxs []int) (system, user, source string) {
	if len(idxs) == 1 {
		system, user = buildExtractPrompt(p.getPrompt(prompts.MemoryExtractEpisodes), p.Language, windows[idxs[0]].channelWindow, p.cfg.MaxEpisodesPerWindow)
		return system, user, extractSource
	}
	cws := make([]channelWindow, len(idxs))
	for i, idx := range idxs {
		cws[i] = windows[idx].channelWindow
	}
	system, user = buildBatchExtractPrompt(p.getPrompt(prompts.MemoryExtractEpisodesBatch), p.Language, cws, p.cfg.MaxEpisodesPerWindow*len(idxs))
	return system, user, extractBatchSource
}

// buildEpisodeNodes turns kept episodes into new episode nodes plus updated
// entity pages carrying back-links for resolved entity hints (aliases resolved
// via the index; unresolvable hints are dropped, never invented). label is
// the batch's channel name(s), used only for the unresolved-hint log line.
func (p *Pipeline) buildEpisodeNodes(label string, kept []extractedEpisode) (nodes []Node, ids []string) {
	entityIdx := make(map[string]int) // entity node ID → index in nodes
	var unresolved []db.EntityHint    // hints with no matching entity, for promotion tracking
	for _, ep := range kept {
		title := strings.Join(strings.Fields(ep.Title), " ")
		if title == "" {
			title = "Untitled episode"
		}
		n := Node{
			ID:     NewID("episode"),
			Type:   "episode",
			Tier:   "short",
			Status: "active",
			Title:  title,
			Body:   episodeBody(title, ep),
		}
		nodes = append(nodes, n)
		ids = append(ids, n.ID)

		link := "- [[" + n.ID + "|" + linkLabel(title) + "]]\n"
		for _, hint := range ep.EntityHints {
			en, rerr := Resolve(p.vault, p.db, hint)
			if rerr != nil {
				// Unresolved hint: no entity page matches it yet. Log as before
				// and persist it for concept-entity promotion once it recurs
				// across enough distinct episodes (spec goal 6). Keyed on the
				// episode id, so re-extracting the same episode never
				// double-counts. Normalized the same way conceptAlias expects.
				p.logf("memory: extract [%s]: entity hint %q unresolved", label, hint)
				if norm := strings.ToLower(strings.TrimSpace(hint)); norm != "" {
					unresolved = append(unresolved, db.EntityHint{Hint: norm, EpisodeID: n.ID})
				}
				continue
			}
			if en.Type != "entity" || en.Status != "active" {
				continue
			}
			idx, seen := entityIdx[en.ID]
			if !seen {
				idx = len(nodes)
				entityIdx[en.ID] = idx
				nodes = append(nodes, en)
				ids = append(ids, en.ID)
			}
			nodes[idx].Body = appendToLinks(nodes[idx].Body, link)
		}
	}
	// Accumulation runs whenever memory is enabled (harmless when the semantic
	// tier is off): promotion reads it later, gated separately. A record
	// failure must not fail the batch — the hints are best-effort telemetry.
	if err := p.db.RecordEntityHints(unresolved); err != nil {
		p.logf("memory: record entity hints [%s]: %v", label, err)
	}
	return nodes, ids
}

// episodeBody renders the v1 episode template for an extracted episode:
// H1 title, participants line, Story, Outcome, Provenance. (The template's
// time-range line is omitted in v1 — provenance ts values carry the range.)
func episodeBody(title string, ep extractedEpisode) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n", title)
	if len(ep.Participants) > 0 {
		fmt.Fprintf(&b, "Participants: %s\n\n", strings.Join(ep.Participants, ", "))
	}
	b.WriteString("## Story\n")
	if ep.Story != "" {
		b.WriteString(ep.Story + "\n")
	}
	b.WriteString("\n## Outcome\n")
	if ep.Outcome != nil && *ep.Outcome != "" {
		b.WriteString(*ep.Outcome + "\n")
	}
	b.WriteString("\n## Provenance\n")
	for _, r := range ep.Refs {
		fmt.Fprintf(&b, "- %s %s\n", r.ChannelID, r.TS)
	}
	return b.String()
}

// linkLabelReplacer strips characters that would break a [[id|label]]
// wiki-link out of AI-authored titles.
var linkLabelReplacer = strings.NewReplacer("[[", "", "]]", "", "|", "/", "\n", " ")

func linkLabel(title string) string {
	return linkLabelReplacer.Replace(title)
}
