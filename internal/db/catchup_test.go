package db

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestListCatchupDigests_WindowOverlapAndTopics(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'eng', 'public')`)
	require.NoError(t, err)
	in, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary, message_count) VALUES ('1:C1', 900, 1100, 'channel', 'overlaps start', 7)`)
	require.NoError(t, err)
	inID, err := in.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO digest_topics (digest_id, idx, title, summary) VALUES (?, 0, 'Deploy', 'shipped v2')`, inID)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('1:C1', 2100, 2200, 'channel', 'after')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('', 1000, 2000, 'daily', 'rollup excluded')`)
	require.NoError(t, err)

	items, err := d.ListCatchupDigests(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "digests", items[0].Area)
	assert.Equal(t, int(inID), items[0].ID)
	assert.Equal(t, "#eng", items[0].Title)
	assert.Contains(t, items[0].Body, "overlaps start")
	assert.Contains(t, items[0].Body, "Deploy: shipped v2")
	assert.Equal(t, "1:C1", items[0].ChannelID)
}

// The per-area cap is what bounds the compose prompt, so it must actually
// truncate rather than being a hint the query ignores.
func TestListCatchupDigests_CapTruncates(t *testing.T) {
	d := openTestDB(t)
	const limit = 3
	for i := 0; i < limit+2; i++ {
		_, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('1:C1', ?, ?, 'channel', 'x')`,
			1000+i, 1100+i)
		require.NoError(t, err)
	}

	items, err := d.ListCatchupDigests(1000, 2000, limit)
	require.NoError(t, err)
	assert.Len(t, items, limit, "the per-area cap bounds what the gather returns")
}

// A malformed topics_json costs the row its body, never the whole gather.
func TestListCatchupStreams_UnreadableTopicsJSON(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO stream_digests (source, account_id, period_from, period_to, topics_json)
		VALUES ('gmail', 1, '1970-01-01T00:20:00Z', '1970-01-01T00:30:00Z', 'not json')`)
	require.NoError(t, err)

	items, err := d.ListCatchupStreams(1000, 2000, 10)
	require.NoError(t, err, "an unreadable payload is not a gather failure")
	require.Len(t, items, 1)
	assert.Empty(t, items[0].Body)
	assert.Equal(t, "gmail", items[0].Title, "the row itself still reaches the recap")
}

