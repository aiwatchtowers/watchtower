package inboxfeed

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/tools"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

// The STRIP-01/02/03 guards (docs/inventory/reaction-commands.md), moved
// from the Desktop's ActionStripViewModel tests when the Mac's Inbox began
// reading inbox.feed and writing through inbox.act (#1170 Task 11c). Each
// keeps the Swift guard's name and meaning: what the Mac lists is Build's
// pure read, and every press is one inbox.act write of only its own columns.

const (
	stripAutomation = `INSERT INTO automations (id, slug, scope, path, name, enabled, disabled_reason, origin, builtin_id)
		VALUES (1, 'mail-summary', 'personal', '/recipes/mail.md', 'Mail summary', 1, '', 'owner', NULL)`
	stripRun = `INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (1, 1, 'manual', 'succeeded')`
)

// stripOutput is an open inbox output of automation 1.
func stripOutput(id int, kind, title, created, extra string) string {
	cols, vals := "", ""
	if extra != "" {
		parts := strings.SplitN(extra, "=", 2)
		cols, vals = ", "+parts[0], ", "+parts[1]
	}
	return fmt.Sprintf(`INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, priority, created_at,
		blocks_json, content_hash, written_at, changed_at%s)
		VALUES (%d, 1, 1, '%s', '%s', 'body', 'medium', '%s', '', 'h%d', '%s', '%s'%s)`,
		cols, id, kind, title, created, id, created, created, vals)
}

// dump is every row of each table, in rowid order, as text.
func dump(t *testing.T, d *db.DB, tables ...string) map[string][]string {
	t.Helper()
	out := map[string][]string{}
	for _, table := range tables {
		out[table] = dumpTable(t, d, table)
	}
	return out
}

func dumpTable(t *testing.T, d *db.DB, table string) []string {
	t.Helper()
	rows, err := d.Query("SELECT * FROM " + table + " ORDER BY rowid")
	if err != nil {
		t.Fatalf("%s: %v", table, err)
	}
	defer rows.Close()
	cols, _ := rows.Columns()
	var out []string
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			t.Fatal(err)
		}
		line := make([]string, len(cols))
		for i, c := range cols {
			line[i] = fmt.Sprintf("%s=%v", c, vals[i])
		}
		out = append(out, strings.Join(line, " "))
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// row is one row of table as column → value text.
func row(t *testing.T, d *db.DB, table string, id int64) map[string]string {
	t.Helper()
	rows, err := d.Query("SELECT * FROM "+table+" WHERE id = ?", id)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	cols, _ := rows.Columns()
	if !rows.Next() {
		t.Fatalf("%s %d: no row", table, id)
	}
	vals := make([]any, len(cols))
	ptrs := make([]any, len(cols))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	if err := rows.Scan(ptrs...); err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for i, c := range cols {
		if vals[i] == nil {
			out[c] = ""
			continue
		}
		out[c] = fmt.Sprint(vals[i])
	}
	return out
}

// changedColumns are the columns whose value differs between two rows.
func changedColumns(before, after map[string]string) []string {
	var out []string
	for c, v := range after {
		if before[c] != v {
			out = append(out, c)
		}
	}
	slices.Sort(out)
	return out
}

func stripBuild(t *testing.T, d *db.DB) api.Feed {
	t.Helper()
	feed, err := Build(context.Background(), d, Options{Now: actNow})
	if err != nil {
		t.Fatal(err)
	}
	return feed
}

func hasCard(feed api.Feed, id string) bool {
	return slices.ContainsFunc(feed.Cards, func(c api.Card) bool { return c.ID == id })
}

func stripAct(t *testing.T, d *db.DB, target string, verb api.ActVerb, p api.ActParams) api.Response {
	t.Helper()
	return callAct(t, actTower(d, actNow, ActDeps{}), actParams(t, target, verb, p), socket)
}

