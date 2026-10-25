package db

import (
	"context"
	"strconv"
	"testing"
	"time"
)

// mediaFixtures inserts one parent of every kind: Slack message 1:C1/1.0,
// ext document (5, "p1"), Gmail message (1, "g1"), IMAP message (1, 7, 42),
// chat attachment 1 (an image in conversation 1) and target image 1.
func mediaFixtures(t *testing.T, d *DB) {
	t.Helper()
	mustExecAll(t, d,
		`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1.0', '1:U1', 'hello')`,
		`INSERT INTO jira_accounts (id, cloud_id) VALUES (1, 'c1')`,
		`INSERT INTO ext_sources (id, provider, jira_account_id, container_key) VALUES (5, 'confluence', 1, 'ENG')`,
		`INSERT INTO ext_documents (source_id, ext_id, kind) VALUES (5, 'p1', 'page')`,
		`INSERT INTO google_accounts (id, email) VALUES (1, 'a@example.com')`,
		`INSERT INTO gmail_messages (account_id, id) VALUES (1, 'g1')`,
		`INSERT INTO email_accounts (id, provider, email_address, host) VALUES (1, 'imap', 'login', 'imap.example.com')`,
		`INSERT INTO imap_messages (account_id, uidvalidity, uid) VALUES (1, 7, 42)`,
		`INSERT INTO chat_conversations (id, created_at, updated_at) VALUES (1, 0, 0)`,
		`INSERT INTO chat_attachments (id, conversation_id, name, mime, size, path, sha256, created_at)
			VALUES (1, 1, 'shot.png', 'image/png', 10, '/tmp/a/shot.png', 'ab', 0)`,
		`INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')`,
		`INSERT INTO targets (id, text, period_start, period_end, project_id) VALUES (1, 't', '2026-01-01', '2026-12-31', 1)`,
		`INSERT INTO project_target_images (id, project_id, target_id, file_name, mime, size, sha256, path)
			VALUES (1, 1, 1, 'board.png', 'image/png', 10, 'cd', '/tmp/acme/board.png')`,
	)
}

