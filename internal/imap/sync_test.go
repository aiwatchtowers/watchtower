package imap

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/netsec"
)

// TestTruncateUTF8DoesNotSplitRune mirrors gmail.Syncer's identical helper
// test (internal/gmail/sync_test.go) — verifies the body/snippet truncation
// helper backs off to the last valid rune boundary instead of slicing
// mid-rune when the byte cap lands inside a multibyte UTF-8 sequence.
func TestTruncateUTF8DoesNotSplitRune(t *testing.T) {
	body := strings.Repeat("é", 6) // 12 bytes, 2 bytes/rune
	got := truncateUTF8(body, 7)   // 7 lands mid-4th-rune (bytes 6-7)
	if !utf8.ValidString(got) {
		t.Fatalf("truncateUTF8(%q, 7) = %q is not valid UTF-8", body, got)
	}
	if got != "ééé" {
		t.Fatalf("truncateUTF8(%q, 7) = %q, want %q (back off to previous rune boundary)", body, got, "ééé")
	}

	// Under the cap: no truncation at all.
	if got := truncateUTF8("short", 100); got != "short" {
		t.Fatalf("truncateUTF8 under cap = %q, want unchanged %q", got, "short")
	}
}

// rawMessageSubject builds a minimal raw RFC822 message with a distinct
// subject, for tests that need several distinguishable, orderable messages
// (ascending UIDs come from the order testServer.seedMessage is called in).
func rawMessageSubject(subject string) string {
	return fmt.Sprintf("From: Sender <sender@example.com>\r\nTo: me@example.com\r\nSubject: %s\r\n"+
		"Content-Type: text/plain; charset=utf-8\r\n\r\nBody of %s.\r\n", subject, subject)
}

func newTestSyncer(t *testing.T, database *db.DB, ts *testServer) (*Syncer, db.EmailAccount) {
	t.Helper()
	host, port := ts.hostPort(t)
	id, err := database.CreateEmailAccount(db.EmailAccount{
		Provider: "imap", EmailAddress: "me@example.com",
		Host: host, Port: port, Security: "none", Folder: "INBOX",
	})
	if err != nil {
		t.Fatalf("create email account: %v", err)
	}
	acct, err := database.GetEmailAccount(id)
	if err != nil {
		t.Fatalf("get email account: %v", err)
	}
	cfg := &config.Config{}
	cfg.Imap = config.ImapConfig{InitialHistoryDays: 7, MaxMessagesPerSync: 100, MaxBodyBytes: 51200}
	accountCfg := AccountConfig{Host: acct.Host, Port: acct.Port, Security: SecurityNone, Folder: acct.Folder}
	auth := PasswordAuth{Username: testUsername, Password: testPassword}
	return NewSyncer(acct, accountCfg, auth, database, cfg, nil), acct
}

func TestSyncStoresMessagesAndAdvancesWatermark(t *testing.T) {
	ts := startTestServer(t)
	ts.seedMessage(t, simpleRawMessage)
	database := db.OpenTestDB(t)

	syncer, acct := newTestSyncer(t, database, ts)

	n, err := syncer.Sync(context.Background())
	if err != nil {
		t.Fatalf("Sync: %v", err)
	}
	if n != 1 {
		t.Fatalf("want 1 message synced, got %d", n)
	}

	msgs, err := database.ImapMessagesSyncedAfter(acct.ID, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("query imap_messages: %v", err)
	}
	if len(msgs) != 1 || msgs[0].Subject != "Hello" {
		t.Fatalf("want 1 stored message with subject Hello, got %+v", msgs)
	}

	lastUID, uidValidity, err := database.GetImapWatermark(acct.ID)
	if err != nil {
		t.Fatalf("get watermark: %v", err)
	}
	if lastUID != msgs[0].UID {
		t.Errorf("watermark last_uid = %d, want %d", lastUID, msgs[0].UID)
	}
	if uidValidity == 0 {
		t.Errorf("want non-zero uidvalidity recorded")
	}

	updated, err := database.GetEmailAccount(acct.ID)
	if err != nil {
		t.Fatalf("get email account: %v", err)
	}
	if updated.Status != "ok" {
		t.Errorf("status = %q, want ok", updated.Status)
	}

	// Second sync with nothing new: no additional messages, watermark unchanged.
	n2, err := syncer.Sync(context.Background())
	if err != nil {
		t.Fatalf("second Sync: %v", err)
	}
	if n2 != 0 {
		t.Fatalf("want 0 on second sync, got %d", n2)
	}
}

