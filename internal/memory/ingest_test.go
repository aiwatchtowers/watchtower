package memory

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedInboxItem inserts a minimal inbox item and returns its ID.
func seedInboxItem(t *testing.T, d *db.DB, channelID, messageTS string) int {
	t.Helper()
	res, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type)
		VALUES (?, ?, 'U1ALICE', 'mention')`, channelID, messageTS)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return int(id)
}

// ingestTSSeq keeps signal message timestamps unique across
// seedIngestSituation calls (inbox_items is UNIQUE(channel_id, message_ts)).
var ingestTSSeq int

// seedIngestSituation creates an open situation with two signal refs: one
// resolving against messages and one seeded bad ref (no messages row).
// Returns the situation ID.
func seedIngestSituation(t *testing.T, d *db.DB, title string) int {
	t.Helper()
	ingestTSSeq++
	goodTS := fmt.Sprintf("1752570000.%06d", ingestTSSeq)
	badTS := fmt.Sprintf("1721034000.%06d", ingestTSSeq) // year-shifted: no messages row
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text)
		VALUES ('C1GEN', ?, 'U1ALICE', 'billing is down')`, goodTS)
	require.NoError(t, err)

	sitID, err := d.CreateSituation(db.DashboardSituation{
		Title:      title,
		Summary:    "Billing is down and the team is on it.",
		Chronology: "10:00 alarm fired; 10:05 rollback started.",
	})
	require.NoError(t, err)

	good := seedInboxItem(t, d, "C1GEN", goodTS)
	bad := seedInboxItem(t, d, "C1GEN", badTS) // must be dropped on write (MEM-01)
	require.NoError(t, d.AddSituationSignals(int(sitID), []int{good, bad}))
	return int(sitID)
}

func TestIngestOpenSituationCreatesNode(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	sitID := seedIngestSituation(t, d, "Billing outage")

	stats, err := IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, IngestStats{Created: 1}, stats)

	n, err := Resolve(v, d, fmt.Sprintf("situation:%d", sitID))
	require.NoError(t, err)
	assert.Equal(t, "episode", n.Type)
	assert.Equal(t, "short", n.Tier)
	assert.Equal(t, "active", n.Status)
	assert.Equal(t, "Billing outage", n.Title)
	assert.Contains(t, n.Aliases, fmt.Sprintf("situation:%d", sitID))
	assert.Contains(t, n.Body, "## Story\nBilling is down and the team is on it.")
	assert.Contains(t, n.Body, "10:00 alarm fired; 10:05 rollback started.")
	assert.Contains(t, n.Body, "## Provenance\n- C1GEN 1752570000.", "validated signal ref copied as provenance")
	assert.NotContains(t, n.Body, "1721034000.", "seeded bad ref dropped (MEM-01)")
}

func TestIngestUnchangedSecondRunIsNoOp(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedIngestSituation(t, d, "Billing outage")

	_, err := IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)

	repo := openTestRepo(t, v.path)
	commits := commitCount(t, repo)
	nodesBefore, err := d.ListMemoryNodes()
	require.NoError(t, err)

	stats, err := IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, IngestStats{}, stats, "unchanged situation is untouched")
	assert.Equal(t, commits, commitCount(t, repo), "no commit on a no-op run")

	nodesAfter, err := d.ListMemoryNodes()
	require.NoError(t, err)
	assert.Equal(t, len(nodesBefore), len(nodesAfter))
}

func TestIngestOpenSituationUpdateRewritesBody(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	sitID := seedIngestSituation(t, d, "Billing outage")
	_, err := IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)

	require.NoError(t, d.SetSituationCard(sitID, "Rollback finished, watching metrics.", "", "10:00 alarm; 10:30 rollback done."))

	stats, err := IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, IngestStats{Updated: 1}, stats)

	n, err := Resolve(v, d, fmt.Sprintf("situation:%d", sitID))
	require.NoError(t, err)
	assert.Contains(t, n.Body, "Rollback finished, watching metrics.")
	assert.Equal(t, "active", n.Status, "still open: not finalized by an update")
	assert.Equal(t, "short", n.Tier)
}

func TestIngestDoneTransitionFinalizes(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	sitID := seedIngestSituation(t, d, "Billing outage")
	_, err := IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)

	require.NoError(t, d.SetSituationStatus(sitID, "done", "rollback shipped, incident closed"))

	stats, err := IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, IngestStats{Finalized: 1}, stats)

	n, err := Resolve(v, d, fmt.Sprintf("situation:%d", sitID))
	require.NoError(t, err)
	assert.Equal(t, "closed", n.Status)
	assert.Equal(t, "long", n.Tier)
	assert.Contains(t, n.Body, "## Outcome\nrollback shipped, incident closed\n")

	// A finalized node is terminal for ingest: a third run changes nothing.
	stats, err = IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, IngestStats{}, stats)
}

