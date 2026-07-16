package memory

// This file is the Phase-5 5D mechanical interaction ingest (behind
// memory.sources.actions): a no-AI sub-step that reads the owner's own dashboard
// interactions — 👍/👎 feedback (inbox_feedback) and terminal situation verdicts
// (converted / dismissed / done) — and folds each into memory THREE ways:
//
//  1. a dated owner-action bullet appended to the situation's episode-mirror
//     "## Outcome" (distinct from IngestSituations's status-derived Outcome — it
//     records the OWNER'S ACTION, not the situation's terminal state);
//  2. per-entity engagement aggregates in memory_engagement (BumpEngagements,
//     one transaction per run), the retention-importance input eviction consumes
//     (Task 8);
//  3. staged act:<table>:<row_id> refs for the belief pass input (the MEM-15
//     seam) — the belief math mints owner-action rank only for a validated act:
//     ref.
//
// It forms NO preference beliefs — that is semantic 5D, a later slice. It is a
// pure READER of inbox_feedback / situation_signals / situations (MEM-05): every
// write lands in the vault, memory_engagement, or the workspace interaction floor.
//
// Idempotency has two shapes. inbox_feedback is append-only, so it is
// floor-driven (memory_last_interaction_id over inbox_feedback.id): each row is
// counted exactly once and the floor advances through the scanned prefix.
// Situation verdicts are not id-monotonic, so they are folded by a bounded
// re-scan whose bullet date is the situation's (stable) updated_at — an
// already-annotated mirror is a no-op, so the engagement bump fires only when the
// bullet is genuinely new. See docs/inventory/memory.md (MEM-15 + known
// limitations) for the resolved-ambiguity rationale.

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
)

// outcomeHeadingRe matches an episode mirror's "## Outcome" section heading — the
// anchor the interaction-ingest step appends dated owner-action bullets to
// (appendToSection is idempotent, so a re-scan never duplicates a bullet).
var outcomeHeadingRe = regexp.MustCompile(`(?m)^## Outcome[ \t]*$`)

// interactionRescanWindowDays bounds the floor-less situation-verdict re-scan: a
// situation terminal for longer than this has already had every re-scan chance,
// so it is skipped and the unbounded terminal backlog never rides every run. A
// code const (not config), like the retention/belief math constants.
const interactionRescanWindowDays = 14

// runInteractionIngest is Run step 4c (behind memory.sources.actions): the
// mechanical, no-AI fold of the owner's dashboard interactions into episode-
// mirror outcome annotations + per-entity engagement aggregates, PLUS act: refs
// staged for the belief pass (the MEM-15 seam). It runs as its OWN Run step —
// gated ONLY on memory.sources.actions, independent of the semantic tier —
// because the annotations and engagement aggregates have value on their own; the
// staged act: refs are simply unused when the semantic tier is off. It commits
// its own annotations and advances its OWN interaction floor after that commit
// (a later belief-pass failure never rewinds it), holding the floor on a
// mapping/commit/bump error. It records one pipeline_steps row at stepOffset+1
// and returns the staged act: refs (for runSemantic's belief pass) plus the
// number of step rows recorded (always 1).
func (p *Pipeline) runInteractionIngest(runID int64, stepOffset int, stats *RunStats) (*stagedChat, int) {
	step := stepOffset + 1
	start := time.Now()
	floor, ferr := p.db.MemoryInteractionFloor()
	if ferr != nil {
		p.logf("memory: interaction ingest: read floor: %v", ferr)
		p.recordSemanticStep(runID, &step, "interaction-ingest", "error", nil, start)
		return nil, 1
	}
	staged, folded, bumped, nf, ierr := p.ingestInteractions(floor)
	if ierr != nil {
		p.logf("memory: interaction ingest: %v", ierr) // floor held (nf == floor)
		p.recordSemanticStep(runID, &step, "interaction-ingest", "error", nil, start)
		return nil, 1
	}
	stats.InteractionsIngested += folded
	stats.EngagementUpdated += bumped
	if nf > floor {
		if serr := p.db.SetMemoryInteractionFloor(nf); serr != nil {
			p.logf("memory: interaction ingest: advance floor: %v", serr)
		}
	}
	p.recordSemanticStep(runID, &step, "interaction-ingest", "done", nil, start)
	return staged, 1
}

