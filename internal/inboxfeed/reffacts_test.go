package inboxfeed

import (
	"fmt"
	"strings"
	"testing"

	"watchtower/internal/tower/api"
)

// refCardSeed is an owner automation (1) with a run and one card whose list
// rows carry refs ("kind:id" each).
func refCardSeed(refs ...string) []string {
	rows := make([]string, 0, len(refs))
	for i, r := range refs {
		kind, id, _ := strings.Cut(r, ":")
		rows = append(rows, fmt.Sprintf(`{"title":"Row %d","ref":{"kind":"%s","id":%s}}`, i, kind, id))
	}
	doc := `{"v":1,"blocks":[{"type":"list","rows":[` + strings.Join(rows, ",") + `]}]}`
	return []string{
		"INSERT INTO automations (id, slug, scope, path, name) VALUES (1, 'watch', 'personal', '/recipes/watch.md', 'Watch')",
		"INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (1, 1, 'manual', 'succeeded')",
		"INSERT INTO automation_outputs (id, automation_id, run_id, kind, title, body, created_at, blocks_json) " +
			"VALUES (1, 1, 1, 'inbox', 'Rows', 'Rows.', '2026-11-16T08:00:00Z', '" + doc + "')",
	}
}

// refFacts are the facts of the one card the root lists.
func refFacts(t *testing.T, seed []string) []api.RefFacts {
	t.Helper()
	feed := buildFeed(t, seed, Options{})
	for _, c := range feed.Cards {
		if c.ID == OutputCardID(1) {
			return c.RefFacts
		}
	}
	t.Fatalf("no card o1 in %v", cardIDs(feed.Cards))
	return nil
}

func TestRefFacts_InboxItemOpenAndWaits(t *testing.T) {
	facts := refFacts(t, append(refCardSeed("inbox_item:1", "inbox_item:2", "inbox_item:3"),
		"INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type, snippet, permalink, status, "+
			"item_class, created_at) VALUES (1, 'C1', '1.1', 'U1', 'mention', 'hi', 'https://acme.slack.com/p1', 'pending', "+
			"'actionable', '2026-11-16T08:00:00Z')",
		"INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type, snippet, permalink, status, "+
			"item_class, created_at) VALUES (2, 'C1', '1.2', 'U1', 'email_received', 'mail', '', 'resolved', "+
			"'actionable', '2026-11-16T08:00:00Z')"))
	want := []api.RefFacts{
		{Kind: api.RefInboxItem, ID: 1, Open: true, Waits: true, Reply: true, Link: "https://acme.slack.com/p1",
			TriggerType: "mention"},
		{Kind: api.RefInboxItem, ID: 2, TriggerType: "email_received"},
		{Kind: api.RefInboxItem, ID: 3},
	}
	if fmt.Sprint(facts) != fmt.Sprint(want) {
		t.Errorf("facts %+v\nwant %+v", facts, want)
	}
}

func TestRefFacts_TrackDoneIsClosed(t *testing.T) {
	facts := refFacts(t, append(refCardSeed("track:1", "track:2", "track:3"),
		"INSERT INTO tracks (id, text) VALUES (1, 'Open')",
		"INSERT INTO tracks (id, text, read_at) VALUES (2, 'Done', '2026-11-16T09:00:00Z')",
		"INSERT INTO tracks (id, text, dismissed_at) VALUES (3, 'Stopped', '2026-11-16T09:00:00Z')"))
	got := fmt.Sprint(facts)
	want := fmt.Sprint([]api.RefFacts{{Kind: api.RefTrack, ID: 1, Open: true, Waits: true},
		{Kind: api.RefTrack, ID: 2}, {Kind: api.RefTrack, ID: 3}})
	if got != want {
		t.Errorf("facts %s, want %s", got, want)
	}
}

// A track carries what the Mac's row buttons read: a custom track (Delete…
// and Go to Target in place of Make a Task) and its linked target.
func TestRefFacts_TrackCustomAndLinkedTarget(t *testing.T) {
	facts := refFacts(t, append(refCardSeed("track:1", "track:2"),
		"INSERT INTO targets (id, text, period_start, period_end) VALUES (4, 'Ship', '2026-11-01', '2026-11-30')",
		"INSERT INTO tracks (id, text, origin, linked_target_id) VALUES (1, 'Custom', 'custom', 4)",
		"INSERT INTO tracks (id, text) VALUES (2, 'Extracted')"))
	want := fmt.Sprint([]api.RefFacts{{Kind: api.RefTrack, ID: 1, Open: true, Waits: true, Custom: true, LinkedTargetID: 4},
		{Kind: api.RefTrack, ID: 2, Open: true, Waits: true}})
	if got := fmt.Sprint(facts); got != want {
		t.Errorf("facts %s, want %s", got, want)
	}
}

