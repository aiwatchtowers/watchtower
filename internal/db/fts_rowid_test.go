package db

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// queryInt runs a single-integer query.
func queryInt(t *testing.T, q interface {
	QueryRow(string, ...any) *sql.Row
}, query string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, q.QueryRow(query, args...).Scan(&n), query)
	return n
}

func hasSchemaTable(t *testing.T, q interface {
	QueryRow(string, ...any) *sql.Row
}, name string) bool {
	t.Helper()
	return queryInt(t, q, `SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?`, name) > 0
}

func maintenanceKeyCount(t *testing.T, q interface {
	QueryRow(string, ...any) *sql.Row
}) int {
	t.Helper()
	return queryInt(t, q, `SELECT COUNT(*) FROM db_maintenance WHERE key IN ('fts_rebuild_pending', 'fts_rebuild_cursor_messages')`)
}

// messagesIndexMismatches counts index rows with no message under their
// rowid, or one whose key columns differ.
const messagesIndexMismatches = `SELECT COUNT(*) FROM messages_fts f LEFT JOIN messages m ON m.rowid = f.rowid
	WHERE m.rowid IS NULL OR m.channel_id != f.channel_id OR m.ts != f.ts`

func TestMessagesFTS_TriggersKeepOneRowPerIndexableMessage(t *testing.T) {
	t.Parallel()
	d := openTestDB(t)
	// The live message goes in last, so its rowid is not the index's first.
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, is_deleted) VALUES
		('C1', '1.000002', 'U1', '', 0),
		('C1', '1.000003', 'U1', 'gone text', 1),
		('C1', '1.000001', 'U1', 'alpha live', 0)`)
	require.NoError(t, err)

	live := queryInt(t, d, `SELECT rowid FROM messages WHERE ts = '1.000001'`)
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))
	assert.Equal(t, live, queryInt(t, d, `SELECT rowid FROM messages_fts`))

	_, err = d.Exec(`UPDATE messages SET text = 'bravo edited' WHERE ts = '1.000001'`)
	require.NoError(t, err)
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'bravo'`))
	assert.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'alpha'`))
	assert.Equal(t, live, queryInt(t, d, `SELECT rowid FROM messages_fts`))

	_, err = d.Exec(`UPDATE messages SET is_deleted = 1 WHERE ts = '1.000001'`)
	require.NoError(t, err)
	assert.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))
	_, err = d.Exec(`UPDATE messages SET is_deleted = 0 WHERE ts = '1.000001'`)
	require.NoError(t, err)
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))
	assert.Zero(t, queryInt(t, d, messagesIndexMismatches))

	_, err = d.Exec(`UPDATE messages SET text = '' WHERE ts = '1.000001'`)
	require.NoError(t, err)
	assert.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))
	_, err = d.Exec(`UPDATE messages SET text = 'charlie back' WHERE ts = '1.000001'`)
	require.NoError(t, err)
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))

	_, err = d.Exec(`DELETE FROM messages WHERE ts = '1.000001'`)
	require.NoError(t, err)
	assert.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))
	assert.Zero(t, queryInt(t, d, messagesIndexMismatches))
}

func TestMessagesFTS_ReinsertUnderExistingRowidStaysConsistent(t *testing.T) {
	t.Parallel()
	d := openTestDB(t)
	const r = 4242
	_, err := d.Exec(`INSERT INTO messages_fts(rowid, text, channel_id, ts, user_id) VALUES (?, 'stray words', 'C9', '9.000001', 'U9')`, r)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO messages (rowid, channel_id, ts, user_id, text) VALUES (?, 'C1', '1.000001', 'U1', 'fresh words')`, r)
	require.NoError(t, err)

	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts WHERE rowid = ?`, r))
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'fresh'`))
	assert.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'stray'`))
	assert.Zero(t, queryInt(t, d, messagesIndexMismatches))
}

func TestMessagesFTS_UpsertKeepsRowid(t *testing.T) {
	t.Parallel()
	d := openTestDB(t)
	require.NoError(t, d.UpsertMessage(Message{ChannelID: "C1", TS: "1.000001", UserID: "U1", Text: "first wording"}))
	before := queryInt(t, d, `SELECT rowid FROM messages WHERE channel_id = 'C1' AND ts = '1.000001'`)
	require.NoError(t, d.UpsertMessage(Message{ChannelID: "C1", TS: "1.000001", UserID: "U1", Text: "second wording"}))

	assert.Equal(t, before, queryInt(t, d, `SELECT rowid FROM messages WHERE channel_id = 'C1' AND ts = '1.000001'`))
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'second'`))
	assert.Equal(t, before, queryInt(t, d, `SELECT rowid FROM messages_fts`))
}

