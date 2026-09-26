package kb

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedAll seeds rows for every one of the ten sources and indexes them at
// testNow().
func seedAll(t *testing.T, d *db.DB) {
	t.Helper()
	seedSlack(t, d)
	seedGmail(t, d)
	seedIMAP(t, d)
	seedJira(t, d)
	seedCalendarAndMeetings(t, d)
	seedDigestTopics(t, d)
	seedStreamDigest(t, d)
	seedIdea(t, d)
	_, err := Run(context.Background(), d, Options{Now: testNow()})
	require.NoError(t, err)
}

// seedCalendarAndMeetings seeds two calendar events (one with an unparsable
// start), a segmented transcript and two recaps (event-linked and ad-hoc).
func seedCalendarAndMeetings(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `INSERT INTO calendar_calendars (id, name) VALUES ('cal1','Work')`)
	exec(t, d, `INSERT INTO calendar_events (id, calendar_id, title, description, location, start_time, end_time, organizer_email, attendees, html_link)
		VALUES ('e1','cal1','Release sync','Обсудить стейдж','Room 1','2026-09-11T10:00:00Z','2026-09-11T11:00:00Z','boss@x.io','null','https://cal/e1'),
		       ('e2','cal1','Obj attendees','Квартальное планирование','','not-a-date','','','[{"email":"a@x.io","displayName":"Anna"},"b@x.io"]','')`)
	exec(t, d, `INSERT INTO meeting_transcripts (id, title, transcript_text, segments_json, created_at, updated_at)
		VALUES (7, 'Release sync', 'flat text', ?, '2026-09-11T10:00:00Z', '2026-09-11T10:05:00Z')`,
		`[{"deleted":false,"end_sec":20,"idx":0,"speaker":"anna@x.io","start_sec":12,"text":"Релиз в пятницу, миграция базы"},
		  {"deleted":false,"end_sec":40,"idx":1,"speaker":"bob","start_sec":31.6,"text":"ok"}]`)
	exec(t, d, `INSERT INTO meeting_recaps (id, event_id, source_text, recap_json, created_at, updated_at) VALUES
		(3, 'e1', 'src', '{"summary":"Обсудили ретроспективу","action_items":[{"text":"Подготовить стейдж","assignee":"Anna"}]}', '2026-09-11T12:00:00Z', '2026-09-11T12:00:00Z'),
		(4, NULL, 'src', '{"summary":"Ad-hoc созвон"}', '2026-09-12T12:00:00Z', '2026-09-12T12:00:00Z')`)
}

// seedDigestTopics seeds a channel digest (on seedSlack's #general) and a
// cross-channel daily digest.
func seedDigestTopics(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `INSERT INTO digests (id, channel_id, period_from, period_to, type, summary, created_at)
		VALUES (5, '1:C1', 1758000000, 1758003600, 'channel', 'digest summary', '2026-09-11T10:00:00Z'),
		       (6, '', 1758000000, 1758086400, 'daily', 'daily summary', '2026-09-11T11:00:00Z')`)
	exec(t, d, `INSERT INTO digest_topics (digest_id, idx, title, summary, decisions, action_items) VALUES
		(5, 0, 'Релиз', 'Обсудили выкатку', ?, '[]'),
		(6, 0, 'Day', 'Итоги дня', '[]', '[]')`,
		`[{"text":"Выкатка в четверг","by":"@v","message_ts":"1.2","importance":"medium"}]`)
}

func seedIdea(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `INSERT INTO ideas (id, kind, title, essence, status, last_mention_at, updated_at)
		VALUES (9, 'idea', 'Кэширование', 'Добавить кэширование ответов', 'active', '2026-09-10T10:00:00Z', '2026-09-11T10:00:00Z')`)
	exec(t, d, `INSERT INTO idea_mentions (id, idea_id, source, quote, author, said_at, created_at) VALUES
		(1, 9, 'slack', 'давайте кэш', 'Anna', '2026-09-10T10:00:00Z', '2026-09-11T10:00:00Z')`)
}

