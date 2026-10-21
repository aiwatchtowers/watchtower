package db

import (
	"bytes"
	"context"
	"database/sql"
	"os"
	"testing"
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