func TestTranscriptsFTS_TriggersKeyedByID(t *testing.T) {
	t.Parallel()
	d := openTestDB(t)
	id, err := d.InsertMeetingTranscript(MeetingTranscript{Title: "Sync", TranscriptText: "payments roadmap"})
	require.NoError(t, err)

	check := func(step string, want int) {
		t.Helper()
		assert.Equal(t, want, queryInt(t, d, `SELECT COUNT(*) FROM transcripts_fts`), step)
		if want > 0 {
			assert.Equal(t, int(id), queryInt(t, d, `SELECT rowid FROM transcripts_fts`), step)
			assert.Equal(t, int(id), queryInt(t, d, `SELECT transcript_id FROM transcripts_fts`), step)
		}
	}
	check("insert", 1)
	_, err = d.Exec(`UPDATE meeting_transcripts SET transcript_text = 'invoicing plan' WHERE id = ?`, id)
	require.NoError(t, err)
	check("update text", 1)
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM transcripts_fts WHERE transcripts_fts MATCH 'invoicing'`))
	_, err = d.Exec(`UPDATE meeting_transcripts SET title = 'Renamed' WHERE id = ?`, id)
	require.NoError(t, err)
	check("update title", 1)
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM transcripts_fts WHERE title = 'Renamed'`))
	_, err = d.Exec(`UPDATE meeting_transcripts SET transcript_text = '' WHERE id = ?`, id)
	require.NoError(t, err)
	check("empty text", 0)
	_, err = d.Exec(`DELETE FROM meeting_transcripts WHERE id = ?`, id)
	require.NoError(t, err)
	check("delete", 0)
}

// planDetail returns the EXPLAIN QUERY PLAN details of query, joined.
func planDetail(t *testing.T, d *DB, query string) string {
	t.Helper()
	rows, err := d.Query(`EXPLAIN QUERY PLAN ` + query)
	require.NoError(t, err)
	defer rows.Close()
	var parts []string
	for rows.Next() {
		var id, parent, notUsed int
		var detail string
		require.NoError(t, rows.Scan(&id, &parent, &notUsed, &detail))
		parts = append(parts, detail)
	}
	require.NoError(t, rows.Err())
	return strings.Join(parts, "; ")
}