func TestSyncRecordsAuthErrorOnBadCredentials(t *testing.T) {
	ts := startTestServer(t)
	database := db.OpenTestDB(t)
	host, port := ts.hostPort(t)

	id, err := database.CreateEmailAccount(db.EmailAccount{
		Provider: "imap", EmailAddress: "me@example.com",
		Host: host, Port: port, Security: "none", Folder: "INBOX",
	})
	if err != nil {
		t.Fatalf("create email account: %v", err)
	}
	acct, err := database.GetEmailAccount(id)
	if err != nil {
		t.Fatalf("get email account: %v", err)
	}
	cfg := &config.Config{}
	cfg.Imap = config.ImapConfig{InitialHistoryDays: 7, MaxMessagesPerSync: 100, MaxBodyBytes: 51200}
	accountCfg := AccountConfig{Host: acct.Host, Port: acct.Port, Security: SecurityNone, Folder: acct.Folder}
	syncer := NewSyncer(acct, accountCfg, PasswordAuth{Username: testUsername, Password: "wrong"}, database, cfg, nil)

	if _, err := syncer.Sync(context.Background()); err == nil {
		t.Fatal("want error for wrong password, got nil")
	}

	updated, err := database.GetEmailAccount(acct.ID)
	if err != nil {
		t.Fatalf("get email account: %v", err)
	}
	if updated.Status != "error" || updated.Error == "" {
		t.Errorf("want status=error with a message, got status=%q error=%q", updated.Status, updated.Error)
	}
}

func TestSyncInitialBackfillRespectsHistoryWindow(t *testing.T) {
	ts := startTestServer(t)
	// A message far outside the 7-day backfill window shouldn't be fetched —
	// SINCE matches INTERNALDATE (server receipt time), so seedMessageAt sets
	// that directly rather than relying on the raw message's Date: header.
	ts.seedMessageAt(t, "From: Old <old@example.com>\r\nTo: me@example.com\r\nSubject: Old\r\n"+
		"Content-Type: text/plain; charset=utf-8\r\n\r\nOld body.\r\n", time.Now().AddDate(0, 0, -30))
	ts.seedMessage(t, simpleRawMessage) // recent
	database := db.OpenTestDB(t)

	syncer, _ := newTestSyncer(t, database, ts)
	n, err := syncer.Sync(context.Background())
	if err != nil {
		t.Fatalf("Sync: %v", err)
	}
	if n != 1 {
		t.Fatalf("want 1 message within the backfill window, got %d", n)
	}
}