func totalCount(feed api.Feed) int {
	n := 0
	for _, f := range feed.Folders {
		if !f.Hidden {
			n += f.Count
		}
	}
	return n
}

// --- STRIP-01: gesture-gated ---

func TestStrip01_RefreshPopulatesActionAndReminderRows(t *testing.T) {
	d := seeded(t, []string{
		`INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at) VALUES (1, 'create_target', '{"text":"x"}', 'Do it', 'pending', '2026-11-16T08:00:00Z')`,
		`INSERT INTO reminders (id, message_ref, note, remind_at, status) VALUES (1, 'C1@1', 'call back', '2000-01-01T00:00:00Z', 'pending')`,
	})
	feed := stripBuild(t, d)
	if !hasCard(feed, "a1") || !hasCard(feed, "r1") {
		t.Fatalf("cards %v, want the proposal a1 and the due reminder r1", cardIDs(feed.Cards))
	}
}

func TestStrip01_StripListsOpenInboxOutputs(t *testing.T) {
	d := seeded(t, []string{stripAutomation, stripRun,
		stripOutput(1, "inbox", "Done", "2026-10-01T08:00:00Z", "done_at='2026-10-01T10:00:00Z'"),
		stripOutput(2, "inbox", "Dismissed", "2026-10-01T08:00:00Z", "dismissed_at='2026-10-01T10:00:00Z'"),
		stripOutput(3, "inbox", "Read and done", "2026-10-01T08:00:00Z", "read_at, done_at='2026-10-01T10:00:00Z', '2026-10-01T10:00:00Z'"),
		stripOutput(4, "inbox", "Old", "2026-10-01T09:00:00Z", ""),
		stripOutput(5, "inbox", "Read", "2026-10-01T12:00:00Z", "read_at='2026-10-01T13:00:00Z'"),
		stripOutput(6, "inbox", "New", "2026-10-02T09:00:00Z", ""),
	})
	var ids []string
	var unread []bool
	for _, c := range stripBuild(t, d).Cards {
		if c.CardKind == api.CardArtifact {
			ids, unread = append(ids, c.ID), append(unread, c.Unread)
		}
	}
	if fmt.Sprint(ids) != "[o6 o5 o4]" || fmt.Sprint(unread) != "[true false true]" {
		t.Errorf("artifacts %v unread %v, want [o6 o5 o4] [true false true]: only open kind='inbox' rows, newest first", ids, unread)
	}
}

func TestStrip01_ReportAndBriefingOutputsNotOnStrip(t *testing.T) {
	d := seeded(t, []string{stripAutomation, stripRun,
		stripOutput(1, "report", "Report", "2026-10-01T08:00:00Z", ""),
		stripOutput(2, "briefing", "Briefing", "2026-10-01T08:00:00Z", ""),
	})
	feed := stripBuild(t, d)
	if hasCard(feed, "o1") || hasCard(feed, "o2") {
		t.Errorf("cards %v: a report or briefing output is never listed", cardIDs(feed.Cards))
	}
	if n := totalCount(feed); n != 0 {
		t.Errorf("badge %d, want 0", n)
	}
}

func TestStrip01_SectionsAreProposalsTodayEarlier(t *testing.T) {
	d := seeded(t, []string{stripAutomation, stripRun, stripOutput(1, "inbox", "Card", "2026-11-16T08:00:00Z", ""),
		`INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at) VALUES (1, 'create_target', '{"text":"x"}', 'Do it', 'pending', '2026-11-16T08:00:00Z')`,
		`INSERT INTO reminders (id, message_ref, note, remind_at, status) VALUES (1, 'C1@1', 'call back', '2000-01-01T00:00:00Z', 'pending')`,
		"INSERT INTO tracks (id, text, updated_at, has_updates) VALUES (1, 'Review the plan', '2026-11-16T09:00:00Z', 1)",
		"INSERT INTO ideas (id, kind, title, essence, status, updated_at) VALUES (1, 'idea', 'An idea', 'e', 'proposed', '2026-11-16T07:00:00Z')",
	})
	for _, c := range stripBuild(t, d).Cards {
		if c.Legacy == nil || c.Legacy.Kind == api.LegacyThreadBriefs {
			continue
		}
		for _, it := range c.Legacy.Items {
			if it.RefKind == api.RefAction || it.RefKind == api.RefReminder {
				t.Errorf("legacy list %s carries a strip row %+v", c.ID, it)
			}
		}
	}
}

