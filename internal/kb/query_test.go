package kb

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestBuildMatch(t *testing.T) {
	and, or := BuildMatch(`договор* релиз`)
	assert.Equal(t, `"договор"* "релиз"`, and)
	assert.Equal(t, `"договор"* OR "релиз"`, or)
	and, _ = BuildMatch(`PROJ-123`)
	assert.Equal(t, `"PROJ-123"`, and)
	and, _ = BuildMatch(`Договорённость`)
	assert.Equal(t, `"Договоренность"`, and)
	and, _ = BuildMatch(`foo/bar NEAR and`)
	assert.Equal(t, `"foo" "bar"`, and)
	and, or = BuildMatch(`single`)
	assert.Equal(t, `"single"`, and)
	assert.Equal(t, and, or, "one term: the OR form equals the AND form")
	and, _ = BuildMatch(`foo/bar*`)
	assert.Equal(t, `"foo" "bar"*`, and, "only the last piece of a prefix word is a prefix")
	and, _ = BuildMatch(`-v1.2- _x_`)
	assert.Equal(t, `"v1.2" "x"`, and, "outer -_. are trimmed, inner ones kept")
}

// Review focus #2: hostile input never produces an FTS syntax error.
func TestBuildMatch_HostileInputIsSafe(t *testing.T) {
	d := db.OpenTestDB(t)
	for _, q := range []string{`"`, `(`, `)`, `NEAR`, `-foo`, `*`, `:`, `a:b`, `"unbalanced`, `^x`, `🙂`, `!!!`, `OR AND`, `x**`, `{a}`, `col:val`, `NEAR(a b)`, `a + b`, `title:x`, `""*`} {
		and, or := BuildMatch(q)
		for _, m := range []string{and, or} {
			if m == "" {
				continue
			}
			require.NoError(t, ftsProbe(d, m), "query %q → match %q", q, m)
		}
	}
	and, or := BuildMatch(`!!! ???`)
	assert.Equal(t, "", and)
	assert.Equal(t, "", or)
	and, or = BuildMatch("")
	assert.Equal(t, "", and)
	assert.Equal(t, "", or)
}

// ftsProbe runs match against kb_fts and reports any FTS5 error.
func ftsProbe(d *db.DB, match string) error {
	rows, err := d.QueryContext(context.Background(), `SELECT rowid FROM kb_fts WHERE kb_fts MATCH ?`, match)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() { // drain: a MATCH error can surface while stepping
	}
	return rows.Err()
}
