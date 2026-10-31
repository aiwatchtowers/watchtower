package state

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"
)

// swiftSchema is the CREATE text today's Swift hub (HubSyncState and its
// extensions) leaves in hubstate.db, the ALTER TABLE columns included in
// the order the Swift code adds them, copied so a Go change cannot drift
// from the file the Swift hub writes.
var swiftSchema = []string{
	`CREATE TABLE IF NOT EXISTS slice_state (record_name TEXT PRIMARY KEY, payload_hash TEXT NOT NULL, pushed_at REAL NOT NULL DEFAULT 0)`,
	`CREATE TABLE IF NOT EXISTS hub_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
	`CREATE TABLE IF NOT EXISTS work_alerts (key TEXT PRIMARY KEY, seen_at REAL NOT NULL, pushed_at REAL, generation INTEGER NOT NULL)`,
	`CREATE TABLE IF NOT EXISTS relay_processed (record_name TEXT PRIMARY KEY, phase TEXT NOT NULL CHECK (phase IN ('begun', 'done')), outcome TEXT, updated_at REAL NOT NULL DEFAULT 0, echo BLOB, done_seq INTEGER)`,
	`CREATE TABLE IF NOT EXISTS ask_answer_deliveries (record_name TEXT PRIMARY KEY, delivery TEXT NOT NULL, at REAL NOT NULL)`,
	`CREATE TABLE IF NOT EXISTS phone_recordings (upload_id TEXT PRIMARY KEY, audio_path TEXT NOT NULL, transcript_id INTEGER, status TEXT NOT NULL, percent INTEGER, error TEXT, updated_at REAL NOT NULL)`,
	`CREATE TABLE IF NOT EXISTS session_reports (session_id INTEGER PRIMARY KEY, payload BLOB NOT NULL, fetched_at REAL NOT NULL)`,
	`CREATE TABLE IF NOT EXISTS session_milestones (session_id INTEGER NOT NULL, at REAL NOT NULL, kind TEXT NOT NULL CHECK (kind = 'state'), text TEXT NOT NULL, ref INTEGER)`,
	`CREATE INDEX IF NOT EXISTS session_milestones_by_session ON session_milestones (session_id, at)`,
	`CREATE TABLE IF NOT EXISTS held_session_lines (record_name TEXT PRIMARY KEY, action BLOB NOT NULL, session_id INTEGER NOT NULL, line TEXT NOT NULL, run INTEGER, launch TEXT NOT NULL, reason TEXT NOT NULL, typing INTEGER NOT NULL DEFAULT 0)`,
	`CREATE TABLE IF NOT EXISTS link_codes (nonce TEXT PRIMARY KEY, issued_at REAL NOT NULL, exp REAL NOT NULL, used_by_device TEXT, used_at REAL)`,
	`CREATE TABLE IF NOT EXISTS devices (device_id TEXT PRIMARY KEY, name TEXT NOT NULL, scope TEXT NOT NULL, user_record_name TEXT NOT NULL, linked_at REAL NOT NULL, typing_allowed INTEGER NOT NULL DEFAULT 0, start_sessions_allowed INTEGER NOT NULL DEFAULT 1, decided_at REAL, typing_requested INTEGER NOT NULL DEFAULT 0, permissions_allowed INTEGER NOT NULL DEFAULT 0, permissions_requested INTEGER NOT NULL DEFAULT 0, start_sessions_granted INTEGER NOT NULL DEFAULT 0)`,
	`CREATE TABLE IF NOT EXISTS link_refusals (device_id TEXT PRIMARY KEY, name TEXT NOT NULL, scope TEXT NOT NULL, reason TEXT NOT NULL, at REAL NOT NULL)`,
	`CREATE TABLE IF NOT EXISTS hub_epochs (epoch INTEGER PRIMARY KEY, sealed_keys BLOB NOT NULL, created_at REAL NOT NULL, first_seq INTEGER NOT NULL, retired_at REAL)`,
	`CREATE TABLE IF NOT EXISTS pending_devices (device_id TEXT PRIMARY KEY, name TEXT, model TEXT, scope TEXT, user_record_name TEXT, signing_key BLOB, agreement_key BLOB, link_nonce TEXT, sas TEXT, received_at REAL, typing_requested INTEGER NOT NULL DEFAULT 0, confirm_nonce BLOB, start_sessions INTEGER NOT NULL DEFAULT 1)`,
	`CREATE TABLE IF NOT EXISTS revoked_devices (device_id TEXT PRIMARY KEY, agreement_key BLOB NOT NULL, removed_at REAL NOT NULL, name TEXT, scope TEXT)`,
	`CREATE TABLE IF NOT EXISTS relay_seen (wire_name TEXT NOT NULL, sender_id TEXT NOT NULL, epoch INTEGER NOT NULL, seq INTEGER NOT NULL, at REAL NOT NULL, PRIMARY KEY (wire_name, sender_id))`,
	`ALTER TABLE devices ADD COLUMN signing_key BLOB`,
	`ALTER TABLE devices ADD COLUMN agreement_key BLOB`,
	`ALTER TABLE devices ADD COLUMN link_nonce TEXT`,
	`ALTER TABLE devices ADD COLUMN last_seq INTEGER`,
	`ALTER TABLE link_refusals ADD COLUMN agreement_key BLOB`,
	`ALTER TABLE link_codes ADD COLUMN confirm_nonces_drawn INTEGER NOT NULL DEFAULT 0`,
	`ALTER TABLE slice_state ADD COLUMN wire_name TEXT`,
	`CREATE INDEX IF NOT EXISTS slice_state_by_wire ON slice_state (wire_name)`,
	`CREATE TABLE IF NOT EXISTS slice_assets (file_path TEXT PRIMARY KEY, descriptor BLOB NOT NULL)`,
}

func TestSwiftShapedFileMigrates(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "hub")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	raw, err := sql.Open("sqlite3", filepath.Join(dir, "hubstate.db"))
	if err != nil {
		t.Fatal(err)
	}
	for _, stmt := range swiftSchema {
		if _, err := raw.Exec(stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}
	if _, err := raw.Exec(`INSERT INTO devices (device_id, name, scope, user_record_name, linked_at, typing_allowed, start_sessions_granted, signing_key, agreement_key, link_nonce)
		VALUES ('0B0B0B0B-0B0B-0B0B-0B0B-0B0B0B0B0B0B', 'phone', 'shared', '_acme', 1700000000.5, 1, 1, x'0102', x'0304', 'nonce1')`); err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec(`INSERT INTO hub_meta (key, value) VALUES ('hub_id', 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA')`); err != nil {
		t.Fatal(err)
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(dir)
	if err != nil {
		t.Fatalf("Open over a Swift-shaped file: %v", err)
	}
	defer func() { _ = s.Close() }()

	for _, col := range []string{"last_applied_action_seq", "ordered", "relay_device_id", "resend_requested_from", "acked_epoch"} {
		var n int
		if err := s.db.QueryRow(`SELECT count(*) FROM pragma_table_info('devices') WHERE name = ?`, col).Scan(&n); err != nil || n != 1 {
			t.Fatalf("devices.%s present = %d %v", col, n, err)
		}
	}
	for _, table := range []string{"control_queue", "held_actions", "zone_tokens"} {
		var n int
		if err := s.db.QueryRow(`SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?`, table).Scan(&n); err != nil || n != 1 {
			t.Fatalf("table %s present = %d %v", table, n, err)
		}
	}
	d, ok, err := s.Device("0b0b0b0b-0b0b-0b0b-0b0b-0b0b0b0b0b0b")
	if err != nil || !ok {
		t.Fatalf("Device after migration = %v %v", ok, err)
	}
	if d.Name != "phone" || d.Scope != "shared" || !d.TypingAllowed || !d.StartSessionsAllowed || !d.StartSessionsGranted ||
		string(d.SigningKey) != "\x01\x02" || string(d.AgreementKey) != "\x03\x04" || d.LinkNonce != "nonce1" ||
		d.LastAppliedActionSeq != 0 || d.Ordered || d.RelayDeviceID != "" || d.LinkedAt.UnixMilli() != 1_700_000_000_500 {
		t.Fatalf("device row = %+v", d)
	}
	if v, ok, err := s.Meta(MetaHubID); err != nil || !ok || v != "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA" {
		t.Fatalf("hub_id = %q %v %v", v, ok, err)
	}
}

// TestBaselineMatchesSwiftColumns pins the baseline's columns, per table and
// in order, to the Swift-shaped file's: a fresh Go file and an adopted Swift
// file have the same shape before 00002.
func TestBaselineMatchesSwiftColumns(t *testing.T) {
	swift, err := sql.Open("sqlite3", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = swift.Close() }()
	swift.SetMaxOpenConns(1)
	for _, stmt := range swiftSchema {
		if _, err := swift.Exec(stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}
	s := openTest(t)
	tables := func(db *sql.DB) map[string]string {
		rows, err := db.Query(`SELECT m.name, group_concat(p.name || ' ' || p.type || ' ' || p."notnull" || ' ' || ifnull(p.dflt_value, '') || ' ' || p.pk, ', ' ORDER BY p.cid)
			FROM sqlite_master m JOIN pragma_table_info(m.name) p
			WHERE m.type = 'table' AND m.name NOT LIKE 'goose%' AND m.name NOT LIKE 'sqlite%'
				-- 00002's and 00004's appended devices columns and 00003's pending_devices column: the baseline is what is pinned here.
				AND NOT (m.name = 'devices' AND p.name IN ('last_applied_action_seq', 'ordered', 'relay_device_id', 'resend_requested_from', 'acked_epoch'))
				AND NOT (m.name = 'pending_devices' AND p.name = 'relay_device_id')
			GROUP BY m.name ORDER BY m.name`)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		out := map[string]string{}
		for rows.Next() {
			var n, c string
			if err := rows.Scan(&n, &c); err != nil {
				t.Fatal(err)
			}
			out[n] = c
		}
		return out
	}
	want := tables(swift)
	got := tables(s.db)
	go2 := map[string]bool{"control_queue": true, "held_actions": true, "zone_tokens": true, "recording_jobs": true, "held_uploads": true}
	for name, cols := range want {
		if got[name] != cols {
			t.Errorf("table %s:\n go    %s\n swift %s", name, got[name], cols)
		}
	}
	for name := range got {
		if _, ok := want[name]; !ok && !go2[name] {
			t.Errorf("table %s is not in the Swift sidecar", name)
		}
	}
}
