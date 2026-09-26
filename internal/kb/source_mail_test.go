package kb

import (
	"context"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func seedGmail(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `INSERT INTO google_accounts (id, email) VALUES (1, 'me@x.io')`)
	exec(t, d, `INSERT INTO gmail_messages (account_id, id, thread_id, from_email, from_name, to_json, subject, body_text, internal_date, permalink, updated_at)
		VALUES (1,'m1','t1','a@x.io','Anna','["me@x.io"]','Бюджет Q4','Предлагаю урезать','2026-09-01T10:00:00Z','https://mail/m1','2026-09-01T10:00:05Z'),
		       (1,'m2','t1','me@x.io','Me','["a@x.io"]','Re: Бюджет Q4','','2026-09-02T10:00:00Z','https://mail/m2','2026-09-02T10:00:05Z'),
		       (1,'m3','','b@x.io','Bob','[]','Solo','solo body','2026-09-03T10:00:00Z','','2026-09-03T10:00:05Z')`)
	exec(t, d, `UPDATE gmail_messages SET snippet='snippet two' WHERE id='m2'`)
}

func TestGmail_BuildThread(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedGmail(t, d)
	doc, err := gmailSource{}.Build(ctx, d, "gmail:1:t1")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "Бюджет Q4", doc.Title)
	require.Len(t, doc.Sections, 2)
	assert.Contains(t, doc.Sections[0].Text, "From Anna a@x.io")
	assert.Contains(t, doc.Sections[0].Text, "Предлагаю урезать")
	assert.Contains(t, doc.Sections[1].Text, "snippet two", "empty body falls back to snippet")
	assert.Equal(t, "https://mail/m2", doc.Link)
	assert.Equal(t, map[string]string{"account_id": "1", "thread_id": "t1"}, doc.Anchor)
	assert.Contains(t, doc.Meta, "a@x.io")
}

func TestGmail_ThreadlessMessageAndChanged(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedGmail(t, d)
	doc, err := gmailSource{}.Build(ctx, d, "gmail:1:m:m3")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "Solo", doc.Title)
	keys, next, done, err := gmailSource{}.Changed(ctx, d, "2026-09-01T12:00:00Z", testNow())
	require.NoError(t, err)
	assert.True(t, done)
	assert.Equal(t, []string{"gmail:1:m:m3", "gmail:1:t1"}, keys)
	assert.Equal(t, "2026-09-03T10:00:05Z", next)
	missing, err := gmailSource{}.Build(ctx, d, "gmail:1:nope")
	require.NoError(t, err)
	assert.Nil(t, missing)
}

// Guard: gmailThreadQuery and gmailMessageQuery each hit a proper index
// instead of scanning the account's whole mailbox — see the comment above
// their declaration in source_mail.go.
func TestGmail_QueryPlan(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedGmail(t, d)
	assert.Contains(t, explainPlanDetail(ctx, t, d, gmailThreadQuery, "1", "t1"), "idx_gmail_messages_thread",
		"thread lookup must use the thread_id index")
	assert.Contains(t, explainPlanDetail(ctx, t, d, gmailMessageQuery, "1", "m3"), "sqlite_autoindex_gmail_messages_1",
		"threadless message lookup must use the (account_id, id) primary key")
}

// explainPlanDetail runs EXPLAIN QUERY PLAN over query and returns every
// plan row's detail text joined, so a caller can assert on the index used.
func explainPlanDetail(ctx context.Context, t *testing.T, d *db.DB, query string, args ...any) string {
	t.Helper()
	rows, err := d.QueryContext(ctx, "EXPLAIN QUERY PLAN "+query, args...)
	require.NoError(t, err)
	defer rows.Close()
	var lines []string
	for rows.Next() {
		var id, parent, notused int
		var detail string
		require.NoError(t, rows.Scan(&id, &parent, &notused, &detail))
		lines = append(lines, detail)
	}
	require.NoError(t, rows.Err())
	return strings.Join(lines, "\n")
}

func seedIMAP(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `INSERT INTO email_accounts (id, provider, email_address) VALUES (1, 'imap', 'me@corp.io')`)
	exec(t, d, `INSERT INTO imap_messages (account_id, uid, uidvalidity, from_email, from_name, subject, body_text, internal_date, permalink, updated_at)
		VALUES (1, 42, 7, 'c@corp.io', 'Carl', 'Инвойс', 'Оплатите до пятницы', '2026-09-05T09:00:00Z', 'https://mail/imap/42', '2026-09-05T09:00:05Z')`)
}

func TestIMAP_BuildAndChanged(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedIMAP(t, d)
	doc, err := imapSource{}.Build(ctx, d, "imap:1:7:42")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "Инвойс", doc.Title)
	require.Len(t, doc.Sections, 1)
	assert.Contains(t, doc.Sections[0].Text, "From Carl c@corp.io")
	assert.Contains(t, doc.Sections[0].Text, "Оплатите до пятницы")
	assert.Equal(t, "https://mail/imap/42", doc.Link)
	assert.Equal(t, map[string]string{"account_id": "1", "uidvalidity": "7", "uid": "42"}, doc.Anchor)

	keys, next, done, err := imapSource{}.Changed(ctx, d, "2026-09-05T00:00:00Z", testNow())
	require.NoError(t, err)
	assert.True(t, done)
	assert.Equal(t, []string{"imap:1:7:42"}, keys)
	assert.Equal(t, "2026-09-05T09:00:05Z", next)

	missing, err := imapSource{}.Build(ctx, d, "imap:1:7:999")
	require.NoError(t, err)
	assert.Nil(t, missing)
}
