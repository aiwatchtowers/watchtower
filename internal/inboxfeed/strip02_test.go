package inboxfeed

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// The STRIP-02 writer guards (docs/inventory/reaction-commands.md), moved
// from the Desktop's query tests when the Swift writers were deleted (#1170
// Task 12): every Desktop press is now one of the tower's screen commands,
// and each guard keeps its Swift name and its full-row assertions over the
// command the Mac sends. The strip's own guards (TestStrip02_DoneWritesOnlyDoneAt,
// TestStrip02_DismissWritesOnlyDismissedAt, TestStrip02_MarkReminderDoneDropsItOnNextRefresh,
// TestStrip02_SnoozeReminderMovesItOutOfTheDueWindow, …) are in strip_test.go.

// screenCall runs command with params over the Mac's socket and fails the
// test unless it answered ok.
func screenCall(t *testing.T, d *db.DB, command string, params any) api.Response {
	t.Helper()
	b, err := json.Marshal(params)
	if err != nil {
		t.Fatal(err)
	}
	resp := callScreen(screenTower(d, actNow, ActDeps{}), command, b, socket)
	if resp.Status != api.StatusOK {
		t.Fatalf("%s: status %s %+v, want ok", command, resp.Status, resp.Refusal)
	}
	return resp
}

func write() api.WriteParams { return api.WriteParams{RequestID: newRequestID()} }

// TestStrip02_OutputWritesTouchOnlyTheirOwnColumn: opening, Done and
// Dismiss (outputs.read/done/dismiss) each stamp only their own column; a
// second open keeps the first stamp, and a done or dismissed card takes no
// further stamp.
func TestStrip02_OutputWritesTouchOnlyTheirOwnColumn(t *testing.T) {
	d := seeded(t, []string{stripAutomation, stripRun,
		stripOutput(1, "inbox", "a", "2026-11-16T08:00:00Z", ""),
		stripOutput(2, "inbox", "b", "2026-11-16T08:00:00Z", ""),
		stripOutput(3, "inbox", "c", "2026-11-16T08:00:00Z", "")})
	before := map[int64]map[string]string{}
	for id := int64(1); id <= 3; id++ {
		before[id] = row(t, d, "automation_outputs", id)
	}
	mark := func(command string, id int64) {
		screenCall(t, d, command, api.OutputMarkRequest{WriteParams: write(), ID: id, ContentHash: fmt.Sprintf("h%d", id)})
	}
	mark("outputs.read", 1)
	mark("outputs.done", 2)
	mark("outputs.dismiss", 3)
	// Guarded: opening twice keeps the first stamp, and a done or dismissed
	// card takes no further stamp — answered as a no-op (`already`) or
	// refused as closed (`changed`), never written. The second presses run
	// on a tower whose clock is a minute later, so a second stamp would show
	// by value (the stamps below must all be actNow's).
	later := actNow.Add(time.Minute)
	again := func(command string, id int64) {
		b, err := json.Marshal(api.OutputMarkRequest{WriteParams: write(), ID: id, ContentHash: fmt.Sprintf("h%d", id)})
		if err != nil {
			t.Fatal(err)
		}
		resp := callScreen(screenTower(d, later, ActDeps{}), command, b, socket)
		switch {
		case resp.Status == api.StatusOK:
			if res := actResult(t, resp); !res.Already {
				t.Errorf("%s on output %d wrote again: %+v", command, id, res)
			}
		case resp.Refusal == nil || resp.Refusal.Code != api.CodeChanged:
			t.Errorf("%s on output %d: %s %+v, want already or changed", command, id, resp.Status, resp.Refusal)
		}
	}
	again("outputs.read", 1)
	again("outputs.read", 2)
	again("outputs.dismiss", 2)
	again("outputs.done", 3)
	again("outputs.read", 3)

	if n := len(dumpTable(t, d, "automation_outputs")); n != len(before) {
		t.Fatalf("%d rows, want %d", n, len(before))
	}
	stamps := map[string]bool{"read_at": true, "done_at": true, "dismissed_at": true}
	for id := int64(1); id <= 3; id++ {
		for c, v := range row(t, d, "automation_outputs", id) {
			if !stamps[c] && before[id][c] != v {
				t.Errorf("output %d: %s = %q, was %q", id, c, v, before[id][c])
			}
		}
	}
	stamped := actNow.UTC().Format("2006-01-02T15:04:05Z")
	if stamped == later.UTC().Format("2006-01-02T15:04:05Z") {
		t.Fatal("the second clock must stamp another value")
	}
	var got [][3]string
	for id := int64(1); id <= 3; id++ {
		r := row(t, d, "automation_outputs", id)
		got = append(got, [3]string{r["read_at"], r["done_at"], r["dismissed_at"]})
	}
	want := [][3]string{{stamped, "", ""}, {"", stamped, ""}, {"", "", stamped}}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("read/done/dismissed stamps %v, want %v", got, want)
	}
}

