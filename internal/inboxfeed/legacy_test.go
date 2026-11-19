package inboxfeed

import (
	"fmt"
	"testing"
	"time"

	"watchtower/internal/tower/api"
)

func cardByID(t *testing.T, feed api.Feed, id string) api.Card {
	t.Helper()
	for _, c := range feed.Cards {
		if c.ID == id {
			return c
		}
	}
	t.Fatalf("no card %s in %v", id, cardIDs(feed.Cards))
	return api.Card{}
}

// The root lists a Morning brief card per date under the Mac's rule
// (InboxListBuilder.rootDays): today's, read or not, and every unread
// day, newest first; a read older day is left out. A day carries its
// plan's items (plan_item refs, done flagged) and its attention list.
// Today's placeholder shows only while the owner is known and today has
// neither a briefing nor a plan.
func TestLegacy_MorningBriefPerDateUnderTheUnreadRule(t *testing.T) {
	briefing := func(id int, date, readAt, created string) string {
		return fmt.Sprintf("INSERT INTO briefings (id, user_id, date, attention, read_at, created_at) VALUES "+
			`(%d, 'U1', '%s', '[{"text":"Release waits on you","reason":"tag","priority":"high"}]', %s, '%s')`,
			id, date, readAt, created)
	}
	feed := buildFeed(t, []string{
		briefing(1, "2026-11-16", "'2026-11-16T08:30:00Z'", "2026-11-16T08:00:00Z"),
		briefing(2, "2026-11-15", "NULL", "2026-11-15T08:00:00Z"),
		briefing(3, "2026-11-14", "'2026-11-14T09:00:00Z'", "2026-11-14T08:00:00Z"),
		"INSERT INTO day_plans (id, user_id, plan_date, generated_at) VALUES (1, 'U1', '2026-11-16', '2026-11-16T07:00:00Z')",
		"INSERT INTO day_plan_items (id, day_plan_id, kind, source_type, title, start_time, status, order_index) " +
			"VALUES (1, 1, 'timeblock', 'manual', 'Standup', '2026-11-16T09:30:00Z', 'done', 1)",
		"INSERT INTO day_plan_items (id, day_plan_id, kind, source_type, title, status, order_index, priority) " +
			"VALUES (2, 1, 'backlog', 'manual', 'Sign off', 'pending', 2, 'high')",
	}, Options{})
	if got := fmt.Sprint(cardIDs(feed.Cards)); got != "[brief-2026-11-16 brief-2026-11-15]" {
		t.Fatalf("cards %s", got)
	}
	today := cardByID(t, feed, "brief-2026-11-16")
	if today.Title != "Morning brief" || today.Preview != "today" || today.SourceLine != "Your day · Mon 16 Nov" ||
		today.Unread || today.CardKind != api.CardLegacy {
		t.Errorf("today %+v", today)
	}
	l := today.Legacy
	want := fmt.Sprint([]api.LegacyItem{
		{RefKind: api.RefPlanItem, ID: 1, Title: "Standup", Stamp: "2026-11-16T09:30:00Z", Done: true, Date: "2026-11-16"},
		{RefKind: api.RefPlanItem, ID: 2, Title: "Sign off", High: true, Date: "2026-11-16"},
	})
	if l == nil || l.Kind != api.LegacyMorningBrief || fmt.Sprint(l.Items) != want {
		t.Fatalf("legacy %+v, want items %s", l, want)
	}
	if len(l.Attention) != 1 || l.Attention[0].Text != "Release waits on you" || l.Attention[0].Priority != "high" {
		t.Errorf("attention %+v", l.Attention)
	}
	if !cardByID(t, feed, "brief-2026-11-15").Unread {
		t.Error("the unread day reads as read")
	}

	none := buildFeed(t, nil, Options{})
	if len(none.Cards) != 0 {
		t.Errorf("no owner: no placeholder, got %v", cardIDs(none.Cards))
	}
	owner := []string{"INSERT INTO email_accounts (id, provider, email_address) VALUES (1, 'imap', 'owner@example.com')"}
	placeholder := buildFeed(t, owner, Options{})
	if got := fmt.Sprint(cardIDs(placeholder.Cards)); got != "[brief-2026-11-16]" {
		t.Errorf("owner known: today's placeholder, got %s", got)
	}
	off := buildFeed(t, owner, Options{DisabledFeatures: []string{briefingFeatureID, dayPlanFeatureID}})
	if len(off.Cards) != 0 {
		t.Errorf("briefing and day plan off: no placeholder, got %v", cardIDs(off.Cards))
	}
}

