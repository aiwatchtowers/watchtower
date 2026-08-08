package ideas

import (
	"context"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// BackfillResult totals one Backfill run's yield across every drain cycle.
type BackfillResult struct {
	Proposed        int
	Cycles          int
	MentionsDeduped int
	// Capped reports whether either drain phase hit its own per-phase
	// cycle budget (backfillMaxCycles) without converging — a pathological
	// window still terminates, but the caller (the CLI envelope) needs to
	// know the window was NOT fully drained, so a re-run may still find
	// material.
	Capped bool
}

// backfillMaxCycles bounds each drain phase as a runaway guard (spec §3): a
// pathological window (or a bug that never converges) still terminates. It
// is a per-PHASE budget, not shared: drainStage1 and drainConsolidate each
// get their own full backfillMaxCycles allowance (GB2) — a shared counter
// would let a slow-converging stage-1 pass exhaust the whole budget and
// starve the consolidator of its turn entirely, even though stage-1 capping
// out says nothing about whether stage-2 has material worth consolidating.
// A package-level var, not a const, so tests can shrink it to force capping
// deterministically without seeding thousands of rows.
var backfillMaxCycles = 50

// Backfill mines ideas/decisions over an arbitrary historical window
// [from, to] (spec §3): it lowers the registry's floors to the window start,
// drains stage-1 (Gmail/Jira pre-digests) and then the stage-2 consolidator
// — both bounded by `to` — until nothing more is consumed, then restores
// every floor it touched to max(saved, reached). Re-mining any
// already-mined material is safe and idempotent (IDEA-05): the ref-level
// dedup in applyConsolidateOps means running Backfill twice over the same
// window yields Proposed==0 the second time. progress, if non-nil, is
// called once per drain cycle with the 1-based cycle number (the CLI's
// per-cycle log line).
//
// The restore is deferred, not a final step, so a mid-loop error (a DB
// hiccup, an AI call failing) still leaves every floor honest — restored to
// wherever it actually got, never stuck at the lowered "from" value. Only a
// killed process (not an ordinary Go error return) can skip it; that is
// bounded to the daemon re-mining [reached, now] once, which IDEA-05 makes
// harmless (spec §3).
func (p *Pipeline) Backfill(ctx context.Context, from, to time.Time, progress func(cycle int)) (result BackfillResult, err error) {
	if to.IsZero() {
		to = time.Now()
	}

	savedDigest, savedStream, savedTranscript, err := p.db.GetIdeasFloors()
	if err != nil {
		return BackfillResult{}, fmt.Errorf("backfill: reading ideas floors: %w", err)
	}
	googleAccounts, err := p.db.ListGoogleAccounts()
	if err != nil {
		return BackfillResult{}, fmt.Errorf("backfill: listing google accounts: %w", err)
	}
	jiraAccounts, err := p.db.ListEnabledJiraAccounts()
	if err != nil {
		return BackfillResult{}, fmt.Errorf("backfill: listing jira accounts: %w", err)
	}

	savedEmailFloor := map[int64]float64{}
	savedJiraFloor := map[int64]string{}
	defer func() {
		p.restoreBackfillFloors(savedDigest, savedStream, savedTranscript, savedEmailFloor, savedJiraFloor)
	}()

	if err := p.lowerBackfillFloors(from, to, savedStream, googleAccounts, jiraAccounts, savedEmailFloor, savedJiraFloor); err != nil {
		return result, err
	}

	// Phase 1: drain the Gmail/Jira stage-1 pre-digests until a full cycle
	// moves no account's floor at all, or its own per-phase cycle budget
	// (GB2) runs out. A floor-read failure is fatal — no point attempting
	// phase 2 once the drain loop can no longer even tell whether it
	// converged — so it aborts here, before phase 2 ever runs.
	cycles, capped1, softErr, fatalErr := p.drainStage1(ctx, to, googleAccounts, jiraAccounts, progress)
	if fatalErr != nil {
		result.Cycles = cycles
		result.Capped = capped1
		return result, fatalErr
	}

	// Phase 2: drain the consolidator until a cycle proposes nothing, dedupes
	// nothing, and moves no floor, or its own per-phase cycle budget runs
	// out — independent of phase 1's budget (GB2), so a stage-1 pass that
	// capped out never starves the consolidator of its turn. softErr threads
	// phase 1's error through so the "first error across BOTH phases wins"
	// rule holds even though the two phases are now two functions.
	cycles, proposed, mentionsDeduped, capped2, err := p.drainConsolidate(ctx, from, to, cycles, progress, softErr)
	result.Cycles = cycles
	result.Proposed = proposed
	result.MentionsDeduped = mentionsDeduped
	result.Capped = capped1 || capped2
	return result, err
}

// drainStage1 is Backfill phase 1: repeats the Gmail/Jira stage-1
// pre-digest passes, bounded by `to`, until a full cycle moves no account's
// per-source floor at all, or this phase's OWN per-phase cycle budget
// (backfillMaxCycles) is hit (GB2) — capped reports the latter, distinct
// from the ordinary converged-with-nothing-left-to-do exit. A per-account
// digest failure is logged and does not stop the loop (matches
// runEmailDigests/runJiraDigests' own log-and-continue contract) — softErr
// carries the first one, for the caller to surface only if phase 2 doesn't
// also fail. fatalErr is reserved for a floor-read failure, which the
// caller must treat as an immediate abort of the whole Backfill call.
func (p *Pipeline) drainStage1(ctx context.Context, to time.Time, googleAccounts []db.GoogleAccount, jiraAccounts []db.JiraAccount, progress func(cycle int)) (cycles int, capped bool, softErr, fatalErr error) {
	converged := false
	for cycles < backfillMaxCycles {
		beforeEmail, beforeJira, sferr := p.currentStage1Floors(googleAccounts, jiraAccounts)
		if sferr != nil {
			return cycles, false, softErr, fmt.Errorf("backfill: reading stage-1 floors: %w", sferr)
		}

		cycles++
		if progress != nil {
			progress(cycles)
		}

		if perr := p.runStage1Passes(ctx, to); perr != nil && softErr == nil {
			softErr = perr
		}

		afterEmail, afterJira, aferr := p.currentStage1Floors(googleAccounts, jiraAccounts)
		if aferr != nil {
			return cycles, false, softErr, fmt.Errorf("backfill: reading stage-1 floors: %w", aferr)
		}
		if stage1FloorsEqual(beforeEmail, beforeJira, afterEmail, afterJira) {
			converged = true
			break
		}
	}
	if !converged {
		capped = true
		p.logf("ideas: backfill stage-1 hit the %d-cycle cap without converging — the window is not fully drained yet", backfillMaxCycles)
	}
	return cycles, capped, softErr, nil
}

// runStage1Passes runs one email pass then one jira pass for the current
// drainStage1 cycle, logging either failure distinctly (the two sources fail
// independently and an operator needs to know which), and returning the
// first of the two (nil if both succeeded) for the caller's own "first
// error wins" accumulator.
func (p *Pipeline) runStage1Passes(ctx context.Context, to time.Time) error {
	var firstErr error
	if perr := p.runEmailDigests(ctx, to); perr != nil {
		p.logf("ideas: backfill email digest pass: %v", perr)
		firstErr = perr
	}
	if perr := p.runJiraDigests(ctx, to); perr != nil {
		p.logf("ideas: backfill jira digest pass: %v", perr)
		if firstErr == nil {
			firstErr = perr
		}
	}
	return firstErr
}

// drainConsolidate is Backfill phase 2: repeats consolidateCycle, bounded by
// THIS phase's own per-phase cycle budget (GB2 — independent of phase 1's,
// so a stage-1 pass that capped out never starves phase 2 of its turn),
// continuing the GLOBAL cycle/progress numbering from startCycles wherever
// phase 1 left off, until a cycle proposes nothing, dedupes nothing, and
// moves no workspace floor. capped reports whether this phase's own budget
// ran out before convergence — never set on the error-break path, since an
// erroring pass says nothing about whether the phase would have converged
// given more cycles. priorErr is phase 1's already-accumulated error, if
// any — see consolidateCycle for the fatal-vs-soft error split this loop
// respects. The before-floors read happens here, ahead of the cycle
// counter, so a cycle that fails before ever attempting any work is never
// counted or reported to progress.
func (p *Pipeline) drainConsolidate(ctx context.Context, from, to time.Time, startCycles int, progress func(cycle int), priorErr error) (cycles, proposed, mentionsDeduped int, capped bool, err error) {
	cycles = startCycles
	firstErr := priorErr
	converged := false
	erroredOut := false
	for phaseCycles := 0; phaseCycles < backfillMaxCycles; phaseCycles++ {
		beforeDigest, beforeStream, beforeTranscript, gferr := p.db.GetIdeasFloors()
		if gferr != nil {
			return cycles, proposed, mentionsDeduped, false, fmt.Errorf("backfill: reading consolidate floors: %w", gferr)
		}

		cycles++
		if progress != nil {
			progress(cycles)
		}

		cProposed, cDeduped, floorsMoved, fatalErr, softErr := p.consolidateCycle(ctx, from, to, beforeDigest, beforeStream, beforeTranscript)
		if fatalErr != nil {
			return cycles, proposed, mentionsDeduped, false, fatalErr
		}
		if softErr != nil {
			p.logf("ideas: backfill consolidate pass: %v", softErr)
			if firstErr == nil {
				firstErr = softErr
			}
			erroredOut = true
			break // an erroring pass says nothing about convergence — stop draining
		}
		proposed += cProposed
		mentionsDeduped += cDeduped
		if consolidateConverged(cProposed, cDeduped, floorsMoved) {
			converged = true
			break
		}
	}
	if !converged && !erroredOut {
		capped = true
		p.logf("ideas: backfill consolidate hit the %d-cycle cap without converging — the window is not fully drained yet", backfillMaxCycles)
	}
	return cycles, proposed, mentionsDeduped, capped, firstErr
}

// consolidateConverged reports whether a drainConsolidate cycle found
// nothing left to do: no idea/decision proposed, no mention deduped, and no
// workspace floor moved.
func consolidateConverged(proposed, mentionsDeduped int, floorsMoved bool) bool {
	return proposed == 0 && mentionsDeduped == 0 && !floorsMoved
}

// consolidateCycle runs one runConsolidate call against the floors read at
// the top of this drainConsolidate cycle (before{Digest,Stream,Transcript})
// and reports whether they moved by the time it finished — drainConsolidate's
// single-cycle unit, split out to keep the loop itself and this one cycle's
// bookkeeping each separately readable. fatalErr is a floor-read failure:
// the caller must abort immediately, discarding any earlier error, since
// there is nothing left to preserve once convergence itself can no longer be
// determined. softErr is an ordinary runConsolidate failure, which the
// caller folds into its own "first error wins" accumulator instead.
func (p *Pipeline) consolidateCycle(ctx context.Context, from, to time.Time, beforeDigest, beforeStream, beforeTranscript int64) (proposed, mentionsDeduped int, floorsMoved bool, fatalErr, softErr error) {
	proposed, mentionsDeduped, cerr := p.runConsolidate(ctx, from, to)
	if cerr != nil {
		return 0, 0, false, nil, cerr
	}

	afterDigest, afterStream, afterTranscript, gferr := p.db.GetIdeasFloors()
	if gferr != nil {
		return proposed, mentionsDeduped, false, fmt.Errorf("backfill: reading consolidate floors: %w", gferr), nil
	}
	floorsMoved = afterDigest != beforeDigest || afterStream != beforeStream || afterTranscript != beforeTranscript
	return proposed, mentionsDeduped, floorsMoved, nil, nil
}

// SetBackfillMaxCyclesForTest overrides the Backfill per-phase cycle budget
// (backfillMaxCycles, GB2) for the life of a test and returns a restore func
// — the SetGoogleRevokeEndpointForTest precedent
// (internal/calendar/auth.go). backfillMaxCycles is package-private and
// swapped directly by this package's own tests; this exported seam exists
// for callers OUTSIDE this package (e.g. cmd's `ideas mine --from` CLI
// tests) that need to force a drain phase to cap out deterministically
// without seeding an unrealistically large backlog.
func SetBackfillMaxCyclesForTest(n int) (restore func()) {
	prev := backfillMaxCycles
	backfillMaxCycles = n
	return func() { backfillMaxCycles = prev }
}

// lowerBackfillFloors is Backfill's step 2 (spec §3): it lowers the three
// workspace floors to the window start, then delegates the per-source
// account floor lowering to lowerEmailFloors/lowerJiraFloors — each skips
// (spec §4 layer 2, cost not correctness) any account HasStreamDigestCovering
// already reports fully covered, and leaves the workspace stream floor
// untouched, since stream_digests rows are only ever created going forward.
// savedEmailFloor/savedJiraFloor are filled in as a side effect with every
// touched account's PRE-lower value, for the deferred restore.
func (p *Pipeline) lowerBackfillFloors(from, to time.Time, savedStream int64, googleAccounts []db.GoogleAccount, jiraAccounts []db.JiraAccount, savedEmailFloor map[int64]float64, savedJiraFloor map[int64]string) error {
	fromUnix := from.Unix()
	fromISO := from.UTC().Format(time.RFC3339)
	toISO := to.UTC().Format(time.RFC3339)

	newDigestFloor, err := p.db.DigestTopicFloorForTime(fromUnix)
	if err != nil {
		return fmt.Errorf("backfill: computing digest floor: %w", err)
	}
	newTranscriptFloor, err := p.db.TranscriptFloorForTime(fromISO)
	if err != nil {
		return fmt.Errorf("backfill: computing transcript floor: %w", err)
	}
	if err := p.db.SetIdeasFloors(newDigestFloor, savedStream, newTranscriptFloor); err != nil {
		return fmt.Errorf("backfill: lowering ideas floors: %w", err)
	}

	if err := p.lowerEmailFloors(fromUnix, fromISO, toISO, googleAccounts, savedEmailFloor); err != nil {
		return err
	}
	return p.lowerJiraFloors(from, fromISO, toISO, jiraAccounts, savedJiraFloor)
}

// lowerEmailFloors lowers each Gmail-enabled account's ideas_email_floor to
// fromUnix, skipping (and logging) any account already fully covered for
// [fromISO, toISO] (spec §4 layer 2). savedEmailFloor is filled in with
// every touched account's PRE-lower value, for the deferred restore.
func (p *Pipeline) lowerEmailFloors(fromUnix int64, fromISO, toISO string, googleAccounts []db.GoogleAccount, savedEmailFloor map[int64]float64) error {
	for _, acct := range googleAccounts {
		if !acct.GmailEnabled {
			continue
		}
		floor, err := p.db.IdeasEmailFloor(acct.ID)
		if err != nil {
			return fmt.Errorf("backfill: reading email floor for account %d: %w", acct.ID, err)
		}
		savedEmailFloor[acct.ID] = floor
		covered, err := p.db.HasStreamDigestCovering("gmail", acct.ID, fromISO, toISO)
		if err != nil {
			return fmt.Errorf("backfill: checking gmail coverage for account %d: %w", acct.ID, err)
		}
		if covered {
			p.logf("ideas: backfill account %d already covered for gmail %s..%s, skipping re-digest", acct.ID, fromISO, toISO)
			continue
		}
		if err := p.db.SetIdeasEmailFloor(acct.ID, float64(fromUnix)); err != nil {
			return fmt.Errorf("backfill: lowering email floor for account %d: %w", acct.ID, err)
		}
	}
	return nil
}

// lowerJiraFloors is lowerEmailFloors' Jira sibling: lowers each enabled
// Jira account's ideas_jira_floor to from (Jira's own dotted-ms format),
// same coverage-skip and savedJiraFloor-recording shape.
func (p *Pipeline) lowerJiraFloors(from time.Time, fromISO, toISO string, jiraAccounts []db.JiraAccount, savedJiraFloor map[int64]string) error {
	for _, acct := range jiraAccounts {
		floor, err := p.db.IdeasJiraFloor(acct.ID)
		if err != nil {
			return fmt.Errorf("backfill: reading jira floor for account %d: %w", acct.ID, err)
		}
		savedJiraFloor[acct.ID] = floor
		covered, err := p.db.HasStreamDigestCovering("jira", acct.ID, fromISO, toISO)
		if err != nil {
			return fmt.Errorf("backfill: checking jira coverage for account %d: %w", acct.ID, err)
		}
		if covered {
			p.logf("ideas: backfill account %d already covered for jira %s..%s, skipping re-digest", acct.ID, fromISO, toISO)
			continue
		}
		if err := p.db.SetIdeasJiraFloor(acct.ID, db.FormatJiraTime(from)); err != nil {
			return fmt.Errorf("backfill: lowering jira floor for account %d: %w", acct.ID, err)
		}
	}
	return nil
}

// restoreBackfillFloors restores every floor Backfill touched to
// max(saved, reached) (spec §3 step 4), delegating each of the three
// independent restore targets (workspace, per-account email, per-account
// jira) to its own helper. Errors are logged, not returned — this runs from
// a defer, after Backfill has already decided its own return value, and a
// restore failure must not mask whatever real error (or success) the run
// produced; it is surfaced instead as a log line an operator can act on.
func (p *Pipeline) restoreBackfillFloors(savedDigest, savedStream, savedTranscript int64, savedEmailFloor map[int64]float64, savedJiraFloor map[int64]string) {
	p.restoreWorkspaceFloors(savedDigest, savedStream, savedTranscript)
	p.restoreEmailFloors(savedEmailFloor)
	p.restoreJiraFloors(savedJiraFloor)
}

// restoreWorkspaceFloors is restoreBackfillFloors' workspace-floor step.
func (p *Pipeline) restoreWorkspaceFloors(savedDigest, savedStream, savedTranscript int64) {
	reachedDigest, reachedStream, reachedTranscript, err := p.db.GetIdeasFloors()
	if err != nil {
		p.logf("ideas: backfill: reading ideas floors for restore: %v", err)
		return
	}
	if err := p.db.SetIdeasFloors(
		maxInt64(savedDigest, reachedDigest),
		maxInt64(savedStream, reachedStream),
		maxInt64(savedTranscript, reachedTranscript),
	); err != nil {
		p.logf("ideas: backfill: restoring ideas floors: %v", err)
	}
}

// restoreEmailFloors is restoreBackfillFloors' per-account Gmail step.
func (p *Pipeline) restoreEmailFloors(savedEmailFloor map[int64]float64) {
	for acctID, saved := range savedEmailFloor {
		reached, err := p.db.IdeasEmailFloor(acctID)
		if err != nil {
			p.logf("ideas: backfill: reading email floor for account %d for restore: %v", acctID, err)
			continue
		}
		if err := p.db.SetIdeasEmailFloor(acctID, maxFloat64(saved, reached)); err != nil {
			p.logf("ideas: backfill: restoring email floor for account %d: %v", acctID, err)
		}
	}
}

// restoreJiraFloors is restoreEmailFloors' Jira sibling.
func (p *Pipeline) restoreJiraFloors(savedJiraFloor map[int64]string) {
	for acctID, saved := range savedJiraFloor {
		reached, err := p.db.IdeasJiraFloor(acctID)
		if err != nil {
			p.logf("ideas: backfill: reading jira floor for account %d for restore: %v", acctID, err)
			continue
		}
		if err := p.db.SetIdeasJiraFloor(acctID, maxJiraFloor(saved, reached)); err != nil {
			p.logf("ideas: backfill: restoring jira floor for account %d: %v", acctID, err)
		}
	}
}

// currentStage1Floors reads the current per-account Gmail/Jira pre-digest
// floors for every Gmail-enabled google account and every (already-enabled)
// jira account — the drain loop's before/after snapshot for detecting "this
// cycle consumed nothing."
func (p *Pipeline) currentStage1Floors(googleAccounts []db.GoogleAccount, jiraAccounts []db.JiraAccount) (map[int64]float64, map[int64]string, error) {
	email := make(map[int64]float64, len(googleAccounts))
	for _, acct := range googleAccounts {
		if !acct.GmailEnabled {
			continue
		}
		v, err := p.db.IdeasEmailFloor(acct.ID)
		if err != nil {
			return nil, nil, fmt.Errorf("reading email floor for account %d: %w", acct.ID, err)
		}
		email[acct.ID] = v
	}
	jira := make(map[int64]string, len(jiraAccounts))
	for _, acct := range jiraAccounts {
		v, err := p.db.IdeasJiraFloor(acct.ID)
		if err != nil {
			return nil, nil, fmt.Errorf("reading jira floor for account %d: %w", acct.ID, err)
		}
		jira[acct.ID] = v
	}
	return email, jira, nil
}

// stage1FloorsEqual reports whether none of the given accounts' floors moved
// between two currentStage1Floors snapshots.
func stage1FloorsEqual(beforeEmail map[int64]float64, beforeJira map[int64]string, afterEmail map[int64]float64, afterJira map[int64]string) bool {
	for id, v := range beforeEmail {
		if afterEmail[id] != v {
			return false
		}
	}
	for id, v := range beforeJira {
		if afterJira[id] != v {
			return false
		}
	}
	return true
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func maxFloat64(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}

// maxJiraFloor returns whichever of a, b is later, comparing via
// db.ParseJiraTime. An unparseable value (including "" — never initialized)
// always loses to a parseable one, so restoring an account Backfill actually
// touched keeps the reached value even when it started uninitialized.
func maxJiraFloor(a, b string) string {
	av, aok := db.ParseJiraTime(a)
	bv, bok := db.ParseJiraTime(b)
	switch {
	case aok && bok:
		if av >= bv {
			return a
		}
		return b
	case aok:
		return a
	case bok:
		return b
	default:
		return a
	}
}
