package kb

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedSlack inserts channels/users/messages with raw SQL (explicit columns only).
func seedSlack(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `INSERT INTO channels (id, name, type) VALUES ('1:C1','general','public'), ('1:D1','','dm')`)
	exec(t, d, `UPDATE channels SET dm_user_id='1:U2' WHERE id='1:D1'`)
	exec(t, d, `INSERT INTO users (id, name, display_name) VALUES ('1:U1','anna','Anna'), ('1:U2','bob','')`)
	// thread root + reply + a join message (skipped) + deleted reply (skipped)
	msg(t, d, "1:C1", "1758000000.000100", "1:U1", "Договорились о релизе <@U2>", "1758000000.000100", "")
	msg(t, d, "1:C1", "1758000100.000200", "1:U2", "ok, пятница", "1758000000.000100", "")
	msg(t, d, "1:C1", "1758000200.000300", "1:U2", "joined", "", "channel_join")
	exec(t, d, `INSERT INTO messages (channel_id, ts, user_id, text, thread_ts, is_deleted) VALUES ('1:C1','1758000300.000400','1:U2','gone','1758000000.000100',1)`)
	// top-level messages on 2025-09-16 UTC in a DM
	msg(t, d, "1:D1", "1758000400.000500", "1:U2", "привет", "", "")
	msg(t, d, "1:D1", "1758000500.000600", "1:U1", "hello", "", "")
}

func exec(t *testing.T, d *db.DB, q string, args ...any) {
	t.Helper()
	_, err := d.Exec(q, args...)
	require.NoError(t, err, q)
}

func msg(t *testing.T, d *db.DB, ch, ts, user, text, threadTS, subtype string) {
	t.Helper()
	var th any
	if threadTS != "" {
		th = threadTS
	}
	exec(t, d, `INSERT INTO messages (channel_id, ts, user_id, text, thread_ts, subtype, permalink) VALUES (?,?,?,?,?,?,?)`,
		ch, ts, user, text, th, subtype, "https://slack.test/"+ts)
}

func TestSlack_BuildThread(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	doc, err := newSlackSource().Build(ctx, d, slackThreadRef("1:C1", "1758000000.000100"))
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "slack", doc.Source)
	assert.Equal(t, "#general — Договорились о релизе @bob", doc.Title)
	require.Len(t, doc.Sections, 2, "join subtype and deleted reply are skipped")
	assert.Equal(t, "Anna: Договорились о релизе @bob", doc.Sections[0].Text)
	assert.Equal(t, "1758000000.000100", doc.Sections[0].Anchor)
	assert.Equal(t, "bob: ok, пятница", doc.Sections[1].Text)
	assert.Equal(t, "https://slack.test/1758000000.000100", doc.Link)
	assert.Equal(t, map[string]string{"channel_id": "1:C1", "thread_ts": "1758000000.000100"}, doc.Anchor)
	assert.Equal(t, int64(1758000100), doc.Time.Unix())
	assert.Contains(t, doc.Meta, "Anna")
}

func TestSlack_BuildDay_DMTitle(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	day := time.Unix(1758000400, 0).UTC().Format("2006-01-02")
	doc, err := newSlackSource().Build(ctx, d, slackDayRef("1:D1", day))
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "DM with bob · "+day, doc.Title)
	require.Len(t, doc.Sections, 2)
	assert.Equal(t, map[string]string{"channel_id": "1:D1", "date": day}, doc.Anchor)
}

// errChannelQueryer wraps *db.DB and forces a real (non-ErrNoRows) error on
// the channels lookup only, so a test can prove channelTitle propagates a
// genuine DB error instead of swallowing it as "unknown channel" (review
// finding: any Scan error, including an outage, used to degrade to an
// id-based title that the content-hash gate would then persist).
type errChannelQueryer struct {
	*db.DB
}

func (e errChannelQueryer) QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row {
	if strings.Contains(query, "FROM channels") {
		return e.DB.QueryRowContext(ctx, `SELECT 1 FROM no_such_table_kb_test`)
	}
	return e.DB.QueryRowContext(ctx, query, args...)
}

