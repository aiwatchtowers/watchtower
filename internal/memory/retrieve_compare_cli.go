package memory

// This file is Task 11's offline CLI entry point: it exercises all three
// Task-7 Compare* functions against whatever vault/DB the CLI is pointed at
// — the current live workspace by default, or a read-only snapshot copy for
// Task 13's real-data run — using synthetic-but-grounded inputs for surfaces
// that have no natural batch substrate (recall) and real DB state for those
// that do (briefing's since-window, meeting-prep's actual belief subjects).

import (
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// retrieveCompareQuerySample bounds how many synthetic recall queries a CLI
// run tries — a sample of real node titles, not a real query log (none
// exists; flagged above as weaker evidence than a real sample, should one
// become available before Task 13).
const retrieveCompareQuerySample = 30

// defaultRecallLimit mirrors internal/mcp's own unexported defaultRecallLimit
// (10) without importing internal/mcp — internal/mcp already imports
// internal/memory, so the reverse import would be a package cycle; see
// maxRevisionCompareLimit's comment below for why local duplication is the
// house pattern for these package-cycle-avoiding mirrors.
const defaultRecallLimit = 10

// RetrieveCompareStats is RunRetrieveCompare's outcome — the report's input.
type RetrieveCompareStats struct {
	RecallCompared      int
	BriefingCompared    int
	MeetingPrepCompared int
	Failed              int
}

// RunRetrieveCompare exercises the requested surfaces (any of "recall",
// "briefing", "meeting_prep") against database/vault and returns how many
// comparisons were made. A per-item failure (a single query, or one
// attendee subject) is counted in Failed and does not abort the run —
// matching CompareDigests' per-channel isolation precedent. database is used
// for BOTH the read and the shadow write (unlike Task 8's MCP wiring, the
// CLI's own DB handle is ordinarily writable).
func RunRetrieveCompare(database *db.DB, vault *Vault, since time.Time, surfaces []string) (RetrieveCompareStats, error) {
	var stats RetrieveCompareStats
	want := make(map[string]bool, len(surfaces))
	for _, s := range surfaces {
		want[s] = true
	}

	if want["recall"] {
		n, failed, err := runRecallCompareBatch(database)
		if err != nil {
			return stats, err
		}
		stats.RecallCompared = n
		stats.Failed += failed
	}
	if want["briefing"] {
		n, err := runBriefingCompareBatch(database, vault, since)
		if err != nil {
			return stats, err
		}
		stats.BriefingCompared = n
	}
	if want["meeting_prep"] {
		n, failed, err := runMeetingPrepCompareBatch(database)
		if err != nil {
			return stats, err
		}
		stats.MeetingPrepCompared = n
		stats.Failed += failed
	}
	return stats, nil
}

// runRecallCompareBatch samples up to retrieveCompareQuerySample distinct
// non-tombstone node titles as synthetic queries and runs CompareRecall for
// each, using the SAME legacy computation memory_recall's live handler uses
// (recallAliasHit + SearchMemoryFTS) so the CLI's "legacy" side is not a
// re-implementation that could silently drift from the real one.
func runRecallCompareBatch(database *db.DB) (compared, failed int, err error) {
	nodes, err := database.ListMemoryNodes()
	if err != nil {
		return 0, 0, fmt.Errorf("memory: retrieve-compare recall: listing nodes: %w", err)
	}
	seen := make(map[string]bool)
	for _, n := range nodes {
		if n.Status == "tombstone" || n.Title == "" || seen[n.Title] {
			continue
		}
		seen[n.Title] = true
		if len(seen) > retrieveCompareQuerySample {
			break
		}
		legacyIDs, ferr := legacyRecallIDs(database, n.Title, defaultRecallLimit)
		if ferr != nil {
			failed++
			continue
		}
		if _, cerr := CompareRecall(database, database, n.Title, legacyIDs, defaultRecallLimit); cerr != nil {
			failed++
			continue
		}
		compared++
	}
	return compared, failed, nil
}

// legacyRecallIDs reproduces memory_recall's exact legacy combination
// (alias-first, then FTS, deduped, capped) as a bare id list — kept in one
// place so both the live MCP handler (Task 8) and this offline batch runner
// compute "the legacy result" identically; a future drift between them would
// be a real bug, not a design choice, so this helper is the single source.
func legacyRecallIDs(database *db.DB, query string, limit int) ([]string, error) {
	nodeID, err := database.LookupMemoryAlias(query)
	var ids []string
	if err == nil {
		ids = append(ids, nodeID)
	}
	ftsHits, err := database.SearchMemoryFTS(query, limit)
	if err != nil {
		return nil, err
	}
	for _, h := range ftsHits {
		if len(ids) > 0 && ids[0] == h.ID {
			continue
		}
		ids = append(ids, h.ID)
	}
	if len(ids) > limit {
		ids = ids[:limit]
	}
	return ids, nil
}

// runBriefingCompareBatch runs one CompareRevisions call for the whole
// since-window — briefing's own live call is likewise a single call per
// generation, so this is a faithful one-shot exercise, not a sample.
func runBriefingCompareBatch(database *db.DB, vault *Vault, since time.Time) (int, error) {
	sinceTS := float64(since.Unix())
	legacyIDs, err := legacyRevisionIDs(database, vault, since)
	if err != nil {
		return 0, fmt.Errorf("memory: retrieve-compare briefing: legacy selection: %w", err)
	}
	if _, err := CompareRevisions(database, database, vault, sinceTS, legacyIDs, maxRevisionCompareLimit); err != nil {
		return 0, fmt.Errorf("memory: retrieve-compare briefing: %w", err)
	}
	return 1, nil
}

// maxRevisionCompareLimit mirrors internal/briefing's maxMemoryRevisions (5)
// without importing internal/briefing (would be a package cycle) — a code
// const duplicated at the same value, matching digest_render.go's precedent
// of mirroring the legacy digest_topics JSON shape locally rather than
// importing it.
const maxRevisionCompareLimit = 5

// legacyRevisionIDs reproduces briefing's exact notable-revision belief-id
// selection (status transition or |confidence delta| >= 0.2, capped) as a
// bare id list, so the CLI's "legacy" side matches the live one exactly.
// Calls the SAME memory.NotableRevision (Task 6's relocation) briefing
// itself calls — this file is package memory, so no import prefix needed.
func legacyRevisionIDs(database *db.DB, vault *Vault, since time.Time) ([]string, error) {
	nodes, err := database.ListMemoryNodes()
	if err != nil {
		return nil, err
	}
	var ids []string
	for _, n := range nodes {
		if n.Type != "belief" {
			continue
		}
		node, err := vault.ReadNode(n.ID)
		if err != nil {
			continue
		}
		if _, ok := NotableRevision(node, since); ok {
			ids = append(ids, n.ID)
			if len(ids) >= maxRevisionCompareLimit {
				break
			}
		}
	}
	return ids, nil
}

// runMeetingPrepCompareBatch runs one CompareSubject call per distinct
// belief subject entity — a real, non-synthetic sample: every entity that
// has ever been an attendee's resolved memory page in production would have
// exactly this shape.
func runMeetingPrepCompareBatch(database *db.DB) (compared, failed int, err error) {
	nodes, err := database.ListMemoryNodes()
	if err != nil {
		return 0, 0, fmt.Errorf("memory: retrieve-compare meeting-prep: listing nodes: %w", err)
	}
	subjects := make(map[string]bool)
	for _, n := range nodes {
		if n.Type == "belief" && n.Subject != "" && (n.Status == "active" || n.Status == "shaken") {
			subjects[n.Subject] = true
		}
	}
	for subject := range subjects {
		legacyIDs := legacyBeliefIDsForSubject(nodes, subject)
		if _, cerr := CompareSubject(database, database, subject, legacyIDs, meetingPrepCompareLimitLong, meetingPrepCompareLimitShort); cerr != nil {
			failed++
			continue
		}
		compared++
	}
	return compared, failed, nil
}

// meetingPrepCompareLimitLong/Short mirror internal/meeting's
// maxAttendeeBeliefs (3) and Task 10's meetingPrepShortTermSampleLimit (5)
// without importing internal/meeting (a package cycle) — see
// maxRevisionCompareLimit's comment for why this local duplication is the
// house pattern here.
const (
	meetingPrepCompareLimitLong  = 3
	meetingPrepCompareLimitShort = 5
)

// legacyBeliefIDsForSubject reproduces meeting-prep's exact belief selection
// for one subject (active/shaken, capped) as a bare id list.
func legacyBeliefIDsForSubject(nodes []db.MemoryNodeRow, subject string) []string {
	var ids []string
	for _, n := range nodes {
		if n.Type != "belief" || n.Subject != subject {
			continue
		}
		if n.Status != "active" && n.Status != "shaken" {
			continue
		}
		ids = append(ids, n.ID)
		if len(ids) >= meetingPrepCompareLimitLong {
			break
		}
	}
	return ids
}

// RenderRetrieveCompareReport renders the human-readable markdown compare
// report — deterministic (same stats + timestamp -> identical bytes),
// mirroring RenderCompareReport's shape for the digest-compare precedent.
func RenderRetrieveCompareReport(stats RetrieveCompareStats, generatedAt time.Time) string {
	var b strings.Builder
	b.WriteString("# Retrieval compare report (dark compare-mode, Slice B)\n\n")
	fmt.Fprintf(&b, "Generated: %s\n\n", generatedAt.UTC().Format(time.RFC3339))
	b.WriteString("> Auto-generated by `watchtower memory retrieve-compare`. Every legacy selection stays authoritative and byte-untouched; these comparisons live only in `memory_retrieve_shadow`.\n\n")
	fmt.Fprintf(&b, "- Recall: %d compared (%d failed)\n", stats.RecallCompared, stats.Failed)
	fmt.Fprintf(&b, "- Briefing: %d compared\n", stats.BriefingCompared)
	fmt.Fprintf(&b, "- Meeting prep: %d compared\n\n", stats.MeetingPrepCompared)
	b.WriteString("## Hand-review protocol\n\n")
	b.WriteString("Read `memory_retrieve_shadow` per surface: for recall, confirm coverage_ok on most queries and compare mean_importance_old vs new; for briefing, confirm the top-5 intersection is high and note any importance-driven reordering; for meeting-prep, confirm new_superset_ok and spot-check new_short_term_ids for plausibility (not automatable). This hand-review is the go/no-go input for Task 13's per-surface switch.\n")
	return b.String()
}
