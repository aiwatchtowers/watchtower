package db

import (
	"context"
	"fmt"
	"strings"
	"testing"
)

// The isolation tests (review #601) purge account 1 next to account 10 — the
// "1:" vs "10:" prefix trap — and a sibling row of another source with the
// same account id, and check that only account 1's rows go.

// seedSlackIsolation seeds Slack accounts 1 and 10 across every
// namespace-keyed table the Slack steps touch, and a Gmail backfill row of
// Google account 1.
func seedSlackIsolation(t *testing.T, d *DB) {
	t.Helper()
	var stmts []string
	for _, a := range []string{"1", "10"} {
		stmts = append(stmts,
			fmt.Sprintf(`INSERT INTO slack_accounts (id, team_id) VALUES (%s, 'T%s')`, a, a),
			fmt.Sprintf(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('%[1]s:C1', '1.0', '%[1]s:U1', 'hi'), ('%[1]s:C1', '2.0', '%[1]s:U1', 'hi')`, a),
			fmt.Sprintf(`INSERT INTO reactions (channel_id, message_ts, user_id, emoji) VALUES ('%[1]s:C1', '1.0', '%[1]s:U1', 'eyes')`, a),
			fmt.Sprintf(`INSERT INTO files (id, message_channel_id, message_ts) VALUES ('F%[1]s', '%[1]s:C1', '1.0')`, a),
			fmt.Sprintf(`INSERT INTO sync_state (channel_id) VALUES ('%s:C1')`, a),
			fmt.Sprintf(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated) VALUES
				('source_mute', 'channel:%[1]s:C1', 1, 'implicit', 'x'), ('source_mute', 'sender:%[1]s:U1', 1, 'implicit', 'x')`, a),
			fmt.Sprintf(`INSERT INTO kb_documents (id, source) VALUES ('slack:thread:%[1]s:C1:1.0', 'slack'), ('slack:day:%[1]s:C1:2026-01-01', 'slack')`, a),
			fmt.Sprintf(`INSERT INTO kb_dirty (source, key) VALUES ('slack', 'slack:thread:%[1]s:C1:1.0'), ('slack', 'slack:day:%[1]s:C1:2026-01-01')`, a),
			fmt.Sprintf(`INSERT INTO doc_links (from_kind, from_ref, to_kind, to_ref) VALUES ('slack', 'slack:thread:%[1]s:C1:1.0', 'confluence_page', 'c:%[1]s')`, a),
			fmt.Sprintf(`INSERT INTO history_backfill (source_kind, account_id, floor_ts, upper_ts, reached_ts, started_at, updated_at) VALUES ('slack', %s, 0, 1, 1, 'x', 'x')`, a),
			fmt.Sprintf(`INSERT INTO reaction_commands (account_id, channel_id, message_ts, emoji) VALUES (%[1]s, '%[1]s:C1', '1.0', 'eyes')`, a),
			fmt.Sprintf(`INSERT INTO reaction_events (account_id, channel_id, message_ts, emoji, seen_at) VALUES (%[1]s, '%[1]s:C1', '1.0', 'eyes', 'x')`, a),
			fmt.Sprintf(`INSERT INTO users (id, name) VALUES ('%s:U1', 'u')`, a),
			fmt.Sprintf(`INSERT INTO channels (id, name, type) VALUES ('%s:C1', 'c', 'public')`, a),
		)
	}
	stmts = append(stmts,
		`INSERT INTO google_accounts (id, email) VALUES (1, 'a@example.com')`,
		`INSERT INTO history_backfill (source_kind, account_id, floor_ts, upper_ts, reached_ts, started_at, updated_at) VALUES ('gmail', 1, 0, 1, 1, 'x', 'x')`,
	)
	mustExecAll(t, d, stmts...)
}

