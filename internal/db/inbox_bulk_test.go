package db

import (
	"context"
	"fmt"
	"maps"
	"slices"
	"strings"
	"testing"
	"time"
)

// Every spelling of a sender's address names the same open mail, newest
// first; a muted sender's mail is named too.
func TestOpenMailItemIDsFrom_MatchesEverySpelling(t *testing.T) {
	d := openTestDB(t)
	fx := SeedTestWaitingSplitFixture(t, d, waitingSplitFixture)
	ctx := context.Background()
	for addr, want := range fx.Expected.SenderIDs {
		if addr == "" {
			continue // the CLI refuses an empty sender
		}
		for _, spelling := range []string{addr, strings.ToUpper(addr), "  " + addr + " "} {
			got, err := d.OpenMailItemIDsFrom(ctx, fx.Now, spelling)
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(got, want) {
				t.Errorf("OpenMailItemIDsFrom(%q) = %v, want %v", spelling, got, want)
			}
		}
	}
	got, err := d.OpenMailItemIDsFrom(ctx, fx.Now, "news@example.com")
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(got, []int64{24}) {
		t.Errorf("muted sender's ids = %v, want [24]", got)
	}
	got, err = d.OpenMailItemIDsFrom(ctx, fx.Now, "nobody@example.com")
	if err != nil || len(got) != 0 {
		t.Errorf("unknown sender = %v, %v; want none", got, err)
	}
}

// The people items at least WaitingOlderAfter old are the fixture's Older
// section: exactly 7 × 24 h old is in, one second younger is out, mail
// never is.
func TestOpenPeopleItemIDsOlderThan_MatchesTheOlderSection(t *testing.T) {
	d := openTestDB(t)
	fx := SeedTestWaitingSplitFixture(t, d, waitingSplitFixture)
	got, err := d.OpenPeopleItemIDsOlderThan(context.Background(), fx.Now, WaitingOlderAfter)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(got, fx.Expected.OlderPeopleIDs) {
		t.Fatalf("older people ids = %v, want %v", got, fx.Expected.OlderPeopleIDs)
	}
	if !slices.Contains(got, 5) {
		t.Error("item 5 (exactly 7 × 24 h old) missing")
	}
	if slices.Contains(got, 7) {
		t.Error("item 7 (one second younger) included")
	}
	for _, id := range got {
		if fx.Expected.Kinds[id] != WaitingPeople {
			t.Errorf("item %d is not a people item", id)
		}
	}
	// Mail as old as Older (22, 30) is never named.
	if slices.Contains(got, 22) || slices.Contains(got, 30) {
		t.Errorf("older ids %v include mail", got)
	}
}

// inboxRow reads an inbox_items row as column → value.
func inboxRow(t *testing.T, d *DB, id int64) map[string]any {
	t.Helper()
	rows, err := d.Query(`SELECT * FROM inbox_items WHERE id = ?`, id)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		t.Fatal(err)
	}
	if !rows.Next() {
		t.Fatalf("no inbox item %d", id)
	}
	vals := make([]any, len(cols))
	ptrs := make([]any, len(cols))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	if err := rows.Scan(ptrs...); err != nil {
		t.Fatal(err)
	}
	out := map[string]any{}
	for i, c := range cols {
		if b, ok := vals[i].([]byte); ok {
			vals[i] = string(b)
		}
		out[c] = vals[i]
	}
	return out
}

func insertBulkItem(t *testing.T, d *DB, id int64, status string) {
	t.Helper()
	if _, err := d.Exec(`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type, snippet,
		status, snooze_until, created_at, updated_at, read_at)
		VALUES (?, 'C001', ?, 'U001', 'mention', 'hello', ?, CASE WHEN ? = 'snoozed' THEN '2030-01-01T00:00:00Z' ELSE '' END,
		'2026-11-01T10:00:00Z', '2026-11-01T10:00:00Z', '2026-11-01T11:00:00Z')`,
		id, fmt.Sprintf("1000.%04d", id), status, status); err != nil {
		t.Fatal(err)
	}
}

// bulkNow is the clock of the bulk-resolve tests.
var bulkNow = time.Date(2026, 11, 11, 8, 0, 0, 0, time.UTC)

