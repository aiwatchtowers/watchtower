package state

import (
	"context"
	"database/sql"
	"testing"
	"time"
)

// ICloudRoutes: a row carries an iCloud route only with an iCloud user (a
// CloudKit link); a relay link, or a CloudKit link whose owner could not be
// read, has none.
func TestICloudRoutesSaysWhichRowsCarryAnICloudUser(t *testing.T) {
	s := openTest(t)
	link := func(id, user string) {
		t.Helper()
		if err := s.WithTx(context.Background(), func(tx *sql.Tx) error {
			if err := LinkDevice(tx, Device{ID: id, Name: id, Scope: "private", LinkedAt: time.Now()}); err != nil {
				return err
			}
			_, err := tx.Exec(`UPDATE devices SET user_record_name = ? WHERE device_id = ? COLLATE NOCASE`, user, id)
			return err
		}); err != nil {
			t.Fatal(err)
		}
	}
	link("AAAAAAAA-0000-4000-8000-000000000001", "_user")
	link("AAAAAAAA-0000-4000-8000-000000000002", "")
	got, err := s.ICloudRoutes()
	if err != nil || len(got) != 2 || !got["aaaaaaaa-0000-4000-8000-000000000001"] || got["aaaaaaaa-0000-4000-8000-000000000002"] {
		t.Fatalf("routes %v, %v", got, err)
	}
}