// seedTrackerIsolation seeds Jira and Linear accounts 1 and 10, Confluence
// spaces 1 (account 1) and 10 (account 10), stream digests with their
// knowledge documents, the inbox items whose issue key both accounts share,
// and a Slack backfill row of Slack account 1.
func seedTrackerIsolation(t *testing.T, d *DB) {
	t.Helper()
	var stmts []string
	for _, a := range []string{"1", "10"} {
		stmts = append(stmts,
			fmt.Sprintf(`INSERT INTO jira_accounts (id, cloud_id) VALUES (%[1]s, 'c%[1]s')`, a),
			fmt.Sprintf(`INSERT INTO jira_boards (account_id, id, name) VALUES (%s, 7, 'A')`, a),
			fmt.Sprintf(`INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category, created_at, updated_at, synced_at) VALUES
				(%[1]s, 'OPS-%[1]s', 'OPS', 's', 'Open', 'To Do', 'x', 'x', 'x'), (%[1]s, 'OPS-99', 'OPS', 's', 'Open', 'To Do', 'x', 'x', 'x')`, a),
			fmt.Sprintf(`INSERT INTO jira_comments (account_id, issue_key, id) VALUES (%[1]s, 'OPS-%[1]s', 'cm%[1]s')`, a),
			fmt.Sprintf(`INSERT INTO ext_sources (id, provider, jira_account_id, container_key) VALUES (%[1]s, 'confluence', %[1]s, 'ENG')`, a),
			fmt.Sprintf(`INSERT INTO ext_documents (source_id, ext_id, kind) VALUES (%s, 'p1', 'page')`, a),
			fmt.Sprintf(`INSERT INTO kb_documents (id, source) VALUES ('confluence:%[1]s:p1', 'confluence'), ('jira:%[1]s:OPS-%[1]s', 'jira'), ('linear:%[1]s:ENG-%[1]s', 'linear')`, a),
			fmt.Sprintf(`INSERT INTO doc_links (from_kind, from_ref, to_kind, to_ref) VALUES ('confluence', 'confluence:%[1]s:p1', 'jira_issue', 'OPS-1'), ('jira', 'jira:%[1]s:OPS-%[1]s', 'confluence_page', 'c:1')`, a),
			fmt.Sprintf(`INSERT INTO history_backfill (source_kind, account_id, floor_ts, upper_ts, reached_ts, started_at, updated_at) VALUES ('jira', %s, 0, 1, 1, 'x', 'x')`, a),
			fmt.Sprintf(`INSERT INTO linear_accounts (id, org_id) VALUES (%[1]s, 'o%[1]s')`, a),
			fmt.Sprintf(`INSERT INTO linear_teams (account_id, id, key, name) VALUES (%s, 't1', 'ENG', 'Eng')`, a),
			fmt.Sprintf(`INSERT INTO linear_issues (account_id, id, key, team_id, title, created_at, updated_at, synced_at) VALUES
				(%[1]s, 'i%[1]s', 'ENG-%[1]s', 't1', 'x', 'x', 'x', 'x'), (%[1]s, 'i99', 'ENG-99', 't1', 'x', 'x', 'x', 'x')`, a),
		)
	}
	stmts = append(stmts,
		`INSERT INTO stream_digests (id, source, account_id, period_from, period_to) VALUES
			(1, 'jira', 1, 'a', 'b'), (10, 'jira', 10, 'a', 'b'), (2, 'linear', 1, 'a', 'b'), (20, 'linear', 10, 'a', 'b')`,
		`INSERT INTO kb_documents (id, source) VALUES ('stream_digest:1:0', 'stream_digest'), ('stream_digest:10:0', 'stream_digest'),
			('stream_digest:2:0', 'stream_digest'), ('stream_digest:20:0', 'stream_digest')`,
		// The inbox NOT IN guard: OPS-1/ENG-1 are account 1's alone, the -99
		// keys both accounts'.
		`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type) VALUES
			(1, 'OPS-1', '1', '', 'jira_assigned'), (2, 'OPS-99', '1', '', 'jira_assigned'),
			(3, 'ENG-1', '1', '', 'linear_assigned'), (4, 'ENG-99', '1', '', 'linear_assigned')`,
		`INSERT INTO slack_accounts (id, team_id) VALUES (1, 'T1')`,
		`INSERT INTO history_backfill (source_kind, account_id, floor_ts, upper_ts, reached_ts, started_at, updated_at) VALUES ('slack', 1, 0, 1, 1, 'x', 'x')`,
	)
	mustExecAll(t, d, stmts...)
}