// The triggers' DELETE by rowid is a lookup, not the scan a DELETE by an
// UNINDEXED column is.
func TestFTSWrites_UseRowidLookup(t *testing.T) {
	t.Parallel()
	d := openTestDB(t)
	for _, c := range []struct{ rowid, column string }{
		{`DELETE FROM messages_fts WHERE rowid = 1`, `DELETE FROM messages_fts WHERE channel_id = 'c' AND ts = 't'`},
		{`DELETE FROM transcripts_fts WHERE rowid = 1`, `DELETE FROM transcripts_fts WHERE transcript_id = 1`},
	} {
		byRowid := planDetail(t, d, c.rowid)
		byColumn := planDetail(t, d, c.column)
		assert.Contains(t, byRowid, "VIRTUAL TABLE INDEX 0:=", c.rowid)
		assert.NotEqual(t, byRowid, byColumn, "the rowid plan must differ from the column scan")
	}
	// The triggers issue the rowid form.
	for trig, want := range map[string]string{
		"messages_ai":            "DELETE FROM messages_fts WHERE rowid = NEW.rowid",
		"messages_au":            "DELETE FROM messages_fts WHERE rowid = OLD.rowid",
		"messages_ad":            "DELETE FROM messages_fts WHERE rowid = OLD.rowid",
		"meeting_transcripts_ai": "DELETE FROM transcripts_fts WHERE rowid = NEW.id",
		"meeting_transcripts_au": "DELETE FROM transcripts_fts WHERE rowid = OLD.id",
		"meeting_transcripts_ad": "DELETE FROM transcripts_fts WHERE rowid = OLD.id",
	} {
		var body string
		require.NoError(t, d.QueryRow(`SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?`, trig).Scan(&body))
		assert.Contains(t, body, want, trig)
	}
}

// cpuTime is the CPU time the whole process spends in f (user + system).
func cpuTime(t *testing.T, f func()) time.Duration {
	t.Helper()
	runtime.GC() // a collection owed by an earlier run is not f's
	before := processCPU(t)
	f()
	return processCPU(t) - before
}

func processCPU(t *testing.T) time.Duration {
	t.Helper()
	var ru syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &ru); err != nil {
		t.Fatalf("getrusage: %v", err)
	}
	return time.Duration(ru.Utime.Nano() + ru.Stime.Nano())
}