// A day the client has open (Options.Day, a route to an older read day) is
// listed while it has a briefing or a plan; a day with neither is not, so
// the route selects nothing (the Mac lists only what Go lists).
func TestLegacy_OpenDayListedOnlyWithARecord(t *testing.T) {
	seed := []string{
		"INSERT INTO briefings (id, user_id, date, attention, read_at, created_at) VALUES " +
			"(1, 'U1', '2026-11-14', '[]', '2026-11-14T09:00:00Z', '2026-11-14T08:00:00Z')",
	}
	if got := fmt.Sprint(cardIDs(buildFeed(t, seed, Options{}).Cards)); got != "[]" {
		t.Fatalf("a read older day is not listed: %s", got)
	}
	open := buildFeed(t, seed, Options{Day: "2026-11-14"})
	if got := fmt.Sprint(cardIDs(open.Cards)); got != "[brief-2026-11-14]" {
		t.Fatalf("the open day is listed: %s", got)
	}
	if cardByID(t, open, "brief-2026-11-14").Unread {
		t.Error("the open day keeps its read state")
	}
	if got := fmt.Sprint(cardIDs(buildFeed(t, seed, Options{Day: "2026-11-10"}).Cards)); got != "[]" {
		t.Errorf("a day with neither a briefing nor a plan is not listed: %s", got)
	}
}

// Track my threads is one card: the active tracks newest first, then the
// stopped ones flagged; "N unread" over the active ones only.
func TestLegacy_TracksCardFlagsStopped(t *testing.T) {
	feed := buildFeed(t, []string{
		"INSERT INTO tracks (id, text, priority, updated_at) VALUES (1, 'Budget', 'high', '2026-11-16T09:00:00Z')",
		"INSERT INTO tracks (id, text, read_at, updated_at) VALUES (2, 'Hiring', '2026-11-16T09:00:00Z', '2026-11-16T10:00:00Z')",
		"INSERT INTO track_events (track_id, summary, created_at) VALUES (2, 'moved', '2026-11-16T11:00:00Z')",
		"INSERT INTO tracks (id, text, dismissed_at, updated_at) VALUES (3, 'Office', '2026-11-15T09:00:00Z', '2026-11-15T08:00:00Z')",
	}, Options{})
	c := cardByID(t, feed, TracksCardID)
	if c.Title != "Track my threads" || c.Preview != "2 unread" || !c.Unread || c.Stamp != "2026-11-16T11:00:00Z" {
		t.Errorf("card %+v", c)
	}
	want := fmt.Sprint([]api.LegacyItem{
		{RefKind: api.RefTrack, ID: 2, Title: "Hiring", Subtitle: "Track", Preview: "1 new", Stamp: "2026-11-16T11:00:00Z", Unread: true},
		{RefKind: api.RefTrack, ID: 1, Title: "Budget", Subtitle: "Track", Stamp: "2026-11-16T09:00:00Z", Unread: true, High: true},
		{RefKind: api.RefTrack, ID: 3, Title: "Office", Subtitle: "Track", Stamp: "2026-11-15T08:00:00Z", Unread: true, Stopped: true},
	})
	if got := fmt.Sprint(c.Legacy.Items); got != want {
		t.Errorf("items %s\nwant  %s", got, want)
	}
	stoppedOnly := buildFeed(t, []string{
		"INSERT INTO tracks (id, text, dismissed_at, updated_at) VALUES (3, 'Office', '2026-11-15T09:00:00Z', '2026-11-15T08:00:00Z')",
	}, Options{})
	if c := cardByID(t, stoppedOnly, TracksCardID); c.Unread || c.Preview != "" {
		t.Errorf("only a stopped track: the card stays, unread %v, preview %q", c.Unread, c.Preview)
	}
}

