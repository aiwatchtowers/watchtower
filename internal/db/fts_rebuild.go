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

// ftsRebuildChunkHook, nil in production, runs after each committed fill
// chunk with the chunk's 1-based number within the call (test seam for the
// interrupt and concurrent-write tests). Tests mutate this; no t.Parallel.
var ftsRebuildChunkHook func(chunk int)

// ftsRebuildNeedsDiskBytes is the free space the fill asks for: the new index
// grows to about the legacy index's size, plus its WAL frames.
func ftsRebuildNeedsDiskBytes(legacy int64) int64 { return legacy * 3 / 2 }

// MessagesSearchCheck is the outcome of CheckMessagesSearchRebuild.
type MessagesSearchCheck struct {
	Pending        bool
	LegacyBytes    int64
	NeedsDiskBytes int64 // ftsRebuildNeedsDiskBytes(LegacyBytes)
	FreeDiskBytes  int64
	DiskOK         bool
}

// CheckMessagesSearchRebuild reports whether the messages search fill is
// pending and whether the volume has room for it, by reads only (it works on
// an OpenExisting handle). The fill is pending while fts_rebuild_pending is
// set or messages_fts_legacy exists: a legacy table left without its key is
// still filled and dropped. Not pending reads DiskOK with no sizes; an
// in-memory database reads DiskOK.
func (db *DB) CheckMessagesSearchRebuild() (MessagesSearchCheck, error) {
	pending, hasLegacy, err := messagesSearchPending(db)
	if err != nil || !pending {
		return MessagesSearchCheck{Pending: pending, DiskOK: true}, err
	}
	c := MessagesSearchCheck{Pending: true}
	if hasLegacy {
		// Aggregate mode: one row per table or index, summed from its pages.
		if err := db.QueryRow(`SELECT COALESCE(SUM(pgsize), 0) FROM dbstat('main', 1) WHERE name LIKE 'messages_fts_legacy%'`).Scan(&c.LegacyBytes); err != nil {
			return MessagesSearchCheck{}, fmt.Errorf("measuring messages_fts_legacy: %w", err)
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
}

// FTSRebuildResult is the outcome of RebuildMessagesSearch.
type FTSRebuildResult struct {
	Done    bool  // legacy dropped and keys cleared (also true when nothing was pending)
	Indexed int64 // index rows written by this call
	Chunks  int
}

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
// included), one transaction drops the legacy table (IF EXISTS: another
// process may have dropped it) and deletes both keys. The compaction record
// is not touched: the freed legacy pages make the compaction due on their own.
//
// Nothing pending (see CheckMessagesSearchRebuild) returns Done with no
// writes. Budget stops the call between chunks, Done false, err nil; the next
// call resumes from the cursor. A cancelled ctx rolls back the chunk in
// flight and returns ctx's error, wrapped; committed chunks stay. Safe to run
// from two processes at once: each chunk re-reads the cursor in its write
// transaction.
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
		indexed, done, err := db.fillMessagesSearchChunk(ctx, chunkRows)
		if err != nil {
			if ctx.Err() != nil {
				return res, fmt.Errorf("filling the messages search index: %w", ctx.Err())
			}
			return res, err
		}
		if done {
			res.Done = true
			return res, nil
		}
		res.Chunks++
		res.Indexed += indexed
		if ftsRebuildChunkHook != nil {
			ftsRebuildChunkHook(res.Chunks)
		}
	}
}

// fillMessagesSearchChunk runs one chunk, or the completion when no row is
// left past the cursor (done true).
func (db *DB) fillMessagesSearchChunk(ctx context.Context, chunkRows int) (indexed int64, done bool, err error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return 0, false, fmt.Errorf("beginning a messages search fill chunk: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	cursor, err := readMaintenanceInt(tx, maintFTSRebuildCursor)
	if err != nil {
		return 0, false, err
	}
	var hi sql.NullInt64
	if err := tx.QueryRowContext(ctx, `SELECT MAX(rowid) FROM (SELECT rowid FROM messages WHERE rowid > ? ORDER BY rowid LIMIT ?)`, cursor, chunkRows).Scan(&hi); err != nil {
		return 0, false, fmt.Errorf("finding the next messages search fill chunk: %w", err)
	}
	if !hi.Valid {
		if err := completeMessagesSearchFill(ctx, tx); err != nil {
			return 0, false, err
		}
		return 0, true, nil
	}
	r, err := tx.ExecContext(ctx, `INSERT INTO messages_fts(rowid, text, channel_id, ts, user_id)
		SELECT m.rowid, m.text, m.channel_id, m.ts, m.user_id FROM messages m
		WHERE m.rowid > ? AND m.rowid <= ? AND m.text != '' AND m.is_deleted = 0
		  AND NOT EXISTS (SELECT 1 FROM messages_fts f WHERE f.rowid = m.rowid)
		ORDER BY m.rowid`, cursor, hi.Int64)
	if err != nil {
		return 0, false, fmt.Errorf("filling the messages search index: %w", err)
	}
	if indexed, err = r.RowsAffected(); err != nil {
		return 0, false, fmt.Errorf("filling the messages search index: %w", err)
	}
	if err := writeMaintenance(tx, maintFTSRebuildCursor, fmt.Sprint(hi.Int64)); err != nil {
		return 0, false, err
	}
	if err := tx.Commit(); err != nil {
		return 0, false, fmt.Errorf("committing a messages search fill chunk: %w", err)
	}
	return indexed, false, nil
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
// migrates. Unless opts.Force, a volume with less free space than
// ftsRebuildNeedsDiskBytes of the legacy index is skipped as disk, read
// through OpenExisting before anything is opened for writing. Then it opens
// with OpenExistingRW; a schema that is not current is skipped as
// schema_pending. A cancelled ctx is skipped as interrupted (committed chunks
// stay; the next run resumes). Skips return (result, nil); FTSRebuilt is set
// when a pending fill completed, and a call with nothing pending returns the
// zero result.
func RebuildMessagesSearchAt(ctx context.Context, dbPath string, opts FTSRebuildRunOptions) (CompactResult, error) {
	var res CompactResult
	if !opts.Force {
		ro, err := OpenExisting(dbPath, compactCheckBusy)
		if err != nil {
			return res, err
		}
		check, err := ro.CheckMessagesSearchRebuild()
		_ = ro.Close()
		if err != nil {
			return res, err
		}
		if !check.DiskOK {
			res.Skipped = "disk"
			return res, nil
		}
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
	pending, _, err := messagesSearchPending(d)
	if err != nil || !pending {
		return res, err
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
