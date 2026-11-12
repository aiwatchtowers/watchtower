package builtin

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
)

// windowTestID is the test-only built-in that reads the Slack window.
const windowTestID = "window-test"

// slackSeed is account 1 (owner 1:U0OWNER, "Owner A") with the member
// channel 1:C0ACME (#acme-release) and the non-member channel 1:C0OTHER.
type slackSeed struct {
	t   *testing.T
	d   *db.DB
	seq int
}

func newSlackSeed(t *testing.T) *slackSeed {
	t.Helper()
	d := db.OpenTestDB(t)
	if _, err := d.CreateSlackAccount(db.SlackAccount{TeamID: "T1", TeamName: "acme", TeamDomain: "acme",
		CurrentUserID: "1:U0OWNER"}); err != nil {
		t.Fatal(err)
	}
	s := &slackSeed{t: t, d: d}
	s.exec(`INSERT INTO users (id, name, display_name) VALUES ('1:U0OWNER', 'owner', 'Owner A'), ('1:U0BOB', 'bob', 'Bob')`)
	s.exec(`INSERT INTO channels (id, name, type, is_member) VALUES ('1:C0ACME', 'acme-release', 'public', 1),
		('1:C0OTHER', 'other', 'public', 0)`)
	return s
}

func (s *slackSeed) exec(q string, args ...any) {
	s.t.Helper()
	if _, err := s.d.Exec(q, args...); err != nil {
		s.t.Fatal(err)
	}
}

// msg inserts a message at `at` and returns its ts.
func (s *slackSeed) msg(channel, user, text, threadTS, permalink string, at time.Time) string {
	s.t.Helper()
	s.seq++
	ts := fmt.Sprintf("%d.%06d", at.Unix(), s.seq)
	var thread any
	if threadTS != "" {
		thread = threadTS
	}
	s.exec(`INSERT INTO messages (channel_id, ts, thread_ts, user_id, text, permalink) VALUES (?, ?, ?, ?, ?, ?)`,
		channel, ts, thread, user, text, permalink)
	return ts
}

func (s *slackSeed) maxRowID() int64 {
	s.t.Helper()
	var id int64
	if err := s.d.QueryRow(`SELECT COALESCE(MAX(rowid), 0) FROM messages`).Scan(&id); err != nil {
		s.t.Fatal(err)
	}
	return id
}

// withWindowEntry adds a test built-in that lists slack.window with scope
// for the test.
func withWindowEntry(t *testing.T, scope db.WindowScope) {
	t.Helper()
	old := registry
	registry = append(append([]Entry(nil), registry...), Entry{ID: windowTestID, Name: "Window test",
		Primitives: []string{automations.PrimitiveSlackWindow}, WindowScope: scope})
	t.Cleanup(func() { registry = old })
}

// withLocal sets time.Local for the test.
func withLocal(t *testing.T, loc *time.Location) {
	t.Helper()
	old := time.Local
	time.Local = loc
	t.Cleanup(func() { time.Local = old })
}

func callWindow(t *testing.T, d *db.DB, now time.Time, call automations.PrimitiveCall) (automations.PrimitiveResult, error) {
	t.Helper()
	fn := SlackWindowPrimitives(d, func() time.Time { return now })[automations.PrimitiveSlackWindow]
	if fn == nil {
		t.Fatal("no slack.window primitive")
	}
	call.Name = automations.PrimitiveSlackWindow
	if call.BuiltinID == "" {
		call.BuiltinID = windowTestID
	}
	return fn(context.Background(), call)
}

func mustWindow(t *testing.T, d *db.DB, now time.Time, call automations.PrimitiveCall) automations.PrimitiveResult {
	t.Helper()
	res, err := callWindow(t, d, now, call)
	if err != nil {
		t.Fatalf("slack.window: %v", err)
	}
	return res
}

func windowMessages(t *testing.T, res automations.PrimitiveResult) []map[string]any {
	t.Helper()
	raw, ok := res.Fields["messages"].([]any)
	if !ok {
		t.Fatalf("messages is %T, want []any (a script array)", res.Fields["messages"])
	}
	msgs := make([]map[string]any, 0, len(raw))
	for _, r := range raw {
		m, ok := r.(map[string]any)
		if !ok {
			t.Fatalf("a message is %T", r)
		}
		msgs = append(msgs, m)
	}
	return msgs
}

