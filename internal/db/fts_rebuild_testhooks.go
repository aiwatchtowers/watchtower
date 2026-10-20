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
