package memory

import (
	"fmt"
	"sort"
	"time"

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

// candidateWindowMultiplier widens the FTS candidate pool before importance
// re-ranking (Slice B): fetching only `limit` best-bm25-rank rows would
// never give a high-importance-but-slightly-weaker-match node a chance to
// outrank a trivially-better-ranked but unimportant one, because it would
// never make the window at all. maxCandidateWindow caps the widened window
// (mirrors internal/mcp/server.go's maxListLimit=200 — a single query should
// never scan an effectively unbounded result set).
const candidateWindowMultiplier = 4
const maxCandidateWindow = 200

// RetrieveByQuery replaces memory_recall's pure-FTS-rank ordering with
// importance x relevance (Slice B): it fetches a wider candidate window
// (limit*4, capped at 200) via SearchMemoryFTSCandidates, normalizes each
// row's raw rank into a Relevance via normalizeFTSRank, and re-ranks through
// RankByImportance.
//
// The exact-alias-match short-circuit stays memory_recall's own concern
// (recallAliasHit, internal/mcp/memory.go) — a LATER task wires the MCP
// handler to prepend that hit ahead of this function's results, exactly as
// it prepends today ahead of SearchMemoryFTS's results. This function is
// pure FTS ranking; it knows nothing about aliases.
func RetrieveByQuery(database *db.DB, query string, limit int) ([]db.MemoryNodeRow, error) {
	window := limit * candidateWindowMultiplier
	if window <= 0 || window > maxCandidateWindow {
		window = maxCandidateWindow
	}
	cands, err := database.SearchMemoryFTSCandidates(query, window)
	if err != nil {
		return nil, fmt.Errorf("memory: retrieve by query: %w", err)
	}
	scored := make([]ScoredCandidate, len(cands))
	for i, c := range cands {
		scored[i] = ScoredCandidate{Row: c.Row, Relevance: normalizeFTSRank(c.Rank)}
	}
	return RankByImportance(scored, limit), nil
}

// normalizeFTSRank maps SQLite FTS5's default rank (== bm25(): more NEGATIVE
// is a BETTER match; SearchMemoryFTS's plain `ORDER BY rank` already relies
// on this ascending-is-best convention) into a Relevance in [0, 1),
// monotonically INCREASING with match quality.
//
// The naive `1/(1+rank)` the design spec floated is WRONG: for a strong
// match rank is very negative (e.g. -8), giving 1/(1-8) = 1/-7 — a NEGATIVE
// relevance that also flips sign relative to a weak match's 1/(1-1)=0.5,
// inverting the whole ranking. The correct transform operates on
// x := -rank (>= 0 for every real match; a STRONGER match has a LARGER x):
//
//	relevance = x / (1 + x)
//
// This is monotonically increasing in x, bounded in [0, 1), and never
// negative. rank == 0 (a degenerate edge case FTS5's real bm25 output should
// never actually produce for a MATCHing row) yields relevance 0 — sorting
// last, consistent with RankByImportance's own zero-relevance floor.
func normalizeFTSRank(rank float64) float64 {
	x := -rank
	if x < 0 {
		x = 0 // defensive: a positive rank must never be treated as "better than a match"
	}
	return x / (1 + x)
}

// RetrieveBySubject replaces meeting-prep's ad hoc encounter-order belief
// filter (beliefLinesFor) with importance-ranked selection (Slice B):
// longTerm is every active-or-shaken belief on subjects, ranked by
// RankByImportance with a flat Relevance of 1.0 (an exact subject match has
// no gradation — there is no "how well does this belief match the subject,"
// only yes/no). shortTerm is the recency-ordered short-tier episodes whose
// provenance sender matches a subject (ListShortTierEpisodesForAliases,
// Task 4) — NOT re-ranked by importance: a short-tier episode's value here
// is "what recently happened," not "how important is this in general"
// (design spec §3).
func RetrieveBySubject(database *db.DB, subjects []string, limitLong, limitShort int) (longTerm, shortTerm []db.MemoryNodeRow, err error) {
	if len(subjects) == 0 {
		return nil, nil, nil
	}
	beliefs, err := database.ListBeliefsForSubjects(subjects)
	if err != nil {
		return nil, nil, fmt.Errorf("memory: retrieve by subject: %w", err)
	}
	scored := make([]ScoredCandidate, len(beliefs))
	for i, b := range beliefs {
		scored[i] = ScoredCandidate{Row: b, Relevance: 1.0}
	}
	longTerm = RankByImportance(scored, limitLong)

	shortTerm, err = database.ListShortTierEpisodesForAliases(subjects, limitShort)
	if err != nil {
		return nil, nil, fmt.Errorf("memory: retrieve by subject (short-tier): %w", err)
	}
	return longTerm, shortTerm, nil
}

// RetrieveRevisions replaces briefing's encounter-order-capped notable-
// revision selection (Slice B): every belief node is checked for notability
// via NotableRevision (UNCHANGED filter — MEM-11, this slice never revisits
// what counts as notable), then ranked through RankByImportance so a
// notable change on a high-importance belief surfaces before the
// same-magnitude change on a low-importance one. v is required because
// notability is computed from the live vault body's ## History, which is
// not mirrored into the SQLite index.
func RetrieveRevisions(database *db.DB, v *Vault, sinceTS float64, limit int) ([]db.MemoryNodeRow, error) {
	since := time.Unix(int64(sinceTS), 0).UTC()
	nodes, err := database.ListMemoryNodes()
	if err != nil {
		return nil, fmt.Errorf("memory: retrieve revisions: %w", err)
	}
	var scored []ScoredCandidate
	for _, row := range nodes {
		if row.Type != "belief" {
			continue
		}
		node, err := v.ReadNode(row.ID)
		if err != nil {
			continue // index/vault drift (file removed since indexing) — skip, matching gatherMemoryRevisions's existing tolerance
		}
		nr, ok := NotableRevision(node, since)
		if !ok {
			continue
		}
		scored = append(scored, ScoredCandidate{Row: row, Relevance: nr.Magnitude})
	}
	return RankByImportance(scored, limit), nil
}