// TestSyncStopsWatermarkAtFirstFailureButStillStoresLaterMessages covers fix
// #2: messages are upserted in ascending-UID order, so a later (higher-UID)
// message's success must not let the watermark advance past an earlier one
// that failed to store — or that earlier message becomes permanently
// unreachable (the next cycle's SearchNewSince starts after the watermark).
// Later successes in the same batch are still stored/counted (a retry isn't
// harmful), just not reflected in the watermark yet.
func TestSyncStopsWatermarkAtFirstFailureButStillStoresLaterMessages(t *testing.T) {
	ts := startTestServer(t)
	uid1 := ts.seedMessage(t, rawMessageSubject("First"))
	uid2 := ts.seedMessage(t, rawMessageSubject("Second"))
	uid3 := ts.seedMessage(t, rawMessageSubject("Third"))
	database := db.OpenTestDB(t)

	syncer, acct := newTestSyncer(t, database, ts)
	// Force the middle message's upsert to fail; real ones still hit the DB.
	syncer.upsertImapMessage = func(m db.ImapMessage, syncedAt string) error {
		if m.UID == int64(uid2) {
			return fmt.Errorf("forced failure for uid %d", uid2)
		}
		return database.UpsertImapMessage(m, syncedAt)
	}

	n, err := syncer.Sync(context.Background())
	if err != nil {
		t.Fatalf("Sync: %v", err)
	}
	if n != 2 {
		t.Fatalf("want 2 successfully upserted (uid %d and uid %d), got %d", uid1, uid3, n)
	}

	lastUID, _, err := database.GetImapWatermark(acct.ID)
	if err != nil {
		t.Fatalf("get watermark: %v", err)
	}
	if lastUID != int64(uid1) {
		t.Errorf("watermark last_uid = %d, want %d (stop at the uid before the failure, not %d)", lastUID, uid1, uid3)
	}

	msgs, err := database.ImapMessagesSyncedAfter(acct.ID, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("query imap_messages: %v", err)
	}
	found3 := false
	for _, m := range msgs {
		if m.UID == int64(uid3) {
			found3 = true
		}
	}
	if !found3 {
		t.Errorf("want uid %d stored (later successes in the batch still persist) despite the watermark not advancing past it", uid3)
	}
	if len(msgs) != 2 {
		t.Errorf("want exactly 2 stored rows (uid %d failed), got %d: %+v", uid2, len(msgs), msgs)
	}
}

// TestSyncCapsToMaxMessagesPerSyncAndAdvancesOnlyToLastProcessed covers fix
// #6: when more messages are pending than MaxMessagesPerSync, only the cap's
// worth is stored per cycle, the watermark advances only to the last one
// actually processed (not the full backlog), and a second Sync() picks up
// the remainder.
func TestSyncCapsToMaxMessagesPerSyncAndAdvancesOnlyToLastProcessed(t *testing.T) {
	ts := startTestServer(t)
	// total-capN must not exceed capN itself, so the second sync's own cap
	// doesn't also kick in — this test is about the cap applying per cycle,
	// not about how many cycles a larger backlog takes to fully drain.
	const total = 3
	uids := make([]uint32, total)
	for i := 0; i < total; i++ {
		uids[i] = ts.seedMessage(t, rawMessageSubject(fmt.Sprintf("Msg%d", i)))
	}
	database := db.OpenTestDB(t)
	host, port := ts.hostPort(t)

	id, err := database.CreateEmailAccount(db.EmailAccount{
		Provider: "imap", EmailAddress: "me@example.com",
		Host: host, Port: port, Security: "none", Folder: "INBOX",
	})
	if err != nil {
		t.Fatalf("create email account: %v", err)
	}
	acct, err := database.GetEmailAccount(id)
	if err != nil {
		t.Fatalf("get email account: %v", err)
	}
	const capN = 2
	cfg := &config.Config{}
	cfg.Imap = config.ImapConfig{InitialHistoryDays: 7, MaxMessagesPerSync: capN, MaxBodyBytes: 51200}
	accountCfg := AccountConfig{Host: acct.Host, Port: acct.Port, Security: SecurityNone, Folder: acct.Folder}
	auth := PasswordAuth{Username: testUsername, Password: testPassword}
	syncer := NewSyncer(acct, accountCfg, auth, database, cfg, nil)

	n, err := syncer.Sync(context.Background())
	if err != nil {
		t.Fatalf("first Sync: %v", err)
	}
	if n != capN {
		t.Fatalf("want %d messages stored (capped), got %d", capN, n)
	}

	msgs, err := database.ImapMessagesSyncedAfter(acct.ID, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("query imap_messages: %v", err)
	}
	if len(msgs) != capN {
		t.Fatalf("want %d stored rows after the first (capped) sync, got %d", capN, len(msgs))
	}
	// The discarded tail (uids[capN:]) must never have been fetched/stored at
	// all — the two-phase list-then-fetch shape (fix #7) means the cap is
	// applied before the expensive fetch, not after a fetch-everything call.
	for _, m := range msgs {
		if m.UID >= int64(uids[capN]) {
			t.Errorf("uid %d beyond the cap was stored; the discarded tail must never be fetched", m.UID)
		}
	}

	lastUID, _, err := database.GetImapWatermark(acct.ID)
	if err != nil {
		t.Fatalf("get watermark: %v", err)
	}
	if lastUID != int64(uids[capN-1]) {
		t.Errorf("watermark last_uid = %d, want %d (the last uid actually processed, not the full backlog)", lastUID, uids[capN-1])
	}

	// Second sync picks up the remainder.
	n2, err := syncer.Sync(context.Background())
	if err != nil {
		t.Fatalf("second Sync: %v", err)
	}
	if n2 != total-capN {
		t.Fatalf("want %d remaining messages on the second sync, got %d", total-capN, n2)
	}
	msgsAll, err := database.ImapMessagesSyncedAfter(acct.ID, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("query imap_messages after second sync: %v", err)
	}
	if len(msgsAll) != total {
		t.Fatalf("want all %d messages stored after the second sync, got %d", total, len(msgsAll))
	}
}