// insertMessages inserts n indexable messages in channel ch in one
// transaction.
func insertMessages(t *testing.T, d *DB, ch string, n int) {
	t.Helper()
	tx, err := d.Begin()
	require.NoError(t, err)
	defer func() { _ = tx.Rollback() }()
	stmt, err := tx.Prepare(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES (?, ?, 'U1', ?)`)
	require.NoError(t, err)
	defer stmt.Close()
	for i := range n {
		_, err := stmt.Exec(ch, fmt.Sprintf("%d.%06d", 1700000000+i, i), fmt.Sprintf("message %d about topic%d", i, i%97))
		require.NoError(t, err)
	}
	require.NoError(t, tx.Commit())
}

// A message write costs about the same whatever the index size: a rowid
// lookup grows as log n, a scan of the index as n. With the index eight
// times larger, a scan would take ~8x as long; the bound is the geometric
// mean of 1 and 8. Mutation check (the column-keyed DELETE restored in
// messages_ai): ratio 6.0 against 0.9 with the rowid trigger.
func TestMessagesFTS_WriteCostDoesNotGrowWithIndex(t *testing.T) {
	if raceSlowdown > 1 {
		t.Skip("CPU-time scaling check: the race detector distorts it")
	}
	const batch = 1000
	sizes := []int{2000, 16000}
	dbs := make([]*DB, len(sizes))
	for i, n := range sizes {
		dbs[i] = openTestDB(t)
		insertMessages(t, dbs[i], "CFILL", n)
	}
	best := make([]time.Duration, len(sizes))
	for round := range 3 {
		for i, d := range dbs {
			ch := fmt.Sprintf("CBATCH%d", round)
			took := cpuTime(t, func() { insertMessages(t, d, ch, batch) })
			if round == 0 || took < best[i] {
				best[i] = took
			}
			_, err := d.Exec(`DELETE FROM messages WHERE channel_id = ?`, ch)
			require.NoError(t, err)
		}
	}
	ratio := float64(best[1]) / float64(best[0])
	t.Logf("batch of %d: %v at %d indexed, %v at %d indexed, ratio %.2f", batch, best[0], sizes[0], best[1], sizes[1], ratio)
	assert.Less(t, ratio, 2.83, "a message write must not scan the whole index")
}

// rawFileDBAt opens a new database file migrated to version with goose alone.
func rawFileDBAt(t *testing.T, version int64) *DB {
	t.Helper()
	raw, err := sql.Open("sqlite3", filepath.Join(t.TempDir(), "wt.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = raw.Close() })
	raw.SetMaxOpenConns(1)
	_, err = raw.Exec("PRAGMA foreign_keys=ON")
	require.NoError(t, err)
	require.NoError(t, gooseUpTo(raw, "migrations", version))
	return &DB{DB: raw}
}

func TestMigration147_UpgradeKeepsLegacyAndMarksPending(t *testing.T) {
	t.Parallel()
	d := rawFileDBAt(t, 146)
	for i := range 10 {
		_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', ?, 'U1', ?)`,
			fmt.Sprintf("1.%06d", i), fmt.Sprintf("indexable %d", i))
		require.NoError(t, err)
	}
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, is_deleted) VALUES
		('C1', '2.000001', 'U1', '', 0), ('C1', '2.000002', 'U1', 'tombstoned', 1)`)
	require.NoError(t, err)
	for _, title := range []string{"Payments sync", "Payments review"} {
		_, err := d.Exec(`INSERT INTO meeting_transcripts (title, transcript_text) VALUES (?, 'payments roadmap talk')`, title)
		require.NoError(t, err)
	}
	hitsBefore, err := d.SearchTranscripts("payments", 10)
	require.NoError(t, err)
	require.Len(t, hitsBefore, 2)

	require.NoError(t, d.migrate())

	require.True(t, hasSchemaTable(t, d, "messages_fts_legacy"))
	assert.Equal(t, 10, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts_legacy`))
	assert.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))
	var pending string
	require.NoError(t, d.QueryRow(`SELECT value FROM db_maintenance WHERE key = 'fts_rebuild_pending'`).Scan(&pending))
	assert.Equal(t, "1", pending)
	assert.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM transcripts_fts f LEFT JOIN meeting_transcripts m ON m.id = f.rowid
		WHERE m.id IS NULL OR f.transcript_id != m.id`))
	assert.Equal(t, 2, queryInt(t, d, `SELECT COUNT(*) FROM transcripts_fts`))
	hitsAfter, err := d.SearchTranscripts("payments", 10)
	require.NoError(t, err)
	assert.Equal(t, hitsBefore, hitsAfter)
}

func TestMigration147_FreshInstallHasNoLegacy(t *testing.T) {
	t.Parallel()
	d := openTestDB(t)
	assert.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'messages_fts_legacy%'`))
	assert.Zero(t, maintenanceKeyCount(t, d))

	f, err := openMigratingFresh(t, filepath.Join(t.TempDir(), "fresh.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = f.Close() })
	assert.Zero(t, queryInt(t, f, `SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'messages_fts_legacy%'`))
	assert.Zero(t, maintenanceKeyCount(t, f))
}

func TestMigration147_OnlyNonIndexableRowsDropsLegacy(t *testing.T) {
	t.Parallel()
	d := rawFileDBAt(t, 146)
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, is_deleted) VALUES
		('C1', '1.000001', 'U1', '', 0), ('C1', '1.000002', 'U1', 'tombstoned', 1)`)
	require.NoError(t, err)

	require.NoError(t, d.migrate())

	assert.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'messages_fts_legacy%'`))
	assert.Zero(t, maintenanceKeyCount(t, d))
}

