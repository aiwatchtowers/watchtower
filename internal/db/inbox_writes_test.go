package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

// writesSeed is one row for every Inbox writer: an open card, a briefing, a
// message, a track with a digest and an event, an idea, and a plan item of
// a task.
var writesSeed = []string{
	`INSERT INTO automations (id, slug, scope, path, name, enabled, origin) VALUES (1, 'd', 'personal', '/r/d.md', 'D', 1, 'owner')`,
	`INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (1, 1, 'manual', 'succeeded')`,
	`INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, content_hash) VALUES (1, 1, 1, 'inbox', 'C', 'b', 'h1')`,
	`INSERT INTO briefings (id, user_id, date, created_at) VALUES (1, 'U1', '2026-11-16', '2026-11-16T06:00:00Z')`,
	`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type, created_at) VALUES (1, 'C1', '1.0', 'U1', 'mention', '2026-11-16T07:00:00Z')`,
	`INSERT INTO digests (id, channel_id, period_from, period_to, type, summary, decisions, model) VALUES (5, 'C1', 1, 2, 'channel', 's', '[{"text":"a"}]', 'm')`,
	`INSERT INTO tracks (id, text, related_digest_ids, has_updates) VALUES (1, 'T', '[5]', 1)`,
	`INSERT INTO track_events (id, track_id, summary, created_at) VALUES (1, 1, 'moved', '2026-11-16T09:00:00Z')`,
	`INSERT INTO ideas (id, kind, title, status, needs_review) VALUES (1, 'idea', 'I', 'proposed', 1)`,
	`INSERT INTO day_plans (id, user_id, plan_date, generated_at) VALUES (1, 'U1', '2026-11-16', '2026-11-16T07:00:00Z')`,
	`INSERT INTO targets (id, text, level, status, period_start, period_end) VALUES (3, 'Ship', 'day', 'todo', '2026-11-16', '2026-11-16')`,
	`INSERT INTO day_plan_items (id, day_plan_id, kind, source_type, source_id, title, status, order_index) VALUES (1, 1, 'backlog', 'task', '3', 'Ship', 'pending', 0)`,
}

// writesSnapshot is every row the writers touch, as text.
func writesSnapshot(t *testing.T, d *DB) string {
	t.Helper()
	var b strings.Builder
	for _, q := range []string{
		`SELECT id, COALESCE(read_at,''), COALESCE(done_at,''), COALESCE(dismissed_at,'') FROM automation_outputs`,
		`SELECT id, COALESCE(read_at,'') FROM briefings`,
		`SELECT id, status, resolved_reason, snooze_until, COALESCE(read_at,'') FROM inbox_items`,
		`SELECT id, COALESCE(read_at,''), has_updates, dismissed_at, enabled FROM tracks`,
		`SELECT id, COALESCE(read_at,'') FROM digests`,
		`SELECT digest_id, decision_idx FROM decision_reads`,
		`SELECT id, COALESCE(read_at,'') FROM track_events`,
		`SELECT id, status, snooze_until, needs_review FROM ideas`,
		`SELECT id, status FROM day_plan_items`,
		`SELECT id, status, progress FROM targets`,
		`SELECT id, status FROM inbox_items`,
	} {
		b.WriteString(dumpWriteRows(t, d, q))
	}
	return b.String()
}

func dumpWriteRows(t *testing.T, d *DB, q string) string {
	t.Helper()
	rows, err := d.Query(q)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	cols, _ := rows.Columns()
	var b strings.Builder
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			t.Fatal(err)
		}
		fmt.Fprintf(&b, "%v\n", vals)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return b.String()
}

var errInjected = errors.New("injected fault")

// faultAt sets faultAfter to fail at step for the test.
func faultAt(t *testing.T, step string) *int {
	t.Helper()
	hits := 0
	faultAfter = func(s string) error {
		if s == step {
			hits++
			return errInjected
		}
		return nil
	}
	t.Cleanup(func() { faultAfter = nil })
	return &hits
}

var now16 = time.Date(2026, 11, 16, 10, 0, 0, 0, time.UTC)

// inboxWriters are every Tx writer with the step its first statement ends.
var inboxWriters = []struct {
	name, step string
	run        func(tx *sql.Tx) error
}{
	{"MarkOutputReadTx", "output.read_at", func(tx *sql.Tx) error { _, err := MarkOutputReadTx(tx, 1, "h1", now16); return err }},
	{"MarkOutputDoneTx", "output.done_at", func(tx *sql.Tx) error { _, err := MarkOutputDoneTx(tx, 1, "h1", now16); return err }},
	{"DismissOutputTx", "output.dismissed_at", func(tx *sql.Tx) error { _, err := DismissOutputTx(tx, 1, "h1", now16); return err }},
	{"MarkBriefingReadTx", "briefing.read", func(tx *sql.Tx) error { return MarkBriefingReadTx(tx, []int{1}) }},
	{"MarkInboxItemReadTx", "inbox_item.read", func(tx *sql.Tx) error { return MarkInboxItemReadTx(tx, 1) }},
	{"ResolveInboxItemTx", "inbox_item.resolve", func(tx *sql.Tx) error { return ResolveInboxItemTx(tx, 1, "r") }},
	{"DismissInboxItemTx", "inbox_item.dismiss", func(tx *sql.Tx) error { return DismissInboxItemTx(tx, 1) }},
	{"SnoozeInboxItemTx", "inbox_item.snooze", func(tx *sql.Tx) error { return SnoozeInboxItemTx(tx, 1, "2026-11-17") }},
	{"MarkTrackReadTx", "track.read", func(tx *sql.Tx) error { return MarkTrackReadTx(tx, 1) }},
	{"MarkTrackDoneTx", "track.read", func(tx *sql.Tx) error { return MarkTrackDoneTx(tx, 1) }},
	{"StopTrackTx", "track.stop", func(tx *sql.Tx) error { return StopTrackTx(tx, []int{1}) }},
	{"SetTrackEnabledTx", "track.enabled", func(tx *sql.Tx) error { return SetTrackEnabledTx(tx, 1, false) }},
	{"RestoreTrackTx", "track.restore", func(tx *sql.Tx) error { return RestoreTrackTx(tx, 1) }},
	{"SetIdeaVerdictTx", "idea.verdict", func(tx *sql.Tx) error { return SetIdeaVerdictTx(tx, 1, "active") }},
	{"SnoozeIdeaTx", "idea.snooze", func(tx *sql.Tx) error { return SnoozeIdeaTx(tx, 1, nil) }},
	{"SetPlanItemStatusTx", "plan_item.status", func(tx *sql.Tx) error { return SetPlanItemStatusTx(tx, 1, "done", true) }},
}

