package state

import (
	"context"
	"database/sql"
	"errors"
	"strconv"
	"testing"
	"time"
)

func reopen(t *testing.T, dir string) *Store {
	t.Helper()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func wantRecordings(t *testing.T, s *Store, on, stored bool) {
	t.Helper()
	gotOn, gotStored, err := s.Recordings()
	if err != nil || gotOn != on || gotStored != stored {
		t.Fatalf("Recordings = %v stored=%v err=%v, want %v stored=%v", gotOn, gotStored, err, on, stored)
	}
}

func TestRecordingsDefaultIsOnIfDesktopWasEverSeen(t *testing.T) {
	s := openTest(t)
	if err := s.Heartbeat(time.Unix(1_800_000_000, 0)); err != nil {
		t.Fatal(err)
	}
	wantRecordings(t, s, true, false)
}

func TestRecordingsDefaultIsOffWithoutDesktop(t *testing.T) {
	s := openTest(t)
	wantRecordings(t, s, false, false)
	if _, ok, err := s.DesktopSeenAt(); err != nil || ok {
		t.Fatalf("DesktopSeenAt on a fresh sidecar: ok=%v err=%v", ok, err)
	}
}

func TestStoredRecordingsValueWins(t *testing.T) {
	s := openTest(t)
	if err := s.Heartbeat(time.Unix(1_800_000_000, 0)); err != nil {
		t.Fatal(err)
	}
	if err := s.SetRecordings(false); err != nil {
		t.Fatal(err)
	}
	wantRecordings(t, s, false, true)
	if err := s.Heartbeat(time.Unix(1_800_000_100, 0)); err != nil {
		t.Fatal(err)
	}
	wantRecordings(t, s, false, true) // a heartbeat never turns the switch on
	if err := s.SetRecordings(true); err != nil {
		t.Fatal(err)
	}
	wantRecordings(t, s, true, true)
}

func TestRecordingsOnRefusedWithoutDesktopSeen(t *testing.T) {
	s := openTest(t)
	if err := s.SetRecordings(true); !errors.Is(err, ErrNoTranscriber) {
		t.Fatalf("SetRecordings(true) = %v, want ErrNoTranscriber", err)
	}
	wantRecordings(t, s, false, false) // nothing stored
	if err := s.SetRecordings(false); err != nil {
		t.Fatal(err)
	}
	wantRecordings(t, s, false, true)
}

// Protocol §9's required test: the default survives a restart with no new
// heartbeat.
func TestDesktopSeenAtSurvivesARestart(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t0 := time.Unix(1_800_000_000, 0).UTC()
	if err := s.Heartbeat(t0); err != nil {
		t.Fatal(err)
	}
	if err := s.Heartbeat(t0.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s = reopen(t, dir)
	wantRecordings(t, s, true, false)
	at, ok, err := s.DesktopSeenAt()
	if err != nil || !ok || !at.Equal(t0) {
		t.Fatalf("DesktopSeenAt = %v %v %v, want the first beat %v", at, ok, err, t0)
	}
}

func TestDesktopSeenCarriedOverOnce(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	// A Plan 1b sidecar: the flag and the last beat, no desktop_seen_at.
	if err := s.SetMeta(MetaDesktopSeen, "1"); err != nil {
		t.Fatal(err)
	}
	if err := s.SetMeta(MetaDesktopAt, "1800000000.500"); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s = reopen(t, dir)
	raw, ok, err := s.Meta(MetaDesktopSeenAt)
	if err != nil || !ok || raw != "1800000000.500" {
		t.Fatalf("desktop_seen_at = %q %v %v, want desktop_at's value", raw, ok, err)
	}
	wantRecordings(t, s, true, false)
	// A later beat moves desktop_at; another open changes nothing.
	if err := s.SetMeta(MetaDesktopAt, "1800009999.000"); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s = reopen(t, dir)
	if raw, _, _ := s.Meta(MetaDesktopSeenAt); raw != "1800000000.500" {
		t.Fatalf("a second open rewrote desktop_seen_at: %q", raw)
	}
}

func TestDesktopSeenAtIsATimestamp(t *testing.T) {
	s := openTest(t)
	if err := s.Heartbeat(time.Unix(1_800_000_000, 0)); err != nil {
		t.Fatal(err)
	}
	raw, ok, err := s.Meta(MetaDesktopSeenAt)
	if err != nil || !ok {
		t.Fatalf("desktop_seen_at unset: %v", err)
	}
	if _, err := strconv.ParseFloat(raw, 64); err != nil {
		t.Fatalf("desktop_seen_at %q is not REAL seconds", raw)
	}
	if err := s.SetRecordings(false); err != nil {
		t.Fatal(err)
	}
	if v, _, _ := s.Meta(MetaRecordings); v != "off" {
		t.Fatalf("recordings = %q, want the enum off", v)
	}
}

func TestHeldUploadKeepsItsFirstHoldTime(t *testing.T) {
	s := openTest(t)
	t0 := time.Unix(1_800_000_000, 0).UTC()
	in := func(fn func(tx *sql.Tx) error) error { return s.WithTx(context.Background(), fn) }
	hold := func(at time.Time) {
		t.Helper()
		if err := in(func(tx *sql.Tx) error { return HoldUpload(tx, "u1", "aabb", at) }); err != nil {
			t.Fatal(err)
		}
	}
	hold(t0)
	hold(t0.Add(time.Hour))
	got, err := s.HeldUploads()
	if err != nil || len(got) != 1 || got[0].UploadID != "u1" || got[0].DeviceID != "AABB" || !got[0].HeldAt.Equal(t0) {
		t.Fatalf("held = %+v %v", got, err)
	}
	if err := in(func(tx *sql.Tx) error { return SettleHeldUpload(tx, "u1", HeldExpired, t0.Add(HeldUploadMaxAge)) }); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.HeldUploads(); len(got) != 0 {
		t.Fatalf("a settled upload is still held: %+v", got)
	}
	// Settling again, or settling an upload never held, changes nothing.
	if err := in(func(tx *sql.Tx) error { return SettleHeldUpload(tx, "u1", HeldReceived, t0) }); err != nil {
		t.Fatal(err)
	}
	if err := in(func(tx *sql.Tx) error { return SettleHeldUpload(tx, "never", HeldReceived, t0) }); err != nil {
		t.Fatal(err)
	}
	// Held again after it was settled (the phone sent it once more): a new first hold.
	t1 := t0.Add(8 * 24 * time.Hour)
	hold(t1)
	if got, _ := s.HeldUploads(); len(got) != 1 || !got[0].HeldAt.Equal(t1) {
		t.Fatalf("held again = %+v", got)
	}
	if err := in(func(tx *sql.Tx) error { return SettleHeldUpload(tx, "u1", "bogus", t1) }); err == nil {
		t.Fatal("an unknown outcome was stored")
	}
}