func TestStrip01_StripAndBadgeLeaveOutInboxPressRows(t *testing.T) {
	d := seeded(t, []string{
		`INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at, surface) VALUES (1, 'apply_track_action', '{}', 'press', 'pending', '2026-11-16T08:00:00Z', 'inbox')`,
		`INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at, surface) VALUES (2, 'send_slack_message', '{"text":"hi"}', 'Reply from Messages', 'pending', '2026-11-16T08:00:00Z', 'inbox')`,
	})
	feed := stripBuild(t, d)
	if hasCard(feed, "a1") {
		t.Errorf("the track-action press row is listed: %v", cardIDs(feed.Cards))
	}
	if !hasCard(feed, "a2") {
		t.Errorf("an inbox-surface Reply waits for the owner and is listed: %v", cardIDs(feed.Cards))
	}
	if n := totalCount(feed); n != 1 {
		t.Errorf("badge %d, want 1 (the Reply only)", n)
	}
}

func TestStrip01_ReadAssemblesEverySource(t *testing.T) {
	d := seeded(t, []string{stripAutomation, stripRun, stripOutput(1, "inbox", "Card", "2026-11-16T08:00:00Z", ""),
		`INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at) VALUES (1, 'create_target', '{"text":"x"}', 'Do it', 'pending', '2026-11-16T08:00:00Z')`,
		`INSERT INTO reminders (id, message_ref, note, remind_at, status) VALUES (1, 'C1@1', 'call back', '2000-01-01T00:00:00Z', 'pending')`,
		"INSERT INTO briefings (id, user_id, date, created_at) VALUES (1, 'U1', '2026-11-16', '2026-11-16T06:00:00Z')",
		"INSERT INTO tracks (id, text, updated_at, has_updates) VALUES (1, 'Review the plan', '2026-11-16T09:00:00Z', 1)",
		"INSERT INTO ideas (id, kind, title, essence, status, updated_at) VALUES (1, 'idea', 'An idea', 'e', 'proposed', '2026-11-16T07:00:00Z')",
		"INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type, snippet, status, item_class, created_at) " +
			"VALUES (1, 'C1', '1.1', 'U1', 'mention', 'Can you look?', 'pending', 'actionable', '2026-11-16T09:00:00Z')",
		"INSERT INTO builtin_migrations (builtin_id, status, error, attempts, updated_at) VALUES ('reactions', 'failed', 'no', 1, '2026-11-10T07:00:00Z')",
	})
	feed := stripBuild(t, d)
	for _, id := range []string{"o1", "a1", "r1", "brief-2026-11-16", TracksCardID, IdeasCardID, MessagesCardID} {
		if !hasCard(feed, id) {
			t.Errorf("no %s in %v: the one read assembles every source", id, cardIDs(feed.Cards))
		}
	}
	if !slices.ContainsFunc(feed.Cards, func(c api.Card) bool { return c.CardKind == api.CardNotice }) {
		t.Errorf("no built-in notice in %v", cardIDs(feed.Cards))
	}
}

// --- STRIP-02: the strip is a view, not a store ---

var stripTables = []string{"agent_actions", "reminders", "automation_outputs", "automation_runs", "automations",
	"pipeline_runs", "inbox_folders", "inbox_folder_state", "inbox_folder_routes"}