type isolationCheck struct {
	q    string
	want int
}

func runChecks(t *testing.T, d *DB, checks []isolationCheck) {
	t.Helper()
	for _, c := range checks {
		if got := count(t, d, c.q); got != c.want {
			t.Errorf("%s = %d, want %d", c.q, got, c.want)
		}
	}
}

func TestPurge02_SlackPrefixIsolation(t *testing.T) {
	d := OpenTestDB(t)
	seedSlackIsolation(t, d)
	drainPurge(t, d, "slack", 1, 1)
	var checks []isolationCheck
	for _, c := range []struct{ table, col, one, ten string }{
		{"messages", "channel_id", "'1:C1'", "'10:C1'"},
		{"reactions", "channel_id", "'1:C1'", "'10:C1'"},
		{"files", "message_channel_id", "'1:C1'", "'10:C1'"},
		{"sync_state", "channel_id", "'1:C1'", "'10:C1'"},
		{"inbox_learned_rules", "scope_key", "'channel:1:C1'", "'channel:10:C1'"},
		{"inbox_learned_rules", "scope_key", "'sender:1:U1'", "'sender:10:U1'"},
		{"kb_documents", "id", "'slack:thread:1:C1:1.0'", "'slack:thread:10:C1:1.0'"},
		{"kb_documents", "id", "'slack:day:1:C1:2026-01-01'", "'slack:day:10:C1:2026-01-01'"},
		{"kb_dirty", "key", "'slack:thread:1:C1:1.0'", "'slack:thread:10:C1:1.0'"},
		{"doc_links", "from_ref", "'slack:thread:1:C1:1.0'", "'slack:thread:10:C1:1.0'"},
		{"history_backfill", "source_kind = 'slack' AND account_id", "1", "10"},
		{"reaction_commands", "account_id", "1", "10"},
		{"reaction_events", "account_id", "1", "10"},
		{"users", "id", "'1:U1'", "'10:U1'"},
		{"channels", "id", "'1:C1'", "'10:C1'"},
	} {
		q := `SELECT COUNT(*) FROM ` + c.table + ` WHERE ` + c.col + ` = `
		checks = append(checks, isolationCheck{q + c.one, 0})
		ten := 1
		if c.table == "messages" {
			ten = 2
		}
		checks = append(checks, isolationCheck{q + c.ten, ten})
	}
	checks = append(checks,
		isolationCheck{`SELECT COUNT(*) FROM history_backfill WHERE source_kind = 'gmail' AND account_id = 1`, 1},
		isolationCheck{`SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'hi'`, 2},
	)
	runChecks(t, d, checks)
}