func TestSlack_BuildChannelLookupErrorPropagates(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	doc, err := newSlackSource().Build(ctx, errChannelQueryer{d}, slackThreadRef("1:C1", "1758000000.000100"))
	require.Error(t, err)
	assert.Nil(t, doc)
}

func TestSlack_BuildUnknownChannelFallsBackToID(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	exec(t, d, `INSERT INTO users (id, name) VALUES ('1:U1','anna')`)
	// a thread whose channel has no row in `channels` at all (never synced,
	// or a stale reference) must still title as "#<channel_id>", not error.
	msg(t, d, "1:C3", "1758000700.000100", "1:U1", "no channel row for this one", "1758000700.000100", "")
	doc, err := newSlackSource().Build(ctx, d, slackThreadRef("1:C3", "1758000700.000100"))
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "#1:C3 — no channel row for this one", doc.Title)
}

func TestSlack_BuildMissingReturnsNil(t *testing.T) {
	d := db.OpenTestDB(t)
	doc, err := newSlackSource().Build(context.Background(), d, slackThreadRef("1:C9", "1.1"))
	require.NoError(t, err)
	assert.Nil(t, doc)
	doc, err = newSlackSource().Build(context.Background(), d, "slack:bogus")
	require.NoError(t, err)
	assert.Nil(t, doc)
}

func TestSlack_ChangedRangesAndTail(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	s := newSlackSource()
	now := time.Unix(1758000600, 0) // all rows within the 48h tail
	keys, next, done, err := s.Changed(ctx, d, "", now)
	require.NoError(t, err)
	assert.True(t, done)
	assert.Equal(t, "6", next)
	day := time.Unix(1758000400, 0).UTC().Format("2006-01-02")
	assert.ElementsMatch(t, []string{
		slackThreadRef("1:C1", "1758000000.000100"),
		slackDayRef("1:C1", day), // the channel_join row is top-level
		slackDayRef("1:D1", day),
	}, keys)
	// caught up + tail: still returns tail keys, cursor unchanged
	keys, next, done, err = s.Changed(ctx, d, "6", now)
	require.NoError(t, err)
	assert.True(t, done)
	assert.Equal(t, "6", next)
	assert.NotEmpty(t, keys)
	// far future: tail empty, nothing new
	keys, _, _, err = s.Changed(ctx, d, "6", now.Add(72*time.Hour))
	require.NoError(t, err)
	assert.Empty(t, keys)
}

func TestSlack_KeysAndProgress(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	s := newSlackSource()
	keys, err := s.Keys(ctx, d)
	require.NoError(t, err)
	assert.Contains(t, keys, slackThreadRef("1:C1", "1758000000.000100"))
	p, err := s.Progress(ctx, d, "3")
	require.NoError(t, err)
	assert.InDelta(t, 0.5, p, 0.001)
	empty := db.OpenTestDB(t)
	p, err = s.Progress(ctx, empty, "")
	require.NoError(t, err)
	assert.Equal(t, 1.0, p)
}

// Review focus #1: a huge channel-day renders every message into many
// chunks, resolving the author's name once from the per-instance cache.
func TestSlack_HugeDayRendersAllMessagesIntoManyChunks(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	exec(t, d, `INSERT INTO channels (id, name, type) VALUES ('1:C2','alerts','public')`)
	exec(t, d, `INSERT INTO users (id, name) VALUES ('1:U1','bot')`)
	tx, err := d.Begin()
	require.NoError(t, err)
	for i := 0; i < 3000; i++ {
		_, err := tx.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C2', ?, '1:U1', ?)`,
			fmt.Sprintf("1758000%03d.%06d", i%1000, i), strings.Repeat("alert payload ", 5))
		require.NoError(t, err)
	}
	require.NoError(t, tx.Commit())
	day := time.Unix(1758000000, 0).UTC().Format("2006-01-02")
	s := newSlackSource()
	doc, err := s.Build(ctx, d, slackDayRef("1:C2", day))
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Len(t, doc.Sections, 3000)
	assert.Greater(t, len(BuildChunks(doc.Sections)), 50)
	assert.Equal(t, map[string]string{"1:U1": "bot"}, s.names, "the author is resolved once and cached")
}