func TestSlackWindowPrimitive_FieldsShape(t *testing.T) {
	withWindowEntry(t, db.WindowScopeMemberChannels)
	withLocal(t, time.FixedZone("UTC+5", 5*3600))
	s := newSlackSeed(t)
	now := time.Date(2026, 11, 12, 6, 0, 0, 0, time.UTC) // 11:00 local
	root := s.msg("1:C0ACME", "1:U0OWNER", "ship it", "", "https://acme.example.com/archives/1", now.Add(-2*time.Hour))
	reply := s.msg("1:C0ACME", "1:U0BOB", "<@U0OWNER> done", root, "javascript:alert(1)", now.Add(-time.Hour))

	res := mustWindow(t, s.d, now, automations.PrimitiveCall{})
	if res.Status != "done" {
		t.Fatalf("status %q", res.Status)
	}
	for _, k := range []string{"day", "owner", "messages", "count", "truncated", "skipped_older", "below_floor", "cursor_reset"} {
		if _, ok := res.Fields[k]; !ok {
			t.Errorf("Fields has no %q", k)
		}
	}
	if got := res.Fields["day"]; got != "2026-11-12" {
		t.Errorf("day = %v", got)
	}
	if got := res.Fields["owner"]; fmt.Sprint(got) != fmt.Sprint(map[string]any{"name": "Owner A"}) {
		t.Errorf("owner = %v", got)
	}
	msgs := windowMessages(t, res)
	if len(msgs) != 2 || res.Fields["count"] != 2 || res.Fields["truncated"] != false {
		t.Fatalf("messages %d, count %v, truncated %v", len(msgs), res.Fields["count"], res.Fields["truncated"])
	}
	keys := []string{"id", "channel_id", "channel", "author", "at", "time", "text", "thread_id", "permalink",
		"by_owner", "to_owner", "bot"}
	for _, m := range msgs {
		if len(m) != len(keys) {
			t.Errorf("row has %d keys, want %d: %v", len(m), len(keys), m)
		}
		for _, k := range keys {
			if _, ok := m[k]; !ok {
				t.Errorf("row has no %q", k)
			}
		}
	}
	first, second := msgs[0], msgs[1]
	if first["id"] != "1:C0ACME/"+root || first["thread_id"] != "" {
		t.Errorf("root id %v thread_id %v", first["id"], first["thread_id"])
	}
	if second["id"] != "1:C0ACME/"+reply || second["thread_id"] != "1:C0ACME/"+root {
		t.Errorf("reply id %v thread_id %v", second["id"], second["thread_id"])
	}
	if first["channel"] != "#acme-release" || first["channel_id"] != "1:C0ACME" || first["author"] != "Owner A" {
		t.Errorf("root row %v", first)
	}
	wantAt := time.Unix(now.Add(-2*time.Hour).Unix(), 0).UTC().Format(time.RFC3339)
	if first["at"] != wantAt || first["time"] != "09:00" {
		t.Errorf("at %v time %v; want %s 09:00", first["at"], first["time"], wantAt)
	}
	if first["permalink"] != "https://acme.example.com/archives/1" || second["permalink"] != "" {
		t.Errorf("permalinks %v / %v", first["permalink"], second["permalink"])
	}
	if first["by_owner"] != true || first["to_owner"] != false || second["by_owner"] != false ||
		second["to_owner"] != true || second["bot"] != false {
		t.Errorf("flags root %v reply %v", first, second)
	}
	if res.NextCursor != s.maxRowID() || res.Behind {
		t.Errorf("NextCursor %d Behind %v; want %d false", res.NextCursor, res.Behind, s.maxRowID())
	}
}

