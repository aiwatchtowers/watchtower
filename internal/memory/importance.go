package memory

import (
	"watchtower/internal/db"
)

// ImportanceInputs are the file-derived signals behind a node's importance:
// how many live nodes reference it, whether it originated from a dashboard
// situation, whether the owner ever touched its file, and its linked
// entities' net owner-engagement. Extracted from evict.go's RetentionScore
// (Slice A of the memory-importance-score redesign, MEM-16) so a value can be
// computed independent of eviction's recency factor.
type ImportanceInputs struct {
	LinksIn         int  // live nodes linking to this one
	SituationOrigin bool // node carries a situation:<id> alias
	OwnerTouched    bool // file was ever touched by a memory(owner-edit) commit
	// Engagement is the NET owner-engagement of the entities linking this node
	// (engaged_count − dismissed_count summed over its linking entities, Phase-5
	// 5D memory_engagement). Only a positive net raises importance — a dismissed
	// or never-touched node gets no bonus and never scores below the un-engaged
	// baseline. Clamped to [-engagementNetClamp, +engagementNetClamp] before
	// scoring so one heavily-engaged entity cannot dominate importance.
	Engagement int
}

// engagementNetClamp bounds the net-engagement contribution to importance: a
// net beyond ±3 is clamped, so no single entity's counter can dominate the
// score. Moved here verbatim from evict.go (Slice A) — same value, same
// meaning, now shared by ComputeImportance and (via it) RetentionScore.
const engagementNetClamp = 3

// Importance constants live in code, not config (mirrors belief_math.go /
// evict.go's recency constants): one auditable place for the importance math.
// Moved here verbatim from evict.go (Slice A) — same values.
const (
	importanceSituationBonus = 1.0
	importanceOwnerBonus     = 2.0 // owner-touched outweighs the situation bonus
	// importanceEngagementWeight scales net owner-engagement into importance: an
	// entity the owner actively engages with (👍, converts, resolves — Phase-5 5D)
	// resists eviction/decay on par with an owner-touched file.
	importanceEngagementWeight = 2.0
)

// ComputeImportance is the pure importance formula: links-in + situation-
// origin bonus + owner-touch bonus + clamped net-engagement bonus. A cold,
// unreferenced, un-touched, un-engaged node scores 0 and is always evictable;
// links-in, an owner edit, or positive owner-engagement lift it above zero.
// Side-effect free and exhaustively unit-tested (importance_test.go).
// Extracted from RetentionScore (evict.go), which now delegates here for its
// importance half — recency stays eviction-specific and is applied only by
// RetentionScore, never here. The merged (owner-override-or-computed) result
// of this function is what Reconcile/Rebuild persist into
// memory_nodes.importance_score (index.go, MEM-16) — a periodic snapshot,
// distinct from RetentionScore's always-live recomputation.
func ComputeImportance(in ImportanceInputs) float64 {
	importance := float64(in.LinksIn)
	if in.SituationOrigin {
		importance += importanceSituationBonus
	}
	if in.OwnerTouched {
		importance += importanceOwnerBonus
	}
	net := in.Engagement
	if net > engagementNetClamp {
		net = engagementNetClamp
	} else if net < -engagementNetClamp {
		net = -engagementNetClamp
	}
	if net > 0 { // only positive net raises importance (a dismissed entity never scores below baseline)
		importance += importanceEngagementWeight * float64(net)
	}
	return importance
}

// computeNodeImportance is the merged (owner-override-or-computed)
// importance value for node n at vault-relative path rel: n's
// ImportanceOverride if set, else ComputeImportance fed by live
// links-in/situation-origin/owner-touch/engagement reads. ownerEdited
// resolves the owner-touch signal for rel: Reconcile's bulk pass
// (index.go's reconcilePass.ownerEdited) passes a lazily-memoized lookup
// backed by ONE Vault.OwnerEditedFiles() call per Reconcile run, while
// upsertIndexNode's single-node call sites (no batch to memoize over) pass
// the plain per-file Vault.OwnerEdited method value directly (whole-branch
// review follow-up, added 2026-07-18, MEM-16: a fresh v.OwnerEdited call per
// node was an expensive per-file git-log walk, now paid on every write
// through ~16+ call sites, not just the small bounded eviction-candidate
// set OwnerEdited was originally scoped for). Shared by index.go's
// Reconcile/Rebuild path and merge.go's upsertIndexNode (every non-Reconcile
// write path) so both persist a mutually consistent value for the same file
// — MEM-16, Slice A follow-up (added 2026-07-18: upsertIndexNode previously
// never set this field).
func computeNodeImportance(database *db.DB, ownerEdited func(rel string) (bool, error), n Node, rel string) (float64, error) {
	if n.ImportanceOverride != nil {
		return *n.ImportanceOverride, nil
	}
	linksIn, err := database.CountMemoryLinksIn(n.ID)
	if err != nil {
		return 0, err
	}
	ownerTouched, err := ownerEdited(rel)
	if err != nil {
		return 0, err
	}
	engaged, dismissed, err := database.LinkedEntityEngagement(n.ID)
	if err != nil {
		return 0, err
	}
	return ComputeImportance(ImportanceInputs{
		LinksIn:         linksIn,
		SituationOrigin: hasSituationAlias(n.Aliases),
		OwnerTouched:    ownerTouched,
		Engagement:      engaged - dismissed,
	}), nil
}
