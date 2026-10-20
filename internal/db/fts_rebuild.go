package db

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"time"
)

// db_maintenance keys of the messages search fill (migration 00146).
const (
	maintFTSRebuildPending = "fts_rebuild_pending"
	maintFTSRebuildCursor  = "fts_rebuild_cursor_messages"
)

// ftsRebuildChunkRows is the default number of messages rows one fill chunk
// walks.
const ftsRebuildChunkRows = 5000

// ftsRebuildChunkGap is the pause after each committed chunk, so a writer
// waiting on the lock gets in: SQLite's busy handler sleeps in steps that
// grow to 100 ms, and a waiter only takes the lock if it wakes while it is
// free. Tests set it to 0; they mutate it, no t.Parallel.
var ftsRebuildChunkGap = 100 * time.Millisecond

// ftsRebuildChunkHook, nil in production, runs after each committed fill
// chunk with the chunk's 1-based number within the call (test seam for the
// interrupt and concurrent-write tests). Tests mutate this; no t.Parallel.
var ftsRebuildChunkHook func(chunk int)

// ftsLegacyDrain lists the legacy index's rowid shadow tables a draining
// completion empties, with the rows one drain chunk deletes from each: a
// _data row is a segment page of up to ~4 KB, the others hold one small row
// per message. On synthetic data one DROP of a 2M-message legacy index held
// the write lock for about 0.5 s, past a hook's lock budget, while drain
// chunks of about these sizes held it for tens of milliseconds. Tests mutate
// this; no t.Parallel.
var ftsLegacyDrain = []struct {
	table  string
	delete string // deletes the table's first ? rows
	rows   int
}{
	{"messages_fts_legacy_data", `DELETE FROM messages_fts_legacy_data WHERE rowid IN (SELECT rowid FROM messages_fts_legacy_data ORDER BY rowid LIMIT ?)`, 150},
	{"messages_fts_legacy_content", `DELETE FROM messages_fts_legacy_content WHERE rowid IN (SELECT rowid FROM messages_fts_legacy_content ORDER BY rowid LIMIT ?)`, 1500},
	{"messages_fts_legacy_docsize", `DELETE FROM messages_fts_legacy_docsize WHERE rowid IN (SELECT rowid FROM messages_fts_legacy_docsize ORDER BY rowid LIMIT ?)`, 1500},
}

// ftsRebuildNeedsDiskBytes is the free space the fill asks for: the new index
// grows to about the legacy index's size, plus its WAL frames.
func ftsRebuildNeedsDiskBytes(legacy int64) int64 { return legacy * 3 / 2 }

// MessagesSearchCheck is the outcome of CheckMessagesSearchRebuild.
type MessagesSearchCheck struct {
	Pending bool
	// FillDone: the cursor is past the last message, so only dropping (or
	// draining) the legacy index is left. Freeing space needs none: no
	// sizes are read and DiskOK is true.
	FillDone       bool
	LegacyBytes    int64
	NeedsDiskBytes int64 // ftsRebuildNeedsDiskBytes(LegacyBytes)
	FreeDiskBytes  int64
	DiskOK         bool
}

// CheckMessagesSearchRebuild reports whether the messages search fill is
// pending and whether the volume has room for it, by reads only (it works on
// an OpenExisting handle). The fill is pending while fts_rebuild_pending is
// set or messages_fts_legacy exists: a legacy table left without its key is
// still filled and dropped. Not pending or FillDone reads DiskOK with no
// sizes (FillDone skips the dbstat walk of the legacy pages); an in-memory
// database reads DiskOK.
func (db *DB) CheckMessagesSearchRebuild() (MessagesSearchCheck, error) {
	pending, hasLegacy, err := messagesSearchPending(db)
	if err != nil || !pending {
		return MessagesSearchCheck{Pending: pending, DiskOK: true}, err
	}
	c := MessagesSearchCheck{Pending: true}
	if c.FillDone, err = messagesSearchFillDone(db); err != nil {
		return MessagesSearchCheck{}, err
	}
	if c.FillDone {
		c.DiskOK = true
		return c, nil
	}
	if hasLegacy {
		if c.LegacyBytes, err = legacySearchBytes(db); err != nil {
			return MessagesSearchCheck{}, err
		}
	}
	c.NeedsDiskBytes = ftsRebuildNeedsDiskBytes(c.LegacyBytes)
	file, err := mainDatabaseFile(db)
	if err != nil {
		return MessagesSearchCheck{}, err
	}
	if file == "" {
		c.DiskOK = true
		return c, nil
	}
	if c.FreeDiskBytes, err = freeDiskBytes(filepath.Dir(file)); err != nil {
		return MessagesSearchCheck{}, fmt.Errorf("checking free disk space: %w", err)
	}
	c.DiskOK = c.FreeDiskBytes >= c.NeedsDiskBytes
	return c, nil
}

