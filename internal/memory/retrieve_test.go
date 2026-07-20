package memory

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/db"
)

// candRow returns a minimal MemoryNodeRow carrying only the fields
// RankByImportance reads (id + importance_score) — everything else is
// irrelevant to this pure function.
func candRow(id string, importance float64) db.MemoryNodeRow {
	return db.MemoryNodeRow{ID: id, ImportanceScore: importance}
}

// TestRankByImportance_ImportanceOnlyOrdering: equal relevance, ordering
// follows importance_score descending.
func TestRankByImportance_ImportanceOnlyOrdering(t *testing.T) {
	cands := []ScoredCandidate{
		{Row: candRow("low", 1), Relevance: 1.0},
		{Row: candRow("high", 5), Relevance: 1.0},
		{Row: candRow("mid", 3), Relevance: 1.0},
	}
	got := RankByImportance(cands, 3)
	require := []string{"high", "mid", "low"}
	for i, want := range require {
		assert.Equal(t, want, got[i].ID)
	}
}

// TestRankByImportance_RelevanceOnlyOrdering: equal importance, ordering
// follows relevance descending — the "same node kind, different match
// strength" case RetrieveByQuery relies on.
func TestRankByImportance_RelevanceOnlyOrdering(t *testing.T) {
	cands := []ScoredCandidate{
		{Row: candRow("weak", 2), Relevance: 0.1},
		{Row: candRow("strong", 2), Relevance: 0.9},
		{Row: candRow("mid", 2), Relevance: 0.5},
	}
	got := RankByImportance(cands, 3)
	require := []string{"strong", "mid", "weak"}
	for i, want := range require {
		assert.Equal(t, want, got[i].ID)
	}
}

// TestRankByImportance_ZeroImportanceSortsLast: a freshly-seeded node with no
// importance signal yet scores 0 regardless of relevance and sorts behind
// every nonzero-importance node — an accepted characteristic (design spec
// §1), not a bug.
func TestRankByImportance_ZeroImportanceSortsLast(t *testing.T) {
	cands := []ScoredCandidate{
		{Row: candRow("fresh", 0), Relevance: 1.0}, // max relevance, zero importance
		{Row: candRow("aged", 1), Relevance: 0.1},   // min relevance, nonzero importance
	}
	got := RankByImportance(cands, 2)
	assert.Equal(t, "aged", got[0].ID)
	assert.Equal(t, "fresh", got[1].ID)
}

// TestRankByImportance_TieOrderIsStable: two candidates with identical scores
// keep their input order — this is what makes sort.SliceStable (not
// sort.Slice) the correct choice; the assertion would be flaky under
// sort.Slice, which is explicitly allowed to reorder equal elements.
func TestRankByImportance_TieOrderIsStable(t *testing.T) {
	cands := []ScoredCandidate{
		{Row: candRow("first", 2), Relevance: 1.0},
		{Row: candRow("second", 2), Relevance: 1.0},
		{Row: candRow("third", 2), Relevance: 1.0},
	}
	got := RankByImportance(cands, 3)
	require := []string{"first", "second", "third"}
	for i, want := range require {
		assert.Equal(t, want, got[i].ID, "equal-scoring candidates must keep input order")
	}
}

// TestRankByImportance_LimitTruncatesSmaller: limit below len(candidates)
// keeps only the top-limit by score.
func TestRankByImportance_LimitTruncatesSmaller(t *testing.T) {
	cands := []ScoredCandidate{
		{Row: candRow("a", 1), Relevance: 1.0},
		{Row: candRow("b", 2), Relevance: 1.0},
		{Row: candRow("c", 3), Relevance: 1.0},
	}
	got := RankByImportance(cands, 1)
	assert.Len(t, got, 1)
	assert.Equal(t, "c", got[0].ID)
}

// TestRankByImportance_LimitLargerThanInputIsNoop: limit above
// len(candidates) returns every candidate, sorted, no error/panic.
func TestRankByImportance_LimitLargerThanInputIsNoop(t *testing.T) {
	cands := []ScoredCandidate{
		{Row: candRow("a", 1), Relevance: 1.0},
		{Row: candRow("b", 2), Relevance: 1.0},
	}
	got := RankByImportance(cands, 50)
	assert.Len(t, got, 2)
	assert.Equal(t, "b", got[0].ID)
}

// TestRankByImportance_LimitZeroOrNegativeReturnsEmpty: a pure-truncation
// primitive treats limit<=0 as "exactly that many" (0), never "unlimited" —
// the opposite of db.ListDisputePendingBeliefs's <=0-means-unbounded query
// convention, deliberately, since inverting it here would silently turn
// "give me 0" into "give me everything."
func TestRankByImportance_LimitZeroOrNegativeReturnsEmpty(t *testing.T) {
	cands := []ScoredCandidate{{Row: candRow("a", 1), Relevance: 1.0}}
	assert.Empty(t, RankByImportance(cands, 0))
	assert.Empty(t, RankByImportance(cands, -1))
}
