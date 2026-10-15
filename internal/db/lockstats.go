package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"

	"watchtower/internal/db/lockmetrics"
)

// SampleLockStats writes one lock-health sample to the lockmetrics sink and
// returns the pool stats to pass as prev on the next call (the daemon calls
// it once per sync cycle):
//   - a pool_wait event with the time database/sql spent waiting for a free
//     connection since prev, only when that time is above zero;
//   - a wal event with the size of the -wal file and the result of
//     PRAGMA wal_checkpoint(PASSIVE), which never waits on or blocks a
//     writer. An in-memory database has no WAL file and writes none.
//
// Nothing here fails the caller: a stat or checkpoint error is recorded in
// the wal event's err. With the sink disabled it only reads the pool stats.
func (db *DB) SampleLockStats(ctx context.Context, prev sql.DBStats) sql.DBStats {
	cur := db.Stats()
	if !lockmetrics.Enabled() {
		return cur
	}
	if wait := cur.WaitDuration - prev.WaitDuration; wait > 0 {
		lockmetrics.Record(lockmetrics.Event{Kind: lockmetrics.KindPoolWait, WaitMS: wait.Milliseconds()})
	}
	db.recordWALSample(ctx)
	return cur
}

// recordWALSample writes the wal event of SampleLockStats.
func (db *DB) recordWALSample(ctx context.Context) {
	ev := lockmetrics.Event{Kind: lockmetrics.KindWAL}
	var errs []error

	var seq int
	var name, file string
	if err := db.QueryRowContext(ctx, `PRAGMA database_list`).Scan(&seq, &name, &file); err != nil {
		errs = append(errs, fmt.Errorf("database_list: %w", err))
	} else if file == "" {
		return // in-memory: no WAL file to sample
	} else if fi, err := os.Stat(file + "-wal"); err == nil {
		ev.WALBytes = fi.Size()
	} else if !errors.Is(err, os.ErrNotExist) { // no -wal yet = 0 bytes
		errs = append(errs, fmt.Errorf("stat wal: %w", err))
	}

	var busy, logFrames, ckpt int64
	if err := db.QueryRowContext(ctx, `PRAGMA wal_checkpoint(PASSIVE)`).Scan(&busy, &logFrames, &ckpt); err != nil {
		errs = append(errs, fmt.Errorf("wal_checkpoint: %w", err))
	} else {
		ev.Checkpoint = fmt.Sprintf("busy=%d log=%d ckpt=%d", busy, logFrames, ckpt)
	}
	if err := errors.Join(errs...); err != nil {
		ev.Err = err.Error()
	}
	lockmetrics.Record(ev)
}
