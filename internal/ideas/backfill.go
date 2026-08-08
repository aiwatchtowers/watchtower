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
}

// backfillMaxCycles bounds the drain loop as a runaway guard (spec §3): a
// pathological window (or a bug that never converges) still terminates.
const backfillMaxCycles = 50

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

	var firstErr error
	cycles := 0

	// Phase 1: drain the Gmail/Jira stage-1 pre-digests until a full cycle
	// moves no account's floor at all.
	for cycles < backfillMaxCycles {
		beforeEmail, beforeJira, sferr := p.currentStage1Floors(googleAccounts, jiraAccounts)
		if sferr != nil {
			result.Cycles = cycles
			return result, fmt.Errorf("backfill: reading stage-1 floors: %w", sferr)
		}

		cycles++
		if progress != nil {
			progress(cycles)
		}

		if perr := p.runEmailDigests(ctx, to); perr != nil {
			p.logf("ideas: backfill email digest pass: %v", perr)
			if firstErr == nil {
				firstErr = perr
			}
		}
		if perr := p.runJiraDigests(ctx, to); perr != nil {
			p.logf("ideas: backfill jira digest pass: %v", perr)
			if firstErr == nil {
				firstErr = perr
			}
		}

		afterEmail, afterJira, aferr := p.currentStage1Floors(googleAccounts, jiraAccounts)
		if aferr != nil {
			result.Cycles = cycles
			return result, fmt.Errorf("backfill: reading stage-1 floors: %w", aferr)
		}
		if stage1FloorsEqual(beforeEmail, beforeJira, afterEmail, afterJira) {
			break
		}
	}

	// Phase 2: drain the consolidator until a cycle proposes nothing, dedupes
	// nothing, and moves no floor.
	for cycles < backfillMaxCycles {
		beforeDigest, beforeStream, beforeTranscript, gferr := p.db.GetIdeasFloors()
		if gferr != nil {
			result.Cycles = cycles
			return result, fmt.Errorf("backfill: reading consolidate floors: %w", gferr)
		}

		cycles++
		if progress != nil {
			progress(cycles)
		}

		proposed, mentionsDeduped, cerr := p.runConsolidate(ctx, to)
		if cerr != nil {
			p.logf("ideas: backfill consolidate pass: %v", cerr)
			if firstErr == nil {
				firstErr = cerr
			}
			break // an erroring pass says nothing about convergence — stop draining
		}
		result.Proposed += proposed
		result.MentionsDeduped += mentionsDeduped

		afterDigest, afterStream, afterTranscript, gferr := p.db.GetIdeasFloors()
		if gferr != nil {
			result.Cycles = cycles
			return result, fmt.Errorf("backfill: reading consolidate floors: %w", gferr)
		}
		floorsMoved := afterDigest != beforeDigest || afterStream != beforeStream || afterTranscript != beforeTranscript
		if proposed == 0 && mentionsDeduped == 0 && !floorsMoved {
			break
		}
	}

	result.Cycles = cycles
	return result, firstErr
}

// lowerBackfillFloors is Backfill's step 2 (spec §3): it lowers the three
// workspace floors to the window start, then — per account, skipping
// anything HasStreamDigestCovering already reports fully covered (spec §4
// layer 2, cost not correctness) — lowers the per-account Gmail/Jira source
// floors instead of the (unmoved) workspace stream floor, since stream_digests
// rows are only ever created going forward. savedEmailFloor/savedJiraFloor
// are filled in as a side effect with every touched account's PRE-lower
// value, for the deferred restore.
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
// max(saved, reached) (spec §3 step 4). Errors are logged, not returned —
// this runs from a defer, after Backfill has already decided its own return
// value, and a restore failure must not mask whatever real error (or
// success) the run produced; it is surfaced instead as a log line an
// operator can act on.
func (p *Pipeline) restoreBackfillFloors(savedDigest, savedStream, savedTranscript int64, savedEmailFloor map[int64]float64, savedJiraFloor map[int64]string) {
	reachedDigest, reachedStream, reachedTranscript, err := p.db.GetIdeasFloors()
	if err != nil {
		p.logf("ideas: backfill: reading ideas floors for restore: %v", err)
	} else if err := p.db.SetIdeasFloors(
		maxInt64(savedDigest, reachedDigest),
		maxInt64(savedStream, reachedStream),
		maxInt64(savedTranscript, reachedTranscript),
	); err != nil {
		p.logf("ideas: backfill: restoring ideas floors: %v", err)
	}

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
