// Command interop is the Go half of the Go↔Swift engine interop test
// (WatchtowerDesktop/Tests/Core/SQLCipherInteropTests.swift, board #603). It
// is a test-only helper: scripts/build-app.sh builds only the repository
// root, so this never ships. Every subcommand prints one JSON object on
// stdout; a failure prints {"error": "..."} and exits 1.
//
//	interop write --path P [--key-hex H]
//	interop read --path P [--key-hex H] --expect-table T
//	interop versions
package main

import (
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"regexp"

	"watchtower/internal/sqlcipher"
)

// The shape write builds: ftsRows chunks (every tenth one holds ftsKeyword),
// then batchTxs transactions of batchRows rows each.
const (
	ftsRows    = 2000
	batchTxs   = 200
	batchRows  = 50
	ftsKeyword = "lighthouse"
)

func main() {
	out, err := run(os.Args[1:])
	if err != nil {
		out = map[string]any{"error": err.Error()}
	}
	if encErr := json.NewEncoder(os.Stdout).Encode(out); encErr != nil {
		fmt.Fprintln(os.Stderr, encErr)
		os.Exit(1)
	}
	if err != nil {
		os.Exit(1)
	}
}

func run(args []string) (map[string]any, error) {
	if len(args) == 0 {
		return nil, errors.New("usage: interop write|read|versions [flags]")
	}
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	path := fs.String("path", "", "database file")
	keyHex := fs.String("key-hex", "", "raw 32-byte key as 64 hex digits; empty opens without a key")
	table := fs.String("expect-table", "", "read: the table the Swift side created")
	if err := fs.Parse(args[1:]); err != nil {
		return nil, err
	}
	switch args[0] {
	case "versions":
		return versions()
	case "write":
		if *path == "" {
			return nil, errors.New("write needs --path")
		}
		return write(*path, *keyHex)
	case "read":
		if *path == "" || *table == "" {
			return nil, errors.New("read needs --path and --expect-table")
		}
		return read(*path, *keyHex, *table)
	default:
		return nil, fmt.Errorf("unknown subcommand %q", args[0])
	}
}

// open returns a one-connection handle on path, keyed when keyHex is set.
func open(path, keyHex string) (*sql.DB, error) {
	c := &sqlcipher.Connector{Path: path, Params: "_busy_timeout=5000"}
	if keyHex != "" {
		key, err := hex.DecodeString(keyHex)
		if err != nil {
			return nil, fmt.Errorf("--key-hex: %w", err)
		}
		if len(key) != sqlcipher.KeyLen {
			return nil, fmt.Errorf("--key-hex is %d bytes, want %d", len(key), sqlcipher.KeyLen)
		}
		c.Key = func() ([]byte, error) { return append([]byte(nil), key...), nil }
	}
	d := sql.OpenDB(c)
	d.SetMaxOpenConns(1)
	return d, nil
}

func versions() (map[string]any, error) {
	d, err := open(":memory:", "")
	if err != nil {
		return nil, err
	}
	defer d.Close()
	var cipher, sqliteVer string
	if err := d.QueryRow(`PRAGMA cipher_version`).Scan(&cipher); err != nil {
		return nil, fmt.Errorf("cipher_version: %w", err)
	}
	if err := d.QueryRow(`SELECT sqlite_version()`).Scan(&sqliteVer); err != nil {
		return nil, fmt.Errorf("sqlite_version: %w", err)
	}
	return map[string]any{"cipher_version": cipher, "sqlite_version": sqliteVer}, nil
}