// messagesSearchFillDone reports whether the fill cursor has reached the
// highest messages rowid (an empty messages table included). Both reads are
// O(log n).
func messagesSearchFillDone(q queryRower) (bool, error) {
	cursor, err := readMaintenanceInt(q, maintFTSRebuildCursor)
	if err != nil {
		return false, err
	}
	var maxRowid int64
	if err := q.QueryRow(`SELECT COALESCE(MAX(rowid), 0) FROM messages`).Scan(&maxRowid); err != nil {
		return false, fmt.Errorf("reading the last messages rowid: %w", err)
	}
	return cursor >= maxRowid, nil
}

// legacySearchBytes sums the pages of messages_fts_legacy and its shadow
// tables. dbstat is asked one name at a time: it pushes `name =` down into
// its scan, while a LIKE would walk every b-tree of the file.
func legacySearchBytes(db *DB) (int64, error) {
	names, err := legacySearchTables(db)
	if err != nil {
		return 0, err
	}
	var total int64
	for _, name := range names {
		var n int64
		// Aggregate mode: one row per table, summed from its pages.
		if err := db.QueryRow(`SELECT COALESCE(SUM(pgsize), 0) FROM dbstat('main', 1) WHERE name = ?`, name).Scan(&n); err != nil {
			return 0, fmt.Errorf("measuring %s: %w", name, err)
		}
		total += n
	}
	return total, nil
}