// ingestInteractions folds the owner's dashboard interactions above the given
// interaction floor. It returns the act: refs staged for the belief pass (nil
// when none), the count of distinct interactions folded, the number of
// engagement aggregates bumped, and the new floor (== floor on a
// mapping/commit/bump error, so the caller holds it and re-scans next run).
//
// Idempotency & discipline:
//   - inbox_feedback is append-only and floor-driven; InteractionsIngested counts
//     DISTINCT feedback ids (one 👍 shared by N situations is one interaction).
//   - situation verdicts have no floor: they are folded by a bounded idempotent
//     re-scan whose novelty key is the situation id + verdict TEXT (not the
//     movable updated_at date), so AttachSignal bumping updated_at cannot
//     double-annotate/double-bump; a genuinely changed verdict (a target added)
//     still appends.
//   - engagement bumps are deduped per (act: ref, entity), so one interaction
//     bumps a shared entity once, and applied in ONE transaction (BumpEngagements):
//     if ANY bump fails the whole batch rolls back and the feedback floor is HELD
//     (transient-error semantics like chat ingest), so the re-scan is clean.
func (p *Pipeline) ingestInteractions(floor int64) (staged *stagedChat, interactions, bumped int, newFloor int64, err error) {
	newFloor = floor
	sc := &stagedChat{refs: map[string]bool{}, subjects: map[string]bool{}}

	// loaded caches each situation mirror read once; order/dirty track only the
	// mirrors whose body actually changed, so a no-op re-scan commits nothing
	// (an unchanged node would be an empty git commit).
	loaded := map[string]*Node{}
	dirty := map[string]bool{}
	var order []string
	// bumps is deduped per (act: ref, entity) so one interaction touching a
	// shared entity through several situations bumps it once.
	bumps := map[string]db.EngagementBump{}

	load := func(alias string) (*Node, bool, error) {
		if n, ok := loaded[alias]; ok {
			return n, true, nil
		}
		n, rerr := Resolve(p.vault, p.db, alias)
		if rerr != nil {
			if errors.Is(rerr, ErrNotFound) {
				return nil, false, nil
			}
			return nil, false, fmt.Errorf("memory: interactions: resolve %s: %w", alias, rerr)
		}
		loaded[alias] = &n
		return &n, true, nil
	}
	markDirty := func(alias string) {
		if !dirty[alias] {
			dirty[alias] = true
			order = append(order, alias)
		}
	}

	// fold applies one interaction: annotate the mirror (when present), stage the
	// act: ref (ts in whole unix seconds), and record the deduped per-entity
	// engagement bumps (stamp in RFC3339). verdictText is "" for the feedback path
	// (which always folds, keyed by the floor); a non-empty verdictText gates the
	// situation path on the verdict being genuinely new (idempotent re-scan).
	fold := func(sitID int, ref, tsUnix, stamp, date, bullet, verdictText string, engaged bool) (folded bool, ferr error) {
		subjects, serr := p.situationSubjects(fmt.Sprintf("%d", sitID))
		if serr != nil {
			return false, fmt.Errorf("memory: interactions: situation %d: %w", sitID, serr)
		}
		if len(subjects) == 0 {
			return false, nil // maps to no memory entity — consumed, nothing folded
		}
		alias := fmt.Sprintf("situation:%d", sitID)
		n, ok, merr := load(alias)
		if merr != nil {
			return false, merr
		}
		if verdictText != "" {
			// A verdict is folded only when its verdict text is not already present
			// (any date) — an already-annotated mirror, or one memory does not hold,
			// is a no-op, so a bounded re-scan never double-counts engagement.
			if !ok || outcomeHasVerdict(n.Body, verdictText) {
				return false, nil
			}
			n.Body = appendOutcomeBullet(n.Body, date, bullet)
			markDirty(alias)
		} else if ok && annotateOutcome(n, date, bullet) {
			markDirty(alias) // best-effort trace; the floor is the feedback dedupe key
		}
		sc.refs[ref+" "+tsUnix] = true
		for _, s := range subjects {
			sc.subjects[s] = true
			bumps[ref+"\x00"+s] = db.EngagementBump{NodeID: s, Engaged: engaged, At: stamp}
		}
		return true, nil
	}

	// (A) inbox_feedback — append-only, floor-driven. InteractionsIngested counts
	// distinct feedback ids, so a feedback item on several situations is one.
	feedback, ferr := p.db.ListInteractionFeedback(floor)
	if ferr != nil {
		return nil, 0, 0, floor, ferr
	}
	foldedFB := map[int64]bool{}
	for _, fb := range feedback {
		if fb.SituationID != 0 {
			ref := fmt.Sprintf("act:inbox_feedback:%d", fb.ID)
			bullet := "owner marked useful"
			if fb.Rating < 0 {
				bullet = "owner dismissed"
			}
			folded, fErr := fold(fb.SituationID, ref, strconv.FormatInt(fb.TSUnix, 10), fb.At, fb.Date, bullet, "", fb.Rating > 0)
			if fErr != nil {
				return nil, 0, 0, floor, fErr
			}
			if folded {
				foldedFB[fb.ID] = true
			}
		}
		if fb.ID > newFloor {
			newFloor = fb.ID // consumed whether or not it mapped to an entity
		}
	}
	interactions += len(foldedFB)

	// (B) situation verdicts — bounded idempotent re-scan (no floor): a situation
	// terminal for longer than interactionRescanWindowDays is skipped, so the
	// unbounded terminal backlog never rides every run.
	since := time.Now().AddDate(0, 0, -interactionRescanWindowDays).UTC().Format(time.RFC3339)
	sits, serr := p.db.ListInteractionSituations(since)
	if serr != nil {
		return nil, 0, 0, floor, serr
	}
	for _, s := range sits {
		ref := fmt.Sprintf("act:situations:%d", s.ID)
		bullet, engaged := verdictBullet(s)
		folded, fErr := fold(s.ID, ref, strconv.FormatInt(s.TSUnix, 10), s.At, s.Date, bullet, bullet, engaged)
		if fErr != nil {
			return nil, 0, 0, floor, fErr
		}
		if folded {
			interactions++
		}
	}

	// Commit the annotated mirrors as one vault commit + index mirror. A commit
	// failure freezes the whole step (floor unmoved, nothing bumped — re-scanned
	// next run). Index-mirror errors are non-fatal (reconcile self-heals).
	if len(order) > 0 {
		nodes := make([]Node, 0, len(order))
		ids := make([]string, 0, len(order))
		for _, alias := range order {
			nodes = append(nodes, *loaded[alias])
			ids = append(ids, loaded[alias].ID)
		}
		msg := CommitMsg{
			Op:      "interactions",
			Summary: fmt.Sprintf("%d situation mirror(s) annotated", len(order)),
			Cause:   "interactions",
			NodeIDs: ids,
		}
		if _, werr := p.vault.WriteNodes(nodes, msg); werr != nil {
			return nil, 0, 0, floor, werr
		}
		now := time.Now().UTC().Format(time.RFC3339)
		for _, n := range nodes {
			if ierr := upsertIndexNode(p.db, n, now); ierr != nil {
				p.logf("memory: interactions: index %s: %v", n.ID, ierr)
			}
		}
	}

	// Aggregate writes AFTER the commit, all-or-nothing: if ANY bump fails the tx
	// rolls back and we HOLD the feedback floor (return floor + error) so the whole
	// batch re-scans next run — because the tx left nothing partially applied, the
	// re-scan re-bumps cleanly with no double-count (feedback annotations are
	// idempotent; the situation path re-folds only if its verdict is still novel).
	if len(bumps) > 0 {
		batch := make([]db.EngagementBump, 0, len(bumps))
		for _, b := range bumps {
			batch = append(batch, b)
		}
		if berr := p.db.BumpEngagements(batch); berr != nil {
			return nil, 0, 0, floor, fmt.Errorf("memory: interactions: bump engagement: %w", berr)
		}
		bumped = len(batch)
	}

	if len(sc.refs) == 0 {
		sc = nil
	}
	return sc, interactions, bumped, newFloor, nil
}