// A security-none account on a remote host stops syncing visibly: its row
// carries the cleartext refusal under netsec.StatusPrefix, which the
// Desktop shows as "Stopped syncing" — never a silent failure.
func TestSyncRecordsACleartextRefusal(t *testing.T) {
	database := db.OpenTestDB(t)
	id, err := database.CreateEmailAccount(db.EmailAccount{
		Provider: "imap", EmailAddress: "me@example.com",
		Host: "imap.example.com", Port: 143, Security: "none", Folder: "INBOX",
	})
	if err != nil {
		t.Fatalf("create email account: %v", err)
	}
	acct, err := database.GetEmailAccount(id)
	if err != nil {
		t.Fatalf("get email account: %v", err)
	}
	cfg := &config.Config{}
	accountCfg := AccountConfig{Host: acct.Host, Port: acct.Port, Security: SecurityNone, Folder: acct.Folder}
	syncer := NewSyncer(acct, accountCfg, PasswordAuth{Username: testUsername, Password: testPassword}, database, cfg, nil)
	if _, err := syncer.Sync(context.Background()); !errors.Is(err, netsec.ErrCleartext) {
		t.Fatalf("Sync err = %v, want netsec.ErrCleartext", err)
	}
	updated, err := database.GetEmailAccount(id)
	if err != nil {
		t.Fatalf("get email account: %v", err)
	}
	if updated.Status != "error" || !strings.HasPrefix(updated.Error, netsec.StatusPrefix) {
		t.Errorf("want status=error with the %q prefix, got status=%q error=%q", netsec.StatusPrefix, updated.Status, updated.Error)
	}
}

func storedUIDs(t *testing.T, database *db.DB, acctID, uidValidity int64) []int64 {
	t.Helper()
	uids, err := database.ImapStoredUIDs(acctID, uidValidity)
	if err != nil {
		t.Fatalf("ImapStoredUIDs: %v", err)
	}
	return uids
}

func syncedValidity(t *testing.T, database *db.DB, acctID int64) int64 {
	t.Helper()
	_, v, err := database.GetImapWatermark(acctID)
	if err != nil {
		t.Fatalf("watermark: %v", err)
	}
	return v
}

