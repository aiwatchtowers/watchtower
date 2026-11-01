package adopt

import (
	"database/sql"
	"path/filepath"
	"testing"

	"watchtower/internal/hub/state"
)

// TestAdoptAddsEveryMissingFoldedInColumnFromAWALSource: a WAL-mode Swift
// file missing a folded-in column adopts too — the copy goes DELETE before
// the repairs, so the dry run sees them.
func TestAdoptAddsEveryMissingFoldedInColumnFromAWALSource(t *testing.T) {
	for _, c := range foldedIn {
		t.Run(c.table+"."+c.column, func(t *testing.T) {
			drop := dropColumn(c.table, c.column)
			f := newFixtureIn(t, t.TempDir(), func(db *sql.DB) error {
				if err := drop(db); err != nil {
					return err
				}
				var m string
				if err := db.QueryRow(`PRAGMA journal_mode = WAL`).Scan(&m); err != nil || m != "wal" {
					t.Fatalf("journal mode = %q %v", m, err)
				}
				return nil
			})
			if res, err := f.run(t); err != nil || res.Step != StepDone {
				t.Fatalf("Run = %+v %v", res, err)
			}
			has, _, err := hasColumn(f.goDB(t), c.table, c.column)
			if err != nil || !has {
				t.Fatalf("column after adoption = %v %v", has, err)
			}
		})
	}
}

// TestAnIdleOpenSwiftHandleIsNotDetected documents noOpenTransaction's
// limit: an open handle with no transaction (an idle Swift hub) holds no
// lock, so Run goes ahead. Stopping the Swift hub is the caller's job
// (Desktop's adoption driver, plan Task 22).
func TestAnIdleOpenSwiftHandleIsNotDetected(t *testing.T) {
	f := newFixture(t)
	db, err := rawOpen(filepath.Join(f.mobile, state.FileName), openRW)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = db.Close() }()
	if err := db.Ping(); err != nil {
		t.Fatal(err)
	}
	if res, err := f.run(t); err != nil || res.Step != StepDone {
		t.Fatalf("Run beside an idle handle = %+v %v", res, err)
	}
}