// legacySearchTables lists messages_fts_legacy and its shadow tables.
func legacySearchTables(db *DB) ([]string, error) {
	rows, err := db.Query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'messages_fts_legacy%'`)
	if err != nil {
		return nil, fmt.Errorf("listing the messages_fts_legacy tables: %w", err)
	}
	defer rows.Close()
	var names []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, fmt.Errorf("listing the messages_fts_legacy tables: %w", err)
		}
		names = append(names, name)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing the messages_fts_legacy tables: %w", err)
	}
	return names, nil
}

// messagesSearchPending reads the pending key and whether the legacy table
// exists; pending is either.
func messagesSearchPending(q queryRower) (pending, hasLegacy bool, err error) {
	if _, pending, err = readMaintenance(q, maintFTSRebuildPending); err != nil {
		return false, false, err
	}
	if err := q.QueryRow(`SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'messages_fts_legacy')`).Scan(&hasLegacy); err != nil {
		return false, false, fmt.Errorf("looking up messages_fts_legacy: %w", err)
	}
	return pending || hasLegacy, hasLegacy, nil
}

// mainDatabaseFile is the main database's file path, "" for an in-memory
// database.
func mainDatabaseFile(q *DB) (string, error) {
	rows, err := q.Query(`PRAGMA database_list`)
	if err != nil {
		return "", fmt.Errorf("reading database_list: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var seq int
		var name, file string
		if err := rows.Scan(&seq, &name, &file); err != nil {
			return "", fmt.Errorf("reading database_list: %w", err)
		}
		if name == "main" {
			return file, nil
		}
	}
	if err := rows.Err(); err != nil {
		return "", fmt.Errorf("reading database_list: %w", err)
	}
	return "", nil
}

// FTSRebuildOptions configures RebuildMessagesSearch.
type FTSRebuildOptions struct {
	Budget    time.Duration // 0 = until done; checked between chunks, at least one chunk runs
	ChunkRows int           // 0 = 5000
	// DrainLegacy empties messages_fts_legacy's shadow tables in chunk
	// transactions (ftsLegacyDrain) before the completion drops it, so no
	// single transaction holds the write lock for the whole legacy index —
	// for a run beside live writers (the daemon). Without it the completion
	// drops the table directly (the launch step, daemon stopped).
	DrainLegacy bool
}

// FTSRebuildResult is the outcome of RebuildMessagesSearch.
type FTSRebuildResult struct {
	Done    bool  // legacy dropped and keys cleared (also true when nothing was pending)
	Indexed int64 // index rows written by this call
	Chunks  int   // fill and drain chunks committed by this call
	// DrainChunks of Chunks deleted legacy shadow rows (DrainLegacy).
	DrainChunks int
}

// fillChunkKind is what one fillMessagesSearchChunk call did.
type fillChunkKind int

const (
	chunkFilled    fillChunkKind = iota // indexed the next rows past the cursor
	chunkDrained                        // deleted legacy shadow rows
	chunkCompleted                      // dropped the legacy table and cleared the keys
)

// RebuildMessagesSearch fills the rowid-keyed messages_fts left empty by
// migration 00146, in chunks, and then drops messages_fts_legacy and clears
// the fill keys.
//
// A chunk is one short write transaction over the next ChunkRows messages
// rows past the cursor (fts_rebuild_cursor_messages), indexable or not: hi is
// the highest rowid among them, every indexable row in (cursor, hi] not
// already indexed is inserted under its rowid — the triggers index new and
// edited messages since the migration, so NOT EXISTS skips them — and the
// cursor moves to hi in the same transaction. Bounding by hi rather than
// limiting the indexable rows moves the cursor past runs of empty or deleted
// messages. When no row is left past the cursor (an empty messages table
// included) and opts.DrainLegacy is set, each further chunk deletes the next
// rows of the legacy shadow tables (nothing reads the legacy index any more)
// until a chunk finds them all below its limits; that chunk, or with
// DrainLegacy unset the first one past the cursor, drops the legacy table (IF EXISTS: another
// process may have dropped it) and deletes both keys. The compaction record
// is not touched: the freed legacy pages make the compaction due on their own.
//
// Nothing pending (see CheckMessagesSearchRebuild) returns Done with no
// writes. Budget stops the call between chunks, Done false, err nil; the next
// call resumes from the cursor. A cancelled ctx rolls back the chunk in
// flight, or ends the pause between chunks (ftsRebuildChunkGap), and returns
// ctx's error, wrapped; committed chunks stay. Two processes may run it at
// once: each chunk re-reads the pending state and the cursor in its write
// transaction, and one that finds the fill finished by the other completes
// without writing a cursor.
func (db *DB) RebuildMessagesSearch(ctx context.Context, opts FTSRebuildOptions) (FTSRebuildResult, error) {
	var res FTSRebuildResult
	pending, _, err := messagesSearchPending(db)
	if err != nil {
		return res, err
	}
	if !pending {
		res.Done = true
		return res, nil
	}
	chunkRows := opts.ChunkRows
	if chunkRows <= 0 {
		chunkRows = ftsRebuildChunkRows
	}
	start := time.Now()
	for {
		if err := ctx.Err(); err != nil {
			return res, fmt.Errorf("filling the messages search index: %w", err)
		}
		if res.Chunks > 0 && opts.Budget > 0 && time.Since(start) >= opts.Budget {
			return res, nil
		}
		indexed, kind, err := db.fillMessagesSearchChunk(ctx, chunkRows, opts.DrainLegacy)
		if err != nil {
			if ctx.Err() != nil {
				return res, fmt.Errorf("filling the messages search index: %w", ctx.Err())
			}
			return res, err
		}
		if kind == chunkCompleted {
			res.Done = true
			return res, nil
		}
		res.Chunks++
		res.Indexed += indexed
		if kind == chunkDrained {
			res.DrainChunks++
		}
		if ftsRebuildChunkHook != nil {
			ftsRebuildChunkHook(res.Chunks)
		}
		if err := waitChunkGap(ctx); err != nil {
			return res, fmt.Errorf("filling the messages search index: %w", err)
		}
	}
}

// waitChunkGap waits ftsRebuildChunkGap, or until ctx is done.
func waitChunkGap(ctx context.Context) error {
	if ftsRebuildChunkGap <= 0 {
		return ctx.Err()
	}
	t := time.NewTimer(ftsRebuildChunkGap)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// fillMessagesSearchChunk runs one chunk, or the completion when
// no row is left past the cursor or another process has finished the fill
// since the last chunk — the completion then only clears what is left. With
// drain set, a chunk past the cursor deletes legacy shadow rows first and
// completes only when they are all gone.
func (db *DB) fillMessagesSearchChunk(ctx context.Context, chunkRows int, drain bool) (indexed int64, kind fillChunkKind, err error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return 0, chunkFilled, fmt.Errorf("beginning a messages search fill chunk: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	pending, _, err := messagesSearchPending(tx)
	if err != nil {
		return 0, chunkFilled, err
	}
	var cursor int64
	var hi sql.NullInt64
	if pending {
		if cursor, err = readMaintenanceInt(tx, maintFTSRebuildCursor); err != nil {
			return 0, chunkFilled, err
		}
		if err := tx.QueryRowContext(ctx, `SELECT MAX(rowid) FROM (SELECT rowid FROM messages WHERE rowid > ? ORDER BY rowid LIMIT ?)`, cursor, chunkRows).Scan(&hi); err != nil {
			return 0, chunkFilled, fmt.Errorf("finding the next messages search fill chunk: %w", err)
		}
	}
	if !hi.Valid {
		if pending && drain {
			drained, err := drainMessagesSearchLegacy(ctx, tx)
			if err != nil {
				return 0, chunkFilled, err
			}
			if !drained {
				if err := tx.Commit(); err != nil {
					return 0, chunkFilled, fmt.Errorf("committing a messages_fts_legacy drain chunk: %w", err)
				}
				return 0, chunkDrained, nil
			}
		}
		if err := completeMessagesSearchFill(ctx, tx); err != nil {
			return 0, chunkFilled, err
		}
		return 0, chunkCompleted, nil
	}
	r, err := tx.ExecContext(ctx, `INSERT INTO messages_fts(rowid, text, channel_id, ts, user_id)
		SELECT m.rowid, m.text, m.channel_id, m.ts, m.user_id FROM messages m
		WHERE m.rowid > ? AND m.rowid <= ? AND m.text != '' AND m.is_deleted = 0
		  AND NOT EXISTS (SELECT 1 FROM messages_fts f WHERE f.rowid = m.rowid)
		ORDER BY m.rowid`, cursor, hi.Int64)
	if err != nil {
		return 0, chunkFilled, fmt.Errorf("filling the messages search index: %w", err)
	}
	if indexed, err = r.RowsAffected(); err != nil {
		return 0, chunkFilled, fmt.Errorf("filling the messages search index: %w", err)
	}
	if err := writeMaintenance(tx, maintFTSRebuildCursor, fmt.Sprint(hi.Int64)); err != nil {
		return 0, chunkFilled, err
	}
	if err := tx.Commit(); err != nil {
		return 0, chunkFilled, fmt.Errorf("committing a messages search fill chunk: %w", err)
	}
	return indexed, chunkFilled, nil
}

// drainMessagesSearchLegacy deletes the next rows of each legacy shadow
// table, up to its ftsLegacyDrain limit, and reports whether the tables are
// now empty: every delete stayed below its limit (or the legacy table is
// gone). Deleting shadow rows directly leaves the FTS5 table inconsistent:
// until the completion drops it, PRAGMA integrity_check reports "malformed
// inverted index for FTS5 table main.messages_fts_legacy". Nothing in the
// app runs integrity_check or reads the legacy index, and a DROP of the
// half-drained table (the launch step's direct completion included) works.
func drainMessagesSearchLegacy(ctx context.Context, tx *sql.Tx) (drained bool, err error) {
	var exists bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'messages_fts_legacy')`).Scan(&exists); err != nil {
		return false, fmt.Errorf("looking up messages_fts_legacy: %w", err)
	}
	if !exists {
		return true, nil
	}
	drained = true
	for _, d := range ftsLegacyDrain {
		r, err := tx.ExecContext(ctx, d.delete, d.rows)
		if err != nil {
			return false, fmt.Errorf("draining %s: %w", d.table, err)
		}
		n, err := r.RowsAffected()
		if err != nil {
			return false, fmt.Errorf("draining %s: %w", d.table, err)
		}
		if n >= int64(d.rows) {
			drained = false
		}
	}
	return drained, nil
}