func pendingReminder() []string {
	return []string{`INSERT INTO reminders (id, message_ref, note, remind_at, status)
		VALUES (1, 'C1@1', 'a', '2000-01-01T00:00:00Z', 'pending')`}
}

// dueReminders is the due set at nowUTC (ReminderQueries.fetchDue's rule).
func dueReminders(t *testing.T, d *db.DB, nowUTC string) []string {
	t.Helper()
	rows, err := d.Query(`SELECT message_ref FROM reminders WHERE status = 'pending' AND remind_at <= ? ORDER BY remind_at, id`, nowUTC)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var ref string
		if err := rows.Scan(&ref); err != nil {
			t.Fatal(err)
		}
		out = append(out, ref)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// TestStrip02_MarkDoneRemovesFromDue: reminders.done drops the reminder out
// of the due set and stamps it done.
func TestStrip02_MarkDoneRemovesFromDue(t *testing.T) {
	d := seeded(t, pendingReminder())
	screenCall(t, d, "reminders.done", api.ReminderWriteRequest{WriteParams: write(), ID: 1})
	if due := dueReminders(t, d, "2100-01-01T00:00:00Z"); len(due) != 0 {
		t.Errorf("due %v: a done reminder must drop out of the due set", due)
	}
	r := row(t, d, "reminders", 1)
	if r["status"] != "done" {
		t.Errorf("status %q, want done", r["status"])
	}
	if r["done_at"] == "" {
		t.Error("done_at not stamped")
	}
}

// TestStrip02_SnoozeBumpsRemindAt: reminders.snooze moves remind_at; the
// reminder stays pending and is due once the new time has passed.
func TestStrip02_SnoozeBumpsRemindAt(t *testing.T) {
	d := seeded(t, pendingReminder())
	screenCall(t, d, "reminders.snooze", api.ReminderWriteRequest{WriteParams: write(), ID: 1, Until: "2999-01-01T00:00:00Z"})
	if due := dueReminders(t, d, "2100-01-01T00:00:00Z"); len(due) != 0 {
		t.Errorf("due %v: a snoozed reminder must not be due before its new remind_at", due)
	}
	if due := dueReminders(t, d, "3000-01-01T00:00:00Z"); fmt.Sprint(due) != "[C1@1]" {
		t.Errorf("due %v, want [C1@1]: still pending, so due once its new remind_at has passed", due)
	}
}

// TestStrip02_MarkMessageReadWritesOnlyReadAt: inbox_items.read writes only
// read_at, and never moves a read_at already there.
func TestStrip02_MarkMessageReadWritesOnlyReadAt(t *testing.T) {
	d := seeded(t, messageSeed())
	before := row(t, d, "inbox_items", 1)
	screenCall(t, d, "inbox_items.read", api.ScreenIDRequest{WriteParams: write(), ID: 1})
	after := row(t, d, "inbox_items", 1)
	if after["read_at"] == "" {
		t.Error("read_at not stamped")
	}
	if got := changedColumns(before, after); fmt.Sprint(got) != "[read_at]" {
		t.Errorf("changed %v, want only [read_at]", got)
	}
	if _, err := d.Exec(`UPDATE inbox_items SET read_at = '2026-10-01T00:00:00Z' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	screenCall(t, d, "inbox_items.read", api.ScreenIDRequest{WriteParams: write(), ID: 1})
	if r := row(t, d, "inbox_items", 1); r["read_at"] != "2026-10-01T00:00:00Z" {
		t.Errorf("read_at %q, want the first stamp kept", r["read_at"])
	}
}

// TestStrip02_MarkAllEventsReadTouchesOnlyThatTrack: tracks.events_read
// without an event marks every event of its track read and no other track's.
func TestStrip02_MarkAllEventsReadTouchesOnlyThatTrack(t *testing.T) {
	d := seeded(t, []string{
		"INSERT INTO tracks (id, text, updated_at) VALUES (1, 'A', '2026-11-15T09:00:00Z')",
		"INSERT INTO tracks (id, text, updated_at) VALUES (2, 'B', '2026-11-15T09:00:00Z')",
		"INSERT INTO track_events (track_id, summary) VALUES (1, 's')",
		"INSERT INTO track_events (track_id, summary) VALUES (1, 's')",
		"INSERT INTO track_events (track_id, summary) VALUES (2, 's')",
	})
	screenCall(t, d, "tracks.events_read", api.TrackEventsReadRequest{WriteParams: write(), TrackID: 1})
	unread := func(track int) int {
		var n int
		if err := d.QueryRow(`SELECT COUNT(*) FROM track_events WHERE track_id = ? AND (read_at IS NULL OR read_at = '')`,
			track).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if n := unread(1); n != 0 {
		t.Errorf("track 1 has %d unread events, want 0", n)
	}
	if n := unread(2); n != 1 {
		t.Errorf("track 2 has %d unread events, want 1: another track's events are untouched", n)
	}
}