func TestStrip02_RefreshIsAPureRead(t *testing.T) {
	d := seeded(t, []string{stripAutomation, stripRun, stripOutput(1, "inbox", "Card", "2026-11-16T08:00:00Z", ""),
		`INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at, surface, context_type, context_id) VALUES (1, 'create_target', '{"text":"x"}', 'Do it', 'pending', '2026-11-16T08:00:00Z', 'automation', 'automation_run', '1')`,
		`INSERT INTO reminders (message_ref, note, remind_at, status) VALUES ('C1@1','call back','2000-01-01T00:00:00Z','pending')`,
	})
	before := dump(t, d, stripTables...)
	feed := stripBuild(t, d)
	stripBuild(t, d)
	if after := dump(t, d, stripTables...); fmt.Sprint(after) != fmt.Sprint(before) {
		t.Errorf("a read changed rows:\nbefore %v\nafter  %v", before, after)
	}
	if !hasCard(feed, "o1") || !hasCard(feed, "a1") || !hasCard(feed, "r1") {
		t.Errorf("cards %v, want o1, a1 and r1", cardIDs(feed.Cards))
	}
}

func TestStrip02_RefreshIsStillOnePureRead(t *testing.T) {
	d := seeded(t, []string{
		"INSERT INTO briefings (id, user_id, date, created_at) VALUES (1, 'U1', '2026-11-16', '2026-11-16T06:00:00Z')",
		"INSERT INTO tracks (id, text, updated_at, has_updates) VALUES (1, 'Review the plan', '2026-11-16T09:00:00Z', 1)",
		"INSERT INTO track_events (id, track_id, summary, created_at) VALUES (1, 1, 'moved', '2026-11-16T09:00:00Z')",
		"INSERT INTO ideas (id, kind, title, essence, status, updated_at) VALUES (1, 'idea', 'An idea', 'e', 'proposed', '2026-11-16T07:00:00Z')",
		"INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type, snippet, status, item_class, created_at) " +
			"VALUES (1, 'C1', '1.1', 'U1', 'mention', 'Can you look?', 'pending', 'actionable', '2026-11-16T09:00:00Z')",
	})
	tables := append([]string{"briefings", "day_plans", "day_plan_items", "tracks", "track_events", "ideas", "inbox_items"},
		stripTables...)
	before := dump(t, d, tables...)
	stripBuild(t, d)
	stripBuild(t, d)
	if after := dump(t, d, tables...); fmt.Sprint(after) != fmt.Sprint(before) {
		t.Errorf("a read changed rows:\nbefore %v\nafter  %v", before, after)
	}
}

func reminderSeed() []string {
	return []string{`INSERT INTO reminders (id, message_ref, note, remind_at, status) VALUES (1, 'C1@1', 'call back', '2026-11-16T09:00:00Z', 'pending')`}
}

func TestStrip02_MarkReminderDoneDropsItOnNextRefresh(t *testing.T) {
	d := seeded(t, reminderSeed())
	if !hasCard(stripBuild(t, d), "r1") {
		t.Fatal("the due reminder is not listed")
	}
	actResult(t, stripAct(t, d, "r1", api.ActRef, api.ActParams{RefKind: api.RefReminder, RefID: 1, RefVerb: api.RefDone}))
	if hasCard(stripBuild(t, d), "r1") {
		t.Error("a done reminder is still listed")
	}
	if r := row(t, d, "reminders", 1); r["status"] != "done" {
		t.Errorf("reminder %v, want done", r)
	}
}

func TestStrip02_SnoozeReminderMovesItOutOfTheDueWindow(t *testing.T) {
	d := seeded(t, reminderSeed())
	until := "2026-11-16T11:00:00Z"
	actResult(t, stripAct(t, d, "r1", api.ActRef, api.ActParams{RefKind: api.RefReminder, RefID: 1, RefVerb: api.RefSnooze, Until: until}))
	if hasCard(stripBuild(t, d), "r1") {
		t.Error("a snoozed reminder is still due")
	}
	if r := row(t, d, "reminders", 1); r["remind_at"] != until {
		t.Errorf("remind_at %q, want %q", r["remind_at"], until)
	}
}

