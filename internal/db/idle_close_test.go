package db

import (
	"path/filepath"
	"testing"
	"testing/fstest"
	"testing/synctest"
	"time"
)

// These tests run in a synctest bubble: the handles open inside it, so
// database/sql's idle cleaner runs on the bubble's clock, and idling is a
// sleep that passes at once when everything else waits.

// idle lets every handle of the bubble sit idle for well past
// idleCloseAfter (database/sql's cleaner closes a connection on the first
// tick it is past its idle time) and waits for the cleaner to finish.
func idle() {
	time.Sleep(3 * idleCloseAfter)
	synctest.Wait()
}

// wantIdleClosed checks that the pool closed n connections as idle and
// holds none open.
func wantIdleClosed(t *testing.T, d *DB, n int64) {
	t.Helper()
	if st := d.Stats(); st.MaxIdleTimeClosed != n || st.OpenConnections != 0 {
		t.Fatalf("want %d idle-closed and none open, got %+v", n, st)
	}
}

// A file handle closes its connection once it has been idle for
// idleCloseAfter, so an idle MCP server holds no file handle; the next
// query opens a fresh connection.
func TestIdleClose_FileHandleClosesIdleConnection(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		d, _ := openTemp(t)
		wantPragma(t, d, "foreign_keys", 1)
		idle()
		wantIdleClosed(t, d, 1)
		wantPragma(t, d, "foreign_keys", 1)
	})
}

// After an idle close the next connection carries what SetBusyTimeout and
// SetReadOnly set on the handle (the TestPragmasSurviveInterruptedQuery
// shape).
func TestIdleClose_PragmasSurvive(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		d, _ := openTemp(t)
		mustOK(t, d.SetBusyTimeout(1500*time.Millisecond))
		mustOK(t, d.SetReadOnly())
		const marker = -1234
		if _, err := d.Exec("PRAGMA cache_size=-1234"); err != nil {
			t.Fatal(err)
		}
		idle()
		wantIdleClosed(t, d, 1)
		if got := pragmaInt(t, d, "cache_size"); got == marker {
			t.Fatal("the idle connection was not replaced; the test proves nothing")
		}
		wantPragma(t, d, "busy_timeout", 1500)
		wantPragma(t, d, "query_only", 1)
		if _, err := d.Exec(`CREATE TABLE fence_probe (x INTEGER)`); err == nil {
			t.Error("a write went through on a read-only handle after an idle close")
		}
	})
}

// The hook and sidecar openers idle-close too.
func TestIdleClose_HookAndSidecarOpeners(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		seed, path := openTemp(t)
		mustOK(t, seed.Close())
		ro, err := OpenExisting(path, 200*time.Millisecond)
		mustOK(t, err)
		t.Cleanup(func() { _ = ro.Close() })
		wantPragma(t, ro, "query_only", 1)
		idle()
		wantIdleClosed(t, ro, 1)
		wantPragma(t, ro, "query_only", 1)

		rw, err := OpenExistingRW(path, 200*time.Millisecond)
		mustOK(t, err)
		t.Cleanup(func() { _ = rw.Close() })
		idle()
		wantIdleClosed(t, rw, 1)

		side, err := OpenSidecar(filepath.Join(t.TempDir(), "side.db"), fstest.MapFS{
			"00001_init.sql": {Data: []byte("-- +goose Up\nCREATE TABLE s (v INTEGER);\n-- +goose Down\nDROP TABLE s;\n")},
		})
		mustOK(t, err)
		t.Cleanup(func() { _ = side.Close() })
		idle()
		wantIdleClosed(t, &DB{DB: side}, 1)
	})
}

// An in-memory database lives in its connection: it is never idle-closed.
func TestIdleClose_MemoryKeepsItsData(t *testing.T) {
	synctest.Test(t, testIdleCloseMemoryKeepsItsData)
}

func testIdleCloseMemoryKeepsItsData(t *testing.T) {
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
	idle()
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
	synctest.Test(t, func(t *testing.T) {
		d, _ := openTemp(t)
		d.KeepConnectionWarm()
		if _, err := d.Exec("PRAGMA cache_size=-1234"); err != nil {
			t.Fatal(err)
		}
		idle()
		wantPragma(t, d, "cache_size", -1234)
		if n := d.Stats().MaxIdleTimeClosed; n != 0 {
			t.Errorf("%d connections idle-closed on a warm handle", n)
		}
	})
}