// Only rows open at now (openInboxClause, the dry run's rule) are resolved,
// with the bulk reason; closed, snoozed, archived, ambient, deleted-Jira and
// unknown ids are skipped; no other column changes.
func TestResolveOpenInboxItems_SkipsClosedSnoozedAndUnknown(t *testing.T) {
	d := openTestDB(t)
	statuses := map[int64]string{1: "pending", 2: "resolved", 3: "snoozed", 4: "dismissed", 5: "pending",
		6: "pending", 7: "pending", 8: "pending", 9: "pending", 10: "pending"}
	for _, id := range slices.Sorted(maps.Keys(statuses)) {
		insertBulkItem(t, d, id, statuses[id])
	}
	account := SeedTestJiraAccount(t, d)
	stamp := sqlStamp(bulkNow)
	for _, q := range []string{
		// 6: archived by the daemon after the dry run.
		`UPDATE inbox_items SET archived_at = '2026-11-11T07:00:00Z', archive_reason = 'stale' WHERE id = 6`,
		// 7: pending but snoozed until after now.
		`UPDATE inbox_items SET snooze_until = '2026-11-12T08:00:00Z' WHERE id = 7`,
		// 8: a Jira item whose issue was deleted at the source.
		`UPDATE inbox_items SET trigger_type = 'jira_assigned', channel_id = 'ACME-2' WHERE id = 8`,
		// 9: a snooze already past — open, resolved.
		`UPDATE inbox_items SET snooze_until = '2026-11-11T06:00:00Z' WHERE id = 9`,
		// 10: ambient — never open.
		`UPDATE inbox_items SET item_class = 'ambient' WHERE id = 10`,
	} {
		if _, err := d.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := d.Exec(`INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category,
		created_at, updated_at, synced_at, is_deleted) VALUES (?, 'ACME-2', 'ACME', 'ACME-2', 'To Do', 'new', ?, ?, ?, 1)`,
		account, stamp, stamp, stamp); err != nil {
		t.Fatal(err)
	}
	wantResolved := []int64{5, 9, 1}
	before := map[int64]map[string]any{}
	for id := range statuses {
		before[id] = inboxRow(t, d, id)
	}

	got, err := d.ResolveOpenInboxItems(context.Background(), bulkNow,
		[]int64{5, 2, 3, 4, 6, 7, 8, 999, 9, 10, 1, 5}, BulkResolveReason)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(got, wantResolved) {
		t.Fatalf("resolved = %v, want %v (input order, duplicates dropped)", got, wantResolved)
	}
	for id := range statuses {
		after := inboxRow(t, d, id)
		want := maps.Clone(before[id])
		if slices.Contains(wantResolved, id) {
			if after["updated_at"] == before[id]["updated_at"] {
				t.Errorf("item %d: updated_at not moved", id)
			}
			want["status"], want["resolved_reason"], want["updated_at"] = "resolved", "Marked done in bulk", after["updated_at"]
		}
		if !maps.Equal(after, want) {
			t.Errorf("item %d:\n got %v\nwant %v", id, after, want)
		}
	}
	if got, err := d.ResolveOpenInboxItems(context.Background(), bulkNow, nil, BulkResolveReason); err != nil || len(got) != 0 {
		t.Errorf("no ids = %v, %v; want none", got, err)
	}
}

// Each chunk of 200 is its own transaction: a failed third chunk keeps the
// first two resolved, reports them with the error, and leaves the rest open.
func TestResolveOpenInboxItems_ChunksAndReportsPartial(t *testing.T) {
	d := openTestDB(t)
	ids := make([]int64, 0, 450)
	for id := int64(1); id <= 450; id++ {
		insertBulkItem(t, d, id, "pending")
		ids = append(ids, id)
	}
	if _, err := d.Exec(`CREATE TRIGGER fail_third_chunk BEFORE UPDATE OF status ON inbox_items
		WHEN OLD.id > 400 BEGIN SELECT RAISE(ABORT, 'chunk refused'); END`); err != nil {
		t.Fatal(err)
	}
	got, err := d.ResolveOpenInboxItems(context.Background(), bulkNow, ids, BulkResolveReason)
	if err == nil {
		t.Fatal("want the third chunk's error")
	}
	if !slices.Equal(got, ids[:400]) {
		t.Fatalf("resolved %d ids (%v…), want the first 400", len(got), got[:min(3, len(got))])
	}
	var pending, resolved int
	if err := d.QueryRow(`SELECT COALESCE(SUM(status = 'pending'), 0), COALESCE(SUM(status = 'resolved'), 0) FROM inbox_items`).
		Scan(&pending, &resolved); err != nil {
		t.Fatal(err)
	}
	if pending != 50 || resolved != 400 {
		t.Errorf("pending %d resolved %d, want 50 and 400", pending, resolved)
	}
}

// A cancelled context stops before the first chunk.
func TestResolveOpenInboxItems_CancelledContext(t *testing.T) {
	d := openTestDB(t)
	insertBulkItem(t, d, 1, "pending")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if got, err := d.ResolveOpenInboxItems(ctx, bulkNow, []int64{1}, BulkResolveReason); err == nil || len(got) != 0 {
		t.Errorf("cancelled = %v, %v; want an error and nothing", got, err)
	}
}

// A dry run names at most BulkResolveMaxIDs ids, the newest, so its ids
// always fit one --ids press; the next dry run names the rest.
func TestOpenPeopleItemIDsOlderThan_CappedAtThePressLimit(t *testing.T) {
	d := openTestDB(t)
	const n = BulkResolveMaxIDs + 5
	// Item i is i seconds older than item 1, all past the Older line.
	if _, err := d.Exec(`WITH RECURSIVE seq(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM seq WHERE i < ?)
		INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type, created_at, updated_at)
		SELECT i, 'C001', printf('1000.%05d', i), 'U001', 'mention',
			strftime('%Y-%m-%dT%H:%M:%SZ', '2026-11-01T10:00:00Z', '-' || i || ' seconds'), '2026-11-01T10:00:00Z'
		FROM seq`, n); err != nil {
		t.Fatal(err)
	}
	got, err := d.OpenPeopleItemIDsOlderThan(context.Background(), bulkNow, WaitingOlderAfter)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != BulkResolveMaxIDs || got[0] != 1 || got[len(got)-1] != BulkResolveMaxIDs {
		t.Fatalf("%d ids, first %d, last %d; want %d newest first", len(got), got[0], got[len(got)-1], BulkResolveMaxIDs)
	}
}
