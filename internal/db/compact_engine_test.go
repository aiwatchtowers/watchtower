package db

import (
	"bytes"
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"testing"

	"watchtower/internal/sqlcipher"
)

// TestEngine_VacuumPlaintext: the SQLCipher engine VACUUMs a plaintext
// (unkeyed) file with the full schema and FTS rows in several tables, and
// db compact does so end to end. The #602 spike once saw "unable to open
// database" here; db compact VACUUMs plaintext files until Stage 3 encrypts
// them, so this is a regression test.
func TestEngine_VacuumPlaintext(t *testing.T) {
	path := compactFixture(t)
	d, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	mustOK(t, d.WithTx(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`INSERT INTO kb_documents (id, source) VALUES ('doc-1', 'acme')`); err != nil {
			return err
		}
		for i := 1; i <= 2000; i++ {
			if _, err := tx.Exec(`INSERT INTO messages (channel_id, ts, text) VALUES ('acme:C' || (?1 % 7), ?1 || '.000100', 'quarterly roadmap note ' || ?1)`, i); err != nil {
				return err
			}
			if _, err := tx.Exec(`INSERT INTO kb_chunks (doc_id, idx, body) VALUES ('doc-1', ?1, 'roadmap chunk body ' || ?1)`, i); err != nil {
				return err
			}
		}
		_, err := tx.Exec(`DELETE FROM messages WHERE rowid % 3 = 0`)
		return err
	}))
	if _, err := d.Exec(`VACUUM`); err != nil {
		t.Fatalf("VACUUM of a plaintext file: %v", err)
	}
	var hits int
	mustOK(t, d.QueryRow(`SELECT count(*) FROM kb_fts WHERE kb_fts MATCH 'roadmap'`).Scan(&hits))
	if hits != 2000 {
		t.Errorf("kb_fts hits after VACUUM = %d, want 2000", hits)
	}
	mustOK(t, d.Close())

	res, err := Compact(context.Background(), path, CompactOptions{Force: true, Version: "1.0.0"})
	if err != nil || !res.Compacted {
		t.Fatalf("Compact: (%+v, %v)", res, err)
	}
	head, err := os.ReadFile(path)
	mustOK(t, err)
	if !bytes.HasPrefix(head, []byte("SQLite format 3\x00")) {
		t.Error("the compacted file is not a plaintext SQLite file")
	}
}

// reservedBytesFixture creates a plaintext file whose pages carry 12
// reserved bytes (header byte 20), as macOS's system SQLite writes them on
// real installs, then migrates it through Open.
func reservedBytesFixture(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "watchtower.db")
	raw := sql.OpenDB(&sqlcipher.Connector{Path: path})
	conn, err := raw.Conn(context.Background())
	mustOK(t, err)
	mustOK(t, conn.Raw(func(dc any) error {
		return dc.(*sqlcipher.SQLiteConn).SetFileControlInt("main", sqlcipher.SQLITE_FCNTL_RESERVE_BYTES, 12)
	}))
	_, err = conn.ExecContext(context.Background(), `CREATE TABLE reserve_seed (x)`)
	mustOK(t, err)
	mustOK(t, conn.Close())
	mustOK(t, raw.Close())
	if got := headerReserve(t, path); got != 12 {
		t.Fatalf("fixture reserved bytes = %d, want 12", got)
	}
	d, err := Open(path)
	mustOK(t, err)
	mustOK(t, d.Close())
	stubFreeDisk(t, 1<<50)
	return path
}

func headerReserve(t *testing.T, path string) byte {
	t.Helper()
	head, err := os.ReadFile(path)
	mustOK(t, err)
	if len(head) < 100 {
		t.Fatalf("%s: short file (%d bytes)", path, len(head))
	}
	return head[20]
}

// TestEngine_CompactPlaintextWithReservedBytes: db compact VACUUMs a
// plaintext file with 12 reserved bytes per page. Unpatched SQLCipher
// attaches a keyless codec to VACUUM's temporary database whenever the main
// database has reserved bytes and fails with "unable to open database";
// internal/sqlcipher/patches/0001 attaches it only when the main database
// has a codec.
func TestEngine_CompactPlaintextWithReservedBytes(t *testing.T) {
	path := reservedBytesFixture(t)
	d, err := Open(path)
	mustOK(t, err)
	mustOK(t, d.WithTx(func(tx *sql.Tx) error {
		for i := 1; i <= 2000; i++ {
			if _, err := tx.Exec(`INSERT INTO messages (channel_id, ts, text) VALUES ('acme:C' || (?1 % 7), ?1 || '.000100', 'reserved bytes note ' || ?1)`, i); err != nil {
				return err
			}
		}
		_, err := tx.Exec(`DELETE FROM messages WHERE rowid % 3 = 0`)
		return err
	}))
	mustOK(t, d.Close())
	wantRows, wantDigest := messagesDigest(t, path)

	res, err := Compact(context.Background(), path, CompactOptions{Force: true, Version: "1.0.0"})
	if err != nil || !res.Compacted {
		t.Fatalf("Compact of a plaintext file with reserved bytes: (%+v, %v)", res, err)
	}
	gotRows, gotDigest := messagesDigest(t, path)
	if gotRows != wantRows || gotDigest != wantDigest {
		t.Errorf("messages after Compact = %d rows (digest %x), want %d (digest %x)", gotRows, gotDigest, wantRows, wantDigest)
	}
	head, err := os.ReadFile(path)
	mustOK(t, err)
	if !bytes.HasPrefix(head, []byte("SQLite format 3\x00")) {
		t.Error("the compacted file is not a plaintext SQLite file")
	}
}
