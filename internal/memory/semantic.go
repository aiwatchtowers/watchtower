package memory

import (
	"context"
	"time"
)

// semanticEvictScoreThreshold is the retention-score cutoff below which a cold
// closed long episode is evicted into a rollup. Like the retention constants
// (evict.go) it lives in code, not config — one auditable place for the math.
const semanticEvictScoreThreshold = 0.5

// semanticRun carries one runSemantic invocation's state between its steps.
type semanticRun struct {
	ctx   context.Context
	runID int64
	step  int // next pipeline_steps number
	acc   *usageAccumulator
	stats *RunStats
	now   time.Time

	// Phase-4 chat surface: the owner turns staged before the belief pass and
	// the floor bounds the pass may advance once it consumed them.
	staged                        *stagedChat
	chatFloorBefore, chatNewFloor int64

	rewritten []string // subjects the rewrite step produced; scope of the belief pass
}

// semanticStep is one named step of the semantic tier after the chat ingest.
type semanticStep struct {
	name string
	run  func(*semanticRun)
}

// runSemantic executes the Phase-3 semantic tier in the spec order:
// dedupe → concept promotion → page rewrite → belief pass → aging → eviction
// (→ reflection when its surface is on). The mechanical steps (dedupe/promote/
// age/evict) always run; the two strong-tier AI steps (rewrite/beliefs) are
// skipped once the run's output-token budget is spent — a budget-skipped step
// still records a pipeline_steps row with status 'skipped' (the status column is
// free text; 'skipped' is the cheapest honest representation of "would have
// run, budget denied it"). Every step records its own row and is failure-
// isolated: a step error is logged and the next step still runs. No step
// advances a watermark. Config bounds are floor-guarded (an explicit 0 falls
// back to the default rather than disabling the bound). batchSteps is the count
// of extraction batch rows already recorded — the fallback base for step
// numbering when the DB read fails.
//
// Cancellation: ctx is checked before every step. Once the run is cancelled
// (daemon shutdown) no further step starts — each remaining one records a
// 'skipped' row, the same representation a budget skip uses — so nothing is
// written after the stop by a step that had not begun. A step already running
// honours ctx itself between candidates and writes nothing partial.
func (p *Pipeline) runSemantic(ctx context.Context, runID int64, batchSteps int, acc *usageAccumulator, stats *RunStats) {
	r := &semanticRun{ctx: ctx, runID: runID, step: p.nextSemanticStep(runID, batchSteps), acc: acc, stats: stats, now: time.Now()}

	// Phase-4 chat surface (dark unless memory.surfaces.chat): stage owner Discuss
	// turns as owner-rank belief evidence BEFORE the belief pass. No AI call and no
	// vault write of its own, so it runs regardless of ctx; the floor it read only
	// advances after a clean belief pass (semanticBeliefs).
	if p.cfg.Surfaces.Chat {
		p.semanticChatIngest(r)
	}

	steps := p.semanticSteps()
	for i, s := range steps {
		if ctx.Err() != nil {
			p.skipSemanticSteps(r, steps[i:])
			return
		}
		s.run(r)
	}
}

// semanticSteps lists the semantic tier's steps in run order; reflection is
// listed only when its surface is on, so a cancelled run records exactly the
// rows an uncancelled one would have.
func (p *Pipeline) semanticSteps() []semanticStep {
	steps := []semanticStep{
		{"dedupe", p.semanticDedupe},
		{"promote", p.semanticPromote},
		{"rewrite", p.semanticRewrite},
		{"beliefs", p.semanticBeliefs},
		{"age", p.semanticAge},
		{"evict", p.semanticEvict},
	}
	if p.cfg.Surfaces.Reflection {
		steps = append(steps, semanticStep{"reflect", p.semanticReflect})
	}
	return steps
}

// skipSemanticSteps records every step in rest as 'skipped' — the steps a
// cancelled run never started.
func (p *Pipeline) skipSemanticSteps(r *semanticRun, rest []semanticStep) {
	p.logf("memory: semantic tier interrupted before %s: %v", rest[0].name, r.ctx.Err())
	for _, s := range rest {
		p.recordSemanticStep(r.runID, &r.step, s.name, "skipped", nil, time.Now())
	}
}

