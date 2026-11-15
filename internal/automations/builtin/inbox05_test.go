package builtin

import (
	"context"
	"reflect"
	"testing"
	"time"

	"watchtower/internal/db"
)

// inboxRow is one inbox_items row as SELECT * returns it, column by column.
func inboxRow(t *testing.T, d *db.DB, ts string) map[string]any {
	t.Helper()
	rows, err := d.Query(`SELECT * FROM inbox_items WHERE message_ts = ?`, ts)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		t.Fatal(err)
	}
	if !rows.Next() {
		t.Fatalf("no inbox_items row %s", ts)
	}
	vals := make([]any, len(cols))
	ptrs := make([]any, len(cols))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	if err := rows.Scan(ptrs...); err != nil {
		t.Fatal(err)
	}
	out := make(map[string]any, len(cols))
	for i, c := range cols {
		if b, ok := vals[i].([]byte); ok {
			vals[i] = string(b)
		}
		out[c] = vals[i]
	}
	if rows.Next() {
		t.Fatalf("more than one inbox_items row %s", ts)
	}
	return out
}

// INBOX-05: a source_mute rule scoped email:<address> (any spelling of the
// address) leaves that sender's mail out of attention.waiting — Mail waiting
// only. It never changes the inbox_items row, and the Messages / Catch-Up
// reader (db.OpenInboxItems) still returns the item. A source_mute rule
// scoped sender:<id> mutes nothing here.
func TestInbox05_MutedSenderLeavesMailWaitingOnly(t *testing.T) {
	f := newFixture(t)
	now := f.clock.Now()
	f.insertMail(t, "3000.0001", " Muted@Example.com ", "Muted subject", now)
	f.insertMail(t, "3000.0002", "other@example.com", "Other subject", now.Add(-time.Minute))
	stamp := now.UTC().Format(time.RFC3339)
	for _, scope := range []string{"email:muted@example.com", "sender:other@example.com"} {
		if _, err := f.d.Exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
			VALUES ('source_mute', ?, -1, 'user_rule', ?)`, scope, stamp); err != nil {
			t.Fatal(err)
		}
	}
	before := inboxRow(t, f.d, "3000.0001")

	fields := waitingFields(t, f.d, now)

	if m := rowsOf(t, fields, "mail_items"); len(m) != 1 || m[0]["who"] != "other@example.com" {
		t.Errorf("mail_items = %v; want other@example.com's mail only (a sender: rule mutes nothing)", m)
	}
	if s := rowsOf(t, fields, "senders"); len(s) != 1 || s[0]["address"] != "other@example.com" {
		t.Errorf("senders = %v; want other@example.com only", s)
	}
	for _, it := range rowsOf(t, fields, "items") {
		if it["trigger"] == "email_received" {
			t.Errorf("items has mail row %v; want people only (the muted mail in neither list)", it)
		}
	}

	after := inboxRow(t, f.d, "3000.0001")
	if len(after) != len(before) {
		t.Fatalf("row has %d columns after, %d before", len(after), len(before))
	}
	for c, v := range before {
		if !reflect.DeepEqual(after[c], v) {
			t.Errorf("inbox_items.%s = %v after the run; was %v", c, after[c], v)
		}
	}

	open, err := f.d.OpenInboxItems(context.Background(), now, 200)
	if err != nil {
		t.Fatal(err)
	}
	found := map[string]bool{}
	for _, it := range open {
		found[it.MessageTS] = true
	}
	if !found["3000.0001"] || !found["3000.0002"] {
		t.Errorf("OpenInboxItems = %v; want both mail items (a mute hides Mail waiting only)", found)
	}
}
