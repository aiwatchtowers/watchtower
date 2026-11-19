package inboxfeed

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// The Desktop guards of IDEA-03, IDEA-04 (docs/inventory/ideas.md) and
// CATCHUP-01 (docs/inventory/catchup.md) whose Swift writers were deleted
// (#1170 Task 12): the Mac now sends the tower's screen commands, so each
// guard moved here with its name and its assertions, over the command the
// Mac sends.

// ideaRow is the idea's owner-visible columns.
type ideaRow struct {
	Status, ReviewReason, SnoozeUntil string
	NeedsReview                       bool
	MergedInto, ConvertedTarget       sql.NullInt64
}

func readIdea(t *testing.T, d *db.DB, id int64) ideaRow {
	t.Helper()
	var r ideaRow
	if err := d.QueryRow(`SELECT status, review_reason, snooze_until, needs_review, merged_into_id, converted_target_id
		FROM ideas WHERE id = ?`, id).Scan(&r.Status, &r.ReviewReason, &r.SnoozeUntil, &r.NeedsReview,
		&r.MergedInto, &r.ConvertedTarget); err != nil {
		t.Fatal(err)
	}
	return r
}

func insertIdea(t *testing.T, d *db.DB, kind, title, status string, flagged bool) int64 {
	t.Helper()
	reason := ""
	if flagged {
		reason = "brought up again"
	}
	res, err := d.Exec(`INSERT INTO ideas (kind, title, status, needs_review, review_reason) VALUES (?, ?, ?, ?, ?)`,
		kind, title, status, flagged, reason)
	if err != nil {
		t.Fatal(err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func insertMention(t *testing.T, d *db.DB, ideaID int64, quote, saidAt string) {
	t.Helper()
	if _, err := d.Exec(`INSERT INTO idea_mentions (idea_id, source, quote, said_at) VALUES (?, 'slack', ?, ?)`,
		ideaID, quote, saidAt); err != nil {
		t.Fatal(err)
	}
}

func mentionQuotes(t *testing.T, d *db.DB, ideaID int64) []string {
	t.Helper()
	rows, err := d.Query(`SELECT quote FROM idea_mentions WHERE idea_id = ? ORDER BY said_at, id`, ideaID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var q string
		if err := rows.Scan(&q); err != nil {
			t.Fatal(err)
		}
		out = append(out, q)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// --- IDEA-03 / IDEA-04 ---

func TestIdeas04_SetStatusClearsNeedsReview(t *testing.T) {
	d := seeded(t, nil)
	id := insertIdea(t, d, "idea", "I", "proposed", true)
	screenCall(t, d, "ideas.status", api.IdeaStatusRequest{WriteParams: write(), ID: id, Status: "active"})
	got := readIdea(t, d, id)
	if got.Status != "active" || got.NeedsReview || got.ReviewReason != "" {
		t.Errorf("idea %+v, want active with the review flag cleared", got)
	}
}

func TestIdeas03_MergeReparentsMentionsAndFollowsLink(t *testing.T) {
	d := seeded(t, nil)
	source := insertIdea(t, d, "idea", "Duplicate idea", "proposed", false)
	target := insertIdea(t, d, "idea", "Canonical idea", "proposed", false)
	insertMention(t, d, source, "one", "2026-11-15T09:00:00Z")
	insertMention(t, d, source, "two", "2026-11-15T09:00:01Z")

	screenCall(t, d, "ideas.merge", api.IdeaMergeRequest{WriteParams: write(), ID: source, Into: target})

	got := readIdea(t, d, source)
	if got.Status != "merged" || got.MergedInto.Int64 != target {
		t.Errorf("source %+v, want merged into %d", got, target)
	}
	if q := mentionQuotes(t, d, source); len(q) != 0 {
		t.Errorf("source keeps mentions %v, want none", q)
	}
	if q := mentionQuotes(t, d, target); fmt.Sprint(q) != "[one two]" {
		t.Errorf("target mentions %v, want [one two]", q)
	}
}

func TestIdeas03_MarkConvertedSetsStatusAndTargetLink(t *testing.T) {
	d := seeded(t, nil)
	id := insertIdea(t, d, "idea", "Ship it", "active", false)
	res := convertIdea(t, d, id)
	got := readIdea(t, d, id)
	if got.Status != "converted" || got.ConvertedTarget.Int64 != res.TargetID || res.TargetID == 0 {
		t.Errorf("idea %+v after converting to target %d, want converted with its link", got, res.TargetID)
	}
}

// IDEA-03's "links, not deletes" for convert, asserted on the things that
// would actually be lost: the mention chronology and the Discuss chat.
func TestIdeas03_MarkConvertedKeepsMentionsAndChat(t *testing.T) {
	d := seeded(t, nil)
	id := insertIdea(t, d, "idea", "Ship it", "active", false)
	insertMention(t, d, id, "first sighting", "2026-04-27T00:00:01Z")
	insertMention(t, d, id, "second sighting", "2026-04-27T00:00:02Z")
	res, err := d.Exec(`INSERT INTO chat_conversations (context_type, context_id, title, created_at, updated_at)
		VALUES ('idea', ?, 'Discuss', 0, 0)`, fmt.Sprint(id))
	if err != nil {
		t.Fatal(err)
	}
	conv, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at) VALUES (?, 'user', 'message 0', 0)`,
		conv); err != nil {
		t.Fatal(err)
	}

	convertIdea(t, d, id)

	if got := readIdea(t, d, id); got.Status != "converted" {
		t.Errorf("status %q, want converted: the row survives conversion", got.Status)
	}
	if q := mentionQuotes(t, d, id); fmt.Sprint(q) != "[first sighting second sighting]" {
		t.Errorf("mentions %v: conversion is a link — the mentions stay on the converted idea", q)
	}
	var conversations, messages int
	if err := d.QueryRow(`SELECT COUNT(*) FROM chat_conversations WHERE context_type = 'idea' AND context_id = ?`,
		fmt.Sprint(id)).Scan(&conversations); err != nil {
		t.Fatal(err)
	}
	if err := d.QueryRow(`SELECT COUNT(*) FROM chat_messages WHERE conversation_id IN
		(SELECT id FROM chat_conversations WHERE context_type = 'idea' AND context_id = ?)`, fmt.Sprint(id)).Scan(&messages); err != nil {
		t.Fatal(err)
	}
	if conversations != 1 || messages != 1 {
		t.Errorf("chat %d conversations, %d messages: the Discuss chat and its messages survive conversion", conversations, messages)
	}
}

func convertIdea(t *testing.T, d *db.DB, id int64) api.IdeaConvertResult {
	t.Helper()
	resp := screenCall(t, d, "ideas.converted", api.IdeaConvertedRequest{WriteParams: write(), ID: id, Today: "2026-11-16"})
	var res api.IdeaConvertResult
	if err := json.Unmarshal(resp.Result, &res); err != nil {
		t.Fatal(err)
	}
	return res
}

// Every owner action has to clear needs_review, not just ideas.status: a
// resurfaced idea the owner acts on via snooze/merge/supersede/convert/
// decision_seen/decisions_seen_all would otherwise stay in the "For review"
// list (or, for decisions, the unread ledger) forever.
func TestIdeas04_EveryOwnerActionClearsNeedsReview(t *testing.T) {
	d := seeded(t, nil)
	flaggedIdea := func() int64 { return insertIdea(t, d, "idea", "I", "rejected", true) }
	flaggedDecision := func() int64 { return insertIdea(t, d, "decision", "D", "active", true) }

	snoozed := flaggedIdea()
	screenCall(t, d, "ideas.snooze", api.IdeaSnoozeRequest{WriteParams: write(), ID: snoozed})

	merged, mergeTarget := flaggedIdea(), flaggedIdea()
	screenCall(t, d, "ideas.merge", api.IdeaMergeRequest{WriteParams: write(), ID: merged, Into: mergeTarget})

	superseded := flaggedIdea()
	screenCall(t, d, "ideas.supersede", api.IdeaSupersedeRequest{WriteParams: write(), ID: superseded})

	converted := flaggedIdea()
	convertIdea(t, d, converted)

	decisionSeen := flaggedDecision()
	screenCall(t, d, "ideas.decision_seen", api.ScreenIDRequest{WriteParams: write(), ID: decisionSeen})

	allDecisionsSeen := flaggedDecision()
	screenCall(t, d, "ideas.decisions_seen_all", api.DecisionsSeenAllRequest{WriteParams: write()})

	for _, c := range []struct {
		label string
		id    int64
	}{{"snooze", snoozed}, {"merge", merged}, {"supersede", superseded}, {"markConverted", converted},
		{"markDecisionSeen", decisionSeen}, {"markAllDecisionsSeen", allDecisionsSeen}} {
		if got := readIdea(t, d, c.id); got.NeedsReview || got.ReviewReason != "" {
			t.Errorf("%s must clear needs_review and review_reason: %+v", c.label, got)
		}
	}
}

// --- CATCHUP-01 ---

// catchupBase is 2027-01-15T12:00:00Z, the base the store's own guards use
// (internal/db/catchup_store_test.go): the window sits at local midday in
// every time zone.
const catchupBase = 1_800_014_400

func localDate(unix int64) string { return time.Unix(unix, 0).Local().Format("2006-01-02") }

func insertRecap(t *testing.T, d *db.DB, from, to int64, status string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO catchup_recaps (period_from, period_to, status) VALUES (?, ?, ?)`, from, to, status)
	if err != nil {
		t.Fatal(err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func acknowledge(t *testing.T, d *db.DB, id int64) api.Response {
	t.Helper()
	b, err := json.Marshal(api.ScreenIDRequest{WriteParams: write(), ID: id})
	if err != nil {
		t.Fatal(err)
	}
	return callScreen(screenTower(d, actNow, ActDeps{}), "catchup.acknowledge", b, socket)
}

func count(t *testing.T, d *db.DB, query string, args ...any) int {
	t.Helper()
	var n int
	if err := d.QueryRow(query, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func mustExec(t *testing.T, d *db.DB, query string, args ...any) {
	t.Helper()
	if _, err := d.Exec(query, args...); err != nil {
		t.Fatal(err)
	}
}

func insertDigest(t *testing.T, d *db.DB, from, to int64, kind, summary string) {
	t.Helper()
	mustExec(t, d, `INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('1:C1', ?, ?, ?, ?)`,
		from, to, kind, summary)
}

func insertStreamDigest(t *testing.T, d *db.DB, from, to string) {
	t.Helper()
	mustExec(t, d, `INSERT INTO stream_digests (source, account_id, period_from, period_to) VALUES ('gmail', 1, ?, ?)`, from, to)
}

func insertInboxItem(t *testing.T, d *db.DB, ts, created, mentioned string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, created_at, mentioned_at)
		VALUES ('1:C1', ?, '1:U1', 'mention', ?, ?)`, ts, created, mentioned)
	if err != nil {
		t.Fatal(err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func TestCatchup01_AcknowledgeMarksWindowReadOnFiveSurfaces(t *testing.T) {
	d := seeded(t, nil)
	insertDigest(t, d, catchupBase+1500, catchupBase+1600, "channel", "in")
	// Straddles the window start — the gather cites it, so the ack marks it.
	insertDigest(t, d, catchupBase+500, catchupBase+1200, "channel", "straddle")
	// Produced by the run's own top-up: period_to carries its own now(),
	// landing a second past the window's `to`.
	insertDigest(t, d, catchupBase+1900, catchupBase+2001, "channel", "topup")
	insertStreamDigest(t, d, "2027-01-15T12:25:00Z", "2027-01-15T12:26:40Z")
	insertStreamDigest(t, d, "2027-01-15T12:08:20Z", "2027-01-15T12:20:00Z")
	insertStreamDigest(t, d, "2027-01-15T12:31:40Z", "2027-01-15T12:33:21Z")
	mustExec(t, d, `INSERT INTO tracks (text, updated_at, has_updates, dismissed_at) VALUES ('t', '2027-01-15T12:25:00Z', 1, '')`)
	insertInboxItem(t, d, "1.0", "2027-01-15T12:25:00Z", "")
	mustExec(t, d, `INSERT INTO briefings (user_id, date) VALUES ('1:U0', ?)`, localDate(catchupBase+1500))
	recap := insertRecap(t, d, catchupBase+1000, catchupBase+2000, "ready")

	if resp := acknowledge(t, d, recap); resp.Status != api.StatusOK {
		t.Fatalf("acknowledge: %s %+v", resp.Status, resp.Refusal)
	}

	for _, c := range []struct {
		query, why string
		want       int
	}{
		{`SELECT COUNT(*) FROM digests WHERE read_at IS NOT NULL`, "every digest overlapping the window — inside, straddling the start, and the top-up ending past `to`", 3},
		{`SELECT COUNT(*) FROM stream_digests WHERE read_at IS NOT NULL`, "the same three overlap cases on the stream surface", 3},
		{`SELECT COUNT(*) FROM tracks WHERE read_at IS NOT NULL AND has_updates = 0`, "tracks are marked read and lose their update flag", 1},
		{`SELECT COUNT(*) FROM inbox_items WHERE read_at IS NOT NULL`, "the inbox item in the window", 1},
		{`SELECT COUNT(*) FROM briefings WHERE read_at IS NOT NULL`, "the briefing of the window's day", 1},
	} {
		if n := count(t, d, c.query); n != c.want {
			t.Errorf("%d, want %d: %s", n, c.want, c.why)
		}
	}
	if n := count(t, d, `SELECT COUNT(*) FROM catchup_recaps WHERE id = ? AND acknowledged_at IS NOT NULL`, recap); n != 1 {
		t.Error("the recap stamps its own acknowledged_at")
	}
}

func TestCatchup01_AcknowledgeLeavesItemsOutsideWindowUnread(t *testing.T) {
	d := seeded(t, nil)
	insertDigest(t, d, catchupBase+1500, catchupBase+1600, "channel", "in")
	// Starts at/after the window's `to` — no overlap, so no ack.
	insertDigest(t, d, catchupBase+2500, catchupBase+2600, "channel", "out")
	// Overlaps the window, but a daily roll-up is not a catch-up surface.
	insertDigest(t, d, catchupBase+1500, catchupBase+1600, "daily", "daily")
	insertStreamDigest(t, d, "2027-01-15T12:41:40Z", "2027-01-15T12:43:20Z")
	insertInboxItem(t, d, "1.0", "2027-01-15T13:00:00Z", "")
	recap := insertRecap(t, d, catchupBase+1000, catchupBase+2000, "ready")

	if resp := acknowledge(t, d, recap); resp.Status != api.StatusOK {
		t.Fatalf("acknowledge: %s %+v", resp.Status, resp.Refusal)
	}

	read := func(summary string) bool {
		return count(t, d, `SELECT COUNT(*) FROM digests WHERE summary = ? AND read_at IS NOT NULL`, summary) == 1
	}
	if !read("in") {
		t.Error("in-window digest read")
	}
	if read("out") {
		t.Error("digest starting after the window stays unread")
	}
	if read("daily") {
		t.Error("a non-channel digest is not a catch-up surface")
	}
	if n := count(t, d, `SELECT COUNT(*) FROM stream_digests WHERE read_at IS NOT NULL`); n != 0 {
		t.Error("stream digest starting after the window stays unread")
	}
	if n := count(t, d, `SELECT COUNT(*) FROM inbox_items WHERE read_at IS NOT NULL`); n != 0 {
		t.Error("inbox item created after the window stays unread")
	}
}

// A channel item created before the window but given a new mention inside
// it (#586, mentioned_at) is acknowledged with that window; one with no fold
// in the window is not.
func TestCatchup01_AcknowledgeMarksItemByNewestMention(t *testing.T) {
	d := seeded(t, nil)
	folded := insertInboxItem(t, d, "1.0", "2027-01-15T11:00:00Z", "2027-01-15T12:25:00Z")
	stale := insertInboxItem(t, d, "2.0", "2027-01-15T11:00:00Z", "")
	recap := insertRecap(t, d, catchupBase+1000, catchupBase+2000, "ready")

	if resp := acknowledge(t, d, recap); resp.Status != api.StatusOK {
		t.Fatalf("acknowledge: %s %+v", resp.Status, resp.Refusal)
	}

	if n := count(t, d, `SELECT COUNT(*) FROM inbox_items WHERE id = ? AND read_at IS NOT NULL`, folded); n != 1 {
		t.Error("a mention folded in inside the window is acknowledged")
	}
	if n := count(t, d, `SELECT COUNT(*) FROM inbox_items WHERE id = ? AND read_at IS NOT NULL`, stale); n != 0 {
		t.Error("an item with nothing new in the window stays unread")
	}
}

// `to` is an EXCLUSIVE instant, so a window ending exactly on a local
// midnight (what the `yesterday` preset resolves to) covers the day BEFORE
// it: the briefing dated the day the window ends on must stay unread.
func TestCatchup01_AcknowledgeMarksWindowReadOnMidnightTo(t *testing.T) {
	d := seeded(t, nil)
	base := time.Unix(catchupBase, 0).Local()
	midnight := time.Date(base.Year(), base.Month(), base.Day(), 0, 0, 0, 0, base.Location())
	dayBefore := midnight.AddDate(0, 0, -1)
	endDate, coveredDate := midnight.Format("2006-01-02"), dayBefore.Format("2006-01-02")
	mustExec(t, d, `INSERT INTO briefings (user_id, date) VALUES ('1:U0', ?), ('1:U0', ?)`, coveredDate, endDate)
	recap := insertRecap(t, d, dayBefore.Unix(), midnight.Unix(), "ready")

	if resp := acknowledge(t, d, recap); resp.Status != api.StatusOK {
		t.Fatalf("acknowledge: %s %+v", resp.Status, resp.Refusal)
	}

	if n := count(t, d, `SELECT COUNT(*) FROM briefings WHERE date = ? AND read_at IS NOT NULL`, coveredDate); n != 1 {
		t.Error("the day the window actually covers is marked read")
	}
	if n := count(t, d, `SELECT COUNT(*) FROM briefings WHERE date = ? AND read_at IS NOT NULL`, endDate); n != 0 {
		t.Error("the briefing for the day the window ENDS on stays unread")
	}
}

// "I'm caught up" on a recap that never finished would mark its whole window
// read without the operator ever having been shown what was in it: refused
// (`changed`, "…this recap isn't ready."), nothing marked, nothing stamped.
func TestCatchup01_AcknowledgeRefusesRecapThatIsNotReady(t *testing.T) {
	d := seeded(t, nil)
	insertDigest(t, d, catchupBase+1500, catchupBase+1600, "channel", "in")
	for _, status := range []string{"building", "failed"} {
		recap := insertRecap(t, d, catchupBase+1000, catchupBase+2000, status)
		resp := acknowledge(t, d, recap)
		if resp.Status != api.StatusRefused || resp.Refusal == nil || resp.Refusal.Code != api.CodeChanged {
			t.Errorf("a %s recap: %s %+v, want refused changed", status, resp.Status, resp.Refusal)
		}
	}
	if n := count(t, d, `SELECT COUNT(*) FROM digests WHERE read_at IS NOT NULL`); n != 0 {
		t.Error("a refused acknowledge marks nothing read")
	}
	if n := count(t, d, `SELECT COUNT(*) FROM catchup_recaps WHERE acknowledged_at IS NOT NULL`); n != 0 {
		t.Error("and stamps no recap")
	}
}