// An idea snoozed to a later day is closed until that day starts in the
// owner's zone; an active idea is shown but waits on no verdict.
func TestRefFacts_IdeaSnoozedIsClosedUntilDue(t *testing.T) {
	seed := append(refCardSeed("idea:1", "idea:2", "idea:3"),
		"INSERT INTO ideas (id, kind, title, status, snooze_until) VALUES (1, 'idea', 'Tomorrow', 'proposed', '2026-11-17')",
		"INSERT INTO ideas (id, kind, title, status, snooze_until) VALUES (2, 'idea', 'Today', 'proposed', '2026-11-16')",
		"INSERT INTO ideas (id, kind, title, status) VALUES (3, 'idea', 'Active', 'active')")
	facts := refFacts(t, seed)
	want := fmt.Sprint([]api.RefFacts{{Kind: api.RefIdea, ID: 1, IdeaKind: "idea", IdeaStatus: "proposed"},
		{Kind: api.RefIdea, ID: 2, Open: true, Waits: true, IdeaKind: "idea", IdeaStatus: "proposed"},
		{Kind: api.RefIdea, ID: 3, Open: true, IdeaKind: "idea", IdeaStatus: "active"}})
	if got := fmt.Sprint(facts); got != want {
		t.Errorf("facts %s, want %s", got, want)
	}
	next := buildFeed(t, seed, Options{Now: testNow.AddDate(0, 0, 1)})
	for _, c := range next.Cards {
		if c.ID == OutputCardID(1) && !c.RefFacts[0].Open {
			t.Errorf("the next day the snoozed idea is still closed: %+v", c.RefFacts[0])
		}
	}
}

// A Reply to an item waits while its proposal is pending, approved or
// executing; a rejected one frees it.
func TestRefFacts_ReplyWaitingWhenAProposalIsOpen(t *testing.T) {
	item := func(id int) string {
		return fmt.Sprintf("INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type, snippet, "+
			"permalink, status, item_class, created_at) VALUES (%d, 'C1', '1.%d', 'U1', 'mention', 'hi', "+
			"'https://acme.slack.com/p%d', 'pending', 'actionable', '2026-11-16T08:00:00Z')", id, id, id)
	}
	reply := func(id int, item int, status string) string {
		return fmt.Sprintf("INSERT INTO agent_actions (id, tool, args_json, status, surface, context_type, context_id, created_at) "+
			"VALUES (%d, 'send_slack_message', '{}', '%s', 'inbox', 'inbox_item', '%d', '2026-11-16T09:00:00Z')", id, status, item)
	}
	facts := refFacts(t, append(refCardSeed("inbox_item:1", "inbox_item:2"),
		item(1), item(2), reply(1, 1, "approved"), reply(2, 2, "rejected")))
	if !facts[0].ReplyWaiting || facts[1].ReplyWaiting {
		t.Errorf("reply_waiting %v, %v; want true, false", facts[0].ReplyWaiting, facts[1].ReplyWaiting)
	}
}

// Closed rows stay in the document: the facts list every ref, open or not,
// once each, in document order; the screen models hide the closed ones.
func TestRefFacts_ClosedRowsStayInTheDocument(t *testing.T) {
	feed := buildFeed(t, append(refCardSeed("track:2", "track:1", "track:2", "reminder:1"),
		"INSERT INTO tracks (id, text) VALUES (1, 'Open')",
		"INSERT INTO tracks (id, text, read_at) VALUES (2, 'Done', '2026-11-16T09:00:00Z')",
		"INSERT INTO reminders (id, message_ref, note, remind_at, status) VALUES (1, 'C1@1700000000.000100', 'n', '2026-11-16T11:00:00Z', 'done')"),
		Options{})
	var card api.Card
	for _, c := range feed.Cards {
		if c.ID == OutputCardID(1) {
			card = c
		}
	}
	if !strings.Contains(card.Blocks, `"Row 0"`) {
		t.Fatalf("the document lost its rows: %q", card.Blocks)
	}
	want := fmt.Sprint([]api.RefFacts{{Kind: api.RefTrack, ID: 2}, {Kind: api.RefTrack, ID: 1, Open: true, Waits: true},
		{Kind: api.RefReminder, ID: 1, Link: "https://slack.com/archives/C1/p1700000000000100"}})
	if got := fmt.Sprint(card.RefFacts); got != want {
		t.Errorf("facts %s, want %s", got, want)
	}
	if f := feed.Folders[0]; f.Count != 1 || f.Waiting != 1 {
		t.Errorf("root counts %d, waiting %d; want 1, 1", f.Count, f.Waiting)
	}
}