// TestIngestFloorAdvancesAndSkipsTerminal: finalizing a situation advances the
// ingest floor past it, and a later run no longer rescans terminal situations at
// or below the floor (Task 13). Open situations do not advance the floor.
func TestIngestFloorAdvancesAndSkipsTerminal(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d) // so the floor scalar persists
	sitID := seedIngestSituation(t, d, "Billing outage")

	// First run ingests the OPEN situation — an open situation never advances
	// the floor (it can still transition and must stay scannable).
	_, err := IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)
	floor, err := d.MemoryIngestFloor()
	require.NoError(t, err)
	assert.Zero(t, floor, "open situation does not advance the floor")

	// Finalize it → the next run finalizes the node and advances the floor.
	require.NoError(t, d.SetSituationStatus(sitID, "done", "closed"))
	stats, err := IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)
	require.Equal(t, 1, stats.Finalized)
	floor, err = d.MemoryIngestFloor()
	require.NoError(t, err)
	assert.Equal(t, int64(sitID), floor, "floor advanced to the finalized situation id")

	// The terminal situation is now at/below the floor: listIngestSituations no
	// longer returns it.
	sits, err := listIngestSituations(d, floor)
	require.NoError(t, err)
	for _, s := range sits {
		assert.NotEqual(t, sitID, s.id, "terminal situation at/below the floor is not rescanned")
	}

	// A third run is a clean no-op — nothing terminal left to rescan.
	stats, err = IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, IngestStats{}, stats)
}

// TestIngestFloorBlockedByLowerOpenSituation: the floor never advances past a
// still-open lower-id situation, even when a higher-id terminal situation
// finalizes — so the open one stays scannable if it later transitions (the
// contiguous-terminal-prefix invariant). Open situations are always scanned.
func TestIngestFloorBlockedByLowerOpenSituation(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	openID := seedIngestSituation(t, d, "Long-running") // lower id, stays open
	termID := seedIngestSituation(t, d, "Short-lived")  // higher id, will finalize

	// Ingest both while open.
	_, err := IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)

	// Finalize only the higher-id one.
	require.NoError(t, d.SetSituationStatus(termID, "done", "closed"))
	stats, err := IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, 1, stats.Finalized)

	// The floor must stay below the still-open lower-id situation.
	floor, err := d.MemoryIngestFloor()
	require.NoError(t, err)
	assert.Less(t, floor, int64(openID), "floor stays below the still-open lower-id situation")

	// The open situation is still returned by listIngestSituations.
	sits, err := listIngestSituations(d, floor)
	require.NoError(t, err)
	found := false
	for _, s := range sits {
		if s.id == openID {
			found = true
		}
	}
	assert.True(t, found, "open situation always scanned regardless of the floor")
}

func TestIngestConvertedMentionsLink(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	toTarget := seedIngestSituation(t, d, "Billing outage")
	toTrack := seedIngestSituation(t, d, "Migration saga")
	_, err := IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)

	require.NoError(t, d.MarkSituationConverted(toTarget, 7, 0))
	require.NoError(t, d.MarkSituationConverted(toTrack, 0, 13))

	stats, err := IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, IngestStats{Finalized: 2}, stats)

	n, err := Resolve(v, d, fmt.Sprintf("situation:%d", toTarget))
	require.NoError(t, err)
	assert.Equal(t, "closed", n.Status)
	assert.Contains(t, n.Body, "Converted to target #7", "outcome links the conversion product (DASH-03 stays reachable from memory too)")

	n, err = Resolve(v, d, fmt.Sprintf("situation:%d", toTrack))
	require.NoError(t, err)
	assert.Contains(t, n.Body, "Converted to track #13")
}

// dumpTable renders every row of a table for byte-identical before/after
// comparisons.
func dumpTable(t *testing.T, d *db.DB, table string) string {
	t.Helper()
	rows, err := d.Query(`SELECT * FROM ` + table + ` ORDER BY rowid`)
	require.NoError(t, err)
	defer rows.Close()

	cols, err := rows.Columns()
	require.NoError(t, err)
	vals := make([]any, len(cols))
	ptrs := make([]any, len(cols))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	var b strings.Builder
	for rows.Next() {
		require.NoError(t, rows.Scan(ptrs...))
		fmt.Fprintf(&b, "%v\n", vals)
	}
	require.NoError(t, rows.Err())
	return b.String()
}

// TestMemory05_InboxUntouched guards MEM-05: consolidation reads situations
// and inbox items but writes nothing to inbox tables and never moves
// inbox_last_processed_ts.
func TestMemory05_InboxUntouched(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	_, err := d.Exec(`INSERT INTO workspace (id, name, inbox_last_processed_ts) VALUES ('T1', 'test', 1752570123.5)`)
	require.NoError(t, err)
	sitID := seedIngestSituation(t, d, "Billing outage")

	inboxBefore := dumpTable(t, d, "inbox_items")
	situationsBefore := dumpTable(t, d, "situations")
	signalsBefore := dumpTable(t, d, "situation_signals")

	_, err = IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, situationsBefore, dumpTable(t, d, "situations"), "create pass leaves situations byte-identical")

	require.NoError(t, d.SetSituationStatus(sitID, "done", "closed"))
	situationsBefore = dumpTable(t, d, "situations") // re-dump: the status change is the test's own write
	_, err = IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)

	assert.Equal(t, inboxBefore, dumpTable(t, d, "inbox_items"), "inbox_items byte-identical")
	assert.Equal(t, situationsBefore, dumpTable(t, d, "situations"), "situations byte-identical")
	assert.Equal(t, signalsBefore, dumpTable(t, d, "situation_signals"), "situation_signals byte-identical")

	var wm float64
	require.NoError(t, d.QueryRow(`SELECT inbox_last_processed_ts FROM workspace`).Scan(&wm))
	assert.Equal(t, 1752570123.5, wm, "inbox watermark untouched")
}

