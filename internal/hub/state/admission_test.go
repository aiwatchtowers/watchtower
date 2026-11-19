package state

import (
	"context"
	"database/sql"
	"testing"
	"time"
)

// TestRelayAdmittedAtIsATimestamp: devices.relay_admitted_at is a REAL
// timestamp column (no content, so it needs no allowlist class), nullable,
// and NULL on a fresh link.
func TestRelayAdmittedAtIsATimestamp(t *testing.T) {
	s := openTest(t)
	var typ string
	var notNull int
	if err := s.db.QueryRow(`SELECT type, "notnull" FROM pragma_table_info('devices') WHERE name = 'relay_admitted_at'`).
		Scan(&typ, &notNull); err != nil {
		t.Fatal(err)
	}
	if typ != "REAL" || notNull != 0 || textual(typ) {
		t.Fatalf("relay_admitted_at is %q (not null %d), want a nullable REAL", typ, notNull)
	}
	if _, listed := sidecarColumns["devices.relay_admitted_at"]; listed {
		t.Fatal("a REAL column must not be in the text allowlist")
	}
}

// MarkRelayAdmitted stamps only the linked phones it names that carry no
// stamp yet, keeps the first stamp, and a re-link clears it.
func TestMarkRelayAdmittedStampsOnceAndARelinkClears(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	link := func(id, relay string) {
		t.Helper()
		if err := s.WithTx(ctx, func(tx *sql.Tx) error {
			return LinkDevice(tx, Device{ID: id, Name: "phone", Scope: "private", LinkedAt: time.Unix(1, 0), RelayDeviceID: relay})
		}); err != nil {
			t.Fatal(err)
		}
	}
	const a, b = "0A0A0A0A-0A0A-0A0A-0A0A-0A0A0A0A0A0A", "0B0B0B0B-0B0B-0B0B-0B0B-0B0B0B0B0B0B"
	link(a, "relay-a")
	link(b, "relay-b")
	first, later := time.Unix(1_700_000_000, 0), time.Unix(1_800_000_000, 0)
	if n, err := s.MarkRelayAdmitted([]string{"relay-a", "relay-x", ""}, first); err != nil || n != 1 {
		t.Fatalf("stamped %d, %v", n, err)
	}
	if n, err := s.MarkRelayAdmitted([]string{"relay-a"}, later); err != nil || n != 0 {
		t.Fatalf("stamped again %d, %v", n, err)
	}
	da, _, _ := s.Device(a)
	db, _, _ := s.Device(b)
	if !da.RelayAdmittedAt.Equal(first) || !db.RelayAdmittedAt.IsZero() {
		t.Fatalf("stamps a=%v b=%v", da.RelayAdmittedAt, db.RelayAdmittedAt)
	}
	link(a, "relay-a")
	if d, _, _ := s.Device(a); !d.RelayAdmittedAt.IsZero() {
		t.Fatalf("a re-link kept the stamp %v", d.RelayAdmittedAt)
	}
}