// Idea finder lists the ideas to judge first; Thread briefs one item per
// brief of the last 24 hours (never unread); Messages, while it stands in
// for Waiting for me, the open messages.
func TestLegacy_IdeaFinderAndThreadBriefsAndMessages(t *testing.T) {
	feed := buildFeed(t, []string{
		"INSERT INTO ideas (id, kind, title, essence, status, updated_at) VALUES (1, 'idea', 'Old', 'e1', 'active', '2026-11-16T07:00:00Z')",
		"INSERT INTO ideas (id, kind, title, essence, status, updated_at) VALUES (2, 'idea', 'Judge me', 'e2', 'proposed', '2026-11-15T07:00:00Z')",
		"INSERT INTO ideas (id, kind, title, status, chat_born, updated_at) VALUES (3, 'decision', 'Keep it', 'not_now', 1, '2026-11-16T06:00:00Z')",
		"INSERT INTO agent_actions (id, tool, args_json, reason, status, created_at, decided_at, applied_at, result_json) " +
			`VALUES (1, 'brief_context', '{"summary":"asked"}', 'Brief of #eng', 'applied', '2026-11-16T10:00:00Z', ` +
			`'2026-11-16T10:00:00Z', '2026-11-16T10:00:00Z', '{"summary":"The thread agreed."}')`,
		"INSERT INTO agent_actions (id, tool, args_json, status, created_at, decided_at, applied_at) " +
			`VALUES (2, 'brief_context', '{"summary":"old"}', 'applied', '2026-11-14T10:00:00Z', '2026-11-14T10:00:00Z', '2026-11-14T10:00:00Z')`,
		"INSERT INTO users (id, name, display_name) VALUES ('U1', 'ann', 'Ann')",
		"INSERT INTO channels (id, name, type) VALUES ('C1', 'eng', 'public')",
		"INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type, snippet, permalink, status, " +
			"item_class, priority, why_matters, created_at) VALUES (1, 'C1', '1.1', 'U1', 'mention', 'Can you look?', " +
			"'https://acme.slack.com/p1', 'pending', 'actionable', 'high', 'Blocks the release', '2026-11-16T09:00:00Z')",
	}, Options{})
	ideas := cardByID(t, feed, IdeasCardID)
	if ideas.Preview != "1 to judge" || !ideas.Unread || ideas.Stamp != "2026-11-16T07:00:00Z" {
		t.Errorf("ideas %+v", ideas)
	}
	if got := fmt.Sprint(ideas.Legacy.Items); got != fmt.Sprint([]api.LegacyItem{
		{RefKind: api.RefIdea, ID: 2, Title: "Judge me", Subtitle: "Idea · proposed", Preview: "e2", Stamp: "2026-11-15T07:00:00Z", Unread: true},
		{RefKind: api.RefIdea, ID: 1, Title: "Old", Subtitle: "Idea · active", Preview: "e1", Stamp: "2026-11-16T07:00:00Z"},
		{RefKind: api.RefIdea, ID: 3, Title: "Keep it", Subtitle: "Decision · not now · Chat", Stamp: "2026-11-16T06:00:00Z"},
	}) {
		t.Errorf("idea items %s", got)
	}
	brief := cardByID(t, feed, ThreadBriefCardID(1))
	if brief.Unread || brief.Title != "Brief of #eng" || brief.SourceLine != "Thread brief" ||
		brief.Stamp != "2026-11-16T10:00:00Z" || brief.Legacy.Kind != api.LegacyThreadBriefs ||
		len(brief.Legacy.Items) != 1 || brief.Legacy.Items[0].Title != "Brief of #eng" ||
		brief.Legacy.Items[0].Preview != "The thread agreed." || brief.Legacy.Items[0].RefKind != api.RefAction {
		t.Errorf("thread brief %+v", brief)
	}
	msgs := cardByID(t, feed, MessagesCardID)
	if msgs.Preview != "1 waiting" || msgs.SourceLine != "Mentions, DMs and replies" || !msgs.Unread {
		t.Errorf("messages %+v", msgs)
	}
	if got := fmt.Sprint(msgs.Legacy.Items); got != fmt.Sprint([]api.LegacyItem{{RefKind: api.RefInboxItem, ID: 1,
		Title: "Can you look?", Subtitle: "Ann · #eng", Preview: "Blocks the release", Stamp: "2026-11-16T09:00:00Z",
		Unread: true, High: true}}) {
		t.Errorf("message items %s", got)
	}
	// Root order: newest first by each entry's own time.
	if got := fmt.Sprint(cardIDs(feed.Cards)); got != "[thread-brief-1 messages ideas]" {
		t.Errorf("root %s", got)
	}
}

