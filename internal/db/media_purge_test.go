package db

import (
	"context"
	"fmt"
	"strings"
	"testing"
)

// mediaPurgeSources maps each media_items parent column (the first column
// of each of its foreign keys) to the purge source whose accounts own it.
// A column in mediaPurgeKept is deliberately left to its parent, with the
// reason. A new parent column in neither map fails the guard.
var (
	mediaPurgeSources = map[string]string{
		"slack_channel_id": "slack",
		"gmail_account_id": "google",
		"ext_source_id":    "jira", // Confluence spaces belong to a Jira account
	}
	mediaPurgeKept = map[string]string{
		"imap_account_id":    "IMAP is not a purge source; the rows stay with imap_messages (purgeKeptTables)",
		"chat_attachment_id": "the owner's own upload, no account",
		"target_image_id":    "the owner's own upload, no account",
	}
)

// mediaParentFKs reads media_items' foreign keys: parent column → parent table.
func mediaParentFKs(t *testing.T, d *DB) map[string]string {
	t.Helper()
	rows, err := d.Query(`SELECT "from", "table" FROM pragma_foreign_key_list('media_items') WHERE seq = 0`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var col, table string
		if err := rows.Scan(&col, &table); err != nil {
			t.Fatal(err)
		}
		out[col] = table
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// mediaPurgeGaps checks steps (per source) against media_items' parent
// columns: each account-scoped column has a media_items step in its
// source's list that reads the column and runs before the step deleting
// the parent table (so the chunk limit, not a cascade, bounds the delete).
func mediaPurgeGaps(fks map[string]string, steps map[string][]PurgeStep) []string {
	var gaps []string
	for col, parent := range fks {
		_, kept := mediaPurgeKept[col]
		src, owned := mediaPurgeSources[col]
		switch {
		case kept && owned:
			gaps = append(gaps, col+" is both purged and kept")
			continue
		case kept:
			continue
		case !owned:
			gaps = append(gaps, col+" is a new media_items parent column; add it to mediaPurgeSources or mediaPurgeKept")
			continue
		}
		mediaAt, parentAt := -1, -1
		for i, st := range steps[src] {
			if st.Table == "media_items" && strings.Contains(st.SQL, col) && mediaAt < 0 {
				mediaAt = i
			}
			if st.Table == parent && parentAt < 0 {
				parentAt = i
			}
		}
		switch {
		case mediaAt < 0:
			gaps = append(gaps, fmt.Sprintf("no %s purge step deletes media_items by %s", src, col))
		case parentAt >= 0 && mediaAt > parentAt:
			gaps = append(gaps, fmt.Sprintf("the %s media step runs after the %s step", src, parent))
		}
	}
	return gaps
}

func purgeStepLists(t *testing.T, d *DB) map[string][]PurgeStep {
	t.Helper()
	out := map[string][]PurgeStep{}
	for _, src := range purgeSources {
		steps, err := d.PurgeSteps(src, 1)
		if err != nil {
			t.Fatal(err)
		}
		out[src] = steps
	}
	return out
}

// TestPurge02_MediaItemsCoveredPerParent extends the PURGE-02 coverage
// guard to media_items, whose account is read through its parent columns
// (no account_id, no foreign key to an account table): the guard passes on
// the real step lists and fails when any one media step is removed.
func TestPurge02_MediaItemsCoveredPerParent(t *testing.T) {
	d := OpenTestDB(t)
	fks := mediaParentFKs(t, d)
	if len(fks) != 6 {
		t.Fatalf("media_items parent foreign keys = %v, want 6", fks)
	}
	steps := purgeStepLists(t, d)
	if gaps := mediaPurgeGaps(fks, steps); len(gaps) != 0 {
		t.Fatalf("media purge gaps: %v", gaps)
	}
	// each media step seeks its parent-column index, never scans the table
	for src, list := range steps {
		for _, st := range list {
			if st.Table != "media_items" {
				continue
			}
			plan := explainDetails(t, d, st.SQL, append(append([]any{}, st.Args...), 500)...)
			if strings.Contains(plan, "SCAN media_items") {
				t.Errorf("%s step %q scans media_items:\n%s", src, st.Name, plan)
			}
		}
	}
	for col, src := range mediaPurgeSources {
		var cut []PurgeStep
		for _, st := range steps[src] {
			if !(st.Table == "media_items" && strings.Contains(st.SQL, col)) {
				cut = append(cut, st)
			}
		}
		if len(cut) == len(steps[src]) {
			t.Fatalf("%s has no media step for %s", src, col)
		}
		broken := map[string][]PurgeStep{}
		for k, v := range steps {
			broken[k] = v
		}
		broken[src] = cut
		if gaps := mediaPurgeGaps(fks, broken); len(gaps) == 0 {
			t.Errorf("removing the %s media step for %s went unnoticed", src, col)
		}
	}
	// a media step moved after its parent's step is caught too
	moved := map[string][]PurgeStep{}
	for k, v := range steps {
		moved[k] = v
	}
	var slack []PurgeStep
	var media PurgeStep
	for _, st := range steps["slack"] {
		if st.Table == "media_items" {
			media = st
			continue
		}
		slack = append(slack, st)
	}
	moved["slack"] = append(slack, media)
	if gaps := mediaPurgeGaps(fks, moved); len(gaps) == 0 {
		t.Error("a media step after the messages step went unnoticed")
	}
}

// TestPurge02_MediaItemsGoWithEverySource: one ok item per purge source
// (and one on account 2 of each), each source's steps run: account 1's
// items are gone, deleted by the media step itself (so the rows are counted
// on the ledger and the chunk limit applies), account 2's stay.
func TestPurge02_MediaItemsGoWithEverySource(t *testing.T) {
	d := OpenTestDB(t)
	mediaFixtures(t, d)
	mustExecAll(t, d,
		`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '2.0', '1:U1', 'two'), ('2:C1', '1.0', '2:U1', 'other')`,
		`INSERT INTO jira_accounts (id, cloud_id) VALUES (2, 'c2')`,
		`INSERT INTO ext_sources (id, provider, jira_account_id, container_key) VALUES (6, 'confluence', 2, 'OPS')`,
		`INSERT INTO ext_documents (source_id, ext_id, kind) VALUES (6, 'p2', 'page')`,
		`INSERT INTO google_accounts (id, email) VALUES (2, 'b@example.com')`,
		`INSERT INTO gmail_messages (account_id, id) VALUES (2, 'g2')`,
	)
	ok := func(kind, key, cols, vals, kbSource, kbRef string) {
		insertMediaRow(t, d, kind, key, cols+", status, body, kb_source, kb_ref",
			vals+", 'ok', 'b', '"+kbSource+"', '"+kbRef+"'")
	}
	ok("slack", "slack:1:C1:1.0", "slack_channel_id, slack_ts", "'1:C1', '1.0'", "slack", "slack:day:1:C1:1970-01-01")
	ok("slack", "slack:1:C1:2.0", "slack_channel_id, slack_ts", "'1:C1', '2.0'", "slack", "slack:day:1:C1:1970-01-01")
	ok("slack", "slack:2:C1:1.0", "slack_channel_id, slack_ts", "'2:C1', '1.0'", "slack", "slack:day:2:C1:1970-01-01")
	ok("gmail", "gmail:1:g1", "gmail_account_id, gmail_message_id", "1, 'g1'", "gmail", "gmail:1:m:g1")
	ok("gmail", "gmail:2:g2", "gmail_account_id, gmail_message_id", "2, 'g2'", "gmail", "gmail:2:m:g2")
	ok("confluence", "ext:5:p1", "ext_source_id, ext_id", "5, 'p1'", "confluence", "confluence:5:p1")
	ok("confluence", "ext:6:p2", "ext_source_id, ext_id", "6, 'p2'", "confluence", "confluence:6:p2")

	cases := []struct {
		source, mine, other string
		want                int64
	}{
		{"slack", `slack_channel_id = '1:C1'`, `slack_channel_id = '2:C1'`, 2},
		{"google", `gmail_account_id = 1`, `gmail_account_id = 2`, 1},
		{"jira", `ext_source_id = 5`, `ext_source_id = 6`, 1},
	}
	for _, c := range cases {
		t.Run(c.source, func(t *testing.T) {
			steps, err := d.PurgeSteps(c.source, 1)
			if err != nil {
				t.Fatal(err)
			}
			var mediaRows int64
			for _, st := range steps {
				for {
					n, err := d.RunPurgeStep(context.Background(), st, 1)
					if err != nil {
						t.Fatalf("%s: %v", st.Name, err)
					}
					if n > 1 {
						t.Fatalf("%s: one chunk affected %d rows, limit 1", st.Name, n)
					}
					if st.Table == "media_items" {
						mediaRows += n
					}
					if n == 0 {
						break
					}
				}
			}
			if mediaRows != c.want {
				t.Errorf("the media step deleted %d rows, want %d (a cascade deleted the rest uncounted)", mediaRows, c.want)
			}
			if n := count(t, d, `SELECT COUNT(*) FROM media_items WHERE `+c.mine); n != 0 {
				t.Errorf("account 1 media items left: %d", n)
			}
			if n := count(t, d, `SELECT COUNT(*) FROM media_items WHERE `+c.other); n != 1 {
				t.Errorf("account 2 media items = %d, want 1", n)
			}
		})
	}
	// the purge's own kb_dirty marks of account 1 went with its knowledge steps
	for k := range kbDirtyKeys(t, d) {
		if strings.Contains(k, ":1:") || strings.Contains(k, ":5:") {
			t.Errorf("a purged account's mark survived: %s", k)
		}
	}
}

// Deleting a conversation cascades to its attachments and their items;
// deleting a target cascades to its images and their items.
func TestChatAndTargetDeleteTakeMedia(t *testing.T) {
	d := OpenTestDB(t)
	mediaFixtures(t, d)
	if n := count(t, d, `SELECT COUNT(*) FROM media_items WHERE parent_kind IN ('chat', 'target')`); n != 2 {
		t.Fatalf("owner-upload items = %d, want 2", n)
	}
	mustExecAll(t, d, `DELETE FROM chat_conversations WHERE id = 1`)
	if n := count(t, d, `SELECT COUNT(*) FROM media_items WHERE parent_kind = 'chat'`); n != 0 {
		t.Errorf("a deleted conversation left %d chat items", n)
	}
	mustExecAll(t, d, `DELETE FROM targets WHERE id = 1`)
	if n := count(t, d, `SELECT COUNT(*) FROM media_items WHERE parent_kind = 'target'`); n != 0 {
		t.Errorf("a deleted target left %d target items", n)
	}
}