// insertMediaRow inserts one link item on the given parent columns.
func insertMediaRow(t *testing.T, d *DB, parentKind, key, cols, vals string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO media_items (kind, parent_kind, parent_key, locator, scope, content_at, `+cols+`)
		VALUES ('link', ?, ?, 'https://example.com/x', 's', '2099-01-01T00:00:00Z', `+vals+`)`, parentKind, key)
	if err != nil {
		t.Fatalf("insert %s item: %v", parentKind, err)
	}
	id, _ := res.LastInsertId()
	return id
}

func TestMigration00156_MediaItems(t *testing.T) {
	d := openTestDB(t)
	start, err := d.MediaStartAt()
	if err != nil {
		t.Fatalf("MediaStartAt: %v", err)
	}
	if start.IsZero() || time.Since(start) > time.Hour {
		t.Fatalf("start_at %v is not the migration time", start)
	}
	mediaFixtures(t, d)

	// the owner-upload triggers recorded one pending item each
	if n := count(t, d, `SELECT COUNT(*) FROM media_items WHERE parent_kind = 'chat' AND chat_attachment_id = 1
			AND status = 'pending' AND kind = 'image' AND scope = 'owner' AND from_owner = 1
			AND locator = '/tmp/a/shot.png' AND parent_key = 'chat:1'`); n != 1 {
		t.Fatalf("chat image items = %d, want 1", n)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM media_items WHERE parent_kind = 'target' AND target_image_id = 1
			AND status = 'pending' AND scope = 'owner' AND from_owner = 1 AND parent_key = 'target:1'
			AND locator = '/tmp/acme/board.png'`); n != 1 {
		t.Fatalf("target image items = %d, want 1", n)
	}
	mustExecAll(t, d,
		`INSERT INTO chat_attachments (id, conversation_id, name, mime, size, path, sha256, created_at)
			VALUES (2, 1, 'notes.txt', 'text/plain', 10, '/tmp/a/notes.txt', 'ef', 0)`,
		`INSERT INTO chat_projects (id, name, created_at, updated_at) VALUES (1, 'p', 0, 0)`,
		`INSERT INTO chat_attachments (id, project_id, name, mime, size, path, sha256, created_at)
			VALUES (3, 1, 'p.png', 'image/png', 10, '/tmp/a/p.png', 'gh', 0)`,
	)
	if n := count(t, d, `SELECT COUNT(*) FROM media_items WHERE chat_attachment_id IN (2, 3)`); n != 0 {
		t.Fatalf("text or project-level attachments created %d items", n)
	}

	// two parents set fails the CHECK
	if _, err := d.Exec(`INSERT INTO media_items (kind, parent_kind, parent_key, locator, scope, content_at,
			slack_channel_id, slack_ts, gmail_account_id, gmail_message_id)
		VALUES ('link', 'slack', 'slack:1:C1:1.0', 'u', 's', 'x', '1:C1', '1.0', 1, 'g1')`); err == nil {
		t.Fatal("an item with two parents was accepted")
	}
	// a parent kind without its columns fails too
	if _, err := d.Exec(`INSERT INTO media_items (kind, parent_kind, parent_key, locator, scope, content_at)
		VALUES ('link', 'slack', 'slack:x', 'u', 's', 'x')`); err == nil {
		t.Fatal("a slack item without its message columns was accepted")
	}

	slackID := insertMediaRow(t, d, "slack", "slack:1:C1:1.0", "slack_channel_id, slack_ts", "'1:C1', '1.0'")
	// an upsert of the message keeps its item
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.UpsertMessageBatch(tx, []Message{{ChannelID: "1:C1", TS: "1.0", UserID: "1:U1", Text: "edited"}}); err != nil {
		_ = tx.Rollback()
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM media_items WHERE id = ?`, slackID); n != 1 {
		t.Fatal("upserting the message removed its item")
	}

	extID := insertMediaRow(t, d, "confluence", "ext:5:p1", "ext_source_id, ext_id", "5, 'p1'")
	gmailID := insertMediaRow(t, d, "gmail", "gmail:1:g1", "gmail_account_id, gmail_message_id", "1, 'g1'")
	imapID := insertMediaRow(t, d, "imap", "imap:1:7:42", "imap_account_id, imap_uidvalidity, imap_uid", "1, 7, 42")

	cases := []struct {
		name, del, gone string
		id              int64
	}{
		{"messages", `DELETE FROM messages WHERE channel_id = '1:C1' AND ts = '1.0'`, "", slackID},
		{"ext_documents", `DELETE FROM ext_documents WHERE source_id = 5 AND ext_id = 'p1'`, "", extID},
		{"gmail_messages", `DELETE FROM gmail_messages WHERE account_id = 1 AND id = 'g1'`, "", gmailID},
		{"imap_messages", `DELETE FROM imap_messages WHERE account_id = 1 AND uid = 42`, "", imapID},
		{"chat_attachments", `DELETE FROM chat_attachments WHERE id = 1`, "chat_attachment_id = 1", 0},
		{"project_target_images", `DELETE FROM project_target_images WHERE id = 1`, "target_image_id = 1", 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			q, arg := `SELECT COUNT(*) FROM media_items WHERE id = ?`, any(c.id)
			if c.gone != "" {
				q, arg = `SELECT COUNT(*) FROM media_items WHERE `+c.gone+` OR ? = 0`, any(1)
			}
			if n := count(t, d, q, arg); n != 1 {
				t.Fatalf("before delete: %d items, want 1", n)
			}
			mustExecAll(t, d, c.del)
			if n := count(t, d, q, arg); n != 0 {
				t.Fatalf("deleting the %s parent left %d items", c.name, n)
			}
		})
	}
}

func TestMediaKBDirtyTriggers(t *testing.T) {
	d := openTestDB(t)
	mediaFixtures(t, d)
	key := "slack|slack:thread:1:C1:1.0"
	id := insertMediaRow(t, d, "slack", "slack:1:C1:1.0", "slack_channel_id, slack_ts, kb_source, kb_ref",
		"'1:C1', '1.0', 'slack', 'slack:thread:1:C1:1.0'")
	if got := kbDirtyKeys(t, d); len(got) != 0 {
		t.Fatalf("a pending insert marked kb_dirty: %v", got)
	}
	mustExecAll(t, d, `UPDATE media_items SET status = 'ok', body = 'b1' WHERE id = `+itoa(id))
	if g, ok := kbDirtyKeys(t, d)[key]; !ok || g != 0 {
		t.Fatalf("ok update: kb_dirty = %v", kbDirtyKeys(t, d))
	}
	mustExecAll(t, d, `UPDATE media_items SET body = 'b2' WHERE id = `+itoa(id))
	if g := kbDirtyKeys(t, d)[key]; g != 1 {
		t.Fatalf("second update: gen = %d, want 1", g)
	}
	mustExecAll(t, d, `DELETE FROM media_items WHERE id = `+itoa(id))
	if g := kbDirtyKeys(t, d)[key]; g != 2 {
		t.Fatalf("deleting an ok item: gen = %d, want 2", g)
	}

	mustExecAll(t, d, `DELETE FROM kb_dirty`)
	pending := insertMediaRow(t, d, "slack", "slack:1:C1:1.0", "slack_channel_id, slack_ts, kb_source, kb_ref",
		"'1:C1', '1.0', 'slack', 'slack:thread:1:C1:1.0'")
	mustExecAll(t, d, `DELETE FROM media_items WHERE id = `+itoa(pending))
	noRef := insertMediaRow(t, d, "slack", "slack:1:C1:1.0", "slack_channel_id, slack_ts", "'1:C1', '1.0'")
	mustExecAll(t, d,
		`UPDATE media_items SET status = 'ok', body = 'x' WHERE id = `+itoa(noRef),
		`DELETE FROM media_items WHERE id = `+itoa(noRef))
	if got := kbDirtyKeys(t, d); len(got) != 0 {
		t.Fatalf("a pending delete or an item without kb_ref marked: %v", got)
	}
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func slackParent(at time.Time) MediaParent {
	return MediaParent{Kind: "slack", SlackChannelID: "1:C1", SlackTS: "1.0", ContentAt: at}
}

func TestRecordMedia(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	mediaFixtures(t, d)
	start, err := d.MediaStartAt()
	if err != nil {
		t.Fatal(err)
	}

	old := slackParent(start.Add(-time.Minute))
	n, err := RecordMedia(ctx, d, old, []MediaFound{{Kind: "link", Locator: "https://example.com/a"}})
	if err != nil || n != 0 {
		t.Fatalf("old content: n=%d err=%v, want 0, nil", n, err)
	}
	if c := count(t, d, `SELECT COUNT(*) FROM media_items WHERE parent_kind = 'slack'`); c != 0 {
		t.Fatalf("old content recorded %d rows", c)
	}

	p := slackParent(start.Add(time.Minute))
	p.FromOwner = true
	found := []MediaFound{
		{Kind: "link", Locator: "https://example.com/a", ContentKey: "url:example.com/a"},
		{Kind: "link", Locator: "https://example.com/b"},
		{Kind: "image", Locator: "F1", Name: "x.png", MediaType: "image/png", Size: 4096},
		{Kind: "image", Locator: "F2", Status: "skipped_type"},
	}
	if n, err := RecordMedia(ctx, d, p, found); err != nil || n != 4 {
		t.Fatalf("first record: n=%d err=%v", n, err)
	}
	if c := count(t, d, `SELECT COUNT(*) FROM media_items WHERE parent_key = 'slack:1:C1:1.0'
			AND scope = 'slack:1' AND from_owner = 1 AND slack_channel_id = '1:C1' AND slack_ts = '1.0'`); c != 4 {
		t.Fatalf("scope/from_owner/parent columns: %d rows match, want 4", c)
	}
	if c := count(t, d, `SELECT COUNT(*) FROM media_items WHERE locator = 'F2' AND status = 'skipped_type'`); c != 1 {
		t.Fatal("skipped_type row not terminal")
	}
	if _, err := RecordMedia(ctx, d, p, []MediaFound{{Kind: "link", Locator: "u", Status: "ok"}}); err == nil {
		t.Fatal("a found status other than skipped_type was accepted")
	}

	mustExecAll(t, d, `UPDATE media_items SET status = 'ok', body = 'kept' WHERE locator = 'https://example.com/a'`)
	// re-record without replaceKinds: nothing deleted, the ok row kept
	if n, err := RecordMedia(ctx, d, p, found[:1]); err != nil || n != 0 {
		t.Fatalf("re-record: n=%d err=%v", n, err)
	}
	if c := count(t, d, `SELECT COUNT(*) FROM media_items WHERE parent_kind = 'slack'`); c != 4 {
		t.Fatalf("re-record without replaceKinds left %d rows, want 4", c)
	}
	if c := count(t, d, `SELECT COUNT(*) FROM media_items WHERE locator = 'https://example.com/a'
			AND status = 'ok' AND body = 'kept'`); c != 1 {
		t.Fatal("re-record changed an ok row")
	}
	// replaceKinds "link": link b goes, images stay
	if _, err := RecordMedia(ctx, d, p, found[:1], "link"); err != nil {
		t.Fatal(err)
	}
	if c := count(t, d, `SELECT COUNT(*) FROM media_items WHERE locator = 'https://example.com/b'`); c != 0 {
		t.Fatal("replaceKinds kept a link no longer found")
	}
	if c := count(t, d, `SELECT COUNT(*) FROM media_items WHERE kind = 'image' AND parent_kind = 'slack'`); c != 2 {
		t.Fatalf("replaceKinds link removed images: %d left", c)
	}
	// replacing with nothing found removes every row of the kind
	if _, err := RecordMedia(ctx, d, p, nil, "image"); err != nil {
		t.Fatal(err)
	}
	if c := count(t, d, `SELECT COUNT(*) FROM media_items WHERE kind = 'image' AND parent_kind = 'slack'`); c != 0 {
		t.Fatalf("replaceKinds image with none found left %d", c)
	}

	// pending listing never shows the skipped_type row
	items, err := d.ListPendingMedia(ctx, true, time.Now(), MediaCursor{}, 100)
	if err != nil {
		t.Fatal(err)
	}
	for _, it := range items {
		if it.Status == "skipped_type" {
			t.Fatal("skipped_type row listed")
		}
	}

	// other parent kinds: key and scope
	for _, c := range []struct {
		p          MediaParent
		key, scope string
	}{
		{MediaParent{Kind: "confluence", ExtSourceID: 5, ExtID: "p1"}, "ext:5:p1", "ext:5"},
		{MediaParent{Kind: "gmail", GmailAccountID: 1, GmailMessageID: "g1"}, "gmail:1:g1", "gmail:1"},
		{MediaParent{Kind: "imap", IMAPAccountID: 1, IMAPUIDValidity: 7, IMAPUID: 42}, "imap:1:7:42", "imap:1"},
	} {
		c.p.ContentAt = start.Add(time.Minute)
		if c.p.Key() != c.key || c.p.Scope() != c.scope {
			t.Fatalf("%s: key %q scope %q", c.p.Kind, c.p.Key(), c.p.Scope())
		}
		if n, err := RecordMedia(ctx, d, c.p, []MediaFound{{Kind: "image", Locator: "att"}}); err != nil || n != 1 {
			t.Fatalf("%s: n=%d err=%v", c.p.Kind, n, err)
		}
	}
}

func TestListPendingMedia(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	mediaFixtures(t, d) // chat 1 and target 1: owner rows, ids 1 and 2
	start, err := d.MediaStartAt()
	if err != nil {
		t.Fatal(err)
	}
	p := slackParent(start.Add(time.Minute))
	if _, err := RecordMedia(ctx, d, p, []MediaFound{
		{Kind: "link", Locator: "https://example.com/1"},
		{Kind: "image", Locator: "F1"},
	}); err != nil {
		t.Fatal(err)
	}
	mustExecAll(t, d, `UPDATE media_items SET status = 'unavailable' WHERE locator = 'F1'`)
	mustExecAll(t, d, `INSERT INTO messages (channel_id, ts, user_id) VALUES ('1:C1', '2.0', '1:U1')`)
	own := MediaParent{Kind: "slack", SlackChannelID: "1:C1", SlackTS: "2.0", ContentAt: start.Add(time.Minute), FromOwner: true}
	if _, err := RecordMedia(ctx, d, own, []MediaFound{{Kind: "link", Locator: "https://example.com/own"}}); err != nil {
		t.Fatal(err)
	}

	locs := func(visionOK bool) []string {
		t.Helper()
		var out []string
		cur := MediaCursor{}
		for {
			items, err := d.ListPendingMedia(ctx, visionOK, time.Now(), cur, 2)
			if err != nil {
				t.Fatal(err)
			}
			if len(items) == 0 {
				return out
			}
			for _, it := range items {
				out = append(out, it.Locator)
			}
			last := items[len(items)-1]
			cur = MediaCursor{FromOwner: last.FromOwner, ID: last.ID}
		}
	}
	got := locs(false)
	want := []string{"/tmp/a/shot.png", "/tmp/acme/board.png", "https://example.com/own", "https://example.com/1"}
	if !equalStrings(got, want) {
		t.Fatalf("visionOK=false: %v, want %v", got, want)
	}
	got = locs(true)
	want = []string{"/tmp/a/shot.png", "/tmp/acme/board.png", "https://example.com/own", "https://example.com/1", "F1"}
	if !equalStrings(got, want) {
		t.Fatalf("visionOK=true: %v, want %v", got, want)
	}

	// moving start_at past the rows hides them
	if err := d.SetMediaStartAt(start.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if moved, _ := d.MediaStartAt(); !moved.Equal(start.Add(time.Hour).Truncate(time.Second)) {
		t.Fatalf("start_at %v after SetMediaStartAt", moved)
	}
	if got := locs(true); len(got) != 0 {
		t.Fatalf("rows below start_at listed: %v", got)
	}
	if _, err := d.ListPendingMedia(ctx, true, time.Now(), MediaCursor{}, 0); err == nil {
		t.Fatal("a zero limit was accepted")
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestFindDescribedMedia_ScopedByAccount(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	mediaFixtures(t, d)
	start, _ := d.MediaStartAt()
	if _, err := RecordMedia(ctx, d, slackParent(start.Add(time.Minute)),
		[]MediaFound{{Kind: "image", Locator: "F1", ContentKey: "sha256:aa"}}); err != nil {
		t.Fatal(err)
	}
	if got, err := d.FindDescribedMedia(ctx, "sha256:aa", "slack:1"); err != nil || got != nil {
		t.Fatalf("a pending row was found: %v %v", got, err)
	}
	mustExecAll(t, d, `UPDATE media_items SET status = 'ok', title = 'T', body = 'B', keys_json = '["K1"]' WHERE locator = 'F1'`)
	got, err := d.FindDescribedMedia(ctx, "sha256:aa", "slack:1")
	if err != nil || got == nil {
		t.Fatalf("ok row in scope not found: %v %v", got, err)
	}
	if got.Title != "T" || got.Body != "B" || len(got.Keys) != 1 || got.Keys[0] != "K1" || got.Scope != "slack:1" {
		t.Fatalf("found row: %+v", got)
	}
	if other, err := d.FindDescribedMedia(ctx, "sha256:aa", "slack:2"); err != nil || other != nil {
		t.Fatalf("found across accounts: %v %v", other, err)
	}
}

func mediaRow(t *testing.T, d *DB, id int64) MediaItem {
	t.Helper()
	it, err := d.getMediaItem(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	return *it
}

func TestFailMedia_FinalOnThirdAttempt(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	mediaFixtures(t, d)
	for i := 1; i <= 3; i++ {
		final, err := d.FailMedia(ctx, 1, "timeout", 3)
		if err != nil {
			t.Fatal(err)
		}
		if final != (i == 3) {
			t.Fatalf("attempt %d: final = %v", i, final)
		}
		it := mediaRow(t, d, 1)
		if it.Attempts != i {
			t.Fatalf("attempt %d: attempts = %d", i, it.Attempts)
		}
		wantStatus := "pending"
		if i == 3 {
			wantStatus = "failed"
		}
		if it.Status != wantStatus {
			t.Fatalf("attempt %d: status %q, want %q", i, it.Status, wantStatus)
		}
	}
	if _, err := d.FailMedia(ctx, 999, "timeout", 3); err == nil {
		t.Fatal("failing a missing row succeeded")
	}
}

func TestFailMedia_StoresOnlyClass(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	mediaFixtures(t, d)
	if _, err := d.FailMedia(ctx, 1, "timeout", 3); err != nil {
		t.Fatal(err)
	}
	if it := mediaRow(t, d, 1); it.Error != "timeout" {
		t.Fatalf("error = %q", it.Error)
	}
	before := mediaRow(t, d, 1)
	for _, bad := range []string{"https://x.example/?token=a", "dial tcp: refused", "", "TIMEOUT"} {
		if _, err := d.FailMedia(ctx, 1, bad, 3); err == nil {
			t.Fatalf("class %q accepted", bad)
		}
		if bad != "" { // an empty class is a success result for FinishMedia
			if err := d.FinishMedia(ctx, 1, MediaResult{Status: "unreachable", ErrorClass: bad}); err == nil {
				t.Fatalf("FinishMedia class %q accepted", bad)
			}
		}
		if after := mediaRow(t, d, 1); after.Error != before.Error || after.Attempts != before.Attempts || after.Status != before.Status {
			t.Fatalf("class %q changed the row: %+v", bad, after)
		}
	}
}

func TestFinishMedia(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	mediaFixtures(t, d)
	err := d.FinishMedia(ctx, 1, MediaResult{
		Status: "ok", ContentKey: "sha256:bb", Title: "T", Body: "B", ImageText: "X K1",
		Keys: []string{"K1"}, KBSource: "slack", KBRef: "slack:thread:1:C1:1.0",
	})
	if err != nil {
		t.Fatal(err)
	}
	it := mediaRow(t, d, 1)
	if it.Status != "ok" || it.ContentKey != "sha256:bb" || it.Kind != "image" || it.Title != "T" ||
		it.Body != "B" || it.ImageText != "X K1" || len(it.Keys) != 1 || it.KBRef != "slack:thread:1:C1:1.0" ||
		it.KBSource != "slack" || it.DescribedAt == "" || it.Error != "" {
		t.Fatalf("finished row: %+v", it)
	}
	if g, ok := kbDirtyKeys(t, d)["slack|slack:thread:1:C1:1.0"]; !ok || g != 0 {
		t.Fatalf("FinishMedia did not mark kb_dirty: %v", kbDirtyKeys(t, d))
	}
	// an empty ContentKey keeps the stored one
	if err := d.FinishMedia(ctx, 1, MediaResult{Status: "too_large", ErrorClass: "too_large"}); err != nil {
		t.Fatal(err)
	}
	if it := mediaRow(t, d, 1); it.ContentKey != "sha256:bb" || it.Status != "too_large" || it.Error != "too_large" {
		t.Fatalf("second finish: %+v", it)
	}
	if it := mediaRow(t, d, 1); it.KBSource != "slack" || it.KBRef != "slack:thread:1:C1:1.0" {
		t.Fatalf("an empty KBRef dropped the stored document: %+v", it)
	}
	if err := d.FinishMedia(ctx, 999, MediaResult{Status: "ok"}); err == nil {
		t.Fatal("finishing a missing row succeeded")
	}
}

func TestMediaKBDirty_MovedRefMarksOldDocument(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	mediaFixtures(t, d)
	if err := d.FinishMedia(ctx, 1, MediaResult{Status: "ok", Body: "B", KBSource: "slack", KBRef: "slack:day:1:C1:2026-10-25"}); err != nil {
		t.Fatal(err)
	}
	mustExecAll(t, d, `DELETE FROM kb_dirty`)
	if err := d.FinishMedia(ctx, 1, MediaResult{Status: "ok", Body: "B", KBSource: "slack", KBRef: "slack:thread:1:C1:1.0"}); err != nil {
		t.Fatal(err)
	}
	got := kbDirtyKeys(t, d)
	for _, k := range []string{"slack|slack:day:1:C1:2026-10-25", "slack|slack:thread:1:C1:1.0"} {
		if _, ok := got[k]; !ok {
			t.Fatalf("moving the ref did not mark %s: %v", k, got)
		}
	}
	// a plain kb_ref change on an ok row marks both too
	mustExecAll(t, d, `DELETE FROM kb_dirty`, `UPDATE media_items SET kb_ref = 'slack:thread:1:C1:9.0' WHERE id = 1`)
	got = kbDirtyKeys(t, d)
	for _, k := range []string{"slack|slack:thread:1:C1:1.0", "slack|slack:thread:1:C1:9.0"} {
		if _, ok := got[k]; !ok {
			t.Fatalf("a kb_ref update did not mark %s: %v", k, got)
		}
	}
	// a pending row's ref change marks nothing
	mustExecAll(t, d, `DELETE FROM kb_dirty`, `UPDATE media_items SET kb_ref = 'slack:thread:1:C1:3.0' WHERE id = 2`)
	if got := kbDirtyKeys(t, d); len(got) != 0 {
		t.Fatalf("a pending row's ref change marked: %v", got)
	}
}

func TestRecordMedia_RefusesZeroContentAt(t *testing.T) {
	d := openTestDB(t)
	mediaFixtures(t, d)
	p := MediaParent{Kind: "slack", SlackChannelID: "1:C1", SlackTS: "1.0"}
	if _, err := RecordMedia(context.Background(), d, p, []MediaFound{{Kind: "link", Locator: "https://example.com/z"}}); err == nil {
		t.Fatal("a zero ContentAt was accepted")
	}
}

func TestDeferMedia_HidesRowUntilItsTime(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	mediaFixtures(t, d)
	mustExecAll(t, d, `DELETE FROM media_items`) // only the row under test
	start, err := d.MediaStartAt()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := RecordMedia(ctx, d, slackParent(start.Add(time.Minute)), []MediaFound{{Kind: "image", Locator: "F1"}}); err != nil {
		t.Fatal(err)
	}
	var id int64
	if err := d.QueryRow(`SELECT id FROM media_items WHERE locator = 'F1'`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	if err := d.DeferMedia(ctx, id, now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		at   time.Time
		want int
	}{{now, 0}, {now.Add(59 * time.Minute), 0}, {now.Add(time.Hour), 1}} {
		items, err := d.ListPendingMedia(ctx, true, c.at, MediaCursor{}, 10)
		if err != nil {
			t.Fatal(err)
		}
		if len(items) != c.want {
			t.Fatalf("at %v: %d rows listed, want %d", c.at, len(items), c.want)
		}
		if c.want == 1 && !MediaListable(items[0], true, c.at) {
			t.Fatal("a listed row is not MediaListable")
		}
	}
	it, err := d.getMediaItem(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if MediaListable(*it, true, now) {
		t.Fatal("a deferred row is MediaListable before its time")
	}
}