func hitRefs(res Result) []string {
	refs := make([]string, 0, len(res.Hits))
	for _, h := range res.Hits {
		refs = append(refs, h.Ref)
	}
	return refs
}

func hitSources(res Result) map[string]bool {
	out := map[string]bool{}
	for _, h := range res.Hits {
		out[h.Source] = true
	}
	return out
}

// writeSearchDoc stores a one-section document directly (fusion/recency
// fixtures that need precise control over text and time).
func writeSearchDoc(t *testing.T, d *db.DB, id, text string, at time.Time) {
	t.Helper()
	_, err := writeDoc(context.Background(), d, &Doc{
		ID: "idea:" + id, Source: "idea", Title: "doc " + id, Time: at,
		Anchor: map[string]string{"idea_id": id}, Sections: []Section{{Text: text}},
	})
	require.NoError(t, err)
}

func TestSearch_MorphologyAndYo(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedAll(t, d)
	res, err := Search(ctx, d, Request{Queries: []string{"договор*"}, Now: testNow()})
	require.NoError(t, err)
	require.NotEmpty(t, res.Hits)
	assert.Equal(t, slackThreadRef("1:C1", "1758000000.000100"), res.Hits[0].Ref)
	assert.Equal(t, "2025-09-16T05:21:40Z", res.Hits[0].When)
	assert.Equal(t, "https://slack.test/1758000000.000100", res.Hits[0].Link)
	assert.Equal(t, map[string]string{"channel_id": "1:C1", "thread_ts": "1758000000.000100"}, res.Hits[0].Anchor)
	require.NotEmpty(t, res.Hits[0].Snippets)
	assert.Contains(t, res.Hits[0].Snippets[0], "Договорились")
	res, err = Search(ctx, d, Request{Queries: []string{"стейдж"}, Now: testNow()})
	require.NoError(t, err)
	refs := hitRefs(res)
	assert.Contains(t, refs, "jira:1:PROJ-123")
	assert.Contains(t, refs, "calendar:e1")

	// ё is folded on both sides: a ё query and an е prefix both find «Договорённость».
	yo := db.OpenTestDB(t)
	writeSearchDoc(t, yo, "1", "Договорённость о сроках", testNow())
	for _, q := range []string{"договорен*", "договорённость", "ДОГОВОРЕННОСТЬ"} {
		res, err = Search(ctx, yo, Request{Queries: []string{q}, Now: testNow()})
		require.NoError(t, err)
		assert.Equal(t, []string{"idea:1"}, hitRefs(res), q)
	}
}

func TestSearch_SourceAndTimeFilters(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedAll(t, d)
	// "стейдж" matches jira, calendar, recap and stream_digest documents.
	all, err := Search(ctx, d, Request{Queries: []string{"стейдж"}, Now: testNow()})
	require.NoError(t, err)
	require.Greater(t, len(hitSources(all)), 1)

	res, err := Search(ctx, d, Request{Queries: []string{"стейдж"}, Sources: []string{"jira"}, Now: testNow()})
	require.NoError(t, err)
	assert.Equal(t, []string{"jira:1:PROJ-123"}, hitRefs(res))

	res, err = Search(ctx, d, Request{Queries: []string{"стейдж"}, Sources: []string{"jira", "calendar"}, Now: testNow()})
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"jira:1:PROJ-123", "calendar:e1"}, hitRefs(res))

	// The jira document's time is 2026-04-21T10:00Z: a From after it excludes it.
	after := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	res, err = Search(ctx, d, Request{Queries: []string{"стейдж"}, From: after, Now: testNow()})
	require.NoError(t, err)
	assert.NotEmpty(t, res.Hits)
	assert.NotContains(t, hitRefs(res), "jira:1:PROJ-123")
	for _, h := range res.Hits {
		assert.GreaterOrEqual(t, h.When, "2026-05-01T00:00:00Z", h.Ref)
	}

	// To is exclusive and keeps only what happened before it.
	res, err = Search(ctx, d, Request{Queries: []string{"стейдж"}, To: after, Now: testNow()})
	require.NoError(t, err)
	assert.Equal(t, []string{"jira:1:PROJ-123"}, hitRefs(res))
	res, err = Search(ctx, d, Request{Queries: []string{"стейдж"}, To: time.Date(2026, 4, 21, 10, 0, 0, 0, time.UTC), Now: testNow()})
	require.NoError(t, err)
	assert.Empty(t, res.Hits, "To equal to the document time excludes it")
}