func TestSync_ExpungedMessageIsDeleted(t *testing.T) {
	ts := startTestServer(t)
	u1 := ts.seedMessage(t, rawMessageSubject("one"))
	ts.seedMessage(t, rawMessageSubject("two"))
	ts.seedMessage(t, rawMessageSubject("three"))
	database := db.OpenTestDB(t)
	syncer, acct := newTestSyncer(t, database, ts)
	if _, err := syncer.Sync(context.Background()); err != nil {
		t.Fatalf("Sync: %v", err)
	}
	ts.expungeUIDs(t, u1)
	if _, err := syncer.Sync(context.Background()); err != nil {
		t.Fatalf("second Sync: %v", err)
	}
	got := storedUIDs(t, database, acct.ID, syncedValidity(t, database, acct.ID))
	if len(got) != 2 {
		t.Fatalf("stored = %v, want 2 rows", got)
	}
	for _, u := range got {
		if u == int64(u1) {
			t.Fatalf("expunged uid %d still stored", u1)
		}
	}
}

func TestSync_EmptyMailboxDeletesNothing(t *testing.T) {
	ts := startTestServer(t)
	u1 := ts.seedMessage(t, rawMessageSubject("one"))
	u2 := ts.seedMessage(t, rawMessageSubject("two"))
	database := db.OpenTestDB(t)
	syncer, acct := newTestSyncer(t, database, ts)
	var logs strings.Builder
	syncer.logger = log.New(&logs, "", 0)
	if _, err := syncer.Sync(context.Background()); err != nil {
		t.Fatalf("Sync: %v", err)
	}
	ts.expungeUIDs(t, u1, u2)
	if _, err := syncer.Sync(context.Background()); err != nil {
		t.Fatalf("second Sync: %v", err)
	}
	if got := storedUIDs(t, database, acct.ID, syncedValidity(t, database, acct.ID)); len(got) != 2 {
		t.Fatalf("stored = %v, want 2 rows kept", got)
	}
	if !strings.Contains(logs.String(), "refus") {
		t.Errorf("log lacks the refusal: %q", logs.String())
	}
}

func TestSync_OverHalfGoneDeletesNothing(t *testing.T) {
	ts := startTestServer(t)
	var uids []uint32
	for i := 0; i < 4; i++ {
		uids = append(uids, ts.seedMessage(t, rawMessageSubject(fmt.Sprintf("m%d", i))))
	}
	database := db.OpenTestDB(t)
	syncer, acct := newTestSyncer(t, database, ts)
	if _, err := syncer.Sync(context.Background()); err != nil {
		t.Fatalf("Sync: %v", err)
	}
	ts.expungeUIDs(t, uids[0], uids[1], uids[2])
	if _, err := syncer.Sync(context.Background()); err != nil {
		t.Fatalf("second Sync: %v", err)
	}
	if got := storedUIDs(t, database, acct.ID, syncedValidity(t, database, acct.ID)); len(got) != 4 {
		t.Fatalf("stored = %v, want 4 rows kept", got)
	}
}

func TestSync_UIDValidityCleanupKeepsCurrentEpoch(t *testing.T) {
	ts := startTestServer(t)
	ts.seedMessage(t, rawMessageSubject("one"))
	ts.seedMessage(t, rawMessageSubject("two"))
	database := db.OpenTestDB(t)
	syncer, acct := newTestSyncer(t, database, ts)

	const old = int64(999999937) // a value the in-memory server never assigns
	for uid := int64(1); uid <= 3; uid++ {
		if err := database.UpsertImapMessage(db.ImapMessage{
			AccountID: acct.ID, UID: uid, UIDValidity: old, Subject: "old",
		}, "2026-01-01T00:00:00Z"); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	if err := database.SetImapWatermark(acct.ID, 3, old); err != nil {
		t.Fatalf("seed watermark: %v", err)
	}

	if _, err := syncer.Sync(context.Background()); err != nil {
		t.Fatalf("Sync: %v", err)
	}
	if got := storedUIDs(t, database, acct.ID, old); len(got) != 0 {
		t.Fatalf("rows under the old epoch remain: %v", got)
	}
	cur := syncedValidity(t, database, acct.ID)
	if cur == old {
		t.Fatalf("watermark validity did not move")
	}
	if got := storedUIDs(t, database, acct.ID, cur); len(got) != 2 {
		t.Fatalf("current-epoch rows = %v, want 2", got)
	}
}