// annotateOutcome appends a dated owner-action bullet to the mirror's "## Outcome"
// section, returning whether the body actually changed (false when the identical
// dated bullet is already present — the feedback path's idempotent re-scan guard,
// keyed on the stable created_at date).
func annotateOutcome(n *Node, date, text string) bool {
	nb := appendOutcomeBullet(n.Body, date, text)
	if nb == n.Body {
		return false
	}
	n.Body = nb
	return true
}

// appendOutcomeBullet appends "- <date>: <text>" to the "## Outcome" section
// (appendToSection is verbatim-idempotent).
func appendOutcomeBullet(body, date, text string) string {
	return appendToSection(body, outcomeHeadingRe, "## Outcome", fmt.Sprintf("- %s: %s\n", date, text))
}

// outcomeHasVerdict reports whether the mirror's "## Outcome" already carries a
// bullet with the given verdict text (ANY date). The situation-verdict novelty
// key is the verdict TEXT, not the dated line, so re-scanning after AttachSignal
// moved updated_at (hence the bullet date) never re-folds the same verdict; a
// genuinely changed verdict is different text and does append.
func outcomeHasVerdict(body, verdictText string) bool {
	inOutcome := false
	for _, line := range strings.Split(body, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "## ") {
			inOutcome = trimmed == "## Outcome"
			continue
		}
		if !inOutcome || !strings.HasPrefix(trimmed, "- ") {
			continue
		}
		// A bullet is "- <date>: <verdict text>"; compare the text after the date.
		if _, rest, ok := strings.Cut(strings.TrimPrefix(trimmed, "- "), ": "); ok && rest == verdictText {
			return true
		}
	}
	return false
}

// verdictBullet renders a terminal situation's owner-action bullet text and
// whether it counts as engaged (converted/done) or dismissed.
func verdictBullet(s db.InteractionSituation) (bullet string, engaged bool) {
	switch s.Status {
	case "converted":
		var links []string
		if s.ConvertedTargetID != 0 {
			links = append(links, fmt.Sprintf("target #%d", s.ConvertedTargetID))
		}
		if s.ConvertedTrackID != 0 {
			links = append(links, fmt.Sprintf("track #%d", s.ConvertedTrackID))
		}
		if len(links) == 0 {
			return "converted", true
		}
		return "converted to " + strings.Join(links, " and "), true
	case "done":
		return "owner resolved", true
	default: // dismissed
		return "owner dismissed", false
	}
}