// The Messages card's items carry their ref facts, in item order, as an
// artifact's rows do: shown and waiting, Reply (a Slack mention with a
// permalink has one, mail has none) and an open Reply (a pending
// send_slack_message in the item's context). The Mac's Reply… reads them.
func TestLegacy_MessagesItemsCarryRefFacts(t *testing.T) {
	item := func(id int, trigger, permalink, created string) string {
		return fmt.Sprintf("INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type, "+
			"snippet, permalink, status, priority, created_at, updated_at) VALUES (%d, 'C1', '1700000000.00%04d', "+
			"'U2', '%s', 'Can you look?', '%s', 'pending', 'medium', '%s', '%s')",
			id, id, trigger, permalink, created, created)
	}
	feed := buildFeed(t, []string{
		item(1, "mention", "https://example.slack.com/archives/C1/p1", "2026-11-16T09:00:00Z"),
		item(2, "email_received", "", "2026-11-16T08:00:00Z"),
		item(3, "dm", "https://example.slack.com/archives/C1/p3", "2026-11-16T07:00:00Z"),
		"INSERT INTO agent_actions (id, tool, args_json, context_type, context_id, status) " +
			`VALUES (1, 'send_slack_message', '{}', 'inbox_item', '3', 'pending')`,
	}, Options{})
	card := cardByID(t, feed, MessagesCardID)
	if card.Legacy == nil || len(card.Legacy.Items) != 3 {
		t.Fatalf("messages card items: %+v", card.Legacy)
	}
	type fact struct {
		id                       int64
		open, waits, reply, wait bool
	}
	var got []fact
	for _, f := range card.RefFacts {
		if f.Kind != api.RefInboxItem {
			t.Fatalf("fact kind %s", f.Kind)
		}
		got = append(got, fact{f.ID, f.Open, f.Waits, f.Reply, f.ReplyWaiting})
	}
	want := []fact{{1, true, true, true, false}, {2, true, true, false, false}, {3, true, true, true, true}}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("facts %v, want %v (items in order 1, 2, 3)", got, want)
	}
}

// A folder hidden by its own flag under a hidden parent: Hidden is the
// effective value (an ancestor's included), OwnHidden the folder's own, so
// the Mac's Show Hidden Folders draws exactly the folders the owner hid.
func TestFolders_OwnHiddenBesideTheEffectiveFlag(t *testing.T) {
	feed := buildFeed(t, []string{
		"INSERT INTO inbox_folders (id, kind, parent_id, slug, title, icon, position, hidden) VALUES (3, 'owner', 1, 'old', 'Old', '', 1, 1)",
		"INSERT INTO inbox_folders (id, kind, parent_id, slug, title, icon, position, hidden) VALUES (4, 'owner', 3, 'older', 'Older', '', 0, 1)",
		"INSERT INTO inbox_folders (id, kind, parent_id, slug, title, icon, position, hidden) VALUES (5, 'owner', 3, 'kept', 'Kept', '', 1, 0)",
	}, Options{})
	got := map[int64][2]bool{}
	for _, f := range feed.Folders {
		got[f.ID] = [2]bool{f.Hidden, f.OwnHidden}
	}
	want := map[int64][2]bool{1: {false, false}, 2: {false, false}, 3: {true, true}, 4: {true, true}, 5: {true, false}}
	for id, w := range want {
		if got[id] != w {
			t.Errorf("folder %d hidden/own %v, want %v", id, got[id], w)
		}
	}
}

