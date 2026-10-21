package db

import (
	"context"
	"fmt"
	"strings"
	"testing"
)

var purgeSources = []string{"slack", "google", "jira", "linear"}

// purgeKeptTables are account-scoped tables a purge deliberately leaves, with
// the reason. A table named here and in a step list fails the test too.
var purgeKeptTables = map[string]string{
	"imap_messages":   "IMAP is not a purge source (no revocation signal; spec, Sources)",
	"account_purges":  "the purge ledger itself",
	"jira_user_map":   "an identity map keyed by the Atlassian user id, not by a Jira account row",
	"linear_user_map": "an identity map keyed by the Linear user id, not by a Linear account row",
}

// drainPurge runs every step of one account purge to completion.
func drainPurge(t *testing.T, d *DB, source string, id int64, limit int) int64 {
	t.Helper()
	steps, err := d.PurgeSteps(source, id)
	if err != nil {
		t.Fatal(err)
	}
	var total int64
	for _, st := range steps {
		for {
			n, err := d.RunPurgeStep(context.Background(), st, limit)
			if err != nil {
				t.Fatalf("%s: %v", st.Name, err)
			}
			if n > int64(limit) {
				t.Fatalf("%s: one chunk affected %d rows, limit %d", st.Name, n, limit)
			}
			total += n
			if n == 0 {
				break
			}
		}
	}
	return total
}

func count(t *testing.T, d *DB, q string, args ...any) int {
	t.Helper()
	var n int
	if err := d.QueryRow(q, args...).Scan(&n); err != nil {
		t.Fatalf("%s: %v", q, err)
	}
	return n
}

func mustExecAll(t *testing.T, d *DB, stmts ...string) {
	t.Helper()
	for _, q := range stmts {
		if _, err := d.Exec(q); err != nil {
			t.Fatalf("%v\n%s", err, q)
		}
	}
}

// accountTableSources names the purge sources whose accounts own rows of an
// account-scoped table that has no foreign key to tell (an account_id
// column read together with a source/kind column). A new such table must be
// added here, or the guard fails.
var accountTableSources = map[string][]string{
	"history_backfill":  {"slack", "google", "jira"}, // source_kind slack | gmail | jira (imap is no purge source)
	"stream_digests":    {"google", "jira", "linear"},
	"reaction_commands": {"slack"},
	"reaction_events":   {"slack"},
	"reminders":         {"slack"},
}

// slackNamespacedTables hold Slack rows keyed by "<account>:<raw id>"
// strings, not by an account column the schema scan can see; the Slack
// steps must cover each.
var slackNamespacedTables = []string{
	"messages", "reactions", "files", "inbox_items", "inbox_learned_rules", "digests", "tracks",
	"user_analyses", "people_cards", "user_interactions", "issue_slack_links", "sync_state",
	"watch_list", "channel_settings", "users", "channels", "kb_documents", "kb_dirty", "doc_links",
}

// purgeSourceOf maps an account table to its purge source.
var purgeSourceOf = map[string]string{
	"slack_accounts": "slack", "google_accounts": "google", "jira_accounts": "jira", "linear_accounts": "linear",
}

