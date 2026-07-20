package memory

// This file is Slice B's Task 7 shared dark-compare infrastructure — the same
// role digest_compare.go plays for the channel-digest render, but lighter:
// none of RetrieveByQuery/RetrieveBySubject/RetrieveRevisions makes an AI
// call, so there is no per-item cost to isolate or skip-if-fresh. Each
// Compare* function is called from exactly two places: inline, once per live
// request, from the surface's own call site (mcp/memory.go, briefing's
// gatherMemoryRevisions, meeting's gatherMemoryContext — Tasks 8-10) and, in
// a loop, from the offline CLI batch runner (RunRetrieveCompare, Task 11)
// against a snapshot. Both paths get identical diff math because both call
// the SAME function — the live inline call is not a separate, drifting copy.
//
// Every Compare* function takes readDB (the connection it computes the new
// retrieval result from — read-only is fine, these are pure SELECTs) and
// shadowDB (the connection it writes the one telemetry row to) SEPARATELY.
// The split exists because memory_recall's MCP connection is deliberately
// read-only (internal/mcp's package doc: "every registered tool is a read
// surface") — Task 8 passes a second, narrowly-scoped writable handle as
// shadowDB there; Tasks 9/10 and Task 11's CLI runner pass the SAME *db.DB
// for both (their connections are ordinarily writable already).