// semanticChatIngest stages owner Discuss turns for the belief pass. The floor
// advances only after the belief pass consumed the staged turns without a
// cap-break (semanticBeliefs), so a failed, budget-skipped, cap-truncated or
// cancelled pass re-scans the same turns next run.
func (p *Pipeline) semanticChatIngest(r *semanticRun) {
	start := time.Now()
	floor, ferr := p.db.MemoryChatTurnFloor()
	if ferr != nil {
		p.logf("memory: chat ingest: read floor: %v", ferr)
		p.recordSemanticStep(r.runID, &r.step, "chat-ingest", "error", nil, start)
		return
	}
	s, nf, ierr := p.ingestChatStatements(floor, chatContextTypes(p.cfg.Sources.Chats))
	r.chatFloorBefore, r.chatNewFloor = floor, nf
	if ierr != nil {
		p.logf("memory: chat ingest: %v", ierr)
		r.chatNewFloor = floor // do not advance on error
	} else {
		r.staged = s
	}
	p.recordSemanticStep(r.runID, &r.step, "chat-ingest", stepStatus(ierr), nil, start)
}

// semanticDedupe is the mechanical episode dedupe.
func (p *Pipeline) semanticDedupe(r *semanticRun) {
	start := time.Now()
	deduped, err := DedupeEpisodes(r.ctx, p.vault, p.db, orDefault(p.cfg.Semantic.DedupeMaxMerges, 20), p.logf)
	r.stats.Deduped += deduped
	p.recordSemanticStep(r.runID, &r.step, "dedupe", stepStatus(err), nil, start)
	if err != nil {
		p.logf("memory: dedupe: %v", err)
	}
}

// semanticPromote is the mechanical concept-entity promotion from recurring hints.
func (p *Pipeline) semanticPromote(r *semanticRun) {
	start := time.Now()
	promoted, err := PromoteConcepts(p.vault, p.db, orDefault(p.cfg.Semantic.ConceptMinEpisodes, 5), orDefault(p.cfg.Semantic.ConceptMaxCreate, 10))
	r.stats.Promoted += promoted
	p.recordSemanticStep(r.runID, &r.step, "promote", stepStatus(err), nil, start)
	if err != nil {
		p.logf("memory: promote concepts: %v", err)
	}
}

// semanticRewrite is the strong-tier entity page rewrite (budget-gated). The
// rewritten subjects scope the belief pass.
func (p *Pipeline) semanticRewrite(r *semanticRun) {
	if p.outputBudgetExceeded(r.acc) {
		p.logf("memory: rewrite skipped: output budget exceeded")
		p.recordSemanticStep(r.runID, &r.step, "rewrite", "skipped", nil, r.now)
		return
	}
	start := time.Now()
	rewritten, failed, usage, err := p.RewriteEntityPages(r.ctx, orDefault(p.cfg.Semantic.RewriteMaxEntities, 10), r.now)
	r.acc.add(usage)
	r.rewritten = rewritten
	r.stats.Rewritten += len(rewritten)
	r.stats.RewriteFailed += failed
	p.recordSemanticStep(r.runID, &r.step, "rewrite", stepStatus(err), usage, start)
	if err != nil {
		p.logf("memory: rewrite entity pages: %v", err)
	}
}

// semanticBeliefs is the strong-tier belief revision over the rewritten subjects
// + shaken beliefs (budget-gated). Only a pass that ran to a clean commit
// without the beliefs_max cap truncating its op loop advances the chat-turn
// floor — a budget-skip, a belief-pass error, or a cap-break re-stages the same
// owner turns next run.
func (p *Pipeline) semanticBeliefs(r *semanticRun) {
	if p.outputBudgetExceeded(r.acc) {
		p.logf("memory: belief pass skipped: output budget exceeded")
		p.recordSemanticStep(r.runID, &r.step, "beliefs", "skipped", nil, time.Now())
		return
	}
	start := time.Now()
	touched, rejected, capHit, usage, err := p.ReviseBeliefs(r.ctx, r.rewritten, r.staged, orDefault(p.cfg.Semantic.BeliefsMax, 20), r.now)
	r.acc.add(usage)
	r.stats.BeliefOps += touched
	r.stats.BeliefOpsRejected += rejected
	p.recordSemanticStep(r.runID, &r.step, "beliefs", stepStatus(err), usage, start)
	if err != nil {
		p.logf("memory: revise beliefs: %v", err)
		return
	}
	if !capHit {
		p.advanceChatFloor(r)
	}
}

