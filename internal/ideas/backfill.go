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
// [from, to] (spec §3): it starts from floors lowered to the window start —
// kept in memory, never written to the DB —, drains stage-1 (Gmail/Jira
// pre-digests) and then the stage-2 consolidator — both bounded by `to` —
// until nothing more is consumed, then raises every stored floor it worked
// on to max(saved, reached). Re-mining any
// already-mined material is safe and idempotent (IDEA-05): the ref-level
// dedup in applyConsolidateOps means running Backfill twice over the same
// window yields Proposed==0 the second time. progress, if non-nil, is
// called once per drain cycle with the 1-based cycle number (the CLI's
// per-cycle log line).
//
// The stored floors are never lowered: the drain works from its in-memory
// floors, and the deferred raise moves a stored floor only upward. A killed
// process (which skips the defer) therefore leaves every stored floor
// exactly where it was, so the forward run neither re-mines weeks of history
// nor pays its stage-1 calls again; the material the run did apply is
// already in the registry (IDEA-05 dedups a later re-mine).
func (p *Pipeline) Backfill(ctx context.Context, from, to time.Time, progress func(cycle int)) (result BackfillResult, err error) {
	// A bounded backfill's stream listing is capped on the row's OWN content
	// window (period_to <= to), so it can skip going-forward rows the
	// consolidator then advances the stream floor past — capture the bound now,
	// before `to` defaults to now, so restore can keep the floor honest (D10).
	// The unbounded/default path leaves this "" and restores exactly as before.
	streamCapISO := ""
	if !to.IsZero() {
		streamCapISO = to.UTC().Format(time.RFC3339)
	}
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

	floors, err := p.backfillStartFloors(from, to, savedStream, googleAccounts, jiraAccounts)
	if err != nil {
		return result, err
	}
	defer func() {
		p.raiseBackfillFloors(savedDigest, savedStream, savedTranscript, floors, streamCapISO)
	}()

	// Phase 1: drain the Gmail/Jira stage-1 pre-digests until a full cycle
	// moves no account's floor at all, or its own per-phase cycle budget
	// (GB2) runs out. A floor-read failure is fatal — no point attempting
	// phase 2 once the drain loop can no longer even tell whether it
	// converged — so it aborts here, before phase 2 ever runs.
	cycles, capped1, softErr, fatalErr := p.drainStage1(ctx, to, googleAccounts, jiraAccounts, floors, progress)
	if fatalErr != nil {
		result.Cycles = cycles
		result.Capped = capped1
		return result, fatalErr
	}

	// The consolidator keeps its own gate, as in Run: with ideas.enabled=false
	// only the stage-1 stream digests (gated by the caller on streams.enabled)
	// run, and the registry spends nothing (FEAT-01, R17).
	if p.cfg != nil && !p.cfg.Ideas.Enabled {
		result.Cycles = cycles
		result.Capped = capped1
		return result, softErr
	}

	// Phase 2: drain the consolidator until a cycle proposes nothing, dedupes
	// nothing, and moves no floor, or its own per-phase cycle budget runs
	// out — independent of phase 1's budget (GB2), so a stage-1 pass that
	// capped out never starves the consolidator of its turn. softErr threads
	// phase 1's error through so the "first error across BOTH phases wins"
	// rule holds even though the two phases are now two functions.
	cycles, proposed, mentionsDeduped, capped2, err := p.drainConsolidate(ctx, from, to, &floors.ws, cycles, progress, softErr)
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
func (p *Pipeline) drainStage1(ctx context.Context, to time.Time, googleAccounts []db.GoogleAccount, jiraAccounts []db.JiraAccount, floors *backfillFloors, progress func(cycle int)) (cycles int, capped bool, softErr, fatalErr error) {
	converged := false
	for cycles < backfillMaxCycles {
		beforeEmail, beforeJira, sferr := p.currentStage1Floors(googleAccounts, jiraAccounts, floors)
		if sferr != nil {
			return cycles, false, softErr, fmt.Errorf("backfill: reading stage-1 floors: %w", sferr)
		}

		cycles++
		if progress != nil {
			progress(cycles)
		}

		if perr := p.runStage1Passes(ctx, to, googleAccounts, jiraAccounts, floors); perr != nil && softErr == nil {
			softErr = perr
		}

		afterEmail, afterJira, aferr := p.currentStage1Floors(googleAccounts, jiraAccounts, floors)
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

// runStage1Passes runs one email pass then one jira pass per account for the
// current drainStage1 cycle: an account Backfill lowered runs from its
// in-memory floor (advanced in floors), any other account (covered, so not
// lowered) runs its ordinary stored-floor pass. Each failure is logged
// naming its source and account, and the first one is returned (nil if all
// succeeded) for the caller's own "first error wins" accumulator.
func (p *Pipeline) runStage1Passes(ctx context.Context, to time.Time, googleAccounts []db.GoogleAccount, jiraAccounts []db.JiraAccount, floors *backfillFloors) error {
	if p.generator == nil {
		return nil
	}
	var firstErr error
	note := func(what string, accountID int64, err error) {
		if err == nil {
			return
		}
		p.logf("ideas: backfill %s digest account %d: %v", what, accountID, err)
		if firstErr == nil {
			firstErr = err
		}
	}
	for _, acct := range googleAccounts {
		if !acct.GmailEnabled {
			continue
		}
		if floor, ok := floors.email[acct.ID]; ok {
			reached, err := p.emailDigestPass(ctx, acct, floor, to)
			floors.email[acct.ID] = reached
			note("email", acct.ID, err)
		} else {
			note("email", acct.ID, p.runEmailDigestAccount(ctx, acct, to))
		}
	}
	for _, acct := range jiraAccounts {
		if floor, ok := floors.jira[acct.ID]; ok {
			reached, err := p.jiraDigestPass(ctx, acct, floor, to)
			floors.jira[acct.ID] = reached
			note("jira", acct.ID, err)
		} else {
			note("jira", acct.ID, p.runJiraDigestAccount(ctx, acct, to))
		}
	}
	return firstErr
}

// drainConsolidate is Backfill phase 2: repeats consolidateCycle, bounded by
// THIS phase's own per-phase cycle budget (GB2 — independent of phase 1's,
// so a stage-1 pass that capped out never starves phase 2 of its turn),
// continuing the GLOBAL cycle/progress numbering from startCycles wherever
// phase 1 left off, until a cycle proposes nothing, dedupes nothing, and
// moves no workspace floor (the in-memory ws). capped reports whether this
// phase's own budget ran out before convergence — never set on the
// error-break path, since an erroring pass says nothing about whether the
// phase would have converged given more cycles. priorErr is phase 1's
// already-accumulated error, if any.
func (p *Pipeline) drainConsolidate(ctx context.Context, from, to time.Time, ws *workspaceFloors, startCycles int, progress func(cycle int), priorErr error) (cycles, proposed, mentionsDeduped int, capped bool, err error) {
	cycles = startCycles
	firstErr := priorErr
	converged := false
	erroredOut := false
	for phaseCycles := 0; phaseCycles < backfillMaxCycles; phaseCycles++ {
		cycles++
		if progress != nil {
			progress(cycles)
		}

		cProposed, cDeduped, floorsMoved, softErr := p.consolidateCycle(ctx, from, to, ws)
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

// consolidateCycle runs one consolidate call from the in-memory workspace
// floors ws (which it advances) and reports whether they moved —
// drainConsolidate's single-cycle unit. softErr is an ordinary consolidate
// failure, which the caller folds into its own "first error wins"
// accumulator.
func (p *Pipeline) consolidateCycle(ctx context.Context, from, to time.Time, ws *workspaceFloors) (proposed, mentionsDeduped int, floorsMoved bool, softErr error) {
	before := *ws
	proposed, mentionsDeduped, err := p.consolidate(ctx, from, to, ws)
	if err != nil {
		return 0, 0, false, err
	}
	return proposed, mentionsDeduped, *ws != before, nil
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

// backfillFloors is the floor set one Backfill run works from, kept in
// memory: the three workspace floors and the per-account stage-1 floors of
// every account the run lowered. Nothing here is written to the DB until the
// final raise (raiseBackfillFloors), which only ever moves a stored floor up.
type backfillFloors struct {
	ws    workspaceFloors
	email map[int64]float64
	jira  map[int64]string
}

// backfillStartFloors is Backfill's step 2 (spec §3): the three workspace
// floors lowered to the window start (the stream floor stays at savedStream,
// since stream_digests rows are only ever created going forward), and every
// Gmail-enabled / enabled Jira account's stage-1 floor lowered to from —
// skipping (spec §4 layer 2, cost not correctness) any account
// HasStreamDigestCovering already reports fully covered; a skipped account
// keeps running its ordinary stored-floor pass.
func (p *Pipeline) backfillStartFloors(from, to time.Time, savedStream int64, googleAccounts []db.GoogleAccount, jiraAccounts []db.JiraAccount) (*backfillFloors, error) {
	fromUnix := from.Unix()
	fromISO := from.UTC().Format(time.RFC3339)
	toISO := to.UTC().Format(time.RFC3339)

	newDigestFloor, err := p.db.DigestTopicFloorForTime(fromUnix)
	if err != nil {
		return nil, fmt.Errorf("backfill: computing digest floor: %w", err)
	}
	newTranscriptFloor, err := p.db.TranscriptFloorForTime(fromISO)
	if err != nil {
		return nil, fmt.Errorf("backfill: computing transcript floor: %w", err)
	}
	floors := &backfillFloors{
		ws:    workspaceFloors{topic: newDigestFloor, stream: savedStream, transcript: newTranscriptFloor},
		email: map[int64]float64{},
		jira:  map[int64]string{},
	}

	for _, acct := range googleAccounts {
		if !acct.GmailEnabled {
			continue
		}
		covered, err := p.db.HasStreamDigestCovering("gmail", acct.ID, fromISO, toISO)
		if err != nil {
			return nil, fmt.Errorf("backfill: checking gmail coverage for account %d: %w", acct.ID, err)
		}
		if covered {
			p.logf("ideas: backfill account %d already covered for gmail %s..%s, skipping re-digest", acct.ID, fromISO, toISO)
			continue
		}
		floors.email[acct.ID] = float64(fromUnix)
	}
	for _, acct := range jiraAccounts {
		covered, err := p.db.HasStreamDigestCovering("jira", acct.ID, fromISO, toISO)
		if err != nil {
			return nil, fmt.Errorf("backfill: checking jira coverage for account %d: %w", acct.ID, err)
		}
		if covered {
			p.logf("ideas: backfill account %d already covered for jira %s..%s, skipping re-digest", acct.ID, fromISO, toISO)
			continue
		}
		floors.jira[acct.ID] = db.FormatJiraTime(from)
	}
	return floors, nil
}

// raiseBackfillFloors writes what Backfill reached (spec §3 step 4): each
// stored floor it worked on becomes max(stored, reached), so a stored floor
// is never lowered. Errors are logged, not returned — this runs from a
// defer, after Backfill has already decided its own return value, and a
// write failure must not mask whatever real error (or success) the run
// produced.
func (p *Pipeline) raiseBackfillFloors(savedDigest, savedStream, savedTranscript int64, floors *backfillFloors, streamCapISO string) {
	p.raiseWorkspaceFloors(savedDigest, savedStream, savedTranscript, floors.ws, streamCapISO)
	for acctID, reached := range floors.email {
		p.raiseEmailFloor(acctID, reached)
	}
	for acctID, reached := range floors.jira {
		p.raiseJiraFloor(acctID, reached)
	}
}

// raiseWorkspaceFloors is raiseBackfillFloors' workspace-floor step. For a
// bounded backfill (streamCapISO non-empty) the written stream floor is capped
// below the lowest still-unconsolidated going-forward row (D10): the
// consolidator advances the floor to the highest in-window row it consumed, but
// a lower-id row whose period_to fell after `to` was never in that pass and must
// not be stranded below the floor — capping it back keeps it minable on the next
// incremental pass. Re-mining the already-consolidated rows above the cap is
// harmless (IDEA-05). The unbounded/default path (streamCapISO == "") writes
// exactly max(saved, reached).
func (p *Pipeline) raiseWorkspaceFloors(savedDigest, savedStream, savedTranscript int64, reached workspaceFloors, streamCapISO string) {
	streamFloor := max(savedStream, reached.stream)
	if streamCapISO != "" {
		if pending, perr := p.db.LowestPendingStreamDigestID(savedStream, streamCapISO); perr != nil {
			p.logf("ideas: backfill: finding lowest pending stream digest: %v", perr)
		} else if pending > 0 && pending-1 < streamFloor {
			streamFloor = pending - 1
		}
	}
	if err := p.db.SetIdeasFloors(
		max(savedDigest, reached.topic),
		streamFloor,
		max(savedTranscript, reached.transcript),
	); err != nil {
		p.logf("ideas: backfill: raising ideas floors: %v", err)
	}
}

// currentStage1Floors snapshots the per-account Gmail/Jira pre-digest floors
// for every Gmail-enabled google account and every (already-enabled) jira
// account — the in-memory one for an account Backfill lowered, the stored
// one otherwise — the drain loop's before/after snapshot for detecting
// "this cycle consumed nothing."
func (p *Pipeline) currentStage1Floors(googleAccounts []db.GoogleAccount, jiraAccounts []db.JiraAccount, floors *backfillFloors) (map[int64]float64, map[int64]string, error) {
	email := make(map[int64]float64, len(googleAccounts))
	for _, acct := range googleAccounts {
		if !acct.GmailEnabled {
			continue
		}
		if v, ok := floors.email[acct.ID]; ok {
			email[acct.ID] = v
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
		if v, ok := floors.jira[acct.ID]; ok {
			jira[acct.ID] = v
			continue
		}
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