// TestWriters_FaultSeamRollsBack: a fault after a writer's first statement
// fails it, and the caller's transaction leaves every row as seeded.
func TestWriters_FaultSeamRollsBack(t *testing.T) {
	for _, w := range inboxWriters {
		t.Run(w.name, func(t *testing.T) {
			d := seededTestDB(t)
			if w.name == "RestoreTrackTx" {
				if _, err := d.Exec(`UPDATE tracks SET dismissed_at = '2026-11-16T08:00:00Z'`); err != nil {
					t.Fatal(err)
				}
			}
			before := writesSnapshot(t, d)
			hits := faultAt(t, w.step)
			if err := d.WithTx(w.run); !errors.Is(err, errInjected) {
				t.Fatalf("err %v, want the injected fault", err)
			}
			if *hits != 1 {
				t.Fatalf("the seam at %q ran %d times, want 1", w.step, *hits)
			}
			if after := writesSnapshot(t, d); after != before {
				t.Errorf("rows changed after a rollback:\n%s\nwant\n%s", after, before)
			}
			// Without the fault the writer changes something.
			faultAfter = nil
			if err := d.WithTx(w.run); err != nil {
				t.Fatal(err)
			}
			if writesSnapshot(t, d) == before {
				t.Error("the writer changed nothing without the fault")
			}
		})
	}
}

// killBetween runs w with a fault at each of steps (a process killed
// between two statements of one transaction): every time, the rows stay as
// seeded.
func killBetween(t *testing.T, run func(tx *sql.Tx) error, steps ...string) {
	t.Helper()
	for _, step := range steps {
		d := seededTestDB(t)
		before := writesSnapshot(t, d)
		faultAt(t, step)
		if err := d.WithTx(run); !errors.Is(err, errInjected) {
			t.Fatalf("%s: err %v, want the injected fault", step, err)
		}
		if after := writesSnapshot(t, d); after != before {
			t.Errorf("%s: a kill between statements left a partial write:\n%s\nwant\n%s", step, after, before)
		}
		faultAfter = nil
	}
}

func TestWriters_KillBetweenStatements_TrackDone(t *testing.T) {
	killBetween(t, func(tx *sql.Tx) error { return MarkTrackDoneTx(tx, 1) }, "track.read", "track.digest", "track.done")
}

func TestWriters_KillBetweenStatements_PlanItemCascade(t *testing.T) {
	killBetween(t, func(tx *sql.Tx) error { return SetPlanItemStatusTx(tx, 1, "done", true) }, "plan_item.status")
	// The cascade's own failure (its task gone) rolls the item back too.
	d := seededTestDB(t)
	if _, err := d.Exec(`DELETE FROM targets`); err != nil {
		t.Fatal(err)
	}
	before := writesSnapshot(t, d)
	if err := d.WithTx(func(tx *sql.Tx) error { return SetPlanItemStatusTx(tx, 1, "done", true) }); err == nil {
		t.Fatal("a cascade to a missing task succeeded")
	}
	if after := writesSnapshot(t, d); after != before {
		t.Errorf("the item was marked without its task:\n%s", after)
	}
}

// TestWriters_KillBetweenStatements_ReminderHook: a reminder write commits
// on its own and its approval hook runs after it; a process killed between
// the two leaves the reminder written and nothing queued, which the next
// approval sweep reconciles; a resend writes nothing and fires nothing.
func TestWriters_KillBetweenStatements_ReminderHook(t *testing.T) {
	d := openTestDB(t)
	id, err := d.InsertReminder(Reminder{Note: "n", RemindAt: "2026-11-16T09:00:00Z"})
	if err != nil {
		t.Fatal(err)
	}
	var refs []string
	d.SetApprovalHook(func(ref string) { refs = append(refs, ref) })
	if changed, err := d.MarkReminderDone(id); err != nil || !changed {
		t.Fatalf("MarkReminderDone: %v %v", changed, err)
	}
	if len(refs) != 1 || refs[0] != ReminderRef(id) {
		t.Errorf("hook calls %v, want one for %s", refs, ReminderRef(id))
	}
	// Killed before the hook: the write stands, and a resend is a no-op.
	d.SetApprovalHook(func(string) { t.Error("the hook ran for a write that changed nothing") })
	if changed, err := d.MarkReminderDone(id); err != nil || changed {
		t.Errorf("resend after a kill: changed %v %v, want false", changed, err)
	}
}

func seededTestDB(t *testing.T) *DB {
	t.Helper()
	d := openTestDB(t)
	for _, s := range writesSeed {
		if _, err := d.Exec(s); err != nil {
			t.Fatalf("seed %q: %v", s, err)
		}
	}
	return d
}