func outputSeed() []string {
	return []string{stripAutomation, stripRun, stripOutput(1, "inbox", "Card", "2026-11-16T08:00:00Z", "")}
}

// writesOnly presses verb on o1 and checks that only column moved and the card
// left (or stayed, for a read).
func writesOnly(t *testing.T, verb api.ActVerb, column string, listed bool) {
	t.Helper()
	d := seeded(t, outputSeed())
	before := row(t, d, "automation_outputs", 1)
	actResult(t, stripAct(t, d, "o1", verb, api.ActParams{ContentHash: "h1"}))
	after := row(t, d, "automation_outputs", 1)
	if got := changedColumns(before, after); fmt.Sprint(got) != "["+column+"]" {
		t.Errorf("%s changed %v, want only %s", verb, got, column)
	}
	if hasCard(stripBuild(t, d), "o1") != listed {
		t.Errorf("after %s the card listed = %v, want %v", verb, !listed, listed)
	}
}

func TestStrip02_DoneWritesOnlyDoneAt(t *testing.T) { writesOnly(t, api.ActDone, "done_at", false) }

func TestStrip02_DismissWritesOnlyDismissedAt(t *testing.T) {
	writesOnly(t, api.ActDismiss, "dismissed_at", false)
}

func TestStrip02_OpeningWritesOnlyReadAt(t *testing.T) {
	writesOnly(t, api.ActRead, "read_at", true)
	d := seeded(t, outputSeed())
	badge := totalCount(stripBuild(t, d))
	actResult(t, stripAct(t, d, "o1", api.ActRead, api.ActParams{ContentHash: "h1"}))
	feed := stripBuild(t, d)
	if c := cardByID(t, feed, "o1"); c.Unread {
		t.Error("an opened card is still unread")
	}
	if n := totalCount(feed); n != badge-1 {
		t.Errorf("badge %d, want %d: an opened plain artifact leaves the badge", n, badge-1)
	}
	after := row(t, d, "automation_outputs", 1)
	if res := actResult(t, stripAct(t, d, "o1", api.ActRead, api.ActParams{ContentHash: "h1"})); !res.Already {
		t.Errorf("opening a read card %+v, want already", res)
	}
	if again := row(t, d, "automation_outputs", 1); fmt.Sprint(again) != fmt.Sprint(after) {
		t.Error("opening a read card wrote")
	}
}

func TestStrip02_FailedWriteKeepsCard(t *testing.T) {
	d := seeded(t, append(outputSeed(),
		"CREATE TRIGGER refuse_output_update BEFORE UPDATE ON automation_outputs BEGIN SELECT RAISE(ABORT, 'disk said no'); END"))
	for _, verb := range []api.ActVerb{api.ActDone, api.ActDismiss} {
		if resp := stripAct(t, d, "o1", verb, api.ActParams{ContentHash: "h1"}); resp.Status == api.StatusOK {
			t.Errorf("%s answered ok over a failing write", verb)
		}
		if !hasCard(stripBuild(t, d), "o1") {
			t.Errorf("a failed %s took the card off", verb)
		}
	}
}

func TestStrip02_OpeningTheDayCardMarksTheBriefingRead(t *testing.T) {
	d := seeded(t, []string{"INSERT INTO briefings (id, user_id, date, created_at) VALUES (1, 'U1', '2026-11-16', '2026-11-16T06:00:00Z')"})
	before := row(t, d, "briefings", 1)
	actResult(t, stripAct(t, d, "brief-2026-11-16", api.ActRead, api.ActParams{}))
	if got := changedColumns(before, row(t, d, "briefings", 1)); fmt.Sprint(got) != "[read_at]" {
		t.Errorf("opening the day changed %v, want [read_at]", got)
	}
}