// TestIngestLookupErrorSkipsSituationAndContinues: a provenance lookup ERROR
// (not a missing message — the check itself failing) must fail only that
// situation: it is logged and skipped this run while ingest continues to the
// next situation. Extends the MEM-01 discipline: refs the checker could not
// verify are never written, and the error is never conflated with a
// positively-invalid ref.
func TestIngestLookupErrorSkipsSituationAndContinues(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	// Situation 1's signal ref triggers a lookup error; situation 2's is fine.
	failTS := "1752570000.900001"
	okTS := "1752570000.900002"
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text)
		VALUES ('C1GEN', ?, 'U1ALICE', 'billing is down'), ('C1GEN', ?, 'U1ALICE', 'network flapping')`, failTS, okTS)
	require.NoError(t, err)

	sitErr, err := d.CreateSituation(db.DashboardSituation{Title: "Lookup breaks", Summary: "s", Chronology: "c"})
	require.NoError(t, err)
	require.NoError(t, d.AddSituationSignals(int(sitErr), []int{seedInboxItem(t, d, "C1GEN", failTS)}))
	sitOK, err := d.CreateSituation(db.DashboardSituation{Title: "Ingests fine", Summary: "s", Chronology: "c"})
	require.NoError(t, err)
	require.NoError(t, d.AddSituationSignals(int(sitOK), []int{seedInboxItem(t, d, "C1GEN", okTS)}))

	var logs []string
	stats, err := IngestSituations(v, d, errCheckerAfter{db: d, failTS: failTS},
		func(f string, a ...any) { logs = append(logs, fmt.Sprintf(f, a...)) })
	require.NoError(t, err, "one situation's lookup error never fails the whole ingest")
	assert.Equal(t, IngestStats{Created: 1}, stats, "the healthy situation is still ingested")

	_, err = Resolve(v, d, fmt.Sprintf("situation:%d", sitOK))
	require.NoError(t, err, "healthy situation mirrored")
	_, err = Resolve(v, d, fmt.Sprintf("situation:%d", sitErr))
	assert.ErrorIs(t, err, ErrNotFound, "erroring situation skipped this run, not written")

	assert.Contains(t, strings.Join(logs, "\n"), "skipped this run", "the skip is logged")

	// The lookup error is transient: with a healthy checker the skipped
	// situation is picked up on the next run.
	stats, err = IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, IngestStats{Created: 1}, stats)
	_, err = Resolve(v, d, fmt.Sprintf("situation:%d", sitErr))
	require.NoError(t, err)
}

// TestIngestLogsRejectedRefCount: positively-invalid signal refs are dropped
// AND surfaced in the log (previously discarded silently).
func TestIngestLogsRejectedRefCount(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	sitID := seedIngestSituation(t, d, "Billing outage") // seeds one good + one bad ref

	var logs []string
	stats, err := IngestSituations(v, d, d, func(f string, a ...any) { logs = append(logs, fmt.Sprintf(f, a...)) })
	require.NoError(t, err)
	assert.Equal(t, IngestStats{Created: 1}, stats)
	assert.Contains(t, strings.Join(logs, "\n"), fmt.Sprintf("ingest situation %d: refs_rejected=1 (MEM-01)", sitID))
}

// TestIngestCorruptedEpisodeFileSkipsSituation: a quarantined/corrupted
// episode file (owner edit gone wrong) must not brick the whole ingest pass —
// the situation is skipped with a log line and other situations still flow
// (F4 spirit carried into ingest).
func TestIngestCorruptedEpisodeFileSkipsSituation(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	brokenID := seedIngestSituation(t, d, "Billing outage")
	_, err := IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err)

	nodeID, err := d.LookupMemoryAlias(fmt.Sprintf("situation:%d", brokenID))
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(
		filepath.Join(v.path, "episodes", nodeID+".md"),
		[]byte("not frontmatter at all"), 0o644))

	healthyID := seedIngestSituation(t, d, "Deploy freeze question")
	stats, err := IngestSituations(v, d, d, t.Logf)
	require.NoError(t, err, "corrupted episode file must not fail the pass")
	assert.Equal(t, 1, stats.Created, "healthy situation still ingested")
	_, err = d.LookupMemoryAlias(fmt.Sprintf("situation:%d", healthyID))
	require.NoError(t, err)
}