func TestMigration147_DownRestoresColumnKeyedIndexes(t *testing.T) {
	t.Parallel()
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, is_deleted) VALUES
		('C1', '1.000001', 'U1', 'kept one', 0), ('C1', '1.000002', 'U1', 'kept two', 0),
		('C1', '1.000003', 'U1', '', 0), ('C1', '1.000004', 'U1', 'tombstoned', 1)`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO meeting_transcripts (title, transcript_text) VALUES ('Sync', 'payments roadmap')`)
	require.NoError(t, err)
	require.NoError(t, ReplayMessagesSearchUpgradeForTest(d))
	require.True(t, hasSchemaTable(t, d, "messages_fts_legacy"))
	_, err = d.Exec(`INSERT INTO db_maintenance (key, value) VALUES ('fts_rebuild_cursor_messages', '1')`)
	require.NoError(t, err)

	require.NoError(t, gooseDownTo(d.DB, "migrations", 146))

	assert.False(t, hasSchemaTable(t, d, "messages_fts_legacy"))
	assert.Equal(t, 2, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts WHERE channel_id = 'C1' AND ts = '1.000002'`))
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM transcripts_fts`))
	for _, trig := range []string{"messages_ai", "messages_ad", "messages_au"} {
		var body string
		require.NoError(t, d.QueryRow(`SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?`, trig).Scan(&body))
		col := "NEW"
		if trig != "messages_ai" {
			col = "OLD"
		}
		assert.Contains(t, body, "channel_id = "+col+".channel_id", trig)
	}
	assert.Zero(t, maintenanceKeyCount(t, d))

	require.NoError(t, gooseUp(d.DB, "migrations"))
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM db_maintenance WHERE key = 'fts_rebuild_pending' AND value = '1'`))
}

func TestSchemaDrift_ToleratesLegacyTable(t *testing.T) {
	t.Parallel()
	d := openTestDB(t)
	require.NoError(t, d.UpsertMessage(Message{ChannelID: "C1", TS: "1.000001", UserID: "U1", Text: "indexable"}))
	require.NoError(t, ReplayMessagesSearchUpgradeForTest(d))
	require.True(t, hasSchemaTable(t, d, "messages_fts_legacy"))
	assert.NoError(t, d.CheckSchemaDrift())
}

// A failed post-goose cleanup does not fail migrate: the legacy table and
// the pending key stay for the fill to finish.
func TestMigration147_CleanupFailureDoesNotFailMigrate(t *testing.T) {
	t.Parallel()
	d := rawFileDBAt(t, 147)
	require.True(t, hasSchemaTable(t, d, "messages_fts_legacy"), "goose alone keeps the legacy table")
	// Without db_maintenance the cleanup's DELETE fails and its tx rolls back.
	_, err := d.Exec(`DROP TABLE db_maintenance`)
	require.NoError(t, err)

	require.NoError(t, d.migrate())

	assert.True(t, hasSchemaTable(t, d, "messages_fts_legacy"), "the failed cleanup rolled back")
}

// While the fill is pending, new and edited messages go to the new index
// only; the legacy index is left as the migration renamed it.
func TestMessagesFTS_WritesDuringPendingFillSkipLegacy(t *testing.T) {
	t.Parallel()
	d := openTestDB(t)
	require.NoError(t, d.UpsertMessage(Message{ChannelID: "C1", TS: "1.000001", UserID: "U1", Text: "old wording"}))
	require.NoError(t, ReplayMessagesSearchUpgradeForTest(d))
	require.True(t, hasSchemaTable(t, d, "messages_fts_legacy"))
	require.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts_legacy`))
	require.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))

	require.NoError(t, d.UpsertMessage(Message{ChannelID: "C1", TS: "1.000002", UserID: "U1", Text: "brand new"}))
	require.NoError(t, d.UpsertMessage(Message{ChannelID: "C1", TS: "1.000001", UserID: "U1", Text: "edited wording"}))

	assert.Equal(t, 2, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts`))
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'brand'`))
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'edited'`))
	assert.Zero(t, queryInt(t, d, messagesIndexMismatches))
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts_legacy`))
	assert.Equal(t, 1, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts_legacy WHERE messages_fts_legacy MATCH 'old'`))
	assert.Zero(t, queryInt(t, d, `SELECT COUNT(*) FROM messages_fts_legacy WHERE messages_fts_legacy MATCH 'brand OR edited'`))
}
