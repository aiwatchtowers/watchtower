package kb

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestTranscript_BuildFromSegmentsSkipsDeleted(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	exec(t, d, `INSERT INTO meeting_transcripts (id, title, transcript_text, segments_json, created_at, updated_at)
		VALUES (7, 'Release sync', 'flat text', ?, '2026-09-11T10:00:00Z', '2026-09-11T10:05:00Z')`,
		`[{"deleted":false,"end_sec":20,"idx":0,"speaker":"anna@x.io","start_sec":12,"text":"Релиз в пятницу"},
		  {"deleted":true,"end_sec":30,"idx":1,"speaker":"bob","start_sec":21,"text":"removed line"},
		  {"deleted":false,"end_sec":40,"idx":2,"speaker":"bob","start_sec":31.6,"text":"ok"}]`)
	doc, err := transcriptSource{}.Build(ctx, d, "transcript:7")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "transcript", doc.Source)
	assert.Equal(t, "Release sync · 2026-09-11", doc.Title)
	require.Len(t, doc.Sections, 2, "the deleted segment is skipped")
	assert.Equal(t, Section{Text: "[anna@x.io] Релиз в пятницу", Anchor: "12"}, doc.Sections[0])
	assert.Equal(t, Section{Text: "[bob] ok", Anchor: "32"}, doc.Sections[1])
	assert.Equal(t, map[string]string{"transcript_id": "7"}, doc.Anchor)
	assert.Equal(t, time.Date(2026, 9, 11, 10, 0, 0, 0, time.UTC), doc.Time)
}

func TestTranscript_NullSegmentsFallBackToLines(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	exec(t, d, `INSERT INTO meeting_transcripts (id, title, transcript_text, created_at, updated_at)
		VALUES (8, 'Ad-hoc', 'first line

second line
', '2026-09-12T09:00:00Z', '2026-09-12T09:00:00Z')`)
	doc, err := transcriptSource{}.Build(ctx, d, "transcript:8")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, []Section{{Text: "first line"}, {Text: "second line"}}, doc.Sections)

	missing, err := transcriptSource{}.Build(ctx, d, "transcript:999")
	require.NoError(t, err)
	assert.Nil(t, missing)
}

func TestRecap_BuildFlattensJSONWithEventTitle(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	exec(t, d, `INSERT INTO calendar_calendars (id, name) VALUES ('cal1','Work')`)
	exec(t, d, `INSERT INTO calendar_events (id, calendar_id, title, start_time, end_time) VALUES ('e1','cal1','Release sync','2026-09-11T10:00:00Z','2026-09-11T11:00:00Z')`)
	exec(t, d, `INSERT INTO meeting_recaps (id, event_id, source_text, recap_json, created_at, updated_at) VALUES
		(3, 'e1', 'src', '{"summary":"Обсудили релиз","key_decisions":["Релиз в пятницу"],"action_items":[{"text":"Подготовить стейдж","assignee":"Anna"}]}', '2026-09-11T12:00:00Z', '2026-09-11T12:00:00Z'),
		(4, NULL, 'src', '{"summary":"Ad-hoc"}', '2026-09-12T12:00:00Z', '2026-09-12T12:00:00Z')`)
	doc, err := recapSource{}.Build(ctx, d, "recap:3")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "Release sync", doc.Title)
	assert.Equal(t, []Section{{Text: "Обсудили релиз"}, {Text: "Релиз в пятницу"}, {Text: "Подготовить стейдж"}}, doc.Sections)
	assert.Equal(t, map[string]string{"recap_id": "3", "event_id": "e1"}, doc.Anchor)
	assert.Equal(t, time.Date(2026, 9, 11, 12, 0, 0, 0, time.UTC), doc.Time)

	adhoc, err := recapSource{}.Build(ctx, d, "recap:4")
	require.NoError(t, err)
	require.NotNil(t, adhoc)
	assert.Equal(t, "Meeting recap", adhoc.Title)
	assert.Equal(t, map[string]string{"recap_id": "4"}, adhoc.Anchor)
}