func TestSearch_ORFallbackRanksBelowAND(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	// "only" matches one word, many times, in a short body — it wins the OR
	// list on bm25; "both" matches both words once in a long body. Filler
	// documents keep "alpha" below half the corpus so its idf is positive.
	writeSearchDoc(t, d, "only", strings.Repeat("alpha ", 4), testNow())
	writeSearchDoc(t, d, "both", "alpha beta and a lot of other filler words", testNow())
	for _, id := range []string{"f1", "f2", "f3", "f4", "f5", "f6", "f7"} {
		writeSearchDoc(t, d, id, "gamma", testNow())
	}
	res, err := Search(ctx, d, Request{Queries: []string{"alpha beta"}, Now: testNow()})
	require.NoError(t, err)
	require.Equal(t, []string{"idea:both", "idea:only"}, hitRefs(res))
	// both: 1/51 (AND rank 1) + 0.5/52 (OR rank 2); only: 0.5/51 (OR rank 1).
	assert.InDelta(t, 1.0/51+0.5/52, res.Hits[0].score, 1e-9)
	assert.InDelta(t, 0.5/51, res.Hits[1].score, 1e-9)

	// A single-term query has no separate OR list (it would duplicate AND).
	res, err = Search(ctx, d, Request{Queries: []string{"beta"}, Now: testNow()})
	require.NoError(t, err)
	require.Equal(t, []string{"idea:both"}, hitRefs(res))
	assert.InDelta(t, 1.0/51, res.Hits[0].score, 1e-9)

	// Queries fuse: a document every query finds outranks one only one query finds.
	res, err = Search(ctx, d, Request{Queries: []string{"alpha*", "beta"}, Now: testNow()})
	require.NoError(t, err)
	require.NotEmpty(t, res.Hits)
	assert.Equal(t, "idea:both", res.Hits[0].Ref)
}

func TestSearch_RecencyFloor(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	// Identical text: bm25 ties, broken by chunk id, so the old document
	// (written first) is rank 1 before recency is applied.
	writeSearchDoc(t, d, "old", "квартальный отчёт по инфраструктуре", testNow().AddDate(-10, 0, 0))
	writeSearchDoc(t, d, "new", "квартальный отчёт по инфраструктуре", testNow())
	res, err := Search(ctx, d, Request{Queries: []string{"отчет"}, Now: testNow()})
	require.NoError(t, err)
	require.Len(t, res.Hits, 2)
	assert.Equal(t, []string{"idea:new", "idea:old"}, hitRefs(res))
	oldHit, newHit := res.Hits[1], res.Hits[0]
	assert.GreaterOrEqual(t, oldHit.score, 0.75*newHit.score, "the recency factor never drops below 0.75")
	assert.Less(t, oldHit.score, newHit.score)
	assert.InDelta(t, 0.75/51, oldHit.score, 1e-9)
	assert.InDelta(t, 1.0/52, newHit.score, 1e-9)
}