func messageSeed() []string {
	return []string{"INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type, snippet, status, item_class, created_at) " +
		"VALUES (1, 'C1', '1.1', 'U1', 'mention', 'Can you look?', 'pending', 'actionable', '2026-11-16T09:00:00Z')"}
}

func TestStrip02_OpeningAMessageWritesOnlyReadAt(t *testing.T) {
	d := seeded(t, messageSeed())
	before := row(t, d, "inbox_items", 1)
	actResult(t, stripAct(t, d, MessagesCardID, api.ActRead, api.ActParams{RefKind: api.RefInboxItem, RefID: 1}))
	if got := changedColumns(before, row(t, d, "inbox_items", 1)); fmt.Sprint(got) != "[read_at]" {
		t.Errorf("opening a message changed %v, want [read_at]", got)
	}
}

func TestStrip02_OpeningAnAlreadyReadCardWritesNothing(t *testing.T) {
	d := seeded(t, append(messageSeed(),
		"INSERT INTO briefings (id, user_id, date, created_at, read_at) VALUES (1, 'U1', '2026-11-16', '2026-11-16T06:00:00Z', '2026-11-16T07:00:00Z')",
		"UPDATE inbox_items SET read_at = '2026-11-16T09:30:00Z' WHERE id = 1"))
	before := dump(t, d, "briefings", "inbox_items")
	for _, c := range []struct {
		target string
		p      api.ActParams
	}{{"brief-2026-11-16", api.ActParams{}}, {MessagesCardID, api.ActParams{RefKind: api.RefInboxItem, RefID: 1}}} {
		if res := actResult(t, stripAct(t, d, c.target, api.ActRead, c.p)); !res.Already {
			t.Errorf("opening read %s: %+v, want already", c.target, res)
		}
	}
	if after := dump(t, d, "briefings", "inbox_items"); fmt.Sprint(after) != fmt.Sprint(before) {
		t.Error("opening an already read card wrote")
	}
}

func TestStrip02_TrackDoneMarksTrackAndEventsRead(t *testing.T) {
	d := seeded(t, []string{
		"INSERT INTO tracks (id, text, updated_at, has_updates) VALUES (1, 'Review the plan', '2026-11-15T09:00:00Z', 1)",
		"INSERT INTO tracks (id, text, updated_at, has_updates) VALUES (2, 'Other', '2026-11-15T09:00:00Z', 1)",
		"INSERT INTO track_events (id, track_id, summary, created_at) VALUES (1, 1, 'moved', '2026-11-16T09:00:00Z')",
		"INSERT INTO track_events (id, track_id, summary, created_at) VALUES (2, 2, 'moved', '2026-11-16T09:00:00Z')",
	})
	actResult(t, stripAct(t, d, TracksCardID, api.ActRef, api.ActParams{RefKind: api.RefTrack, RefID: 1, RefVerb: api.RefDone}))
	if tr := row(t, d, "tracks", 1); tr["read_at"] == "" || tr["has_updates"] != "0" {
		t.Errorf("track %v, want read with no updates", tr)
	}
	if ev := row(t, d, "track_events", 1); ev["read_at"] == "" {
		t.Errorf("event %v, want read", ev)
	}
	if other := row(t, d, "track_events", 2); other["read_at"] != "" {
		t.Error("another track's event was marked read")
	}
}

func TestStrip02_ReplyPressOnlyQueues(t *testing.T) {
	// AUTO-09's guard (testAuto09_ReplyPressOnlyQueues): the press records
	// itself and queues one run; nothing else of the card changes.
	TestInboxAct_ReplyPressQueuesTheRun(t)
}

// --- STRIP-03: decisions flow through the registry ---

