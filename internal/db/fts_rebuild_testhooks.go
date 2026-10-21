package db

import (
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/pressly/goose/v3"
)

// ReplayMessagesSearchUpgradeForTest takes d back below migration 00147 and
// migrates it again — the real upgrade path over the messages d holds — so a
// test outside this package can build an install with the messages search
// fill pending. Outside a test binary it refuses (testing.Testing).
func ReplayMessagesSearchUpgradeForTest(d *DB) error {
	if !testing.Testing() {
		return errors.New("db.ReplayMessagesSearchUpgradeForTest called outside a test binary")
	}
	gooseMu.Lock()
	err := goose.DownTo(d.DB, "migrations", 146)
	gooseMu.Unlock()
	if err != nil {
		return fmt.Errorf("migrating down to 146: %w", err)
	}
	return d.migrate()
}

// SetFTSRebuildChunkHookForTest installs fn as the hook RebuildMessagesSearch
// runs after each committed chunk, for cmd's `db compact` tests, which cannot
// reach ftsRebuildChunkHook. Returns a restore func the caller must invoke
// (typically via t.Cleanup). Outside a test binary it panics
// (testing.Testing).
func SetFTSRebuildChunkHookForTest(fn func(chunk int)) (restore func()) {
	if !testing.Testing() {
		panic("db.SetFTSRebuildChunkHookForTest called outside a test binary")
	}
	prev := ftsRebuildChunkHook
	ftsRebuildChunkHook = fn
	return func() { ftsRebuildChunkHook = prev }
}

// SetFTSLegacyDrainRowsForTest sets the rows one drain chunk deletes from
// every legacy shadow table (ftsLegacyDrain), for the daemon's tests, which
// cannot reach it. Returns a restore func the caller must invoke (typically
// via t.Cleanup). Outside a test binary it panics (testing.Testing).
func SetFTSLegacyDrainRowsForTest(rows int) (restore func()) {
	if !testing.Testing() {
		panic("db.SetFTSLegacyDrainRowsForTest called outside a test binary")
	}
	prev := ftsLegacyDrain
	next := append(ftsLegacyDrain[:0:0], ftsLegacyDrain...)
	for i := range next {
		next[i].rows = rows
	}
	ftsLegacyDrain = next
	return func() { ftsLegacyDrain = prev }
}

// SetFTSRebuildChunkGapForTest sets the pause between fill chunks
// (ftsRebuildChunkGap), for the daemon's tests, which cannot reach it.
// Returns a restore func the caller must invoke (typically via t.Cleanup).
// Outside a test binary it panics (testing.Testing).
func SetFTSRebuildChunkGapForTest(gap time.Duration) (restore func()) {
	if !testing.Testing() {
		panic("db.SetFTSRebuildChunkGapForTest called outside a test binary")
	}
	prev := ftsRebuildChunkGap
	ftsRebuildChunkGap = gap
	return func() { ftsRebuildChunkGap = prev }
}

// SetFTSRebuildMinFreeBytesForTest sets the fill's free-space floor
// (ftsRebuildMinFreeBytes), for the daemon's tests, which cannot reach it.
// Returns a restore func the caller must invoke (typically via t.Cleanup).
// Outside a test binary it panics (testing.Testing).
func SetFTSRebuildMinFreeBytesForTest(n int64) (restore func()) {
	if !testing.Testing() {
		panic("db.SetFTSRebuildMinFreeBytesForTest called outside a test binary")
	}
	prev := ftsRebuildMinFreeBytes
	ftsRebuildMinFreeBytes = n
	return func() { ftsRebuildMinFreeBytes = prev }
}
