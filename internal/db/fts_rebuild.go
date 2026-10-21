package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"time"

	"watchtower/internal/sqlcipher"
)

// db_maintenance keys of the messages search fill: the fill's own
// (migration 00147), and the launch step's fill failure counter.
const (
	maintFTSRebuildPending         = "fts_rebuild_pending"
	maintFTSRebuildCursor          = "fts_rebuild_cursor_messages"
	maintFTSRebuildFailures        = "fts_rebuild_failures"
	maintFTSRebuildFailuresVersion = "fts_rebuild_failures_version"
)

// ftsRebuildMaxFailures consecutive fill failures of the launch step
// (RebuildMessagesSearchAt) for one CLI version stop CheckCompaction from
// reporting the fill as due until the version changes. The daemon keeps
// filling regardless.
const ftsRebuildMaxFailures = 3

// ftsRebuildChunkRows is the default number of messages rows one fill chunk
// walks.
const ftsRebuildChunkRows = 5000

// ftsRebuildChunkTextBytes bounds the indexable text one fill chunk inserts,
// beside ChunkRows: a Slack message holds up to ~40k characters, so 5000 long
// ones would be hundreds of MB in one transaction. The index here keeps its
// own copy of the text (_content) beside the inverted index, and the WAL takes
// whole pages, so a chunk writes a small multiple of its text: about 16 MiB
// of frames for 4 MiB, a quarter of ftsRebuildMinFreeBytes. A chunk takes rows
// while the text before them is under the budget, so its text stays under the
// budget plus one message, and a single message larger than the budget still
// fills a chunk of its own. Tests mutate this; no t.Parallel.
var ftsRebuildChunkTextBytes int64 = 4 << 20

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

// ftsRebuildMinFreeBytes is the free space the fill asks for. The fill frees
// the legacy index before it writes the new one (dropped, or drained and then
// dropped), and the new index, about the legacy one's size, reuses the freed
// pages, so the file does not grow. What needs room is the WAL: a chunk's
// frames (a few MB; ftsRebuildChunkTextBytes bounds them) beside the other writers' frames until the
// next checkpoint. 64 MiB is that headroom many times over and still lets a
// nearly full volume rebuild. Tests mutate this; no t.Parallel.
var ftsRebuildMinFreeBytes int64 = 64 << 20

// MessagesSearchCheck is the outcome of CheckMessagesSearchRebuild.
type MessagesSearchCheck struct {
	Pending        bool
	NeedsDiskBytes int64 // ftsRebuildMinFreeBytes while pending
	FreeDiskBytes  int64
	DiskOK         bool
}

// CheckMessagesSearchRebuild reports whether the messages search fill is
// pending and whether the volume has room for it, by reads only (it works on
// an OpenExisting handle). The fill is pending while fts_rebuild_pending is
// set or messages_fts_legacy exists: a legacy table left without its key is
// still dropped and filled. Not pending reads DiskOK with no disk read; an
// in-memory database reads DiskOK.
func (db *DB) CheckMessagesSearchRebuild() (MessagesSearchCheck, error) {
	pending, _, err := messagesSearchPending(db)
	if err != nil || !pending {
		return MessagesSearchCheck{Pending: pending, DiskOK: true}, err
	}
	file, err := mainDatabaseFile(db)
	if err != nil {
		return MessagesSearchCheck{}, err
	}
	if file == "" {
		return MessagesSearchCheck{Pending: true, NeedsDiskBytes: ftsRebuildMinFreeBytes, DiskOK: true}, nil
	}
	free, err := freeDiskBytes(filepath.Dir(file))
	if err != nil {
		return MessagesSearchCheck{}, fmt.Errorf("checking free disk space: %w", err)
	}
	return pendingMessagesSearchCheck(free), nil
}

// pendingMessagesSearchCheck applies the fill's disk rule to free bytes.
func pendingMessagesSearchCheck(free int64) MessagesSearchCheck {
	return MessagesSearchCheck{
		Pending: true, NeedsDiskBytes: ftsRebuildMinFreeBytes,
		FreeDiskBytes: free, DiskOK: free >= ftsRebuildMinFreeBytes,
	}
}

// MessagesSearchPendingAt reports whether the messages search fill is pending
// in the database at dbPath, by reads only (OpenExisting): the one thing a
// manual `db compact` reads before it runs.
func MessagesSearchPendingAt(dbPath string) (bool, error) {
	d, err := OpenExisting(dbPath, compactCheckBusy)
	if err != nil {
		return false, err
	}
	defer d.Close()
	pending, _, err := messagesSearchPending(d)
	return pending, err
}

// messagesSearchPending reads the pending key and whether the legacy table
// exists; pending is either. The Desktop's Search screen reads the same rule
// through its Swift twin, SearchQueries.messagesIndexRebuildPending
// (WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/SearchQueries.swift);
// a change here changes both, and both test the same states.
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
	// transactions (ftsLegacyDrain) before dropping it, so no single
	// transaction holds the write lock for the whole legacy index — for a
	// run beside live writers (the daemon). Without it the first chunk drops
	// the table directly (the launch step, daemon stopped).
	DrainLegacy bool
}