func seedDigest(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `INSERT INTO channels (id, name, type) VALUES ('1:C1','general','public')`)
	exec(t, d, `INSERT INTO digests (id, channel_id, period_from, period_to, type, summary, created_at)
		VALUES (5, '1:C1', 1758000000, 1758003600, 'channel', 'digest summary', '2026-09-11T10:00:00Z'),
		       (6, '', 1758000000, 1758086400, 'daily', 'daily summary', '2026-09-11T11:00:00Z')`)
	exec(t, d, `INSERT INTO digest_topics (digest_id, idx, title, summary, decisions, action_items) VALUES
		(5, 0, 'Релиз', 'Обсудили релиз', ?, ?),
		(5, 1, 'Stage', 'Нужен стейдж', '[]', '[]'),
		(6, 0, 'Day', 'Итоги дня', '[]', '[]')`,
		`[{"text":"Релиз в пятницу","by":"@v","message_ts":"1.2","importance":"medium"}]`,
		`[{"text":"Подготовить стейдж","assignee":"@a","status":"open"}]`)
}

func TestDigest_BuildTopic(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedDigest(t, d)
	doc, err := digestSource{}.Build(ctx, d, "digest:5:0")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "digest", doc.Source)
	assert.Equal(t, "Релиз", doc.Title)
	assert.Equal(t, []Section{{Text: "Обсудили релиз"}, {Text: "Decision: Релиз в пятницу"}, {Text: "Action: Подготовить стейдж"}}, doc.Sections)
	assert.Equal(t, "#general channel", doc.Meta)
	assert.Equal(t, int64(1758003600), doc.Time.Unix())
	assert.Equal(t, map[string]string{"digest_id": "5", "idx": "0", "channel_id": "1:C1"}, doc.Anchor)

	daily, err := digestSource{}.Build(ctx, d, "digest:6:0")
	require.NoError(t, err)
	require.NotNil(t, daily)
	assert.Equal(t, "daily", daily.Meta, "cross-channel digest carries no channel name")
	assert.Equal(t, map[string]string{"digest_id": "6", "idx": "0"}, daily.Anchor,
		"cross-channel digest anchor has no channel_id key (KB-03: no empty anchor values)")

	gone, err := digestSource{}.Build(ctx, d, "digest:5:9")
	require.NoError(t, err)
	assert.Nil(t, gone)
}

func TestDigest_ChangedIncludesIndexedTopicsOfChangedDigests(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedDigest(t, d)
	// A topic idx 2 of digest 5 was indexed earlier and has since been dropped
	// by a re-upsert; another digest's doc must not be pulled in.
	require.NoError(t, writeTestDoc(ctx, d, "digest:5:2", "digest"))
	require.NoError(t, writeTestDoc(ctx, d, "digest:55:0", "digest"))
	keys, next, done, err := digestSource{}.Changed(ctx, d, "", testNow())
	require.NoError(t, err)
	assert.True(t, done)
	assert.Equal(t, "2026-09-11T11:00:00Z", next)
	assert.Equal(t, []string{"digest:5:0", "digest:5:1", "digest:5:2", "digest:6:0"}, keys)

	// Markers compare with >= : the digest written at exactly the cursor
	// second is re-listed (same-second writes are never lost), older ones not.
	keys, _, _, err = digestSource{}.Changed(ctx, d, "2026-09-11T11:00:00Z", testNow())
	require.NoError(t, err)
	assert.Equal(t, []string{"digest:6:0"}, keys)

	all, err := digestSource{}.Keys(ctx, d)
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"digest:5:0", "digest:5:1", "digest:6:0"}, all)
}

func writeTestDoc(ctx context.Context, d *db.DB, id, source string) error {
	_, err := writeDoc(ctx, d, &Doc{ID: id, Source: source, Title: "t", Sections: []Section{{Text: "body"}}})
	return err
}

func seedStreamDigest(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `INSERT INTO stream_digests (id, source, account_id, scope, period_from, period_to, topics_json, created_at)
		VALUES (2, 'jira', 1, 'PROJ', '2026-09-10T00:00:00Z', '2026-09-11T00:00:00Z', ?, '2026-09-11T01:00:00Z')`,
		`[{"title":"Stage env","summary":"Нужен второй стейдж","ideas":[{"text":"Поднять стейдж","author":"Anna","ref":"PROJ-1"}],"decisions":[]},
		  {"summary":"untitled topic"}]`)
}