// The STRIP-03 guards keep the Swift guards' names (ActionStripViewModelTests:
// the Mac's decisions went through the composed AgentActionFeed, they now go
// through inbox.act to the same registry): same names, same meaning.
func TestStrip03_ApproveDelegatesToTheComposedAgentActionFeed(t *testing.T) {
	ran := 0
	d, _, reg := approvalRig(t, func() { ran++ })
	res := actResult(t, callAct(t, actTower(d, actNow, ActDeps{Registry: reg}), approveParams(t, tools.ArgsSHA256(pendingArgs)), socket))
	if res.Status != "applied" || ran != 1 {
		t.Errorf("approve %+v ran %d, want applied once by the registry", res, ran)
	}
	if s := actionStatusOf(t, d, 1); s != "applied" {
		t.Errorf("row %s, want applied", s)
	}
}

func TestStrip03_ApproveClearsAPriorErrorOnSubsequentSuccess(t *testing.T) {
	d, _, reg := approvalRig(t, nil)
	tw := actTower(d, actNow, ActDeps{Registry: reg})
	if resp := callAct(t, tw, approveParams(t, tools.ArgsSHA256(`{"text":"other"}`)), socket); resp.Status != api.StatusRefused {
		t.Fatalf("a stale approve answered %s", resp.Status)
	}
	res := actResult(t, callAct(t, tw, approveParams(t, tools.ArgsSHA256(pendingArgs)), socket))
	if res.Status != "applied" || res.Error != "" {
		t.Errorf("the next approve %+v, want applied with no error", res)
	}
}

func TestStrip03_DismissDelegatesToTheComposedAgentActionFeed(t *testing.T) {
	// A chat-session call whose outcome is unknown: the registry dismisses it.
	landing, _ := seededAt(t, []string{`INSERT INTO agent_actions (id, tool, args_json, reason, status, error, created_at)
		VALUES (1, 'session_call', '{}', 'r', 'failed', 'session ended while the call ran; outcome unknown',
		'2026-11-16T09:00:00Z')`})
	sessionReg := tools.New(landing)
	session := fakeTool(t, "session_call", nil, nil)
	session.AppliedBySession = true
	if err := sessionReg.Register(session); err != nil {
		t.Fatal(err)
	}
	res := actResult(t, callAct(t, actTower(landing, actNow, ActDeps{Registry: sessionReg}),
		actParams(t, "a1", api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalDismiss}), socket))
	if res.Already {
		t.Errorf("dismiss %+v, want it to land", res)
	}
	row, err := landing.GetAgentAction(1)
	if err != nil || row == nil || row.DismissedAt == "" {
		t.Fatalf("row %+v (%v), want dismissed by the registry", row, err)
	}

	d, _, reg := approvalRig(t, nil)
	resp := callAct(t, actTower(d, actNow, ActDeps{Registry: reg}),
		actParams(t, "a1", api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalDismiss}), socket)
	// The registry decides: a row that is not a session call of unknown
	// outcome is refused, and stays as it was.
	if resp.Status != api.StatusRefused || resp.Refusal.Code != api.CodeChanged {
		t.Errorf("dismiss %s %+v, want the registry's refusal", resp.Status, resp.Refusal)
	}
	if s := actionStatusOf(t, d, 1); s != "pending" {
		t.Errorf("row %s, want pending", s)
	}
}

func TestStrip03_ApproveWithChangedArgsShowsRefusalOnRow(t *testing.T) {
	TestInboxAct_ApprovalArgsChangedIsRefused(t)
}

func TestStrip03_OwnerDecisionsNeedTheSignedDesktop(t *testing.T) {
	d, _, reg := approvalRig(t, nil)
	unsignedCall := tower.Origin{Transport: "socket", Desktop: unsigned.Desktop}
	resp := callAct(t, actTower(d, actNow, ActDeps{Registry: reg}), approveParams(t, tools.ArgsSHA256(pendingArgs)), unsignedCall)
	if resp.Status != api.StatusRefused || resp.Refusal.Code != api.CodeNotPermitted {
		t.Errorf("an unsigned approve %s %+v, want not_permitted", resp.Status, resp.Refusal)
	}
}
