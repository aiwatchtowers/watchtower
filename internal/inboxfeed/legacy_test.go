package inboxfeed

import (
	"fmt"
	"testing"

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