// write builds a WAL file: kb_chunks + an external-content kb_fts shaped like
// the app's (schema.sql), ftsRows rows and an FTS rebuild, then batchTxs
// transactions of batchRows rows each, then a VACUUM.
func write(path, keyHex string) (map[string]any, error) {
	d, err := open(path, keyHex)
	if err != nil {
		return nil, err
	}
	defer d.Close()
	var mode string
	if err := d.QueryRow(`PRAGMA journal_mode = WAL`).Scan(&mode); err != nil {
		return nil, fmt.Errorf("journal_mode: %w", err)
	}
	for _, q := range []string{
		`CREATE TABLE kb_chunks (id INTEGER PRIMARY KEY, title TEXT NOT NULL DEFAULT '', body TEXT NOT NULL, meta TEXT NOT NULL DEFAULT '')`,
		`CREATE VIRTUAL TABLE kb_fts USING fts5(title, body, meta, content='kb_chunks', content_rowid='id', tokenize='porter unicode61 remove_diacritics 2')`,
		`CREATE TRIGGER kb_chunks_ai AFTER INSERT ON kb_chunks BEGIN
		     INSERT INTO kb_fts(rowid, title, body, meta) VALUES (NEW.id, NEW.title, NEW.body, NEW.meta);
		 END`,
		`CREATE TABLE batch (id INTEGER PRIMARY KEY, tx INTEGER NOT NULL, n INTEGER NOT NULL, payload TEXT NOT NULL)`,
	} {
		if _, err := d.Exec(q); err != nil {
			return nil, fmt.Errorf("%.40s: %w", q, err)
		}
	}
	if err := inTx(d, func(tx *sql.Tx) error {
		for i := range ftsRows {
			body := fmt.Sprintf("chunk %d about the harbour", i)
			if i%10 == 0 {
				body = fmt.Sprintf("chunk %d about the %s on the cape", i, ftsKeyword)
			}
			if _, err := tx.Exec(`INSERT INTO kb_chunks(title, body, meta) VALUES (?, ?, ?)`,
				fmt.Sprintf("doc %d", i), body, "source=interop"); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		return nil, fmt.Errorf("fts rows: %w", err)
	}
	if _, err := d.Exec(`INSERT INTO kb_fts(kb_fts) VALUES ('rebuild')`); err != nil {
		return nil, fmt.Errorf("fts rebuild: %w", err)
	}
	for t := range batchTxs {
		if err := inTx(d, func(tx *sql.Tx) error {
			for n := range batchRows {
				if _, err := tx.Exec(`INSERT INTO batch(tx, n, payload) VALUES (?, ?, ?)`, t, n, "row"); err != nil {
					return err
				}
			}
			return nil
		}); err != nil {
			return nil, fmt.Errorf("batch tx %d: %w", t, err)
		}
	}
	if _, err := d.Exec(`VACUUM`); err != nil {
		return nil, fmt.Errorf("vacuum: %w", err)
	}
	var batch int
	if err := d.QueryRow(`SELECT count(*) FROM batch`).Scan(&batch); err != nil {
		return nil, err
	}
	return map[string]any{"journal_mode": mode, "fts_rows": ftsRows, "batch_rows": batch, "keyword": ftsKeyword}, nil
}

var identifier = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// read reopens path and checks the Swift side's table and its rows, plus
// that the FTS index still answers.
func read(path, keyHex, table string) (map[string]any, error) {
	if !identifier.MatchString(table) {
		return nil, fmt.Errorf("--expect-table %q is not a plain identifier", table)
	}
	d, err := open(path, keyHex)
	if err != nil {
		return nil, err
	}
	defer d.Close()
	var found int
	if err := d.QueryRow(`SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?`, table).Scan(&found); err != nil {
		return nil, fmt.Errorf("sqlite_master: %w", err)
	}
	if found != 1 {
		return nil, fmt.Errorf("table %s not found", table)
	}
	var rows int
	if err := d.QueryRow(`SELECT count(*) FROM ` + table).Scan(&rows); err != nil { //nolint:gosec // identifier checked above
		return nil, err
	}
	if rows == 0 {
		return nil, fmt.Errorf("table %s is empty", table)
	}
	var hits int
	if err := d.QueryRow(`SELECT count(*) FROM kb_fts WHERE kb_fts MATCH ?`, ftsKeyword).Scan(&hits); err != nil {
		return nil, fmt.Errorf("fts: %w", err)
	}
	var check string
	if err := d.QueryRow(`PRAGMA integrity_check`).Scan(&check); err != nil {
		return nil, fmt.Errorf("integrity_check: %w", err)
	}
	return map[string]any{"table": table, "rows": rows, "fts_hits": hits, "integrity": check}, nil
}

func inTx(d *sql.DB, fn func(*sql.Tx) error) error {
	tx, err := d.Begin()
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}
