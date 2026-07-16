package memory

// This file is the Phase-5 5D mechanical interaction ingest (behind
// memory.sources.actions): a no-AI sub-step that reads the owner's own dashboard
// interactions — 👍/👎 feedback (inbox_feedback) and terminal situation verdicts
// (converted / dismissed / done) — and folds each into memory THREE ways:
//
//  1. a dated owner-action bullet appended to the situation's episode-mirror
//     "## Outcome" (distinct from IngestSituations's status-derived Outcome — it
//     records the OWNER'S ACTION, not the situation's terminal state);
//  2. per-entity engagement aggregates in memory_engagement (BumpEngagement),
//     the retention-importance input eviction consumes (Task 8);
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
	"time"

	"watchtower/internal/db"
)

// outcomeHeadingRe matches an episode mirror's "## Outcome" section heading — the
// anchor the interaction-ingest step appends dated owner-action bullets to
// (appendToSection is idempotent, so a re-scan never duplicates a bullet).
var outcomeHeadingRe = regexp.MustCompile(`(?m)^## Outcome[ \t]*$`)

// engagementBump is one pending per-entity engagement update, applied AFTER the
// annotation commit so a commit failure never leaves an aggregate ahead of the
// vault (the "advance after success" discipline).
type engagementBump struct {
	nodeID  string
	engaged bool
	at      string
}

// ingestInteractions folds the owner's dashboard interactions above the given
// interaction floor. It returns the act: refs staged for the belief pass (nil
// when none), the number of interaction events folded, the number of engagement
// aggregates bumped, and the new floor (== floor on a commit/mapping error, so
// the caller holds it and re-scans next run). A mapping DB error freezes the
// whole step; a commit failure leaves the floor unmoved and nothing bumped.
func (p *Pipeline) ingestInteractions(floor int64) (staged *stagedChat, interactions, bumped int, newFloor int64, err error) {
	newFloor = floor
	sc := &stagedChat{refs: map[string]bool{}, subjects: map[string]bool{}}

	// loaded caches each situation mirror read once; order/dirty track only the
	// mirrors whose body actually changed, so a no-op re-scan commits nothing
	// (an unchanged node would be an empty git commit).
	loaded := map[string]*Node{}
	dirty := map[string]bool{}
	var order []string
	var bumps []engagementBump

	// load reads a situation's episode mirror once (nil, false when memory holds no
	// mirror for it — e.g. a situation dismissed before it was ever ingested).
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

	// fold applies one interaction to the vault + engagement: annotate the mirror
	// (when present), stage the act: ref, and record the per-entity engagement
	// bumps. gateOnNovelty gates the situation-verdict path on the bullet being
	// genuinely new (idempotent re-scan); the feedback path always folds (the
	// floor, not the bullet, is its dedupe key).
	fold := func(sitID int, ref, at, date, bullet string, engaged, gateOnNovelty bool) (folded bool, ferr error) {
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
		if gateOnNovelty {
			// A verdict is folded only when its dated bullet is newly added — an
			// already-annotated mirror (or a mirror memory does not hold) is a no-op,
			// so a bounded re-scan never double-counts engagement.
			if !ok || !annotateOutcome(n, date, bullet) {
				return false, nil
			}
			markDirty(alias)
		} else if ok && annotateOutcome(n, date, bullet) {
			markDirty(alias) // best-effort trace; the floor is the feedback dedupe key
		}
		sc.refs[ref+" "+at] = true
		for _, s := range subjects {
			sc.subjects[s] = true
			bumps = append(bumps, engagementBump{nodeID: s, engaged: engaged, at: at})
		}
		return true, nil
	}

	// (A) inbox_feedback — append-only, floor-driven.
	feedback, ferr := p.db.ListInteractionFeedback(floor)
	if ferr != nil {
		return nil, 0, 0, floor, ferr
	}
	for _, fb := range feedback {
		if fb.SituationID != 0 {
			ref := fmt.Sprintf("act:inbox_feedback:%d", fb.ID)
			bullet := "owner marked useful"
			if fb.Rating < 0 {
				bullet = "owner dismissed"
			}
			folded, fErr := fold(fb.SituationID, ref, strconv.FormatInt(fb.TSUnix, 10), fb.Date, bullet, fb.Rating > 0, false)
			if fErr != nil {
				return nil, 0, 0, floor, fErr
			}
			if folded {
				interactions++
			}
		}
		if fb.ID > newFloor {
			newFloor = fb.ID // consumed whether or not it mapped to an entity
		}
	}

	// (B) situation verdicts — bounded idempotent re-scan (no floor).
	sits, serr := p.db.ListInteractionSituations()
	if serr != nil {
		return nil, 0, 0, floor, serr
	}
	for _, s := range sits {
		ref := fmt.Sprintf("act:situations:%d", s.ID)
		bullet, engaged := verdictBullet(s)
		folded, fErr := fold(s.ID, ref, strconv.FormatInt(s.TSUnix, 10), s.Date, bullet, engaged, true)
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

	// Aggregate writes AFTER the commit succeeded. A per-entity bump failure is
	// logged, not fatal — the floor still advances (the annotation is durable), so
	// a rare lost count is preferred over a re-scan double-count.
	for _, b := range bumps {
		if berr := p.db.BumpEngagement(b.nodeID, b.engaged, b.at); berr != nil {
			p.logf("memory: interactions: bump engagement %s: %v", b.nodeID, berr)
			continue
		}
		bumped++
	}

	if len(sc.refs) == 0 {
		sc = nil
	}
	return sc, interactions, bumped, newFloor, nil
}

// annotateOutcome appends a dated owner-action bullet to the mirror's "## Outcome"
// section, returning whether the body actually changed (false when the identical
// bullet is already present — the idempotent re-scan guard).
func annotateOutcome(n *Node, date, text string) bool {
	nb := appendToSection(n.Body, outcomeHeadingRe, "## Outcome", fmt.Sprintf("- %s: %s\n", date, text))
	if nb == n.Body {
		return false
	}
	n.Body = nb
	return true
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
		return "converted to " + joinAnd(links), true
	case "done":
		return "owner resolved", true
	default: // dismissed
		return "owner dismissed", false
	}
}

// joinAnd renders a short list as "a" / "a and b" / "a and b and c".
func joinAnd(parts []string) string {
	switch len(parts) {
	case 0:
		return ""
	case 1:
		return parts[0]
	default:
		out := parts[0]
		for _, p := range parts[1:] {
			out += " and " + p
		}
		return out
	}
}
