package db

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// updateGolden regenerates the schema golden file. Run with:
//
//	go test ./internal/db/ -run TestSchemaGolden -update
var updateGolden = flag.Bool("update", false, "update schema golden file")

// TestSchemaGolden captures the full database schema produced by Open() on a
// fresh DB and compares it against testdata/schema_v73.golden. This is the
// regression guard for any migration-system refactor: if the post-refactor
// migrate() produces a different schema, this test fails.
//
// To regenerate after intentional schema changes:
//
//	go test ./internal/db/ -run TestSchemaGolden -update
func TestSchemaGolden(t *testing.T) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "snapshot.db")

	db, err := Open(dbPath)
	require.NoError(t, err)
	defer db.Close()

	dump := dumpSchema(t, db)

	goldenPath := filepath.Join("testdata", "schema_v73.golden")

	if *updateGolden {
		require.NoError(t, os.MkdirAll("testdata", 0o755))
		require.NoError(t, os.WriteFile(goldenPath, []byte(dump), 0o644))
		t.Logf("wrote %s (%d bytes)", goldenPath, len(dump))
		return
	}

	want, err := os.ReadFile(goldenPath)
	require.NoError(t, err, "missing golden file — run with -update to create it")

	if dump != string(want) {
		// Show first divergence to keep diff readable.
		t.Errorf("schema diverged from golden\n--- want\n+++ got\n%s", firstDiff(string(want), dump))
	}
}

// dumpSchema produces a deterministic textual representation of the database
// schema: sqlite_master entries sorted by (type, name) plus pragma table_info
// for each table.
func dumpSchema(t *testing.T, db *DB) string {
	t.Helper()

	var b strings.Builder
	b.WriteString("# sqlite_master\n")

	rows, err := db.Query(`
		SELECT type, name, COALESCE(sql, '') AS sql
		FROM sqlite_master
		WHERE name NOT LIKE 'sqlite_%'
		ORDER BY type, name
	`)
	require.NoError(t, err)
	type entry struct{ Type, Name, SQL string }
	var entries []entry
	for rows.Next() {
		var e entry
		require.NoError(t, rows.Scan(&e.Type, &e.Name, &e.SQL))
		entries = append(entries, e)
	}
	require.NoError(t, rows.Close())

	for _, e := range entries {
		fmt.Fprintf(&b, "%s\t%s\n%s\n\n", e.Type, e.Name, normalizeWhitespace(e.SQL))
	}

	// pragma table_info for each table (column-level details: name, type, default, pk).
	b.WriteString("# table_info\n")
	tables := []string{}
	for _, e := range entries {
		if e.Type == "table" {
			tables = append(tables, e.Name)
		}
	}
	sort.Strings(tables)

	for _, table := range tables {
		fmt.Fprintf(&b, "## %s\n", table)
		ti, err := db.Query(fmt.Sprintf("PRAGMA table_info(%s)", table))
		require.NoError(t, err)
		for ti.Next() {
			var (
				cid     int
				name    string
				ctype   string
				notnull int
				dflt    *string
				pk      int
			)
			require.NoError(t, ti.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk))
			dfltStr := "NULL"
			if dflt != nil {
				dfltStr = *dflt
			}
			fmt.Fprintf(&b, "%d\t%s\t%s\tnotnull=%d\tdflt=%s\tpk=%d\n", cid, name, ctype, notnull, dfltStr, pk)
		}
		require.NoError(t, ti.Close())
		b.WriteString("\n")
	}

	return b.String()
}

// normalizeWhitespace collapses indentation whitespace inside CREATE
// statements so cosmetic-only changes don't fail the golden test.
func normalizeWhitespace(s string) string {
	// Collapse runs of whitespace to single spaces, trim each line, drop empties.
	var out []string
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		// Collapse internal multi-spaces.
		fields := strings.Fields(line)
		out = append(out, strings.Join(fields, " "))
	}
	return strings.Join(out, "\n")
}

// firstDiff returns a short context showing the first line where want and got differ.
func firstDiff(want, got string) string {
	wantLines := strings.Split(want, "\n")
	gotLines := strings.Split(got, "\n")
	max := len(wantLines)
	if len(gotLines) > max {
		max = len(gotLines)
	}
	for i := 0; i < max; i++ {
		var w, g string
		if i < len(wantLines) {
			w = wantLines[i]
		}
		if i < len(gotLines) {
			g = gotLines[i]
		}
		if w != g {
			start := i - 3
			if start < 0 {
				start = 0
			}
			end := i + 4
			if end > max {
				end = max
			}
			var b strings.Builder
			for j := start; j < end; j++ {
				marker := "  "
				if j == i {
					marker = "! "
				}
				if j < len(wantLines) {
					fmt.Fprintf(&b, "%s- %s\n", marker, wantLines[j])
				}
				if j < len(gotLines) {
					fmt.Fprintf(&b, "%s+ %s\n", marker, gotLines[j])
				}
			}
			return b.String()
		}
	}
	return "(diff at end of file — length mismatch)"
}