func TestSlackWindowPrimitive_ScopeFromEntry(t *testing.T) {
	s := newSlackSeed(t)
	now := time.Date(2026, 11, 12, 6, 0, 0, 0, time.UTC)
	s.msg("1:C0ACME", "1:U0BOB", "in scope", "", "", now.Add(-time.Hour))
	s.msg("1:C0OTHER", "1:U0BOB", "not a member", "", "", now.Add(-time.Hour))

	t.Run("member channels", func(t *testing.T) {
		withWindowEntry(t, db.WindowScopeMemberChannels)
		msgs := windowMessages(t, mustWindow(t, s.d, now, automations.PrimitiveCall{}))
		if len(msgs) != 1 || msgs[0]["text"] != "in scope" {
			t.Fatalf("messages %v", msgs)
		}
	})
	t.Run("unknown built-in", func(t *testing.T) {
		if _, err := callWindow(t, s.d, now, automations.PrimitiveCall{BuiltinID: "no-such-builtin"}); err == nil {
			t.Fatal("an unknown built-in id read a window")
		}
	})
	t.Run("empty scope", func(t *testing.T) {
		withWindowEntry(t, "")
		if _, err := callWindow(t, s.d, now, automations.PrimitiveCall{}); err == nil {
			t.Fatal("an entry with no scope read a window")
		}
	})
	t.Run("unknown floor", func(t *testing.T) {
		withWindowEntry(t, db.WindowScopeMemberChannels)
		if _, err := callWindow(t, s.d, now, automations.PrimitiveCall{Floor: "yesterday"}); err == nil {
			t.Fatal("an unknown floor was ignored")
		}
	})
}

func TestSlackWindowPrimitive_FloorTodayIsLocalMidnight(t *testing.T) {
	withWindowEntry(t, db.WindowScopeMemberChannels)
	// UTC+5: local midnight of 2026-11-12 is 2026-11-11 19:00 UTC.
	withLocal(t, time.FixedZone("UTC+5", 5*3600))
	s := newSlackSeed(t)
	now := time.Date(2026, 11, 12, 3, 0, 0, 0, time.UTC) // 08:00 local
	s.msg("1:C0ACME", "1:U0BOB", "seed", "", "", time.Date(2026, 11, 11, 10, 0, 0, 0, time.UTC))
	cursor := s.maxRowID()
	s.msg("1:C0ACME", "1:U0BOB", "yesterday local", "", "", time.Date(2026, 11, 11, 18, 30, 0, 0, time.UTC))
	s.msg("1:C0ACME", "1:U0BOB", "today local", "", "", time.Date(2026, 11, 11, 19, 30, 0, 0, time.UTC))

	res := mustWindow(t, s.d, now, automations.PrimitiveCall{Cursor: cursor, Floor: "today"})
	msgs := windowMessages(t, res)
	if len(msgs) != 1 || msgs[0]["text"] != "today local" {
		t.Fatalf("messages %v", msgs)
	}
	if res.Fields["below_floor"] != 1 || res.Fields["skipped_older"] != 0 {
		t.Errorf("below_floor %v skipped_older %v", res.Fields["below_floor"], res.Fields["skipped_older"])
	}
	if res.Fields["day"] != "2026-11-12" || msgs[0]["time"] != "00:30" {
		t.Errorf("day %v time %v", res.Fields["day"], msgs[0]["time"])
	}
}

func TestSlackWindowPrimitive_PolicyOffSkipsAndKeepsCursor(t *testing.T) {
	withWindowEntry(t, db.WindowScopeMemberChannels)
	policytest.Set(t, map[string]any{policy.KeyAllowedSources: []any{"gmail"}})
	s := newSlackSeed(t)
	now := time.Date(2026, 11, 12, 6, 0, 0, 0, time.UTC)
	s.msg("1:C0ACME", "1:U0BOB", "hidden", "", "", now.Add(-time.Hour))

	res := mustWindow(t, s.d, now, automations.PrimitiveCall{Cursor: 7})
	if res.Status != "skipped" || res.Fields["reason"] != "source_off" ||
		res.Fields["day"] != now.In(time.Local).Format("2006-01-02") || len(res.Fields) != 3 {
		t.Fatalf("status %q fields %v; want reason, day and messages", res.Status, res.Fields)
	}
	if msgs := windowMessages(t, res); len(msgs) != 0 {
		t.Errorf("messages %v", msgs)
	}
	if res.NextCursor != 7 {
		t.Errorf("NextCursor %d; want the call's 7", res.NextCursor)
	}
}