// FTSRebuildResult is the outcome of RebuildMessagesSearch.
type FTSRebuildResult struct {
	Done    bool  // legacy dropped, fill complete and keys cleared (also true when nothing was pending)
	Indexed int64 // index rows written by this call
	Chunks  int   // drain, drop and fill chunks committed by this call
	// DrainChunks of Chunks freed the legacy index: drain deletes
	// (DrainLegacy) and the drop.
	DrainChunks int
}

// fillChunkKind is what one fillMessagesSearchChunk call did.
type fillChunkKind int

const (
	chunkFilled    fillChunkKind = iota // indexed the next rows past the cursor
	chunkDrained                        // deleted legacy shadow rows
	chunkDropped                        // dropped the legacy table
	chunkCompleted                      // cleared the keys: nothing left to fill
)

// RebuildMessagesSearch frees messages_fts_legacy, then fills the rowid-keyed
// messages_fts left empty by migration 00147, in chunks, and clears the fill
// keys.
//
// The legacy index goes first, so the new index reuses its pages and the
// file does not grow (ftsRebuildMinFreeBytes). With opts.DrainLegacy each
// chunk deletes the next rows of the legacy shadow tables (nothing reads the
// legacy index any more) until a chunk finds them all below its limits; that
// chunk, or with DrainLegacy unset the first chunk, drops the legacy table
// and sets fts_rebuild_pending, so a legacy table that was the only pending
// mark still leads to the fill.
//
// A fill chunk is one short write transaction over the next ChunkRows
// messages rows past the cursor (fts_rebuild_cursor_messages), indexable or
// not, cut short once their indexable text reaches ftsRebuildChunkTextBytes
// (at least one row is taken): hi is the highest rowid among them, every
// indexable row in (cursor,
// hi] not already indexed is inserted under its rowid — the triggers index
// new and edited messages since the migration, so NOT EXISTS skips them —
// and the cursor moves to hi in the same transaction. Bounding by hi rather
// than limiting the indexable rows moves the cursor past runs of empty or
// deleted messages. The fill is complete when the legacy table is gone and
// no row is left past the cursor (an empty messages table included); that
// chunk deletes the fill keys and the launch step's failure counter. The
// compaction record is not touched: the freed legacy pages make the
// compaction due on their own.
//
// Nothing pending (see CheckMessagesSearchRebuild) returns Done with no
// writes. Budget stops the call between chunks, Done false, err nil; the next
// call resumes. A cancelled ctx rolls back the chunk in flight, or ends the
// pause between chunks (ftsRebuildChunkGap), and returns ctx's error,
// wrapped; committed chunks stay. A chunk error other than the cancellation
// itself that comes with a cancelled ctx is logged, not lost. Two processes
// may run it at once: each chunk re-reads the pending state, the legacy
// table and the cursor in its write transaction, and one that finds the fill
// finished by the other completes without writing a cursor.
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
				if !isInterruption(err) {
					slog.Warn("a messages search fill chunk failed while the fill was being cancelled", "error", err)
				}
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
		if kind != chunkFilled {
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

// isInterruption reports whether err is a cancellation: a context error, or
// SQLite's SQLITE_INTERRUPT from a statement the cancelled ctx interrupted.
func isInterruption(err error) bool {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var se sqlcipher.Error
	return errors.As(err, &se) && se.Code == sqlcipher.ErrInterrupt
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

// fillMessagesSearchChunk runs one chunk: a drain or the drop of the legacy
// table while it exists (freeMessagesSearchLegacy), else the fill of the next
// rows past the cursor, or the completion when no row is left past it or
// another process has finished the fill since the last chunk — the
// completion then only clears what is left.
func (db *DB) fillMessagesSearchChunk(ctx context.Context, chunkRows int, drain bool) (indexed int64, kind fillChunkKind, err error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return 0, chunkFilled, fmt.Errorf("beginning a messages search fill chunk: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	pending, hasLegacy, err := messagesSearchPending(tx)
	if err != nil {
		return 0, chunkFilled, err
	}
	if hasLegacy {
		kind, err := freeMessagesSearchLegacy(ctx, tx, drain)
		return 0, kind, err
	}
	var cursor int64
	var hi sql.NullInt64
	if pending {
		if cursor, err = readMaintenanceInt(tx, maintFTSRebuildCursor); err != nil {
			return 0, chunkFilled, err
		}
		if err := tx.QueryRowContext(ctx, fillChunkBoundQuery, cursor, chunkRows, ftsRebuildChunkTextBytes).Scan(&hi); err != nil {
			return 0, chunkFilled, fmt.Errorf("finding the next messages search fill chunk: %w", err)
		}
	}
	if !hi.Valid {
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

// fillChunkBoundQuery finds a fill chunk's hi: the highest rowid of the next
// ? (ChunkRows) messages rows past the cursor whose preceding indexable text
// in that window is under ? bytes. The first row's preceding sum is NULL, so
// it is always taken. It walks the rowid index and reads at most ChunkRows
// rows, the ones the chunk's INSERT reads anyway.
const fillChunkBoundQuery = `SELECT MAX(rowid) FROM (
	SELECT rowid, SUM(CASE WHEN text != '' AND is_deleted = 0 THEN octet_length(text) ELSE 0 END)
		OVER (ORDER BY rowid ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS before
	FROM (SELECT rowid, text, is_deleted FROM messages WHERE rowid > ? ORDER BY rowid LIMIT ?)
) WHERE before IS NULL OR before < ?`

// freeMessagesSearchLegacy frees the existing legacy table in tx and commits:
// with drain, it deletes the next legacy shadow rows (chunkDrained) unless
// they are all gone already; then, or at once without drain, it drops the
// table and sets fts_rebuild_pending (chunkDropped), so the fill still runs
// when the legacy table was the only pending mark.
func freeMessagesSearchLegacy(ctx context.Context, tx *sql.Tx, drain bool) (fillChunkKind, error) {
	if drain {
		drained, err := drainMessagesSearchLegacy(ctx, tx)
		if err != nil {
			return chunkDrained, err
		}
		if !drained {
			if err := tx.Commit(); err != nil {
				return chunkDrained, fmt.Errorf("committing a messages_fts_legacy drain chunk: %w", err)
			}
			return chunkDrained, nil
		}
	}
	if _, err := tx.ExecContext(ctx, `DROP TABLE messages_fts_legacy`); err != nil {
		return chunkDropped, fmt.Errorf("dropping messages_fts_legacy: %w", err)
	}
	if err := writeMaintenance(tx, maintFTSRebuildPending, "1"); err != nil {
		return chunkDropped, err
	}
	if err := tx.Commit(); err != nil {
		return chunkDropped, fmt.Errorf("committing the messages_fts_legacy drop: %w", err)
	}
	return chunkDropped, nil
}

// drainMessagesSearchLegacy deletes the next rows of each legacy shadow
// table, up to its ftsLegacyDrain limit, and reports whether the tables are
// now empty: every delete stayed below its limit. Deleting shadow rows
// directly leaves the FTS5 table inconsistent: until the drop, PRAGMA
// integrity_check reports "malformed inverted index for FTS5 table
// main.messages_fts_legacy". Nothing in the app runs integrity_check or reads
// the legacy index, and a DROP of the half-drained table (the launch step's
// direct drop included) works.
func drainMessagesSearchLegacy(ctx context.Context, tx *sql.Tx) (drained bool, err error) {
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

// completeMessagesSearchFill deletes the fill keys and the launch step's
// fill failure counter in tx and commits.
func completeMessagesSearchFill(ctx context.Context, tx *sql.Tx) error {
	if _, err := tx.ExecContext(ctx, `DELETE FROM db_maintenance WHERE key IN (?, ?, ?, ?)`,
		maintFTSRebuildPending, maintFTSRebuildCursor, maintFTSRebuildFailures, maintFTSRebuildFailuresVersion); err != nil {
		return fmt.Errorf("clearing the messages search fill keys: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing the messages search fill completion: %w", err)
	}
	return nil
}

// FTSRebuildRunOptions configures RebuildMessagesSearchAt.
type FTSRebuildRunOptions struct {
	Force   bool   // skip the disk rule
	Version string // CLI build version, for the fill failure counter
}

// RebuildMessagesSearchAt runs the messages search fill on the database at
// dbPath to the end, for `db compact`. It never creates the file or
// migrates. A read-only look through OpenExisting comes first, so nothing is
// opened for writing when there is nothing to do: a schema that is not
// current is skipped as schema_pending, nothing pending returns the zero
// result, and unless opts.Force a volume with less than
// ftsRebuildMinFreeBytes free is skipped as disk. Then it opens with
// OpenExistingRW and checks the schema again. A cancelled ctx is skipped as
// interrupted (committed chunks stay; the next run resumes). Skips return
// (result, nil); FTSRebuilt is set when a pending fill completed, and a call
// with nothing pending returns the zero result.
//
// A fill error is counted in fts_rebuild_failures under opts.Version (a new
// version restarts the count, the fill's completion clears it); at
// ftsRebuildMaxFailures CheckCompaction stops reporting the fill as due. A
// busy error (another process's lock) is not counted, as for the
// compaction. The error is returned either way; the count is not reported
// in the result.
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
		if IsBusy(err) {
			return res, fmt.Errorf("the database is busy (another process holds its lock); not counted as a failure: %w", err)
		}
		if _, cerr := countFailure(d, maintFTSRebuildFailures, maintFTSRebuildFailuresVersion, opts.Version); cerr != nil {
			return res, errors.Join(err, fmt.Errorf("recording the search index rebuild failure: %w", cerr))
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