func completeMessagesSearchFill(ctx context.Context, tx *sql.Tx) error {
	if _, err := tx.ExecContext(ctx, `DROP TABLE IF EXISTS messages_fts_legacy`); err != nil {
		return fmt.Errorf("dropping messages_fts_legacy: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM db_maintenance WHERE key IN (?, ?)`, maintFTSRebuildPending, maintFTSRebuildCursor); err != nil {
		return fmt.Errorf("clearing the messages search fill keys: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing the messages search fill completion: %w", err)
	}
	return nil
}

// FTSRebuildRunOptions configures RebuildMessagesSearchAt.
type FTSRebuildRunOptions struct{ Force bool } // Force skips the disk rule

// RebuildMessagesSearchAt runs the messages search fill on the database at
// dbPath to the end, for `db compact`. It never creates the file or
// migrates. A read-only look through OpenExisting comes first, so nothing is
// opened for writing when there is nothing to do: a schema that is not
// current is skipped as schema_pending, nothing pending returns the zero
// result, and unless opts.Force a volume with less free space than
// ftsRebuildNeedsDiskBytes of the legacy index is skipped as disk. Then it
// opens with OpenExistingRW and checks the schema again. A cancelled ctx is skipped as interrupted (committed chunks
// stay; the next run resumes). Skips return (result, nil); FTSRebuilt is set
// when a pending fill completed, and a call with nothing pending returns the
// zero result.
func RebuildMessagesSearchAt(ctx context.Context, dbPath string, opts FTSRebuildRunOptions) (CompactResult, error) {
	var res CompactResult
	ro, err := OpenExisting(dbPath, compactCheckBusy)
	if err != nil {
		return res, err
	}
	skipped, pending, err := checkMessagesSearchRun(ro, opts)
	_ = ro.Close()
	if err != nil {
		return res, err
	}
	if skipped != "" || !pending {
		res.Skipped = skipped
		return res, nil
	}

	d, err := OpenExistingRW(dbPath, compactBusy)
	if err != nil {
		return res, err
	}
	defer d.Close()
	current, err := d.schemaCurrentErr()
	if err != nil {
		return res, err
	}
	if !current {
		res.Skipped = "schema_pending"
		return res, nil
	}
	if _, err := d.RebuildMessagesSearch(ctx, FTSRebuildOptions{}); err != nil {
		if ctx.Err() != nil {
			res.Skipped = "interrupted"
			return res, nil
		}
		return res, err
	}
	res.FTSRebuilt = true
	return res, nil
}

// checkMessagesSearchRun is RebuildMessagesSearchAt's read-only look: the
// skip reason (schema_pending, disk), or "" with whether the fill is pending.
func checkMessagesSearchRun(ro *DB, opts FTSRebuildRunOptions) (skipped string, pending bool, err error) {
	current, err := ro.schemaCurrentErr()
	if err != nil {
		return "", false, err
	}
	if !current {
		return "schema_pending", false, nil
	}
	check, err := ro.CheckMessagesSearchRebuild()
	if err != nil {
		return "", false, err
	}
	if check.Pending && !opts.Force && !check.DiskOK {
		return "disk", true, nil
	}
	return "", check.Pending, nil
}