// Watchman's morning journal is a root card once Watchman was turned on:
// "Watchman", "N waiting" (unread while one waits) over every night, and
// the newest night's twin decisions — pending, waiting, owner-marked-done,
// owner-first, superseded and check items left out — at the newest item's
// time; not counted in the folder's count. Before the first item it sits at
// the enable time with no night line; before Watchman was turned on there
// is no card.
func TestLegacy_WatchmanJournalCard(t *testing.T) {
	// ownerDone is SQL: NULL or a quoted time.
	item := func(id int, kind, state, outcome string, unsure int, ownerDone, created string) string {
		return fmt.Sprintf("INSERT INTO watchman_items (id, workbench_id, kind, ref_kind, ref_id, state, outcome, unsure, "+
			"owner_done_at, created_at) VALUES (%d, 1, '%s', 'ask', %d, '%s', '%s', %d, %s, '%s')",
			id, kind, id, state, outcome, unsure, ownerDone, created)
	}
	base := []string{
		"INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')",
		"INSERT INTO watchman_workbenches (workbench_id, enabled_at) VALUES (1, '2026-11-10T09:00:00Z')",
	}
	if feed := buildFeed(t, base[:1], Options{}); hasCard(feed, WatchmanCardID) {
		t.Errorf("a card before Watchman was turned on: %v", cardIDs(feed.Cards))
	}
	first := cardByID(t, buildFeed(t, base, Options{}), WatchmanCardID)
	if first.Title != "Watchman" || first.Preview != "" || first.SourceLine != "" || first.Unread ||
		first.Stamp != "2026-11-10T09:00:00Z" || first.Legacy == nil || first.Legacy.Kind != api.LegacyWatchman {
		t.Errorf("before the first item %+v", first)
	}

	// The night before testNow's: 2026-11-15 12:00 to 2026-11-16 12:00 UTC.
	feed := buildFeed(t, append(base,
		item(1, "ask", "done", "answered", 1, "NULL", "2026-11-15T22:00:00Z"),
		item(2, "ask", "done", "answered", 0, "NULL", "2026-11-15T23:00:00Z"),
		item(3, "review_doc", "done", "approved", 1, "NULL", "2026-11-16T01:00:00Z"),
		item(4, "ask", "done", "parked", 1, "NULL", "2026-11-16T02:00:00Z"),                   // waiting
		item(5, "ask", "done", "handed", 1, "'2026-11-16T08:00:00Z'", "2026-11-16T03:00:00Z"), // marked done
		item(6, "ask", "done", "owner_first", 1, "NULL", "2026-11-16T04:00:00Z"),
		item(7, "check", "done", "answered", 1, "NULL", "2026-11-16T05:00:00Z"),
		item(8, "ask", "deciding", "", 1, "NULL", "2026-11-16T06:00:00Z"),
		item(9, "ask", "done", "parked", 1, "NULL", "2026-11-14T22:00:00Z"), // an older night, still waiting
		// Parked, then seen: feedback written, so it no longer waits and is
		// one of the night's decisions.
		item(10, "ask", "done", "parked", 1, "NULL", "2026-11-16T05:30:00Z"),
		"UPDATE watchman_items SET feedback = 'ok' WHERE id = 10",
	), Options{})
	c := cardByID(t, feed, WatchmanCardID)
	if c.Preview != "2 waiting" || !c.Unread || c.SourceLine != "Night of 15 Nov · 4 decided · 3 unsure" ||
		c.Stamp != "2026-11-16T06:00:00Z" || c.CardKind != api.CardLegacy || len(c.Legacy.Items) != 0 {
		t.Errorf("journal card %+v", c)
	}
	for _, f := range feed.Folders {
		if f.Count != 0 {
			t.Errorf("folder %d counts %d: the journal is never counted", f.ID, f.Count)
		}
	}

	tonight := cardByID(t, buildFeed(t, append(base,
		item(1, "ask", "done", "answered", 1, "NULL", "2026-11-16T13:00:00Z")), Options{Now: testNow.Add(2 * time.Hour)}),
		WatchmanCardID)
	if tonight.SourceLine != "Tonight · 1 decided · 1 unsure" || tonight.Preview != "" || tonight.Unread {
		t.Errorf("tonight %+v", tonight)
	}

	// Nights run in Now's zone: 10:00 UTC is last night in UTC, but 13:00
	// — tonight — at UTC+3.
	at10 := append(base, item(1, "ask", "done", "answered", 1, "NULL", "2026-11-16T10:00:00Z"))
	if got := cardByID(t, buildFeed(t, at10, Options{}), WatchmanCardID).SourceLine; got != "Night of 15 Nov · 1 decided · 1 unsure" {
		t.Errorf("in UTC %q", got)
	}
	plus3 := testNow.In(time.FixedZone("UTC+3", 3*3600))
	if got := cardByID(t, buildFeed(t, at10, Options{Now: plus3}), WatchmanCardID).SourceLine; got != "Tonight · 1 decided · 1 unsure" {
		t.Errorf("at UTC+3 %q", got)
	}
}