// Thread promotion: a reply's row also marks its root's channel-day, where
// the root sat as a top-level message until it gained the reply.
func TestSlack_ChangedMarksPromotedRootDay(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	now := time.Unix(1758000600, 0).Add(72 * time.Hour) // outside the tail: range keys only
	_, next, _, err := newSlackSource().Changed(ctx, d, "", now)
	require.NoError(t, err)
	exec(t, d, `UPDATE messages SET thread_ts = ts WHERE channel_id = '1:D1' AND ts = '1758000400.000500'`)
	msg(t, d, "1:D1", "1758000450.000550", "1:U2", "reply", "1758000400.000500", "")
	keys, _, done, err := newSlackSource().Changed(ctx, d, next, now)
	require.NoError(t, err)
	assert.True(t, done)
	day := time.Unix(1758000400, 0).UTC().Format("2006-01-02")
	assert.ElementsMatch(t, []string{slackThreadRef("1:D1", "1758000400.000500"), slackDayRef("1:D1", day)}, keys)

	dayDoc, err := newSlackSource().Build(ctx, d, slackDayRef("1:D1", day))
	require.NoError(t, err)
	require.NotNil(t, dayDoc)
	require.Len(t, dayDoc.Sections, 1, "the promoted root left its day doc")
	assert.Equal(t, "Anna: hello", dayDoc.Sections[0].Text)
}

// A cursor past every rowid (messages wiped or restored from an older copy)
// restarts the scan from the beginning instead of staying stuck.
func TestSlack_ChangedRestartsWhenCursorPastMaxRowid(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	now := time.Unix(1758000600, 0).Add(72 * time.Hour)
	keys, next, done, err := newSlackSource().Changed(ctx, d, "100000", now)
	require.NoError(t, err)
	assert.True(t, done)
	assert.Equal(t, "6", next)
	assert.Contains(t, keys, slackThreadRef("1:C1", "1758000000.000100"))
	assert.Contains(t, keys, slackDayRef("1:D1", time.Unix(1758000400, 0).UTC().Format("2006-01-02")))
}

// A thread whose root has no text (a file share) is titled by its first
// message with text; a thread with no text at all by its author.
func TestSlack_ThreadTitleSkipsEmptyRoot(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	msg(t, d, "1:C1", "1758001000.000100", "1:U1", "", "1758001000.000100", "")
	msg(t, d, "1:C1", "1758001100.000200", "1:U2", "\nсмотри файл выше", "1758001000.000100", "")
	doc, err := newSlackSource().Build(ctx, d, slackThreadRef("1:C1", "1758001000.000100"))
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "#general — смотри файл выше", doc.Title)

	msg(t, d, "1:C1", "1758002000.000100", "1:U1", "  ", "1758002000.000100", "")
	doc, err = newSlackSource().Build(ctx, d, slackThreadRef("1:C1", "1758002000.000100"))
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "#general — thread by Anna", doc.Title)
}

// explainPlan runs `EXPLAIN QUERY PLAN` for query+args and returns each row's
// detail column (always the last column in both the legacy 3-column and the
// current 4-column EXPLAIN QUERY PLAN output shapes), lowercased so callers
// can do a case-insensitive Contains.
func explainPlan(t *testing.T, d *db.DB, query string, args ...any) []string {
	t.Helper()
	rows, err := d.Query("EXPLAIN QUERY PLAN "+query, args...)
	require.NoError(t, err)
	defer rows.Close()
	cols, err := rows.Columns()
	require.NoError(t, err)
	var details []string
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		require.NoError(t, rows.Scan(ptrs...))
		details = append(details, strings.ToLower(fmt.Sprint(vals[len(vals)-1])))
	}
	require.NoError(t, rows.Err())
	return details
}