// TestPurge02_EveryAccountTableCovered is schema-driven: every table with a
// foreign key to an account table, or with an account_id column, is purged
// by a step of the source(s) that own it — the foreign key's account table,
// else accountTableSources — or named in purgeKeptTables. Slack's
// namespace-keyed tables are checked against the Slack steps. It fails when
// a later migration adds an account-scoped table and forgets the purge, or
// covers it only in another source's steps.
func TestPurge02_EveryAccountTableCovered(t *testing.T) {
	d := OpenTestDB(t)
	covered := map[string]map[string]bool{} // source -> table
	for _, src := range purgeSources {
		steps, err := d.PurgeSteps(src, 1)
		if err != nil {
			t.Fatal(err)
		}
		covered[src] = map[string]bool{}
		for _, st := range steps {
			covered[src][st.Table] = true
		}
	}
	coveredAny := func(table string) bool {
		for _, src := range purgeSources {
			if covered[src][table] {
				return true
			}
		}
		return false
	}
	rows, err := d.Query(`SELECT m.name, COALESCE((SELECT group_concat(p."table") FROM pragma_foreign_key_list(m.name) p
			WHERE p."table" LIKE '%\_accounts' ESCAPE '\'), '')
		FROM sqlite_master m
		WHERE m.type = 'table' AND m.name NOT IN ('slack_accounts','google_accounts','jira_accounts','linear_accounts','email_accounts')
		  AND (EXISTS (SELECT 1 FROM pragma_foreign_key_list(m.name) p WHERE p."table" LIKE '%\_accounts' ESCAPE '\')
		    OR EXISTS (SELECT 1 FROM pragma_table_info(m.name) c WHERE c.name IN ('account_id', 'jira_account_id')))
		ORDER BY 1`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	type scoped struct{ name, fks string }
	var tables []scoped
	for rows.Next() {
		var s scoped
		if err := rows.Scan(&s.name, &s.fks); err != nil {
			t.Fatal(err)
		}
		tables = append(tables, s)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if len(tables) < 20 {
		t.Fatalf("schema scan found only %d account-scoped tables; the query is broken", len(tables))
	}
	for _, tb := range tables {
		if _, kept := purgeKeptTables[tb.name]; kept {
			if coveredAny(tb.name) {
				t.Errorf("%s is both purged and listed as kept", tb.name)
			}
			continue
		}
		var owners []string
		for _, fk := range strings.Split(tb.fks, ",") {
			if src, ok := purgeSourceOf[fk]; ok {
				owners = append(owners, src)
			}
		}
		if len(owners) == 0 {
			owners = accountTableSources[tb.name]
		}
		if len(owners) == 0 {
			t.Errorf("%s is account-scoped but its source is unknown; add it to accountTableSources or purgeKeptTables", tb.name)
			continue
		}
		for _, src := range owners {
			if !covered[src][tb.name] {
				t.Errorf("%s belongs to %s accounts but no %s purge step deletes it; add a step or a purgeKeptTables reason", tb.name, src, src)
			}
		}
	}
	for _, name := range slackNamespacedTables {
		if !covered["slack"][name] {
			t.Errorf("%s holds Slack namespaced rows but no Slack purge step deletes it", name)
		}
	}
}

// Every step of every source is valid SQL against the real schema.
func TestPurgeSteps_RunOnEmptyDB(t *testing.T) {
	d := OpenTestDB(t)
	for _, src := range purgeSources {
		if n := drainPurge(t, d, src, 1, 500); n != 0 {
			t.Errorf("%s: an empty database purged %d rows", src, n)
		}
	}
	if _, err := d.PurgeSteps("imap", 1); err == nil {
		t.Fatal("unknown source must error")
	}
}

// TestPurge02_ChunkedResumable: 1 200 messages of account 1 and 10 of
// account 2. Each chunk deletes at most 500, a purge stopped half-way
// completes on a restart, and account 2 is untouched (messages, FTS hits,
// knowledge documents).
func TestPurge02_ChunkedResumable(t *testing.T) {
	d := OpenTestDB(t)
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 1200; i++ {
		if _, err := tx.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, '1:U1', 'purgeword one')`,
			fmt.Sprintf("%d.000100", 1700000000+i)); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 10; i++ {
		if _, err := tx.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('2:C1', ?, '2:U1', 'purgeword two')`,
			fmt.Sprintf("%d.000100", 1700000000+i)); err != nil {
			t.Fatal(err)
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	mustExecAll(t, d,
		`INSERT INTO kb_documents (id, source) VALUES ('slack:thread:1:C1:1700000000.000100', 'slack'), ('slack:day:1:C1:2026-01-01', 'slack'),
			('slack:thread:2:C1:1700000000.000100', 'slack'), ('slack:thread:10:C1:1700000000.000100', 'slack')`,
		`INSERT INTO kb_chunks (doc_id, idx, body) VALUES ('slack:thread:1:C1:1700000000.000100', 0, 'kbword'), ('slack:thread:2:C1:1700000000.000100', 0, 'kbword')`,
	)

	steps, err := d.PurgeSteps("slack", 1)
	if err != nil {
		t.Fatal(err)
	}
	// A first run stops after one chunk of the first step (messages).
	n, err := d.RunPurgeStep(context.Background(), steps[0], 500)
	if err != nil || n != 500 || steps[0].Table != "messages" {
		t.Fatalf("first chunk = %d, %v (step %s)", n, err, steps[0].Table)
	}
	if got := count(t, d, `SELECT COUNT(*) FROM messages WHERE channel_id = '1:C1'`); got != 700 {
		t.Fatalf("after one chunk %d messages left, want 700", got)
	}
	// The restart runs the whole list.
	drainPurge(t, d, "slack", 1, 500)

	if got := count(t, d, `SELECT COUNT(*) FROM messages WHERE channel_id = '1:C1'`); got != 0 {
		t.Errorf("account 1 messages left: %d", got)
	}
	if got := count(t, d, `SELECT COUNT(*) FROM messages WHERE channel_id = '2:C1'`); got != 10 {
		t.Errorf("account 2 messages = %d, want 10", got)
	}
	if got := count(t, d, `SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'purgeword'`); got != 10 {
		t.Errorf("FTS hits = %d, want account 2's 10", got)
	}
	if got := count(t, d, `SELECT COUNT(*) FROM kb_documents`); got != 2 {
		t.Errorf("kb documents = %d, want account 2's and account 10's", got)
	}
	if got := count(t, d, `SELECT COUNT(*) FROM kb_chunks`); got != 1 {
		t.Errorf("kb chunks = %d, want 1", got)
	}
}

// TestPurge02_ScopeKeepsCrossAccount: a cross-channel digest, a track that
// spans two accounts and a transcript-linked calendar event survive; the
// account-only digest, track, people card, inbox item with its situation,
// and the other Google event are gone.
func TestPurge02_ScopeKeepsCrossAccount(t *testing.T) {
	d := OpenTestDB(t)
	mustExecAll(t, d,
		`INSERT INTO digests (id, channel_id, period_from, period_to, type, summary) VALUES
			(1, '1:C1', 0, 1, 'channel', 'only account 1'),
			(2, '', 0, 1, 'daily', 'cross-channel'),
			(3, '2:C1', 0, 1, 'channel', 'account 2')`,
		`INSERT INTO digest_topics (digest_id, idx, title, summary) VALUES (1, 0, 't', 's'), (2, 0, 't', 's')`,
		`INSERT INTO kb_documents (id, source) VALUES ('digest:1:0', 'digest'), ('digest:2:0', 'digest')`,
		`INSERT INTO feedback (entity_type, entity_id, rating) VALUES ('digest', '1', 1), ('decision', '1:0', 1), ('digest', '2', 1)`,
		`INSERT INTO tracks (id, text, channel_ids) VALUES (1, 'mine', '["1:C1","1:C2"]'), (2, 'both', '["1:C1","2:C1"]'), (3, 'none', '[]')`,
		`INSERT INTO people_cards (user_id, period_from, period_to) VALUES ('1:U1', 0, 1), ('2:U1', 0, 1)`,
		`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type) VALUES
			(1, '1:C1', '1.0', '1:U1', 'mention'), (2, '2:C1', '1.0', '2:U1', 'mention'),
			(3, 'memory', '1.0', '', 'decision_made'), (4, '1:C1', '2.0', '1:U1', 'dm')`,
		`INSERT INTO situations (id, title) VALUES (1, 'only account 1'), (2, 'mixed')`,
		`INSERT INTO situation_signals (situation_id, inbox_item_id) VALUES (1, 1), (2, 4), (2, 2)`,
		`INSERT INTO feedback (entity_type, entity_id, rating) VALUES ('inbox', '1', 1), ('situation', '1', 1)`,
		`INSERT INTO google_accounts (id, email) VALUES (1, 'a@example.com'), (2, 'b@example.com')`,
		`INSERT INTO calendar_calendars (id, name, account_id) VALUES ('cal1', 'Work', 1), ('cal2', 'Other', 2)`,
		`INSERT INTO calendar_events (id, calendar_id, start_time, end_time) VALUES
			('ev-kept', 'cal1', '2026-01-01T10:00:00Z', '2026-01-01T11:00:00Z'),
			('ev-gone', 'cal1', '2026-01-02T10:00:00Z', '2026-01-02T11:00:00Z'),
			('ev-other', 'cal2', '2026-01-02T10:00:00Z', '2026-01-02T11:00:00Z')`,
		`INSERT INTO meeting_transcripts (title, transcript_text, event_id) VALUES ('standup', 'text', 'ev-kept')`,
		`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type) VALUES
			(10, 'ev-gone', '1.0', '', 'calendar_invite'), (11, 'ev-other', '1.0', '', 'calendar_invite'),
			(12, 'gmail:1:t1', '1.0', '', 'email_received'), (13, 'gmail:10:t1', '1.0', '', 'email_received')`,
		`INSERT INTO kb_documents (id, source) VALUES ('calendar:ev-gone', 'calendar'), ('calendar:ev-kept', 'calendar'), ('gmail:1:t1', 'gmail'), ('gmail:10:t1', 'gmail')`,
	)
	drainPurge(t, d, "slack", 1, 2)
	drainPurge(t, d, "google", 1, 2)

	checks := []struct {
		q    string
		want int
	}{
		{`SELECT COUNT(*) FROM digests WHERE id = 1`, 0},
		{`SELECT COUNT(*) FROM digests WHERE id IN (2, 3)`, 2},
		{`SELECT COUNT(*) FROM kb_documents WHERE id = 'digest:1:0'`, 0},
		{`SELECT COUNT(*) FROM kb_documents WHERE id = 'digest:2:0'`, 1},
		{`SELECT COUNT(*) FROM feedback WHERE entity_type IN ('digest','decision') AND entity_id LIKE '1%'`, 0},
		{`SELECT COUNT(*) FROM feedback WHERE entity_type = 'digest' AND entity_id = '2'`, 1},
		{`SELECT COUNT(*) FROM tracks WHERE id = 1`, 0},
		{`SELECT COUNT(*) FROM tracks WHERE id IN (2, 3)`, 2},
		{`SELECT COUNT(*) FROM people_cards WHERE user_id = '1:U1'`, 0},
		{`SELECT COUNT(*) FROM people_cards WHERE user_id = '2:U1'`, 1},
		{`SELECT COUNT(*) FROM inbox_items WHERE id IN (1, 4, 10, 12)`, 0},
		{`SELECT COUNT(*) FROM inbox_items WHERE id IN (2, 3, 11, 13)`, 4},
		{`SELECT COUNT(*) FROM situations WHERE id = 1`, 0},
		{`SELECT COUNT(*) FROM situations WHERE id = 2`, 1},
		{`SELECT COUNT(*) FROM feedback WHERE entity_type IN ('inbox','situation')`, 0},
		{`SELECT COUNT(*) FROM calendar_events WHERE id = 'ev-kept'`, 1},
		{`SELECT COUNT(*) FROM calendar_events WHERE id IN ('ev-gone')`, 0},
		{`SELECT COUNT(*) FROM calendar_events WHERE id = 'ev-other'`, 1},
		{`SELECT COUNT(*) FROM calendar_calendars WHERE id = 'cal1' AND account_id IS NULL AND is_selected = 0`, 1},
		{`SELECT COUNT(*) FROM calendar_calendars WHERE id = 'cal2' AND account_id = 2`, 1},
		{`SELECT COUNT(*) FROM kb_documents WHERE id IN ('calendar:ev-gone', 'gmail:1:t1')`, 0},
		{`SELECT COUNT(*) FROM kb_documents WHERE id IN ('calendar:ev-kept', 'gmail:10:t1')`, 2},
		{`SELECT COUNT(*) FROM meeting_transcripts WHERE event_id = 'ev-kept'`, 1},
	}
	for _, c := range checks {
		if got := count(t, d, c.q); got != c.want {
			t.Errorf("%s = %d, want %d", c.q, got, c.want)
		}
	}
}

func TestPurge02_JiraAndLinearScope(t *testing.T) {
	d := OpenTestDB(t)
	mustExecAll(t, d,
		`INSERT INTO jira_accounts (id, cloud_id) VALUES (1, 'c1'), (2, 'c2')`,
		`INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category, created_at, updated_at, synced_at) VALUES
			(1, 'OPS-1', 'OPS', 's', 'Open', 'To Do', '2026-01-01', '2026-01-01', '2026-01-01'),
			(1, 'OPS-2', 'OPS', 's', 'Open', 'To Do', '2026-01-01', '2026-01-01', '2026-01-01'),
			(2, 'OPS-2', 'OPS', 's', 'Open', 'To Do', '2026-01-01', '2026-01-01', '2026-01-01')`,
		`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type) VALUES
			(1, 'OPS-1', '1', '', 'jira_assigned'), (2, 'OPS-2', '1', '', 'jira_assigned')`,
		`INSERT INTO ext_sources (id, provider, jira_account_id, container_key) VALUES (5, 'confluence', 1, 'ENG'), (6, 'confluence', 2, 'ENG')`,
		`INSERT INTO ext_documents (source_id, ext_id, kind) VALUES (5, 'p1', 'page'), (6, 'p1', 'page')`,
		`INSERT INTO kb_documents (id, source) VALUES ('confluence:5:p1', 'confluence'), ('confluence:6:p1', 'confluence'),
			('jira:1:OPS-1', 'jira'), ('jira:2:OPS-2', 'jira')`,
		`INSERT INTO stream_digests (source, account_id, period_from, period_to) VALUES ('jira', 1, 'a', 'b'), ('jira', 2, 'a', 'b')`,
	)
	drainPurge(t, d, "jira", 1, 500)
	checks := []struct {
		q    string
		want int
	}{
		{`SELECT COUNT(*) FROM jira_issues WHERE account_id = 1`, 0},
		{`SELECT COUNT(*) FROM jira_issues WHERE account_id = 2`, 1},
		{`SELECT COUNT(*) FROM inbox_items WHERE id = 1`, 0},
		{`SELECT COUNT(*) FROM inbox_items WHERE id = 2`, 1}, // OPS-2 is also account 2's: not attributable
		{`SELECT COUNT(*) FROM ext_sources`, 1},
		{`SELECT COUNT(*) FROM ext_documents`, 1},
		{`SELECT COUNT(*) FROM kb_documents WHERE id IN ('confluence:6:p1', 'jira:2:OPS-2')`, 2},
		{`SELECT COUNT(*) FROM kb_documents`, 2},
		{`SELECT COUNT(*) FROM stream_digests`, 1},
		{`SELECT COUNT(*) FROM jira_accounts`, 2},
	}
	for _, c := range checks {
		if got := count(t, d, c.q); got != c.want {
			t.Errorf("%s = %d, want %d", c.q, got, c.want)
		}
	}
}

func TestFinishAccountPurge_MarksPurged(t *testing.T) {
	d := OpenTestDB(t)
	mustExecAll(t, d,
		`INSERT INTO linear_accounts (id, org_id, status, error, moved_watermark) VALUES (1, 'o1', 'revoked', 'gone', 'w')`,
		`INSERT INTO account_purges (id, source, account_id, reason, due_at) VALUES (1, 'linear', 1, 'revoked', '2026-01-01T00:00:00Z')`,
	)
	if started, err := d.StartAccountPurge(1); err != nil || !started {
		t.Fatal(started, err)
	}
	if err := d.AddPurgeRows(1, 7); err != nil {
		t.Fatal(err)
	}
	if _, err := d.FailAccountPurge(1, "boom", 3); err != nil {
		t.Fatal(err)
	}
	rows, err := d.ListAccountPurges(true)
	if err != nil || len(rows) != 1 || rows[0].State != "running" || rows[0].Error != "boom" || rows[0].StartedAt == "" {
		t.Fatalf("after a failed chunk: %+v %v", rows, err)
	}
	if kept, err := d.FinishAccountPurge(1, "linear", 1); err != nil || kept {
		t.Fatal(kept, err)
	}
	all, err := d.ListAccountPurges(false)
	if err != nil || all[0].State != "done" || all[0].RowsDeleted != 7 || all[0].Error != "" || all[0].FinishedAt == "" {
		t.Fatalf("ledger after finish: %+v %v", all, err)
	}
	var status, errText, watermark string
	var enabled int
	if err := d.QueryRow(`SELECT status, error, enabled, moved_watermark FROM linear_accounts WHERE id = 1`).
		Scan(&status, &errText, &enabled, &watermark); err != nil {
		t.Fatal(err)
	}
	if status != "purged" || errText != "" || enabled != 0 || watermark != "" {
		t.Fatalf("account after finish: %s %q %d %q", status, errText, enabled, watermark)
	}
	if _, err := d.FinishAccountPurge(1, "imap", 1); err == nil {
		t.Fatal("unknown source must error")
	}
}

// PURGE-02 (review #601): no step scans the knowledge tables inside its
// write transaction. Every kb_documents, kb_dirty and doc_links delete is a
// key range (the ids it needs — the account's stream digests and Confluence
// spaces — are read before, outside any transaction). Checked with EXPLAIN
// QUERY PLAN on a database that has rows for every source.
func TestPurge02_KnowledgeStepsUseKeyRanges(t *testing.T) {
	d := OpenTestDB(t)
	mustExecAll(t, d,
		`INSERT INTO jira_accounts (id, cloud_id) VALUES (1, 'c1')`,
		`INSERT INTO ext_sources (id, provider, jira_account_id, container_key) VALUES (5, 'confluence', 1, 'ENG')`,
		`INSERT INTO stream_digests (source, account_id, period_from, period_to) VALUES ('jira', 1, 'a', 'b'), ('gmail', 1, 'a', 'b'), ('linear', 1, 'a', 'b')`,
	)
	knowledge := map[string]bool{"kb_documents": true, "kb_dirty": true, "doc_links": true}
	for _, src := range purgeSources {
		steps, err := d.PurgeSteps(src, 1)
		if err != nil {
			t.Fatal(err)
		}
		for _, st := range steps {
			if !knowledge[st.Table] {
				continue
			}
			plan := explainDetails(t, d, st.SQL, append(append([]any{}, st.Args...), 500)...)
			for _, detail := range strings.Split(plan, "\n") {
				for table := range knowledge {
					if strings.HasPrefix(detail, "SCAN "+table) {
						t.Errorf("%s step %q scans %s: %s", src, st.Name, table, detail)
					}
				}
			}
		}
	}
}
