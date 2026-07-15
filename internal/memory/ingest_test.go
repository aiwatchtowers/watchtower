package memory

import (
	"fmt"
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

	stats, err := IngestSituations(v, d)
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

	_, err := IngestSituations(v, d)
	require.NoError(t, err)

	repo := openTestRepo(t, v.path)
	commits := commitCount(t, repo)
	nodesBefore, err := d.ListMemoryNodes()
	require.NoError(t, err)

	stats, err := IngestSituations(v, d)
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
	_, err := IngestSituations(v, d)
	require.NoError(t, err)

	require.NoError(t, d.SetSituationCard(sitID, "Rollback finished, watching metrics.", "", "10:00 alarm; 10:30 rollback done."))

	stats, err := IngestSituations(v, d)
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
	_, err := IngestSituations(v, d)
	require.NoError(t, err)

	require.NoError(t, d.SetSituationStatus(sitID, "done", "rollback shipped, incident closed"))

	stats, err := IngestSituations(v, d)
	require.NoError(t, err)
	assert.Equal(t, IngestStats{Finalized: 1}, stats)

	n, err := Resolve(v, d, fmt.Sprintf("situation:%d", sitID))
	require.NoError(t, err)
	assert.Equal(t, "closed", n.Status)
	assert.Equal(t, "long", n.Tier)
	assert.Contains(t, n.Body, "## Outcome\nrollback shipped, incident closed\n")

	// A finalized node is terminal for ingest: a third run changes nothing.
	stats, err = IngestSituations(v, d)
	require.NoError(t, err)
	assert.Equal(t, IngestStats{}, stats)
}

func TestIngestConvertedMentionsLink(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	toTarget := seedIngestSituation(t, d, "Billing outage")
	toTrack := seedIngestSituation(t, d, "Migration saga")
	_, err := IngestSituations(v, d)
	require.NoError(t, err)

	require.NoError(t, d.MarkSituationConverted(toTarget, 7, 0))
	require.NoError(t, d.MarkSituationConverted(toTrack, 0, 13))

	stats, err := IngestSituations(v, d)
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

	_, err = IngestSituations(v, d)
	require.NoError(t, err)
	assert.Equal(t, situationsBefore, dumpTable(t, d, "situations"), "create pass leaves situations byte-identical")

	require.NoError(t, d.SetSituationStatus(sitID, "done", "closed"))
	situationsBefore = dumpTable(t, d, "situations") // re-dump: the status change is the test's own write
	_, err = IngestSituations(v, d)
	require.NoError(t, err)

	assert.Equal(t, inboxBefore, dumpTable(t, d, "inbox_items"), "inbox_items byte-identical")
	assert.Equal(t, situationsBefore, dumpTable(t, d, "situations"), "situations byte-identical")
	assert.Equal(t, signalsBefore, dumpTable(t, d, "situation_signals"), "situation_signals byte-identical")

	var wm float64
	require.NoError(t, d.QueryRow(`SELECT inbox_last_processed_ts FROM workspace`).Scan(&wm))
	assert.Equal(t, 1752570123.5, wm, "inbox watermark untouched")
}
