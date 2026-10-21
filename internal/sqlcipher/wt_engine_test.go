package sqlcipher

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// testKey is a fixed test literal (x'00…01'), never a real key.
var testKey = append(make([]byte, KeyLen-1), 0x01)

func keyFunc(k []byte) func() ([]byte, error) {
	return func() ([]byte, error) { return bytes.Clone(k), nil }
}

func openTest(t *testing.T, c *Connector) *sql.DB {
	t.Helper()
	d := sql.OpenDB(c)
	t.Cleanup(func() { _ = d.Close() })
	return d
}

// versionFile reads VERSION's "<name> <value>" lines.
func versionFile(t *testing.T) map[string]string {
	t.Helper()
	b, err := os.ReadFile("VERSION")
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		k, v, ok := strings.Cut(line, " ")
		if ok {
			out[k] = v
		}
	}
	return out
}

func TestEngine_IsSQLCipher(t *testing.T) {
	d := openTest(t, &Connector{Path: ":memory:"})
	ver := versionFile(t)

	var cipher, sqliteVer string
	if err := d.QueryRow(`PRAGMA cipher_version`).Scan(&cipher); err != nil {
		t.Fatalf("cipher_version: %v", err)
	}
	if want := strings.TrimPrefix(ver["sqlcipher"], "v"); cipher == "" || !strings.HasPrefix(cipher, want) {
		t.Errorf("cipher_version = %q, want a %q build", cipher, want)
	}
	if err := d.QueryRow(`SELECT sqlite_version()`).Scan(&sqliteVer); err != nil {
		t.Fatal(err)
	}
	if sqliteVer != ver["sqlite"] {
		t.Errorf("sqlite_version() = %q, VERSION says %q", sqliteVer, ver["sqlite"])
	}
	rows, err := d.Query(`PRAGMA compile_options`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	opts := map[string]bool{}
	for rows.Next() {
		var o string
		if err := rows.Scan(&o); err != nil {
			t.Fatal(err)
		}
		opts[o] = true
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"ENABLE_FTS5", "ENABLE_DBSTAT_VTAB", "HAS_CODEC", "TEMP_STORE=2",
		"ENABLE_MATH_FUNCTIONS", "ENABLE_STAT4", "LIKE_DOESNT_MATCH_BLOBS",
	} {
		if !opts[want] {
			t.Errorf("compile_options lacks %s", want)
		}
	}
}

// The SQL behaviour modernc.org/sqlite's build had: math functions, and a
// BLOB that never LIKE-matches a text pattern.
func TestEngine_ModerncSQLParity(t *testing.T) {
	d := openTest(t, &Connector{Path: ":memory:"})
	var ceil float64
	var blobLike int
	if err := d.QueryRow(`SELECT ceil(1.2), CAST(x'616263' AS BLOB) LIKE 'abc'`).Scan(&ceil, &blobLike); err != nil {
		t.Fatal(err)
	}
	if ceil != 2 || blobLike != 0 {
		t.Errorf("ceil(1.2) = %v, blob LIKE = %d; want 2 and 0", ceil, blobLike)
	}
}

func TestEngine_FTS5JSONBM25Smoke(t *testing.T) {
	d := openTest(t, &Connector{Path: ":memory:"})
	d.SetMaxOpenConns(1)
	for _, q := range []string{
		`CREATE VIRTUAL TABLE docs USING fts5(title, body)`,
		`INSERT INTO docs VALUES ('alpha', 'the quick brown fox'), ('beta', 'a fox and a fox again'), ('gamma', 'no match here')`,
	} {
		if _, err := d.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	rows, err := d.Query(`SELECT title, snippet(docs, 1, '[', ']', '…', 4) FROM docs WHERE docs MATCH 'fox' ORDER BY bm25(docs)`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var titles, snippets []string
	for rows.Next() {
		var title, snip string
		if err := rows.Scan(&title, &snip); err != nil {
			t.Fatal(err)
		}
		titles, snippets = append(titles, title), append(snippets, snip)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if strings.Join(titles, ",") != "beta,alpha" {
		t.Errorf("bm25 order = %v, want beta,alpha", titles)
	}
	if len(snippets) == 0 || !strings.Contains(snippets[0], "[fox]") {
		t.Errorf("snippets = %q, want a [fox] highlight", snippets)
	}

	var name string
	var n int
	if err := d.QueryRow(`SELECT json_extract('{"a":{"b":"x"}}', '$.a.b'), (SELECT count(*) FROM json_each('[1,2,3]'))`).Scan(&name, &n); err != nil {
		t.Fatal(err)
	}
	if name != "x" || n != 3 {
		t.Errorf("json_extract/json_each = %q/%d, want x/3", name, n)
	}
}

func TestEngine_KeyedRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "keyed.db")
	const marker = "watchtower-plaintext-marker-603"
	keyed := &Connector{Path: path, Params: "_journal_mode=WAL", Key: keyFunc(testKey)}

	d := sql.OpenDB(keyed)
	if _, err := d.Exec(`CREATE TABLE t (v TEXT)`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO t VALUES (?)`, marker); err != nil {
		t.Fatal(err)
	}
	var mode string
	if err := d.QueryRow(`PRAGMA journal_mode`).Scan(&mode); err != nil || mode != "wal" {
		t.Fatalf("journal_mode = %q, %v; want wal", mode, err)
	}
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.HasPrefix(raw, []byte("SQLite format 3\x00")) {
		t.Error("keyed file starts with the plaintext SQLite header")
	}
	for _, f := range []string{path, path + "-wal"} {
		b, err := os.ReadFile(f)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			t.Fatal(err)
		}
		if bytes.Contains(b, []byte(marker)) {
			t.Errorf("%s holds the marker in plaintext", filepath.Base(f))
		}
	}

	again := openTest(t, keyed)
	var got string
	if err := again.QueryRow(`SELECT v FROM t`).Scan(&got); err != nil || got != marker {
		t.Fatalf("reopen with the key: %q, %v", got, err)
	}
	_ = again.Close()

	wrong := append(make([]byte, KeyLen-1), 0x02)
	for name, c := range map[string]*Connector{
		"wrong key": {Path: path, Key: keyFunc(wrong)},
		"no key":    {Path: path},
	} {
		d := openTest(t, c)
		err := d.QueryRow(`SELECT count(*) FROM t`).Scan(new(int))
		if err == nil || !strings.Contains(err.Error(), "file is not a database") {
			t.Errorf("%s: err = %v, want file is not a database", name, err)
		}
	}

	plain := filepath.Join(t.TempDir(), "plain.db")
	p := openTest(t, &Connector{Path: plain})
	if _, err := p.Exec(`CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('x')`); err != nil {
		t.Fatal(err)
	}
	_ = p.Close()
	head, err := os.ReadFile(plain)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(head, []byte("SQLite format 3\x00")) {
		t.Error("an open without a key did not write a plaintext SQLite file")
	}
}

// Patch 0001 keeps upstream behaviour for a keyed main database: a keyless
// ATTACH of a new file and VACUUM INTO take the main database's key, so the
// copies are encrypted and open only with that key.
func TestEngine_KeyedCopiesStayEncrypted(t *testing.T) {
	dir := t.TempDir()
	const marker = "watchtower-plaintext-marker-603"
	d := openTest(t, &Connector{Path: filepath.Join(dir, "keyed.db"), Key: keyFunc(testKey)})
	d.SetMaxOpenConns(1)
	attached, into := filepath.Join(dir, "attached.db"), filepath.Join(dir, "into.db")
	for _, q := range []string{
		`CREATE TABLE t (v TEXT)`,
		`INSERT INTO t VALUES ('` + marker + `')`,
		`ATTACH DATABASE '` + attached + `' AS side`,
		`CREATE TABLE side.t (v TEXT)`,
		`INSERT INTO side.t VALUES ('` + marker + `')`,
		`DETACH DATABASE side`,
		`VACUUM INTO '` + into + `'`,
	} {
		if _, err := d.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}

	for _, path := range []string{attached, into} {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if bytes.HasPrefix(raw, []byte("SQLite format 3\x00")) || bytes.Contains(raw, []byte(marker)) {
			t.Errorf("%s is plaintext", filepath.Base(path))
		}
		var got string
		if err := openTest(t, &Connector{Path: path, Key: keyFunc(testKey)}).QueryRow(`SELECT v FROM t`).Scan(&got); err != nil || got != marker {
			t.Errorf("%s with the key: %q, %v", filepath.Base(path), got, err)
		}
		err = openTest(t, &Connector{Path: path}).QueryRow(`SELECT count(*) FROM t`).Scan(new(int))
		if err == nil || !strings.Contains(err.Error(), "file is not a database") {
			t.Errorf("%s without the key: err = %v, want file is not a database", filepath.Base(path), err)
		}
	}
}

func TestEngine_KeyErrors(t *testing.T) {
	path := filepath.Join(t.TempDir(), "k.db")
	for name, c := range map[string]*Connector{
		"short key":  {Path: path, Key: keyFunc([]byte{1, 2, 3})},
		"key error":  {Path: path, Key: func() ([]byte, error) { return nil, errors.New("locked") }},
		"nil result": {Path: path, Key: func() ([]byte, error) { return nil, nil }},
	} {
		if err := openTest(t, c).Ping(); err == nil {
			t.Errorf("%s: Ping succeeded", name)
		}
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("a refused key still created the file: %v", err)
	}
}

func TestEngine_KeyIsZeroedAfterUse(t *testing.T) {
	var handed []byte
	c := &Connector{Path: filepath.Join(t.TempDir(), "z.db"), Key: func() ([]byte, error) {
		handed = bytes.Clone(testKey)
		return handed, nil
	}}
	if err := openTest(t, c).Ping(); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(handed, make([]byte, KeyLen)) {
		t.Errorf("key bytes after open = %x, want zeroed", handed)
	}
}

// TestEngine_ReadOnlyTxIsDeferred: on a _txlock=immediate handle a ReadOnly
// transaction is a plain BEGIN and never blocks a writer on another
// connection, while a write transaction takes the write lock at BEGIN.
func TestEngine_ReadOnlyTxIsDeferred(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tx.db")
	setup := openTest(t, &Connector{Path: path, Params: "_journal_mode=WAL"})
	if _, err := setup.Exec(`CREATE TABLE t (v INTEGER)`); err != nil {
		t.Fatal(err)
	}
	a := openTest(t, &Connector{Path: path, Params: "_txlock=immediate&_busy_timeout=0"})
	b := openTest(t, &Connector{Path: path, Params: "_txlock=immediate&_busy_timeout=0"})
	ctx := context.Background()

	ro, err := a.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	if err := ro.QueryRow(`SELECT count(*) FROM t`).Scan(new(int)); err != nil {
		t.Fatal(err)
	}
	if _, err := b.Exec(`INSERT INTO t VALUES (1)`); err != nil {
		t.Errorf("a writer was blocked by a ReadOnly transaction: %v", err)
	}
	_ = ro.Rollback()

	rw, err := a.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = rw.Rollback() }()
	start := time.Now()
	_, err = b.Exec(`INSERT INTO t VALUES (2)`)
	if err == nil {
		t.Error("a writer was not blocked by an IMMEDIATE transaction")
	} else if se := (Error{}); !errors.As(err, &se) || se.Code != ErrBusy {
		t.Errorf("writer err = %v, want SQLITE_BUSY", err)
	}
	if time.Since(start) > 2*time.Second {
		t.Errorf("busy writer took %v with _busy_timeout=0", time.Since(start))
	}
}

// TestEngine_ErrorCodes pins the error shape internal/db matches on.
func TestEngine_ErrorCodes(t *testing.T) {
	d := openTest(t, &Connector{Path: ":memory:", Params: "_foreign_keys=1"})
	d.SetMaxOpenConns(1)
	if _, err := d.Exec(`CREATE TABLE p (id INTEGER PRIMARY KEY); CREATE TABLE c (pid INTEGER REFERENCES p(id))`); err != nil {
		t.Fatal(err)
	}
	_, err := d.Exec(`INSERT INTO c VALUES (7)`)
	var se Error
	if !errors.As(err, &se) || se.ExtendedCode != ErrConstraintForeignKey {
		t.Fatalf("err = %#v, want SQLITE_CONSTRAINT_FOREIGNKEY", err)
	}
	if !strings.Contains(err.Error(), "FOREIGN KEY constraint failed") {
		t.Errorf("message = %q", err.Error())
	}
}
