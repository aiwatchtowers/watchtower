package db

import (
	"testing"
	"time"

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
	// event-linked recap whose calendar row is gone → title falls back to the transcript title, then "Meeting"
	_, err := d.Exec(`INSERT INTO meeting_recaps (event_id, source_text, recap_json, created_at) VALUES (NULL, 's', '{"summary":"we agreed","key_decisions":["ship"],"action_items":["a"]}', '1970-01-01T00:20:00Z')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO meeting_transcripts (event_id, title, transcript_text, summary_json, created_at) VALUES (NULL, 'Ad hoc sync', 'txt', '{"summary":"quick"}', '1970-01-01T00:25:00Z')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO meeting_transcripts (event_id, title, transcript_text, summary_json, created_at) VALUES (NULL, 'Old', 'txt', '{"summary":"old"}', '1970-01-01T05:00:00Z')`)
	require.NoError(t, err)

	items, err := d.ListCatchupMeetings(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, items, 2)
	assert.Equal(t, "recaps", items[0].Area)
	assert.Equal(t, "Meeting", items[0].Title)
	assert.Contains(t, items[0].Body, "we agreed")
	assert.Contains(t, items[0].Body, "Decisions: ship")
	assert.Equal(t, "transcripts", items[1].Area)
	assert.Equal(t, "Ad hoc sync", items[1].Title)
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

	// targets.due_date is a LOCAL "YYYY-MM-DDTHH:MM" string, so the fixtures are
	// derived the same way the query builds its bounds — time-zone-independent.
	const dueLayout = "2006-01-02T15:04"
	dueIn := time.Unix(1500, 0).Local().Format(dueLayout)
	overdue := time.Unix(500, 0).Local().Format(dueLayout)
	later := time.Unix(90000, 0).Local().Format(dueLayout)
	_, err = d.Exec(`INSERT INTO targets (text, period_start, period_end, status, priority, due_date) VALUES
		('Due in window', '1970-01-01', '1970-01-01', 'todo', 'high', ?),
		('Overdue', '1970-01-01', '1970-01-01', 'in_progress', 'medium', ?),
		('Done', '1970-01-01', '1970-01-01', 'done', 'high', ?),
		('Later', '1970-01-01', '1970-01-01', 'todo', 'high', ?),
		('No due', '1970-01-01', '1970-01-01', 'todo', 'high', '')`, dueIn, overdue, dueIn, later)
	require.NoError(t, err)
	targets, err := d.ListCatchupTargets(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, targets, 2)
	assert.ElementsMatch(t, []string{"Due in window", "Overdue"}, []string{targets[0].Title, targets[1].Title})
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