func TestRecencyFactor(t *testing.T) {
	now := testNow()
	year := 365.25 * 86400
	assert.Equal(t, 0.75, recencyFactor(0, now), "unknown time")
	assert.Equal(t, 1.0, recencyFactor(float64(now.Unix()), now))
	assert.Equal(t, 1.0, recencyFactor(float64(now.Add(time.Hour).Unix()), now), "future")
	assert.InDelta(t, 1/1.25, recencyFactor(float64(now.Unix())-0.5*year, now), 1e-9)
	assert.Equal(t, 0.75, recencyFactor(float64(now.Unix())-10*year, now))
}

// Review focus #5: an unparsable time is indexed with the recency floor.
func TestSearch_UnknownTimeHasFloor(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedAll(t, d)
	res, err := Search(ctx, d, Request{Queries: []string{"квартальное"}, Now: testNow()})
	require.NoError(t, err)
	require.Len(t, res.Hits, 1)
	assert.Equal(t, "calendar:e2", res.Hits[0].Ref)
	assert.Equal(t, "", res.Hits[0].When)
	assert.InDelta(t, 0.75/51, res.Hits[0].score, 1e-9)
}

func TestSearch_LimitAndSnippets(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	for i := range 30 {
		writeSearchDoc(t, d, string(rune('a'+i%26))+strings.Repeat("x", i/26), "common term", testNow())
	}
	res, err := Search(ctx, d, Request{Queries: []string{"common"}, Now: testNow()})
	require.NoError(t, err)
	assert.Len(t, res.Hits, DefaultLimit)
	res, err = Search(ctx, d, Request{Queries: []string{"common"}, Limit: 500, Now: testNow()})
	require.NoError(t, err)
	assert.Len(t, res.Hits, MaxLimit)
	res, err = Search(ctx, d, Request{Queries: []string{"common"}, Limit: 3, Now: testNow()})
	require.NoError(t, err)
	assert.Len(t, res.Hits, 3)

	// A multi-chunk document keeps at most two snippets...
	multi := db.OpenTestDB(t)
	filler := strings.Repeat(" filler", 250) // ~1750 runes: one section per chunk
	_, err = writeDoc(ctx, multi, &Doc{ID: "idea:m", Source: "idea", Title: "m", Time: testNow(),
		Anchor:   map[string]string{"idea_id": "m"},
		Sections: []Section{{Text: "needle one" + filler}, {Text: "needle two" + filler}, {Text: "needle three" + filler}}})
	require.NoError(t, err)
	res, err = Search(ctx, multi, Request{Queries: []string{"needle"}, Now: testNow()})
	require.NoError(t, err)
	require.Len(t, res.Hits, 1)
	require.Len(t, res.Hits[0].Snippets, 2)
	assert.NotEqual(t, res.Hits[0].Snippets[0], res.Hits[0].Snippets[1])

	// ...and identical snippets from two chunks collapse into one.
	dup := db.OpenTestDB(t)
	_, err = writeDoc(ctx, dup, &Doc{ID: "idea:d", Source: "idea", Title: "d", Time: testNow(),
		Anchor:   map[string]string{"idea_id": "d"},
		Sections: []Section{{Text: "needle same" + filler}, {Text: "needle same" + filler}}})
	require.NoError(t, err)
	res, err = Search(ctx, dup, Request{Queries: []string{"needle"}, Now: testNow()})
	require.NoError(t, err)
	require.Len(t, res.Hits, 1)
	assert.Len(t, res.Hits[0].Snippets, 1)
}

func TestSearch_Validation(t *testing.T) {
	d := db.OpenTestDB(t)
	for _, req := range []Request{
		{}, {Queries: []string{"a", "b", "c", "d", "e", "f"}}, {Queries: []string{"  "}},
		{Queries: []string{"a", ""}},
		{Queries: []string{"a"}, Sources: []string{"nope"}}, {Queries: []string{"a"}, Limit: -1},
		{Queries: []string{"a"}, From: testNow(), To: testNow().Add(-time.Hour)},
		{Queries: []string{"a"}, From: testNow(), To: testNow()},
	} {
		_, err := Search(context.Background(), d, req)
		var re *RequestError
		assert.ErrorAs(t, err, &re, "%+v", req)
	}
	res, err := Search(context.Background(), d, Request{Queries: []string{"!!!"}, Limit: 500})
	require.NoError(t, err)
	assert.Empty(t, res.Hits)
	assert.NotNil(t, res.Hits, "hits serialize as [] not null")
}