func TestListCatchupStreams(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO stream_digests (source, account_id, scope, period_from, period_to, topics_json)
		VALUES ('jira', 1, 'PROJ', '1970-01-01T00:20:00Z', '1970-01-01T00:30:00Z', '[{"title":"Bug bash","summary":"12 fixed"}]')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO stream_digests (source, account_id, period_from, period_to) VALUES ('gmail', 1, '1970-01-01T01:00:00Z', '1970-01-01T02:00:00Z')`)
	require.NoError(t, err)

	items, err := d.ListCatchupStreams(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "streams", items[0].Area)
	assert.Equal(t, "jira · PROJ", items[0].Title)
	assert.Contains(t, items[0].Body, "Bug bash: 12 fixed")
}

func TestListCatchupMeetings_RecapAndAdHoc(t *testing.T) {
	d := openTestDB(t)
	// Recap title fallback chain: calendar event title → linked transcript title
	// → "Meeting". All three tiers get a fixture, ordered by created_at.
	_, err := d.Exec(`INSERT INTO calendar_calendars (id, name) VALUES ('cal1', 'Primary')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO calendar_events (id, calendar_id, title, start_time, end_time)
		VALUES ('E1', 'cal1', 'Weekly sync', '1970-01-01T00:15:00Z', '1970-01-01T00:17:00Z')`)
	require.NoError(t, err)
	// A recording whose recap lives in meeting_recaps carries no summary_json, so
	// it is not itself an ad-hoc transcript — it only supplies the recap's title.
	linked, err := d.Exec(`INSERT INTO meeting_transcripts (event_id, title, transcript_text, summary_json, created_at) VALUES (NULL, 'Linked recording', 'txt', NULL, '1970-01-01T00:19:00Z')`)
	require.NoError(t, err)
	linkedID, err := linked.LastInsertId()
	require.NoError(t, err)
	// The event-linked meeting was recorded too, so its recap has BOTH titles
	// available — which is what makes the event-over-transcript precedence testable.
	evtRec, err := d.Exec(`INSERT INTO meeting_transcripts (event_id, title, transcript_text, summary_json, created_at) VALUES ('E1', 'Weekly sync recording', 'txt', NULL, '1970-01-01T00:17:30Z')`)
	require.NoError(t, err)
	evtRecID, err := evtRec.LastInsertId()
	require.NoError(t, err)

	// tier 1: calendar event title wins over the linked transcript's title
	_, err = d.Exec(`INSERT INTO meeting_recaps (event_id, transcript_id, source_text, recap_json, created_at) VALUES ('E1', ?, 's', '{"summary":"synced"}', '1970-01-01T00:18:00Z')`, evtRecID)
	require.NoError(t, err)
	// tier 2: no event, but a linked transcript
	_, err = d.Exec(`INSERT INTO meeting_recaps (event_id, transcript_id, source_text, recap_json, created_at) VALUES (NULL, ?, 's', '{"summary":"from recording"}', '1970-01-01T00:19:30Z')`, linkedID)
	require.NoError(t, err)
	// tier 3: neither → "Meeting"
	_, err = d.Exec(`INSERT INTO meeting_recaps (event_id, source_text, recap_json, created_at) VALUES (NULL, 's', '{"summary":"we agreed","key_decisions":["ship"],"action_items":["a"]}', '1970-01-01T00:20:00Z')`)
	require.NoError(t, err)

	_, err = d.Exec(`INSERT INTO meeting_transcripts (event_id, title, transcript_text, summary_json, created_at) VALUES (NULL, 'Ad hoc sync', 'txt', '{"summary":"quick"}', '1970-01-01T00:25:00Z')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO meeting_transcripts (event_id, title, transcript_text, summary_json, created_at) VALUES (NULL, 'Old', 'txt', '{"summary":"old"}', '1970-01-01T05:00:00Z')`)
	require.NoError(t, err)

	items, err := d.ListCatchupMeetings(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, items, 4)
	assert.Equal(t, "recaps", items[0].Area)
	assert.Equal(t, "Weekly sync", items[0].Title)
	assert.Contains(t, items[0].Body, "synced")
	assert.Equal(t, "recaps", items[1].Area)
	assert.Equal(t, "Linked recording", items[1].Title)
	assert.Contains(t, items[1].Body, "from recording")
	assert.Equal(t, "recaps", items[2].Area)
	assert.Equal(t, "Meeting", items[2].Title)
	assert.Contains(t, items[2].Body, "we agreed")
	assert.Contains(t, items[2].Body, "Decisions: ship")
	assert.Equal(t, "transcripts", items[3].Area)
	assert.Equal(t, "Ad hoc sync", items[3].Title)
}

func TestListCatchupDecisions_MentionInWindow(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO ideas (id, kind, title, essence, status) VALUES (1, 'decision', 'Use Postgres', 'for analytics', 'active'), (2, 'decision', 'Old', '', 'active'), (3, 'idea', 'Not a decision', '', 'active')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO idea_mentions (idea_id, source, ref, quote, author, said_at) VALUES
		(1, 'slack', 'C1|1', 'let us use pg', 'Ann', '1970-01-01T00:20:00Z'),
		(2, 'slack', 'C1|2', 'old', 'Bob', '1970-01-01T05:00:00Z'),
		(3, 'slack', 'C1|3', 'idea', 'Cy', '1970-01-01T00:20:00Z')`)
	require.NoError(t, err)

	items, err := d.ListCatchupDecisions(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "decisions", items[0].Area)
	assert.Equal(t, 1, items[0].ID)
	assert.Equal(t, "Use Postgres", items[0].Title)
	assert.Contains(t, items[0].Body, "for analytics")
	assert.Contains(t, items[0].Meta, "Ann")
}