// OmitMacOnly (the hub's phone feed) leaves the journal card out before the
// limit: at the cap with the newest card a fresh journal card, the phone
// still gets Limit real cards and the same cut count as with no journal.
func TestLegacy_OmitMacOnlyLeavesTheJournalOutBeforeTheLimit(t *testing.T) {
	seed := []string{
		"INSERT INTO automations (id, slug, scope, path, name) VALUES (1, 'a', 'personal', '/recipes/a.md', 'A')",
		"INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (1, 1, 'manual', 'succeeded')",
	}
	for i := 1; i <= 3; i++ {
		seed = append(seed, fmt.Sprintf("INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, created_at) "+
			"VALUES (%d, 1, 1, 'inbox', 'Card %d', 'Body', '2026-11-16T0%d:00:00Z')", i, i, i+5))
	}
	journal := append(append([]string{}, seed...),
		"INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')",
		"INSERT INTO watchman_workbenches (workbench_id, enabled_at) VALUES (1, '2026-11-10T09:00:00Z')",
		"INSERT INTO watchman_items (id, workbench_id, kind, ref_kind, ref_id, state, outcome, created_at) "+
			"VALUES (1, 1, 'ask', 'ask', 1, 'done', 'parked', '2026-11-16T11:00:00Z')")
	if mac := buildFeed(t, journal, Options{Limit: 2}); !hasCard(mac, WatchmanCardID) {
		t.Fatalf("the Mac's capped feed has no journal card: %v", cardIDs(mac.Cards))
	}
	want := buildFeed(t, seed, Options{Limit: 2, OmitMacOnly: true})
	got := buildFeed(t, journal, Options{Limit: 2, OmitMacOnly: true})
	if fmt.Sprint(cardIDs(got.Cards)) != fmt.Sprint(cardIDs(want.Cards)) || len(got.Cards) != 2 {
		t.Errorf("phone cards %v, want %v", cardIDs(got.Cards), cardIDs(want.Cards))
	}
	if fmt.Sprint(got.More) != fmt.Sprint(want.More) || len(got.More) == 0 {
		t.Errorf("phone more %+v, want %+v", got.More, want.More)
	}
}