// Review focus #2 end to end: hostile queries against a populated index
// answer without an FTS error.
func TestSearch_HostileQueriesAgainstIndex(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedAll(t, d)
	res, err := Search(ctx, d, Request{Queries: []string{`"`, `(`, `NEAR`, `-foo`, `*`}, Now: testNow()})
	require.NoError(t, err)
	assert.Empty(t, res.Hits)
	res, err = Search(ctx, d, Request{Queries: []string{`PROJ-123`, `a:b`, `🙂`, `стейдж)`, `"релиз`}, Now: testNow()})
	require.NoError(t, err)
	assert.Contains(t, hitRefs(res), "jira:1:PROJ-123")
}

// Review focus #3: a half-built index still answers and says so.
func TestSearch_IndexNoteWhileSlackBackfills(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedAll(t, d)
	// A synced message at rowid 40000 puts sync far ahead of the index.
	exec(t, d, `INSERT INTO messages (rowid, channel_id, ts, user_id, text) VALUES (40000, '1:C1', '1700000000.000100', '1:U1', 'old')`)

	// Behind by more than one range (a real backfill): the note says so.
	exec(t, d, `UPDATE kb_sources SET cursor = '19999' WHERE source = 'slack'`)
	res, err := Search(ctx, d, Request{Queries: []string{"стейдж"}, Now: testNow()})
	require.NoError(t, err)
	assert.NotEmpty(t, res.Hits)
	assert.Equal(t, "slack 49% indexed", res.IndexNote)

	// Stale: last update over 24h before now.
	res, err = Search(ctx, d, Request{Queries: []string{"стейдж"}, Now: testNow().Add(25 * time.Hour)})
	require.NoError(t, err)
	assert.Equal(t, "slack 49% indexed; index last updated 2026-09-26T12:00:00Z", res.IndexNote)

	// Behind by exactly one range or less (ordinary sync lag between
	// cycles): no note, although `kb status` still shows the exact figure.
	exec(t, d, `UPDATE kb_sources SET cursor = '20000' WHERE source = 'slack'`)
	res, err = Search(ctx, d, Request{Queries: []string{"стейдж"}, Now: testNow()})
	require.NoError(t, err)
	assert.Equal(t, "", res.IndexNote)
	rows, err := Status(ctx, d)
	require.NoError(t, err)
	assert.InDelta(t, 0.5, rows[len(rows)-1].Progress, 1e-9, "status keeps the exact slack figure")

	// Fully built and fresh: no note.
	exec(t, d, `UPDATE kb_sources SET cursor = '40000' WHERE source = 'slack'`)
	res, err = Search(ctx, d, Request{Queries: []string{"стейдж"}, Now: testNow()})
	require.NoError(t, err)
	assert.Equal(t, "", res.IndexNote)

	empty, err := Search(ctx, db.OpenTestDB(t), Request{Queries: []string{"x"}, Now: testNow()})
	require.NoError(t, err)
	assert.Contains(t, empty.IndexNote, "knowledge index is empty")
}

