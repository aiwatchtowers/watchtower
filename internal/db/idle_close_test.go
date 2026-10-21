package db

import (
	"path/filepath"
	"testing"
	"testing/fstest"
	"time"
)

// shortIdleClose shortens idleCloseAfter for handles opened by the test.
func shortIdleClose(t *testing.T) {
	t.Helper()
	prev := idleCloseAfter
	idleCloseAfter = 50 * time.Millisecond
	t.Cleanup(func() { idleCloseAfter = prev })
}

// waitIdleClosed waits until the pool has closed n connections as idle and
// holds none open.
func waitIdleClosed(t *testing.T, d *DB, n int64) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for st := d.Stats(); st.MaxIdleTimeClosed < n || st.OpenConnections != 0; st = d.Stats() {
		if time.Now().After(deadline) {
			t.Fatalf("idle connection not closed: %+v", d.Stats())
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// A file handle closes its connection once it has been idle for
// idleCloseAfter, so an idle MCP server holds no file handle; the next
// query opens a fresh connection.
func TestIdleClose_FileHandleClosesIdleConnection(t *testing.T) {
	shortIdleClose(t)
	d, _ := openTemp(t)
	wantPragma(t, d, "foreign_keys", 1)
	waitIdleClosed(t, d, 1)
	wantPragma(t, d, "foreign_keys", 1)
}

// After an idle close the next connection carries what SetBusyTimeout and
// SetReadOnly set on the handle (the TestPragmasSurviveInterruptedQuery
// shape).
func TestIdleClose_PragmasSurvive(t *testing.T) {
	shortIdleClose(t)
	d, _ := openTemp(t)
	mustOK(t, d.SetBusyTimeout(1500*time.Millisecond))
	mustOK(t, d.SetReadOnly())
	const marker = -1234
	if _, err := d.Exec("PRAGMA cache_size=-1234"); err != nil {
		t.Fatal(err)
	}
	waitIdleClosed(t, d, 1)
	if got := pragmaInt(t, d, "cache_size"); got == marker {
		t.Fatal("the idle connection was not replaced; the test proves nothing")
	}
	wantPragma(t, d, "busy_timeout", 1500)
	wantPragma(t, d, "query_only", 1)
	if _, err := d.Exec(`CREATE TABLE fence_probe (x INTEGER)`); err == nil {
		t.Error("a write went through on a read-only handle after an idle close")
	}
}

// The hook and sidecar openers idle-close too.
func TestIdleClose_HookAndSidecarOpeners(t *testing.T) {
	shortIdleClose(t)
	seed, path := openTemp(t)
	mustOK(t, seed.Close())
	ro, err := OpenExisting(path, 200*time.Millisecond)
	mustOK(t, err)
	t.Cleanup(func() { _ = ro.Close() })
	wantPragma(t, ro, "query_only", 1)
	waitIdleClosed(t, ro, 1)
	wantPragma(t, ro, "query_only", 1)

	rw, err := OpenExistingRW(path, 200*time.Millisecond)
	mustOK(t, err)
	t.Cleanup(func() { _ = rw.Close() })
	waitIdleClosed(t, rw, 1)

	side, err := OpenSidecar(filepath.Join(t.TempDir(), "side.db"), fstest.MapFS{
		"00001_init.sql": {Data: []byte("-- +goose Up\nCREATE TABLE s (v INTEGER);\n-- +goose Down\nDROP TABLE s;\n")},
	})
	mustOK(t, err)
	t.Cleanup(func() { _ = side.Close() })
	waitIdleClosed(t, &DB{DB: side}, 1)
}

// cleanerGap outlasts database/sql's idle cleaner, which runs at most once
// a second whatever the idle time.
const cleanerGap = 1500 * time.Millisecond

// An in-memory database lives in its connection: it is never idle-closed.
func TestIdleClose_MemoryKeepsItsData(t *testing.T) {
	shortIdleClose(t)
	opened := map[string]*DB{}
	for name, open := range map[string]func() (*DB, error){
		"template clone": func() (*DB, error) { return Open(":memory:") },
		"migrated open": func() (*DB, error) {
			hook := openMemoryHook
			openMemoryHook = nil
			defer func() { openMemoryHook = hook }()
			return Open(":memory:")
		},
	} {
		d, err := open()
		mustOK(t, err)
		t.Cleanup(func() { _ = d.Close() })
		if _, err := d.Exec(`CREATE TABLE keep (v TEXT); INSERT INTO keep VALUES ('x')`); err != nil {
			t.Fatal(err)
		}
		opened[name] = d
	}
	time.Sleep(cleanerGap)
	for name, d := range opened {
		var v string
		if err := d.QueryRow(`SELECT v FROM keep`).Scan(&v); err != nil || v != "x" {
			t.Errorf("%s: after an idle gap: %q, %v", name, v, err)
		}
		if n := d.Stats().MaxIdleTimeClosed; n != 0 {
			t.Errorf("%s: %d connections idle-closed", name, n)
		}
	}
}

// KeepConnectionWarm (the daemon's watchtower.db handle) keeps the
// connection, and with it the page cache.
func TestIdleClose_KeepConnectionWarm(t *testing.T) {
	shortIdleClose(t)
	d, _ := openTemp(t)
	d.KeepConnectionWarm()
	if _, err := d.Exec("PRAGMA cache_size=-1234"); err != nil {
		t.Fatal(err)
	}
	time.Sleep(cleanerGap)
	wantPragma(t, d, "cache_size", -1234)
	if n := d.Stats().MaxIdleTimeClosed; n != 0 {
		t.Errorf("%d connections idle-closed on a warm handle", n)
	}
}
