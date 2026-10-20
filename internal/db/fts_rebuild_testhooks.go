package db

import (
	"errors"
	"fmt"
	"testing"

	"github.com/pressly/goose/v3"
)

// ReplayMessagesSearchUpgradeForTest takes d back below migration 00146 and
// migrates it again — the real upgrade path over the messages d holds — so a
// test outside this package can build an install with the messages search
// fill pending. Outside a test binary it refuses (testing.Testing).
func ReplayMessagesSearchUpgradeForTest(d *DB) error {
	if !testing.Testing() {
		return errors.New("db.ReplayMessagesSearchUpgradeForTest called outside a test binary")
	}
	gooseMu.Lock()
	err := goose.DownTo(d.DB, "migrations", 145)
	gooseMu.Unlock()
	if err != nil {
		return fmt.Errorf("migrating down to 145: %w", err)
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