func TestGetDocument(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedAll(t, d)
	ref := slackThreadRef("1:C1", "1758000000.000100")
	doc, err := GetDocument(ctx, d, ref, DocOptions{})
	require.NoError(t, err)
	assert.Equal(t, ref, doc.Ref)
	assert.Equal(t, "slack", doc.Source)
	assert.Equal(t, "#general — Договорились о релизе @bob", doc.Title)
	assert.Equal(t, "2025-09-16T05:21:40Z", doc.When)
	assert.Equal(t, "https://slack.test/1758000000.000100", doc.Link)
	assert.Equal(t, map[string]string{"channel_id": "1:C1", "thread_ts": "1758000000.000100"}, doc.Anchor)
	assert.Equal(t, "Anna: Договорились о релизе @bob\nbob: ok, пятница", doc.Text)
	assert.False(t, doc.Truncated)

	cut, err := GetDocument(ctx, d, ref, DocOptions{MaxChars: 10})
	require.NoError(t, err)
	assert.Equal(t, "Anna: Дого", cut.Text, "truncation counts runes")
	assert.True(t, cut.Truncated)

	exact, err := GetDocument(ctx, d, ref, DocOptions{MaxChars: utf8.RuneCountInString(doc.Text)})
	require.NoError(t, err)
	assert.False(t, exact.Truncated)
	assert.Equal(t, doc.Text, exact.Text)

	// Chunks are joined in idx order.
	multi := db.OpenTestDB(t)
	a, b := strings.Repeat("a", 1500), strings.Repeat("b", 1500)
	_, err = writeDoc(ctx, multi, &Doc{ID: "idea:m", Source: "idea", Title: "m",
		Anchor: map[string]string{"idea_id": "m"}, Sections: []Section{{Text: a}, {Text: b}}})
	require.NoError(t, err)
	got, err := GetDocument(ctx, multi, "idea:m", DocOptions{})
	require.NoError(t, err)
	assert.Equal(t, a+"\n"+b, got.Text)
	assert.Equal(t, "", got.When, "unknown time renders empty")
	assert.Equal(t, 2, got.ChunkCount)

	// from_chunk opens the document at a chunk (a hit's best-matching part).
	got, err = GetDocument(ctx, multi, "idea:m", DocOptions{FromChunk: 1})
	require.NoError(t, err)
	assert.Equal(t, b, got.Text)
	assert.Equal(t, 1, got.FromChunk)
	assert.False(t, got.Truncated)
	for _, bad := range []int{-1, 2} {
		_, err = GetDocument(ctx, multi, "idea:m", DocOptions{FromChunk: bad})
		var re *RequestError
		assert.ErrorAs(t, err, &re, "from_chunk %d", bad)
	}

	// Default cap is DefaultDocChars.
	long := db.OpenTestDB(t)
	var secs []Section
	for range 8 {
		secs = append(secs, Section{Text: strings.Repeat("я", 1900)})
	}
	_, err = writeDoc(ctx, long, &Doc{ID: "idea:l", Source: "idea", Title: "l", Sections: secs})
	require.NoError(t, err)
	got, err = GetDocument(ctx, long, "idea:l", DocOptions{})
	require.NoError(t, err)
	assert.Equal(t, DefaultDocChars, utf8.RuneCountInString(got.Text))
	assert.True(t, got.Truncated)

	// max_chars is capped at MaxDocChars.
	huge := db.OpenTestDB(t)
	secs = nil
	for range 30 {
		secs = append(secs, Section{Text: strings.Repeat("я", 1900)})
	}
	_, err = writeDoc(ctx, huge, &Doc{ID: "idea:h", Source: "idea", Title: "h", Sections: secs})
	require.NoError(t, err)
	got, err = GetDocument(ctx, huge, "idea:h", DocOptions{MaxChars: 1 << 30})
	require.NoError(t, err)
	assert.Equal(t, MaxDocChars, utf8.RuneCountInString(got.Text))
	assert.True(t, got.Truncated)

	_, err = GetDocument(ctx, d, "idea:nope", DocOptions{})
	assert.ErrorIs(t, err, ErrNotFound)
}

