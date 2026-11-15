package state

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestChatGrant_DefaultOnForLinkedPhones: migration 00017 on a sidecar with
// a phone already linked turns its chat grant on (ask #1340), and a phone
// linked afterwards starts with it on too.
func TestChatGrant_DefaultOnForLinkedPhones(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "hub")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	raw, err := sql.Open("sqlite3", filepath.Join(dir, FileName))
	if err != nil {
		t.Fatal(err)
	}
	for _, stmt := range swiftSchema {
		if _, err := raw.Exec(stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}
	if _, err := raw.Exec(`INSERT INTO devices (device_id, name, scope, user_record_name, linked_at, signing_key, agreement_key, link_nonce)
		VALUES ('0B0B0B0B-0B0B-0B0B-0B0B-0B0B0B0B0B0B', 'phone', 'private', '', 1700000000, x'01', x'02', 'nonce1')`); err != nil {
		t.Fatal(err)
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.Close() }()

	d, ok, err := s.Device("0b0b0b0b-0b0b-0b0b-0b0b-0b0b0b0b0b0b")
	if err != nil || !ok || !d.ChatAllowed {
		t.Fatalf("an already linked phone: ChatAllowed = %v (ok %v, %v)", d.ChatAllowed, ok, err)
	}
	if err := s.WithTx(context.Background(), func(tx *sql.Tx) error {
		return LinkDevice(tx, Device{ID: "AAAAAAAA-0000-4000-8000-000000000001", Name: "new", Scope: "private", LinkedAt: time.Unix(1, 0)})
	}); err != nil {
		t.Fatal(err)
	}
	d, ok, err = s.Device("AAAAAAAA-0000-4000-8000-000000000001")
	if err != nil || !ok || !d.ChatAllowed {
		t.Fatalf("a newly linked phone: ChatAllowed = %v (ok %v, %v)", d.ChatAllowed, ok, err)
	}
}

// AnyChatPhone is true only while a linked phone holds the grant.
func TestAnyChatPhone(t *testing.T) {
	s := openTest(t)
	has := func() bool {
		t.Helper()
		ok, err := s.AnyChatPhone()
		if err != nil {
			t.Fatal(err)
		}
		return ok
	}
	if has() {
		t.Fatal("no phone linked")
	}
	id := "AAAAAAAA-0000-4000-8000-000000000002"
	if err := s.WithTx(context.Background(), func(tx *sql.Tx) error {
		return LinkDevice(tx, Device{ID: id, Name: "p", Scope: "private", LinkedAt: time.Unix(1, 0)})
	}); err != nil {
		t.Fatal(err)
	}
	if !has() {
		t.Fatal("a linked phone holds the grant by default")
	}
	if _, err := s.db.Exec(`UPDATE devices SET chat_allowed = 0`); err != nil {
		t.Fatal(err)
	}
	if has() {
		t.Fatal("the grant is off")
	}
}