// TestListCatchupDecisions_LatestMentionWins pins the bare-column resolution:
// with several in-window mentions, Meta must carry the LATEST one.
func TestListCatchupDecisions_LatestMentionWins(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO ideas (id, kind, title, essence, status) VALUES (1, 'decision', 'Use Postgres', 'for analytics', 'active')`)
	require.NoError(t, err)
	// Rows are inserted out of chronological order so that neither "first row
	// scanned" nor "last row scanned" accidentally yields the latest mention.
	_, err = d.Exec(`INSERT INTO idea_mentions (idea_id, source, ref, quote, author, said_at) VALUES
		(1, 'meeting', 'C1|2', 'last word', 'Zoe', '1970-01-01T00:30:00Z'),
		(1, 'slack', 'C1|3', 'middle word', 'Bob', '1970-01-01T00:25:00Z'),
		(1, 'slack', 'C1|1', 'first word', 'Ann', '1970-01-01T00:18:00Z')`)
	require.NoError(t, err)

	items, err := d.ListCatchupDecisions(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Contains(t, items[0].Meta, "Zoe")
	assert.Contains(t, items[0].Meta, "last word")
	assert.Contains(t, items[0].Meta, "meeting")
}

func TestListCatchupInbox_ActionablePendingInWindow(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO users (id, name, display_name) VALUES ('1:U1', 'ann', 'Ann')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'eng', 'public')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, status, item_class, created_at) VALUES
		('1:C1', '1', '1:U1', 'mention', 'can you review?', 'pending', 'actionable', '1970-01-01T00:20:00Z'),
		('1:C1', '2', '1:U1', 'mention', 'resolved one', 'resolved', 'actionable', '1970-01-01T00:20:00Z'),
		('1:C1', '3', '1:U1', 'stream', 'ambient', 'pending', 'ambient', '1970-01-01T00:20:00Z'),
		('1:C1', '4', '1:U1', 'dm', 'too late', 'pending', 'actionable', '1970-01-01T05:00:00Z')`)
	require.NoError(t, err)

	items, err := d.ListCatchupInbox(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "inbox", items[0].Area)
	assert.Equal(t, "mention", items[0].Title)
	assert.Equal(t, "can you review?", items[0].Body)
	assert.Contains(t, items[0].Meta, "Ann")
	assert.Contains(t, items[0].Meta, "#eng")
	assert.Equal(t, "1:C1", items[0].ChannelID)
	assert.Equal(t, "1:U1", items[0].SenderID)
}

