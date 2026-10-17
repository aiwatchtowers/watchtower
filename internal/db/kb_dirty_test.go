package db

import (
	"database/sql"
	"testing"
)

func kbDirtyKeys(t *testing.T, d *DB) map[string]int {
	t.Helper()
	rows, err := d.Query(`SELECT source || '|' || key, gen FROM kb_dirty`)
	if err != nil {
		t.Fatalf("reading kb_dirty: %v", err)
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var k string
		var g int
		if err := rows.Scan(&k, &g); err != nil {
			t.Fatal(err)
		}
		out[k] = g
	}
	return out
}

func upsertMsgs(t *testing.T, d *DB, msgs ...Message) {
	t.Helper()
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.UpsertMessageBatch(tx, msgs); err != nil {
		_ = tx.Rollback()
		t.Fatalf("UpsertMessageBatch: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
}

func slackPair(text string) []Message {
	return []Message{
		{ChannelID: "1:C001", TS: "1700000000.000100", UserID: "1:U001", Text: text},
		{ChannelID: "1:C001", TS: "1700000100.000200", UserID: "1:U001", Text: text,
			ThreadTS: sql.NullString{String: "1700000000.000100", Valid: true}},
	}
}

func TestKBDirty_SlackTextChangeMarksThreadAndDay(t *testing.T) {
	d := openTestDB(t)
	upsertMsgs(t, d, slackPair("first")...)
	if got := kbDirtyKeys(t, d); len(got) != 0 {
		t.Fatalf("fresh inserts marked kb_dirty: %v", got)
	}
	upsertMsgs(t, d, slackPair("second")...)
	got := kbDirtyKeys(t, d)
	for _, k := range []string{
		"slack|slack:day:1:C001:2023-11-14",
		"slack|slack:thread:1:C001:1700000000.000100",
	} {
		if _, ok := got[k]; !ok {
			t.Errorf("missing %q in %v", k, got)
		}
	}
}

func TestKBDirty_UnchangedUpsertMarksNothing(t *testing.T) {
	d := openTestDB(t)
	upsertMsgs(t, d, slackPair("same")...)
	upsertMsgs(t, d, slackPair("same")...)
	if got := kbDirtyKeys(t, d); len(got) != 0 {
		t.Fatalf("unchanged upsert marked: %v", got)
	}
}

func TestKBDirty_TombstoneMarks(t *testing.T) {
	d := openTestDB(t)
	upsertMsgs(t, d, Message{ChannelID: "1:C001", TS: "1700000000.000100", UserID: "1:U001", Text: "zebrafish"})
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'zebrafish'`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("fts before tombstone: n=%d err=%v", n, err)
	}
	if _, err := d.Exec(`UPDATE messages SET is_deleted = 1, text = '' WHERE channel_id = '1:C001'`); err != nil {
		t.Fatal(err)
	}
	if _, ok := kbDirtyKeys(t, d)["slack|slack:day:1:C001:2023-11-14"]; !ok {
		t.Error("tombstone did not mark the day key")
	}
	if err := d.QueryRow(`SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'zebrafish'`).Scan(&n); err != nil || n != 0 {
		t.Errorf("fts after tombstone: n=%d err=%v", n, err)
	}
}

func TestKBDirty_ReMarkBumpsGen(t *testing.T) {
	d := openTestDB(t)
	m := Message{ChannelID: "1:C001", TS: "1700000000.000100", UserID: "1:U001", Text: "a"}
	upsertMsgs(t, d, m)
	for _, txt := range []string{"b", "c"} {
		m.Text = txt
		upsertMsgs(t, d, m)
	}
	got := kbDirtyKeys(t, d)
	if len(got) != 1 {
		t.Fatalf("want one row, got %v", got)
	}
	for k, g := range got {
		if g < 1 {
			t.Errorf("%s gen = %d, want >= 1", k, g)
		}
	}
}

func seedGoogleAccount(t *testing.T, d *DB) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO google_accounts (email) VALUES ('owner@example.com')`)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := res.LastInsertId()
	return id
}

func TestKBDirty_GmailDeleteMarksThreadOrMessageKey(t *testing.T) {
	d := openTestDB(t)
	acct := seedGoogleAccount(t, d)
	for _, r := range [][2]string{{"g1", "T1"}, {"g2", ""}} {
		if _, err := d.Exec(`INSERT INTO gmail_messages (account_id, id, thread_id) VALUES (?, ?, ?)`, acct, r[0], r[1]); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := d.Exec(`DELETE FROM gmail_messages WHERE account_id = ?`, acct); err != nil {
		t.Fatal(err)
	}
	got := kbDirtyKeys(t, d)
	for _, k := range []string{"gmail|gmail:1:T1", "gmail|gmail:1:m:g2"} {
		if _, ok := got[k]; !ok {
			t.Errorf("missing %q in %v", k, got)
		}
	}
}

func TestKBDirty_JiraCommentDeleteMarksIssue(t *testing.T) {
	d := openTestDB(t)
	if _, err := d.Exec(`PRAGMA foreign_keys = OFF`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO jira_comments (account_id, issue_key, id) VALUES (1, 'PROJ-1', 'c1')`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`DELETE FROM jira_comments WHERE id = 'c1'`); err != nil {
		t.Fatal(err)
	}
	if _, ok := kbDirtyKeys(t, d)["jira|jira:1:PROJ-1"]; !ok {
		t.Errorf("missing jira key in %v", kbDirtyKeys(t, d))
	}
}

func TestMigration00136_AddsSweepStampColumns(t *testing.T) {
	d := openTestDB(t)
	if _, err := d.Exec(`INSERT INTO slack_accounts (team_id) VALUES ('T1')`); err != nil {
		t.Fatal(err)
	}
	acct := seedGoogleAccount(t, d)
	var day, checked string
	if err := d.QueryRow(`SELECT deletion_sweep_day FROM slack_accounts LIMIT 1`).Scan(&day); err != nil || day != "" {
		t.Errorf("deletion_sweep_day = %q, err %v", day, err)
	}
	if err := d.QueryRow(`SELECT deletions_checked_at FROM google_accounts WHERE id = ?`, acct).Scan(&checked); err != nil || checked != "" {
		t.Errorf("deletions_checked_at = %q, err %v", checked, err)
	}
}