func TestStreamDigest_Build(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedStreamDigest(t, d)
	doc, err := streamDigestSource{}.Build(ctx, d, "stream_digest:2:0")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "stream_digest", doc.Source)
	assert.Equal(t, "Stage env", doc.Title)
	assert.Equal(t, []Section{{Text: "Нужен второй стейдж"}, {Text: "Поднять стейдж"}}, doc.Sections)
	assert.Equal(t, "jira PROJ", doc.Meta)
	assert.Equal(t, time.Date(2026, 9, 11, 0, 0, 0, 0, time.UTC), doc.Time)
	assert.Equal(t, map[string]string{"stream_digest_id": "2", "idx": "0", "source": "jira"}, doc.Anchor)

	untitled, err := streamDigestSource{}.Build(ctx, d, "stream_digest:2:1")
	require.NoError(t, err)
	require.NotNil(t, untitled)
	assert.Equal(t, "jira digest", untitled.Title)

	out, err := streamDigestSource{}.Build(ctx, d, "stream_digest:2:2")
	require.NoError(t, err)
	assert.Nil(t, out, "idx out of range")

	keys, next, done, err := streamDigestSource{}.Changed(ctx, d, "", testNow())
	require.NoError(t, err)
	assert.True(t, done)
	assert.Equal(t, "2026-09-11T01:00:00Z", next)
	assert.Equal(t, []string{"stream_digest:2:0", "stream_digest:2:1"}, keys)
}

func TestIdea_BuildOrdersMentionsBySaidAt(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	exec(t, d, `INSERT INTO ideas (id, kind, title, essence, status, last_mention_at, updated_at)
		VALUES (9, 'idea', 'Второй стейдж', 'Поднять второй стейдж', 'active', '2026-09-10T10:00:00Z', '2026-09-11T10:00:00Z')`)
	exec(t, d, `INSERT INTO idea_mentions (id, idea_id, source, quote, author, said_at, created_at) VALUES
		(1, 9, 'slack', 'later quote', '', '2026-09-10T10:00:00Z', '2026-09-11T10:00:00Z'),
		(2, 9, 'jira', 'earlier quote', 'Anna', '2026-09-09T10:00:00Z', '2026-09-11T11:00:00Z')`)
	doc, err := ideaSource{}.Build(ctx, d, "idea:9")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "idea", doc.Source)
	assert.Equal(t, "Второй стейдж", doc.Title)
	assert.Equal(t, "idea active", doc.Meta)
	require.Len(t, doc.Sections, 3)
	assert.Equal(t, "Поднять второй стейдж", doc.Sections[0].Text)
	assert.Equal(t, "Anna: earlier quote", doc.Sections[1].Text)
	assert.Equal(t, "later quote", doc.Sections[2].Text)
	assert.Equal(t, time.Date(2026, 9, 10, 10, 0, 0, 0, time.UTC), doc.Time)
	assert.Equal(t, map[string]string{"idea_id": "9"}, doc.Anchor)

	keys, next, _, err := ideaSource{}.Changed(ctx, d, "2026-09-11T10:30:00Z", testNow())
	require.NoError(t, err)
	assert.Equal(t, []string{"idea:9"}, keys, "a new mention re-renders its idea")
	assert.Equal(t, "2026-09-11T11:00:00Z", next)
}

// A transcript with empty text and no segments stays indexed by its title
// (only a nil Build means "gone").
func TestTranscript_EmptyTextStaysIndexedByTitle(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	exec(t, d, `INSERT INTO meeting_transcripts (id, title, transcript_text, created_at, updated_at)
		VALUES (9, 'Silent standup', '', '2026-09-12T09:00:00Z', '2026-09-12T09:00:00Z')`)
	st, err := Run(ctx, d, Options{Now: testNow(), Sources: []string{"transcript"}})
	require.NoError(t, err)
	assert.Equal(t, 1, st.Written)
	assert.Equal(t, 0, st.Deleted)
	res, err := Search(ctx, d, Request{Queries: []string{"standup"}, Now: testNow()})
	require.NoError(t, err)
	require.Len(t, res.Hits, 1)
	assert.Equal(t, "transcript:9", res.Hits[0].Ref)
	doc, err := GetDocument(ctx, d, "transcript:9", DocOptions{})
	require.NoError(t, err)
	assert.Equal(t, "Silent standup · 2026-09-12", doc.Text)
}