func TestStatus(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedAll(t, d)
	rows, err := Status(ctx, d)
	require.NoError(t, err)
	require.Len(t, rows, len(SourceNames()))
	byName := map[string]SourceStatus{}
	for i, r := range rows {
		assert.Equal(t, SourceNames()[i], r.Source, "one row per source, in source order")
		byName[r.Source] = r
		assert.Equal(t, 1.0, r.Progress, r.Source)
		assert.Equal(t, "2026-09-26T12:00:00Z", r.UpdatedAt, r.Source)
		assert.Equal(t, "2026-09-26T12:00:00Z", r.LastReconciledAt, r.Source)
	}
	slack := byName["slack"]
	assert.Equal(t, countDocs(t, d, "slack"), slack.Docs)
	assert.Equal(t, 2, slack.Docs)
	assert.Equal(t, 2, slack.Chunks)
	assert.Equal(t, "6", slack.Cursor)
	wantDocs := map[string]int{
		"calendar": 2, "idea": 1, "digest": 2, "stream_digest": 2, "recap": 2,
		"transcript": 1, "jira": 1, "imap": 1, "gmail": 2, "slack": 2,
	}
	for name, n := range wantDocs {
		assert.Equal(t, n, byName[name].Docs, name)
		assert.Equal(t, n, byName[name].Chunks, name+": every fixture document is one chunk")
	}

	exec(t, d, `UPDATE kb_sources SET cursor = '3' WHERE source = 'slack'`)
	rows, err = Status(ctx, d)
	require.NoError(t, err)
	for _, r := range rows {
		if r.Source == "slack" {
			assert.InDelta(t, 0.5, r.Progress, 1e-9)
		}
	}

	// A never-run database still lists every source.
	fresh, err := Status(ctx, db.OpenTestDB(t))
	require.NoError(t, err)
	require.Len(t, fresh, len(SourceNames()))
	for _, r := range fresh {
		assert.Equal(t, 0, r.Docs)
		assert.Equal(t, "", r.Cursor)
	}

	raw, err := json.Marshal(rows[0])
	require.NoError(t, err)
	for _, key := range []string{`"source"`, `"docs"`, `"chunks"`, `"cursor"`, `"progress"`, `"last_reconciled_at"`, `"updated_at"`} {
		assert.Contains(t, string(raw), key)
	}
}

func TestHit_ScoreIsNotSerialized(t *testing.T) {
	raw, err := json.Marshal(Hit{Ref: "idea:1", score: 3.5})
	require.NoError(t, err)
	assert.NotContains(t, string(raw), "score")
	assert.NotContains(t, string(raw), "3.5")
}

// A hit names its best-matching chunk and that chunk's anchor, so the model
// can open the document at the matched part and cite the exact message.
func TestSearch_HitCarriesBestChunk(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	_, err := writeDoc(ctx, d, &Doc{
		ID: "slack:thread:1:C1:1.1", Source: "slack", Title: "#general — long thread", Time: testNow(),
		Anchor: map[string]string{"channel_id": "1:C1", "thread_ts": "1.1"},
		Sections: []Section{
			{Text: strings.Repeat("filler ", 285), Anchor: "1.1"},
			{Text: "the needle is here", Anchor: "1.7"},
		},
	})
	require.NoError(t, err)
	res, err := Search(ctx, d, Request{Queries: []string{"needle"}, Now: testNow()})
	require.NoError(t, err)
	require.Len(t, res.Hits, 1)
	assert.Equal(t, 1, res.Hits[0].Chunk)
	assert.Equal(t, "1.7", res.Hits[0].ChunkAnchor)
	doc, err := GetDocument(ctx, d, res.Hits[0].Ref, DocOptions{FromChunk: res.Hits[0].Chunk})
	require.NoError(t, err)
	assert.Equal(t, "the needle is here", doc.Text)

	raw, err := json.Marshal(res.Hits[0])
	require.NoError(t, err)
	assert.Contains(t, string(raw), `"chunk":1`)
	assert.Contains(t, string(raw), `"chunk_anchor":"1.7"`)
}
