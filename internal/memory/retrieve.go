package memory

import (
	"sort"

	"watchtower/internal/db"
)

// ScoredCandidate pairs an indexed node with a caller-computed relevance
// signal (0..1, semantics owned by the caller) for one RankByImportance call
// (Slice B of the memory-retrieval redesign,
// docs/superpowers/specs/2026-07-20-memory-slice-b-unified-retrieval-design.md).
type ScoredCandidate struct {
	Row       db.MemoryNodeRow
	Relevance float64
}

// RankByImportance is the ONE place importance_score and relevance combine:
// score = Row.ImportanceScore * Relevance, sorted descending, truncated to
// limit. Every retrieval function in this package funnels its own relevance
// signal through this single combiner instead of inventing its own ranking
// (RetrieveByQuery's FTS-rank-derived relevance, RetrieveBySubject's flat 1.0
// exact-match relevance, RetrieveRevisions's confidence-delta magnitude).
//
// A node with ImportanceScore == 0 (no override, no organic signal yet — the
// common case for a freshly-seeded entity) scores 0 regardless of relevance
// and sorts last; this is an accepted characteristic, not a bug (design spec
// §1) — a brand-new, untouched node genuinely has no importance signal yet.
//
// limit <= 0 returns nil (zero results) — this is a pure post-fetch
// truncation primitive, not a "fetch N or unbounded" query helper (unlike,
// say, db.ListDisputePendingBeliefs's <=0-means-unlimited convention): the
// caller already decided how many results it wants, so 0 or negative means
// exactly that many. limit >= len(candidates) is a no-op truncation (every
// candidate survives the cut, just sorted).
//
// sort.SliceStable (not sort.Slice) is deliberate: two candidates can score
// identically (e.g. two freshly-seeded, zero-importance nodes, or two exact
// RetrieveBySubject matches with equal importance), and callers may rely on
// encounter order as the tie-break. Go's sort.Slice is explicitly permitted
// to reorder equal elements; only SliceStable guarantees they keep their
// input order (precedent: gmail_extract.go, pipeline.go already use
// SliceStable in this package for the identical reason).
func RankByImportance(candidates []ScoredCandidate, limit int) []db.MemoryNodeRow {
	if limit <= 0 {
		return nil
	}
	ranked := make([]ScoredCandidate, len(candidates))
	copy(ranked, candidates)
	sort.SliceStable(ranked, func(i, j int) bool {
		return ranked[i].Row.ImportanceScore*ranked[i].Relevance >
			ranked[j].Row.ImportanceScore*ranked[j].Relevance
	})
	if limit > len(ranked) {
		limit = len(ranked)
	}
	out := make([]db.MemoryNodeRow, limit)
	for i := 0; i < limit; i++ {
		out[i] = ranked[i].Row
	}
	return out
}
