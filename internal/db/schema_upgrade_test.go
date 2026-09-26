package db

import (
	"database/sql"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// newLegacyDB creates a bare SQLite file stamped with the given legacy
// PRAGMA user_version (no goose_db_version table), mimicking a database
// last touched by the pre-goose migration engine.
func newLegacyDB(t *testing.T, userVersion int) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "legacy.db")
	raw, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	if _, err := raw.Exec(`CREATE TABLE workspace (id TEXT PRIMARY KEY)`); err != nil {
		t.Fatalf("seed table: %v", err)
	}
	if _, err := raw.Exec(`PRAGMA user_version = ` + strconv.Itoa(userVersion)); err != nil {
		t.Fatalf("set user_version: %v", err)
	}
	return path
}

// TestRunSchemaUpgrade_RejectsNonTipLegacyVersion pins the F1 guard: the
// goose baseline (00001) squashes the legacy schema at exactly v73. A DB
// stranded mid-way (e.g. v31) must NOT be silently baselined as if it were
// v73 — the shim has to refuse with a hint to run the previous release once.
func TestRunSchemaUpgrade_RejectsNonTipLegacyVersion(t *testing.T) {
	path := newLegacyDB(t, 31)

	err := RunSchemaUpgrade(path)
	if err == nil {
		t.Fatal("expected error for legacy user_version=31, got nil")
	}
	if !strings.Contains(err.Error(), "31") || !strings.Contains(err.Error(), "73") {
		t.Fatalf("error should name both the found and required legacy versions, got: %v", err)
	}
	if !strings.Contains(err.Error(), "previous release") {
		t.Fatalf("error should tell the user to run the previous release binary, got: %v", err)
	}

	// The refusal must not have half-transitioned the DB.
	raw, oErr := sql.Open("sqlite", path)
	if oErr != nil {
		t.Fatalf("reopen: %v", oErr)
	}
	defer raw.Close()
	var hasGoose int
	if err := raw.QueryRow(
		`SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type='table' AND name='goose_db_version')`,
	).Scan(&hasGoose); err != nil {
		t.Fatalf("check goose table: %v", err)
	}
	if hasGoose != 0 {
		t.Fatal("goose_db_version must not be created for a rejected legacy DB")
	}
}

// TestRunSchemaUpgrade_AcceptsLegacyTipVersion: a DB at exactly the legacy
// tip (v73) is baselined as goose v1.
func TestRunSchemaUpgrade_AcceptsLegacyTipVersion(t *testing.T) {
	path := newLegacyDB(t, 73)

	if err := RunSchemaUpgrade(path); err != nil {
		t.Fatalf("RunSchemaUpgrade at legacy tip: %v", err)
	}

	raw, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer raw.Close()
	var maxVersion int
	if err := raw.QueryRow(`SELECT MAX(version_id) FROM goose_db_version`).Scan(&maxVersion); err != nil {
		t.Fatalf("read goose baseline: %v", err)
	}
	if maxVersion != 1 {
		t.Fatalf("expected goose baseline version 1, got %d", maxVersion)
	}
	var userVersion int
	if err := raw.QueryRow(`PRAGMA user_version`).Scan(&userVersion); err != nil {
		t.Fatalf("read user_version: %v", err)
	}
	if userVersion != 73 {
		t.Fatalf("user_version must be preserved (Swift floor check), got %d", userVersion)
	}
}
