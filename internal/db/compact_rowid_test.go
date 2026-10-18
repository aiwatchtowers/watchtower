package db

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"testing"
)

// rowidTables are the tables whose rowids saved cursors depend on (the
// linkscan synced_at|rowid cursors, memory's rowid identities, the
// knowledge index), each with its primary key columns and a row insert.
// Every table with a rowid-based cursor must be listed here.
var rowidTables = []struct {
	table  string
	pk     string
	insert string // takes the row number as its only argument
}{
	{"messages", "channel_id, ts",
		`INSERT INTO messages (channel_id, ts, text) VALUES ('acme:C' || (?1 % 4), ?1 || '.000100', 'm' || ?1)`},
	{"gmail_messages", "account_id, id",
		`INSERT INTO gmail_messages (account_id, id) VALUES (1, 'g' || ?1)`},
	{"imap_messages", "account_id, uidvalidity, uid",
		`INSERT INTO imap_messages (account_id, uidvalidity, uid) VALUES (1, 7, 1000 - ?1)`},
	{"jira_issues", "account_id, key",
		`INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category, created_at, updated_at, synced_at)
			VALUES (1, 'ACME-' || ?1, 'ACME', 's', 'Open', 'new', '', '', '')`},
	{"jira_comments", "account_id, id",
		`INSERT INTO jira_comments (account_id, issue_key, id) VALUES (1, 'ACME-1', 'c' || ?1)`},
	{"user_interactions", "user_a, user_b, period_from, period_to",
		`INSERT INTO user_interactions (user_a, user_b, period_from, period_to) VALUES ('acme:U0', 'acme:U' || ?1, 0, 1)`},
	{"decision_reads", "digest_id, decision_idx",
		`INSERT INTO decision_reads (digest_id, decision_idx) VALUES (1, ?1)`},
	{"kb_chunks", "id",
		`INSERT INTO kb_chunks (doc_id, idx, body) VALUES ('doc-1', ?1, 'body ' || ?1)`},
}

// Compaction keeps every rowid: VACUUM may renumber the rowids of a table
// without an INTEGER PRIMARY KEY, and the saved cursors would then skip or
// repeat rows. If this fails after a driver upgrade, compaction must reset
// those cursors (spec D2.8) — do not relax the test.
func TestCompact_PreservesRowids(t *testing.T) {
	path := compactFixture(t)
	d, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	for _, stmt := range []string{
		`INSERT INTO google_accounts (id) VALUES (1)`,
		`INSERT INTO email_accounts (id, provider) VALUES (1, 'imap')`,
		`INSERT INTO jira_accounts (id) VALUES (1)`,
		`INSERT INTO digests (id, period_from, period_to, type, summary) VALUES (1, 0, 1, 'daily', 's')`,
		`INSERT INTO kb_documents (id, source) VALUES ('doc-1', 'acme')`,
	} {
		if _, err := d.Exec(stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}
	for _, tt := range rowidTables {
		for i := 1; i <= 30; i++ {
			if _, err := d.Exec(tt.insert, i); err != nil {
				t.Fatalf("seeding %s: %v", tt.table, err)
			}
		}
		if _, err := d.Exec(`DELETE FROM ` + tt.table + ` WHERE rowid % 3 = 0`); err != nil {
			t.Fatalf("deleting from %s: %v", tt.table, err)
		}
	}
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}

	before := rowidSnapshot(t, path)
	res, err := Compact(context.Background(), path, CompactOptions{Force: true, Version: "1.0.0"})
	if err != nil || !res.Compacted {
		t.Fatalf("Compact: (%+v, %v)", res, err)
	}
	after := rowidSnapshot(t, path)
	for table, rows := range before {
		if len(rows) == 0 {
			t.Fatalf("%s: no rows seeded", table)
		}
		if !slices.Equal(rows, after[table]) {
			t.Errorf("%s rowids changed:\nbefore %v\nafter  %v", table, rows, after[table])
		}
	}
}

// rowidSnapshot reads "rowid|pk…" per row in rowid order for every table in
// rowidTables, plus kb_fts's rowids.
func rowidSnapshot(t *testing.T, path string) map[string][]string {
	t.Helper()
	d, err := OpenExisting(path, compactCheckBusy)
	if err != nil {
		t.Fatalf("OpenExisting: %v", err)
	}
	defer d.Close()
	out := map[string][]string{}
	queries := map[string]string{"kb_fts": `SELECT rowid FROM kb_fts ORDER BY rowid`}
	for _, tt := range rowidTables {
		queries[tt.table] = `SELECT rowid, ` + tt.pk + ` FROM ` + tt.table + ` ORDER BY rowid`
	}
	for table, q := range queries {
		out[table] = rowidRows(t, d, table, q)
	}
	return out
}

func rowidRows(t *testing.T, d *DB, table, q string) []string {
	t.Helper()
	rows, err := d.Query(q)
	if err != nil {
		t.Fatalf("%s: %v", table, err)
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			t.Fatalf("%s: %v", table, err)
		}
		parts := make([]string, len(vals))
		for i, v := range vals {
			parts[i] = fmt.Sprint(v)
		}
		out = append(out, strings.Join(parts, "|"))
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("%s: %v", table, err)
	}
	return out
}