// advanceChatFloor moves the Phase-4 chat floor past the turns a clean,
// uncapped belief pass consumed (mirrors the ingest-floor "advance after
// success" discipline). Only then are the staged turns counted as ingested — a
// held floor means they re-scan next run, so counting them now would
// double-count (n8). A pass that completed without a cap-break advances even if
// the model declined to cite any staged ref (by-design: the turns had their
// chance — see spec §2 / MEM known-limitations).
func (p *Pipeline) advanceChatFloor(r *semanticRun) {
	if !p.cfg.Surfaces.Chat || r.chatNewFloor <= r.chatFloorBefore {
		return
	}
	if err := p.db.SetMemoryChatTurnFloor(r.chatNewFloor); err != nil {
		p.logf("memory: chat ingest: advance floor: %v", err)
	} else if r.staged != nil {
		r.stats.ChatTurnsIngested += len(r.staged.statements)
	}
}

// semanticAge ages raw non-situation episodes past their prime to closed+long
// (they are otherwise never closed) so eviction can roll them up. Runs BEFORE
// eviction deliberately: an episode whose newest event already exceeds the
// eviction window (e.g. first run over an old backlog) is aged and then evicted
// in the SAME run — cold content goes straight to its rollup with provenance
// preserved (MEM-07), no one-run grace period.
func (p *Pipeline) semanticAge(r *semanticRun) {
	start := time.Now()
	aged, err := AgeEpisodes(r.ctx, p.vault, p.db, orDefault(p.cfg.Semantic.AgeAfterDays, 14), time.Now(), p.logf)
	r.stats.Aged += aged
	p.recordSemanticStep(r.runID, &r.step, "age", stepStatus(err), nil, start)
	if err != nil {
		p.logf("memory: age episodes: %v", err)
	}
}

// semanticEvict is the mechanical retention scoring + eviction into rollups.
func (p *Pipeline) semanticEvict(r *semanticRun) {
	start := time.Now()
	evicted, err := EvictEpisodes(r.ctx, p.vault, p.db, orDefault(p.cfg.Semantic.EvictAfterDays, 45), semanticEvictScoreThreshold, orDefault(p.cfg.Semantic.EvictMax, 50), p.logf)
	r.stats.Evicted += evicted
	p.recordSemanticStep(r.runID, &r.step, "evict", stepStatus(err), nil, start)
	if err != nil {
		p.logf("memory: evict episodes: %v", err)
	}
}

// semanticReflect is the Phase-4 reflection surface (listed only when
// memory.surfaces.reflection is on): a weekly strong-tier meta-pass over the
// vault's own git history. It fires at most once per week (deterministic
// workspace stagger inside Reflect) and applies observations ONLY as
// dispute_pending flags + entity ## Current notes (MEM-11) — never a direct
// belief mutation. Budget-gated like the other strong-tier steps; a per-run
// failure is logged and never fails the run (isolation), leaving beliefs and
// entities untouched.
func (p *Pipeline) semanticReflect(r *semanticRun) {
	if p.outputBudgetExceeded(r.acc) {
		p.logf("memory: reflection skipped: output budget exceeded")
		p.recordSemanticStep(r.runID, &r.step, "reflect", "skipped", nil, time.Now())
		return
	}
	start := time.Now()
	reflections, flagged, dropped, usage, err := p.Reflect(r.ctx, r.now)
	r.acc.add(usage)
	r.stats.Reflections += reflections
	r.stats.DisputesFlagged += flagged
	r.stats.ReflectionsDropped += dropped
	p.recordSemanticStep(r.runID, &r.step, "reflect", stepStatus(err), usage, start)
	if err != nil {
		p.logf("memory: reflect: %v", err)
	}
}