func TestSlackWindowPrimitive_EmptyWindowKeepsCursor(t *testing.T) {
	withWindowEntry(t, db.WindowScopeMemberChannels)
	s := newSlackSeed(t)
	now := time.Date(2026, 11, 12, 6, 0, 0, 0, time.UTC)
	s.msg("1:C0ACME", "1:U0BOB", "read before", "", "", now.Add(-time.Hour))
	s.msg("1:C0OTHER", "1:U0BOB", "out of scope", "", "", now.Add(-time.Hour))
	cursor := s.maxRowID() - 1 // the out-of-scope row is past it

	res := mustWindow(t, s.d, now, automations.PrimitiveCall{Cursor: cursor})
	if len(windowMessages(t, res)) != 0 || res.NextCursor != s.maxRowID() || res.Fields["cursor_reset"] != false {
		t.Errorf("messages %v NextCursor %d cursor_reset %v; want none, %d and false",
			res.Fields["messages"], res.NextCursor, res.Fields["cursor_reset"], s.maxRowID())
	}
	res = mustWindow(t, s.d, now, automations.PrimitiveCall{Cursor: s.maxRowID()})
	if len(windowMessages(t, res)) != 0 || res.NextCursor != s.maxRowID() {
		t.Errorf("messages %v NextCursor %d; want none and the call's %d", res.Fields["messages"], res.NextCursor, s.maxRowID())
	}
}

// A cursor above the newest message row (the table emptied since the last
// read: rowids are reused) is reset: the window reads as with no cursor and
// says so.
func TestSlackWindowPrimitive_CursorAboveNewestRowResets(t *testing.T) {
	withWindowEntry(t, db.WindowScopeMemberChannels)
	s := newSlackSeed(t)
	now := time.Date(2026, 11, 12, 6, 0, 0, 0, time.UTC)
	s.msg("1:C0ACME", "1:U0BOB", "after the reset", "", "", now.Add(-time.Hour))

	res := mustWindow(t, s.d, now, automations.PrimitiveCall{Cursor: 1000})
	msgs := windowMessages(t, res)
	if len(msgs) != 1 || res.Fields["cursor_reset"] != true || res.NextCursor != s.maxRowID() {
		t.Errorf("messages %v cursor_reset %v NextCursor %d; want one, true and %d",
			msgs, res.Fields["cursor_reset"], res.NextCursor, s.maxRowID())
	}
}

func TestSlackWindowPrimitive_ByteCappedWindowFitsLLMInput(t *testing.T) {
	withWindowEntry(t, db.WindowScopeMemberChannels)
	s := newSlackSeed(t)
	now := time.Date(2026, 11, 12, 6, 0, 0, 0, time.UTC)
	text := strings.Repeat("<@U0OWNER> глянь <https://example.com/a?b=1&c=2|ссылка> \"ок\"\n", 60)
	var root string
	for i := 0; i < db.SlackWindowMaxMessages; i++ {
		ts := s.msg("1:C0ACME", "1:U0BOB", text, root, "https://acme.example.com/archives/p"+fmt.Sprint(i), now.Add(-time.Hour))
		if root == "" {
			root = ts
		}
	}

	res := mustWindow(t, s.d, now, automations.PrimitiveCall{})
	if res.Fields["truncated"] != true || !res.Behind {
		t.Fatalf("the window was not byte-capped: truncated %v", res.Fields["truncated"])
	}
	encoded, err := json.Marshal(res.Fields)
	if err != nil {
		t.Fatal(err)
	}
	if limit := automations.MaxLLMInputBytes - 16<<10; len(encoded) > limit {
		t.Errorf("Fields encode to %d bytes; want ≤ %d", len(encoded), limit)
	}
}

func TestReadPrimitives_IncludesSlackWindow(t *testing.T) {
	prims := ReadPrimitives(nil, time.Now)
	if prims[automations.PrimitiveSlackWindow] == nil {
		t.Fatal("ReadPrimitives has no slack.window")
	}
}

func TestRegistry_WindowReadersDeclareScope(t *testing.T) {
	for _, e := range All() {
		for _, p := range e.Primitives {
			if p == automations.PrimitiveSlackWindow && e.WindowScope == "" {
				t.Errorf("%s calls %s with no WindowScope", e.ID, p)
			}
		}
	}
}