import (
	"encoding/json"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// RecallDiff is CompareRecall's diff-metrics payload (also the report row).
type RecallDiff struct {
	Query             string   `json:"query"`
	OldIDs            []string `json:"old_ids"`
	NewIDs            []string `json:"new_ids"`
	CoverageOK        bool     `json:"coverage_ok"` // every old id present in new — no silent loss of an exact-keyword hit
	MeanImportanceOld float64  `json:"mean_importance_old"`
	MeanImportanceNew float64  `json:"mean_importance_new"`
}

// CompareRecall runs RetrieveByQuery against readDB, diffs it against the
// caller's already-computed legacy result ids (memory_recall's combined
// alias+FTS hit list, in its returned order), writes one memory_retrieve_shadow
// row to shadowDB, and returns the diff. A retrieval or write error is
// returned to the caller, which — per MEM-05/14's "compare mode never touches
// the live response" precedent — must log it and continue returning the
// legacy result regardless (Task 8 enforces this at the call site, not here).
func CompareRecall(readDB, shadowDB *db.DB, query string, legacyIDs []string, limit int) (RecallDiff, error) {
	newRows, err := RetrieveByQuery(readDB, query, limit)
	if err != nil {
		return RecallDiff{}, fmt.Errorf("memory: compare recall: retrieve: %w", err)
	}
	newIDs := nodeIDs(newRows)
	diff := RecallDiff{
		Query:             query,
		OldIDs:            legacyIDs,
		NewIDs:            newIDs,
		CoverageOK:        idsSubsetOf(legacyIDs, newIDs),
		MeanImportanceNew: meanImportance(newRows),
	}
	oldRows, err := loadNodesByID(readDB, legacyIDs)
	if err != nil {
		return RecallDiff{}, fmt.Errorf("memory: compare recall: loading legacy nodes: %w", err)
	}
	diff.MeanImportanceOld = meanImportance(oldRows)

	if err := recordShadow(shadowDB, "recall", query, legacyIDs, newIDs, diff); err != nil {
		return diff, err
	}
	return diff, nil
}

// RevisionDiff is CompareRevisions' diff-metrics payload.
type RevisionDiff struct {
	SinceTS      float64  `json:"since_ts"`
	OldIDs       []string `json:"old_ids"`
	NewIDs       []string `json:"new_ids"`
	Intersection int      `json:"intersection"`
}

// CompareRevisions runs RetrieveRevisions against readDB/vault, diffs it
// against briefing's already-selected legacy notable-revision node ids (same
// cap, same order), writes one shadow row, and returns the diff.
func CompareRevisions(readDB, shadowDB *db.DB, vault *Vault, sinceTS float64, legacyIDs []string, limit int) (RevisionDiff, error) {
	newRows, err := RetrieveRevisions(readDB, vault, sinceTS, limit)
	if err != nil {
		return RevisionDiff{}, fmt.Errorf("memory: compare revisions: retrieve: %w", err)
	}
	newIDs := nodeIDs(newRows)
	diff := RevisionDiff{
		SinceTS:      sinceTS,
		OldIDs:       legacyIDs,
		NewIDs:       newIDs,
		Intersection: idsIntersectionCount(legacyIDs, newIDs),
	}
	queryKey := fmt.Sprintf("%.0f", sinceTS)
	if err := recordShadow(shadowDB, "briefing", queryKey, legacyIDs, newIDs, diff); err != nil {
		return diff, err
	}
	return diff, nil
}

// SubjectDiff is CompareSubject's diff-metrics payload.
type SubjectDiff struct {
	Subject         string   `json:"subject"`
	OldBeliefIDs    []string `json:"old_belief_ids"`
	NewBeliefIDs    []string `json:"new_belief_ids"`
	NewSupersetOK   bool     `json:"new_superset_ok"`    // old belief set subset-of new belief set
	NewShortTermIDs []string `json:"new_short_term_ids"` // additive — no legacy equivalent; spot-check only (design spec §6)
}

// CompareSubject runs RetrieveBySubject for one entity subject against
// readDB, diffs the belief half against meeting-prep's already-selected
// legacy belief ids (same subject, same cap), records the shortTerm episode
// ids for manual spot-check (there is no automatable "plausible" metric —
// design spec §6), writes one shadow row, and returns the diff.
func CompareSubject(readDB, shadowDB *db.DB, subject string, legacyBeliefIDs []string, limitLong, limitShort int) (SubjectDiff, error) {
	longTerm, shortTerm, err := RetrieveBySubject(readDB, []string{subject}, limitLong, limitShort)
	if err != nil {
		return SubjectDiff{}, fmt.Errorf("memory: compare subject %s: retrieve: %w", subject, err)
	}
	newBeliefIDs := nodeIDs(longTerm)
	diff := SubjectDiff{
		Subject:         subject,
		OldBeliefIDs:    legacyBeliefIDs,
		NewBeliefIDs:    newBeliefIDs,
		NewSupersetOK:   idsSubsetOf(legacyBeliefIDs, newBeliefIDs),
		NewShortTermIDs: nodeIDs(shortTerm),
	}
	if err := recordShadow(shadowDB, "meeting_prep", subject, legacyBeliefIDs, newBeliefIDs, diff); err != nil {
		return diff, err
	}
	return diff, nil
}

// recordShadow marshals old/new/diff and calls RecordRetrieveShadow — the
// one place all three Compare* functions touch the DB for a write.
func recordShadow(shadowDB *db.DB, surface, queryKey string, oldIDs, newIDs []string, diff any) error {
	return RecordRetrieveShadow(shadowDB, surface, queryKey, oldIDs, newIDs, diff)
}

// RecordRetrieveShadow marshals oldResult/newResult/diff to JSON and inserts
// one memory_retrieve_shadow row via shadowDB. The ONLY write any of this
// file makes — matching MEM-05/14's "memory writes only memory-owned side
// tables" precedent, extended to Slice B's third telemetry table.
func RecordRetrieveShadow(shadowDB *db.DB, surface, queryKey string, oldResult, newResult, diff any) error {
	oldJSON, err := json.Marshal(oldResult)
	if err != nil {
		return fmt.Errorf("memory: marshal old result for %s shadow: %w", surface, err)
	}
	newJSON, err := json.Marshal(newResult)
	if err != nil {
		return fmt.Errorf("memory: marshal new result for %s shadow: %w", surface, err)
	}
	diffJSON, err := json.Marshal(diff)
	if err != nil {
		return fmt.Errorf("memory: marshal diff metrics for %s shadow: %w", surface, err)
	}
	return shadowDB.InsertMemoryRetrieveShadow(db.MemoryRetrieveShadowRow{
		Surface:         surface,
		QueryKey:        queryKey,
		OldResultJSON:   string(oldJSON),
		NewResultJSON:   string(newJSON),
		DiffMetricsJSON: string(diffJSON),
		TS:              time.Now().UTC().Format(time.RFC3339),
	})
}

// nodeIDs projects a []db.MemoryNodeRow to its ids, in order.
func nodeIDs(rows []db.MemoryNodeRow) []string {
	ids := make([]string, len(rows))
	for i, r := range rows {
		ids[i] = r.ID
	}
	return ids
}

// idsSubsetOf reports whether every id in old is present in new — the
// "nothing is silently lost, only reordered/added" coverage check shared by
// all three surfaces (design spec §6).
func idsSubsetOf(old, new []string) bool {
	present := make(map[string]bool, len(new))
	for _, id := range new {
		present[id] = true
	}
	for _, id := range old {
		if !present[id] {
			return false
		}
	}
	return true
}

// idsIntersectionCount counts ids present in both slices.
func idsIntersectionCount(a, b []string) int {
	inA := make(map[string]bool, len(a))
	for _, id := range a {
		inA[id] = true
	}
	n := 0
	for _, id := range b {
		if inA[id] {
			n++
		}
	}
	return n
}

// meanImportance is the arithmetic mean of rows' ImportanceScore, 0 for an
// empty slice (never NaN — an empty legacy/new set reads as 0, not undefined).
func meanImportance(rows []db.MemoryNodeRow) float64 {
	if len(rows) == 0 {
		return 0
	}
	var sum float64
	for _, r := range rows {
		sum += r.ImportanceScore
	}
	return sum / float64(len(rows))
}

// loadNodesByID fetches each id's current MemoryNodeRow (best-effort — a
// stale/deleted legacy id is skipped, never an error, since the legacy
// caller already resolved it once and this is only needed for the mean-
// importance metric, not a correctness-critical read).
func loadNodesByID(readDB *db.DB, ids []string) ([]db.MemoryNodeRow, error) {
	var rows []db.MemoryNodeRow
	for _, id := range ids {
		row, err := readDB.GetMemoryNode(id)
		if err != nil {
			continue
		}
		rows = append(rows, row)
	}
	return rows, nil
}
