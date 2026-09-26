package db

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestInitTestTemplate_CloneMatchesFreshMigration pins the snapshot clone
// that every Open(":memory:") in a templated test binary returns to a
// database migrated from scratch: same schema, same goose history, the same
// row count in every table (migration-seeded rows included — seeded
// timestamps differ by construction, so counts rather than contents), and
// foreign keys enforced. Without it, hundreds of tests could drift onto a
// schema the product never runs and keep passing.
func TestInitTestTemplate_CloneMatchesFreshMigration(t *testing.T) {
	fresh, err := Open(filepath.Join(t.TempDir(), "fresh.db")) // file path: bypasses the hook
	require.NoError(t, err)
	t.Cleanup(func() { _ = fresh.Close() })
	clone := openTestDB(t)

	require.Equal(t, dumpSchema(t, fresh), dumpSchema(t, clone))
	require.Equal(t, dumpTemplateFacts(t, fresh), dumpTemplateFacts(t, clone))
}

// dumpTemplateFacts renders goose history, per-table row counts and the
// foreign_keys pragma of d.
func dumpTemplateFacts(t *testing.T, d *DB) string {
	t.Helper()
	var b strings.Builder
	for _, v := range queryStrings(t, d, `SELECT version_id || ' ' || is_applied FROM goose_db_version ORDER BY id`) {
		fmt.Fprintf(&b, "goose %s\n", v)
	}
	tables := queryStrings(t, d, `SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name`)
	require.NotEmpty(t, tables)
	for _, name := range tables {
		var n int
		require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM "`+name+`"`).Scan(&n))
		fmt.Fprintf(&b, "rows %s %d\n", name, n)
	}
	var fk int
	require.NoError(t, d.QueryRow(`PRAGMA foreign_keys`).Scan(&fk))
	fmt.Fprintf(&b, "foreign_keys %d\n", fk)
	return b.String()
}

// queryStrings returns the single text column of every row query yields.
func queryStrings(t *testing.T, d *DB, query string) []string {
	t.Helper()
	rows, err := d.Query(query)
	require.NoError(t, err)
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		require.NoError(t, rows.Scan(&s))
		out = append(out, s)
	}
	require.NoError(t, rows.Err())
	return out
}