func TestPurge02_TrackerSiblingIsolation(t *testing.T) {
	d := OpenTestDB(t)
	seedTrackerIsolation(t, d)
	drainPurge(t, d, "jira", 1, 1)
	drainPurge(t, d, "linear", 1, 1)
	runChecks(t, d, []isolationCheck{
		{`SELECT COUNT(*) FROM jira_issues WHERE account_id = 1`, 0},
		{`SELECT COUNT(*) FROM jira_issues WHERE account_id = 10`, 2},
		{`SELECT COUNT(*) FROM jira_boards WHERE account_id = 10`, 1},
		{`SELECT COUNT(*) FROM jira_comments WHERE account_id = 10`, 1},
		{`SELECT COUNT(*) FROM ext_sources WHERE id = 10`, 1},
		{`SELECT COUNT(*) FROM ext_sources WHERE id = 1`, 0},
		{`SELECT COUNT(*) FROM ext_documents WHERE source_id = 10`, 1},
		{`SELECT COUNT(*) FROM kb_documents WHERE id IN ('confluence:1:p1', 'jira:1:OPS-1', 'linear:1:ENG-1', 'stream_digest:1:0', 'stream_digest:2:0')`, 0},
		{`SELECT COUNT(*) FROM kb_documents WHERE id IN ('confluence:10:p1', 'jira:10:OPS-10', 'linear:10:ENG-10', 'stream_digest:10:0', 'stream_digest:20:0')`, 5},
		{`SELECT COUNT(*) FROM kb_dirty WHERE key LIKE 'jira:1:%'`, 0}, // the jira_comments delete trigger's marks go too
		{`SELECT COUNT(*) FROM doc_links WHERE from_ref IN ('confluence:1:p1', 'jira:1:OPS-1')`, 0},
		{`SELECT COUNT(*) FROM doc_links WHERE from_ref IN ('confluence:10:p1', 'jira:10:OPS-10')`, 2},
		{`SELECT COUNT(*) FROM stream_digests WHERE id IN (10, 20)`, 2},
		{`SELECT COUNT(*) FROM stream_digests WHERE id IN (1, 2)`, 0},
		{`SELECT COUNT(*) FROM history_backfill WHERE source_kind = 'jira' AND account_id = 10`, 1},
		{`SELECT COUNT(*) FROM history_backfill WHERE source_kind = 'slack' AND account_id = 1`, 1},
		{`SELECT COUNT(*) FROM linear_issues WHERE account_id = 10`, 2},
		{`SELECT COUNT(*) FROM linear_teams WHERE account_id = 10`, 1},
		{`SELECT COUNT(*) FROM inbox_items WHERE id IN (1, 3)`, 0},
		{`SELECT COUNT(*) FROM inbox_items WHERE id IN (2, 4)`, 2}, // shared keys: not attributable
	})
}

// fingerprint is every table's row count.
func fingerprint(t *testing.T, d *DB) string {
	t.Helper()
	var b strings.Builder
	names := queryStrings(t, d, `SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name`)
	for _, n := range names {
		fmt.Fprintf(&b, "%s=%d ", n, count(t, d, `SELECT COUNT(*) FROM "`+n+`"`))
	}
	return b.String()
}

// TestPurge02_ResumeAfterAnyStop stops a purge after every possible number
// of one-row chunks, across the whole multi-step order, re-reads the step
// list (as a restarted daemon does) and finishes: the result is always the
// one an uninterrupted purge gives.
func TestPurge02_ResumeAfterAnyStop(t *testing.T) {
	cases := []struct {
		source string
		seed   func(*testing.T, *DB)
	}{
		{"slack", seedSlackIsolation},
		{"jira", seedTrackerIsolation},
		{"linear", seedTrackerIsolation},
	}
	for _, c := range cases {
		t.Run(c.source, func(t *testing.T) {
			ref := OpenTestDB(t)
			c.seed(t, ref)
			total := drainPurge(t, ref, c.source, 1, 1)
			want := fingerprint(t, ref)
			for stop := int64(1); stop < total; stop++ {
				d := OpenTestDB(t)
				c.seed(t, d)
				steps, err := d.PurgeSteps(c.source, 1)
				if err != nil {
					t.Fatal(err)
				}
				done := int64(0)
			run:
				for _, st := range steps {
					for done < stop {
						n, err := d.RunPurgeStep(context.Background(), st, 1)
						if err != nil {
							t.Fatal(err)
						}
						if n == 0 {
							continue run
						}
						done += n
					}
					break
				}
				drainPurge(t, d, c.source, 1, 1)
				if got := fingerprint(t, d); got != want {
					t.Fatalf("stopped after %d rows: the resumed purge differs\n got %s\nwant %s", stop, got, want)
				}
				d.Close()
			}
		})
	}
}