// Performance guard (real-DB finding, 740k messages): slackThreadQuery's
// ORDER BY +ts_unix must keep SQLite off idx_messages_channel_ts_unix for the
// sort, so the channel_id/thread_ts equality search still picks
// idx_messages_thread — the unary "+" is the whole fix, so this test would
// have caught the regression it fixes (plan: SEARCH ... USING INDEX
// idx_messages_thread (channel_id=? AND thread_ts=?)).
func TestSlack_ThreadQueryUsesThreadIndex(t *testing.T) {
	d := db.OpenTestDB(t)
	plan := strings.Join(explainPlan(t, d, slackThreadQuery, "1:C1", "0"), " | ")
	assert.Contains(t, plan, "idx_messages_thread")
	assert.NotContains(t, plan, "idx_messages_channel_ts_unix")
}

// slackDayQuery already used idx_messages_channel_ts_unix's ts_unix range
// before this fix; this pins that it still does (plan: SEARCH ... USING
// INDEX idx_messages_channel_ts_unix (channel_id=? AND ts_unix>? AND
// ts_unix<?)).
func TestSlack_DayQueryUsesChannelTsUnixIndex(t *testing.T) {
	d := db.OpenTestDB(t)
	plan := strings.Join(explainPlan(t, d, slackDayQuery, "1:C1", 0.0, 86400.0), " | ")
	assert.Contains(t, plan, "idx_messages_channel_ts_unix")
	assert.Contains(t, plan, "ts_unix>", "the day window must be a range search, not a full scan")
}

// Changed's two collectKeys queries: the rowid-range batch must be a rowid
// SEARCH (plan: SEARCH ... USING INTEGER PRIMARY KEY (rowid>? AND
// rowid<?)), and the 48h tail rescan must use idx_messages_ts_unix (plan:
// SEARCH ... USING INDEX idx_messages_ts_unix (ts_unix>?)) — neither should
// ever degrade into a full table scan on a 740k-row messages table.
func TestSlack_ChangedQueriesUseIndexes(t *testing.T) {
	d := db.OpenTestDB(t)
	rangePlan := strings.Join(explainPlan(t, d,
		`SELECT channel_id, COALESCE(thread_ts, ''), ts_unix FROM messages WHERE rowid > ? AND rowid <= ?`,
		int64(0), int64(100)), " | ")
	assert.Contains(t, rangePlan, "rowid")
	assert.Contains(t, rangePlan, "search", "must be a SEARCH (indexed range), not a SCAN")

	tailPlan := strings.Join(explainPlan(t, d,
		`SELECT channel_id, COALESCE(thread_ts, ''), ts_unix FROM messages WHERE ts_unix >= ?`, 0.0), " | ")
	assert.Contains(t, tailPlan, "idx_messages_ts_unix")
}

// Keys()'s two DISTINCT reconcile queries have no channel_id predicate to
// narrow on, so a full scan of messages is expected once a day — this test
// only records what SQLite actually does, per the coordinator's "just
// report" (no assertion pins these, since a full scan here is not a bug):
// observed on a small seeded DB, thread keys plan to
// "SCAN messages USING INDEX idx_messages_thread" (a full index scan, not a
// SEARCH) and the day-key plan to "SCAN messages USING INDEX
// idx_messages_channel_ts_unix" + "USE TEMP B-TREE FOR DISTINCT".
func TestSlack_KeysQueriesPlan_Reported(t *testing.T) {
	d := db.OpenTestDB(t)
	threadPlan := explainPlan(t, d, `SELECT DISTINCT channel_id, thread_ts FROM messages
		WHERE thread_ts IS NOT NULL AND thread_ts != '' AND is_deleted = 0`)
	dayPlan := explainPlan(t, d, `SELECT DISTINCT channel_id, date(ts_unix, 'unixepoch') FROM messages
		WHERE (thread_ts IS NULL OR thread_ts = '') AND is_deleted = 0`)
	t.Logf("Keys() thread-distinct plan: %v", threadPlan)
	t.Logf("Keys() day-distinct plan: %v", dayPlan)
}