func TestListCatchupTracksAndTargets(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO tracks (text, context, priority, ownership, updated_at, dismissed_at) VALUES
		('Review PR', 'ctx', 'high', 'mine', '1970-01-01T00:20:00Z', ''),
		('Dismissed', '', 'low', 'mine', '1970-01-01T00:20:00Z', '2020-01-01T00:00:00Z'),
		('Old', '', 'low', 'mine', '1970-01-01T05:00:00Z', '')`)
	require.NoError(t, err)
	tracks, err := d.ListCatchupTracks(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, tracks, 1)
	assert.Equal(t, "Review PR", tracks[0].Title)
	assert.Contains(t, tracks[0].Meta, "high")

	// targets.due_date is "YYYY-MM-DDTHH:MM" in UTC (the targets.go convention),
	// so these are literal UTC strings: the window unix 1000..2000 is
	// 00:16..00:33 UTC. Two fixtures pin the bounds against a .Local() shift on a
	// non-UTC host: 'Due in window' (00:20) drops out entirely under a negative
	// offset, and 'Just after window' (00:34, one minute past the end) is pulled
	// in — as in-window or as overdue — under any positive offset.
	_, err = d.Exec(`INSERT INTO targets (text, period_start, period_end, status, priority, due_date) VALUES
		('Due in window', '1970-01-01', '1970-01-01', 'todo', 'high', '1970-01-01T00:20'),
		('Overdue', '1970-01-01', '1970-01-01', 'in_progress', 'medium', '1969-12-31T10:00'),
		('Just after window', '1970-01-01', '1970-01-01', 'todo', 'high', '1970-01-01T00:34'),
		('Done', '1970-01-01', '1970-01-01', 'done', 'high', '1970-01-01T00:20'),
		('Later', '1970-01-01', '1970-01-01', 'todo', 'high', '1970-01-02T00:00'),
		('No due', '1970-01-01', '1970-01-01', 'todo', 'high', '')`)
	require.NoError(t, err)
	targets, err := d.ListCatchupTargets(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, targets, 2)
	assert.ElementsMatch(t, []string{"Due in window", "Overdue"}, []string{targets[0].Title, targets[1].Title})
}

// The overdue backlog is unbounded in practice, so it must never crowd the
// deadlines that fell during the absence out of a capped gather — and a target
// due exactly on the window start belongs to the window, not to neither arm.
func TestListCatchupTargets_InWindowOutranksOverdue(t *testing.T) {
	d := openTestDB(t)
	const limit = 3
	// The window unix 1000..2000 is 00:16..00:33 UTC.
	for i := 0; i < limit+1; i++ {
		_, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, status, priority, due_date)
			VALUES (?, '1969-12-31', '1969-12-31', 'todo', 'high', ?)`,
			fmt.Sprintf("Overdue %d", i), fmt.Sprintf("1969-12-31T0%d:00", i))
		require.NoError(t, err)
	}
	_, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, status, priority, due_date) VALUES
		('Due in window', '1970-01-01', '1970-01-01', 'todo', 'high', '1970-01-01T00:20'),
		('Due exactly at from', '1970-01-01', '1970-01-01', 'todo', 'high', '1970-01-01T00:16')`)
	require.NoError(t, err)

	items, err := d.ListCatchupTargets(1000, 2000, limit)
	require.NoError(t, err)
	require.Len(t, items, limit)
	titles := []string{items[0].Title, items[1].Title, items[2].Title}
	assert.Contains(t, titles, "Due in window", "an overdue backlog past the cap must not hide an in-window deadline")
	assert.Contains(t, titles, "Due exactly at from", "a deadline landing exactly on the window start is in-window")
	assert.Equal(t, "Due exactly at from", items[0].Title, "in-window first, earliest due date first")
	assert.Equal(t, "Due in window", items[1].Title)
}

func TestCatchupCoverage(t *testing.T) {
	d := openTestDB(t)
	slackTo, streamsTo, err := d.CatchupCoverage(1000, 2000)
	require.NoError(t, err)
	assert.Equal(t, 0.0, slackTo)
	assert.Equal(t, 0.0, streamsTo)

	_, err = d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('1:C1', 1000, 1500, 'channel', 'a'), ('1:C2', 1000, 1800, 'channel', 'b'), ('1:C3', 2000, 2500, 'channel', 'c')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO stream_digests (source, account_id, period_from, period_to) VALUES ('jira', 1, '1970-01-01T00:16:40Z', '1970-01-01T00:26:40Z')`) // 1600
	require.NoError(t, err)

	slackTo, streamsTo, err = d.CatchupCoverage(1000, 2000)
	require.NoError(t, err)
	assert.Equal(t, 1800.0, slackTo)
	assert.Equal(t, 1600.0, streamsTo)

	// A top-up digest generated by the run itself: period_from inside the window,
	// period_to stamped with its own time.Now() a second past `to`. It overlaps
	// the window, so coverage counts it — and honestly reports reaching past `to`.
	_, err = d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('1:C4', 1900, 2001, 'channel', 'topup')`)
	require.NoError(t, err)
	slackTo, _, err = d.CatchupCoverage(1000, 2000)
	require.NoError(t, err)
	assert.Equal(t, 2001.0, slackTo, "coverage reaches past `to` when a top-up digest says it does")
}

func TestFetchItemScopeHints_Areas(t *testing.T) {
	d := openTestDB(t)
	res, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('1:C9', 1, 2, 'channel', 's')`)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	ch, snd, err := d.FetchItemScopeHints("digests", int(id))
	require.NoError(t, err)
	assert.Equal(t, "1:C9", ch)
	assert.Empty(t, snd)
	for _, area := range []string{"streams", "recaps", "transcripts", "decisions", "tracks", "targets"} {
		ch, snd, err := d.FetchItemScopeHints(area, 1)
		require.NoError(t, err, area)
		assert.Empty(t, ch+snd, area)
	}
	_, _, err = d.FetchItemScopeHints("briefings", 1)
	assert.Error(t, err, "briefings is no longer an area")
}
