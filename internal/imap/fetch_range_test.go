package imap

import (
	"context"
	"fmt"
	"testing"
	"time"

	"watchtower/internal/db"
)

func TestSearchRangeReturnsOnlyMessagesInsideTheRange(t *testing.T) {
	ts := startTestServer(t)
	day := func(d int) time.Time { return time.Date(2026, 9, d, 12, 0, 0, 0, time.UTC) }
	ts.seedMessageAt(t, rawMessageSubject("too old"), day(18))
	in1 := ts.seedMessageAt(t, rawMessageSubject("in 1"), day(20))
	in2 := ts.seedMessageAt(t, rawMessageSubject("in 2"), day(21))
	ts.seedMessageAt(t, rawMessageSubject("too new"), day(22))

	host, port := ts.hostPort(t)
	cl, _, err := Dial(AccountConfig{Host: host, Port: port, Security: SecurityNone, Folder: "INBOX"},
		PasswordAuth{Username: testUsername, Password: testPassword})
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer func() { _ = cl.Close() }()

	// SINCE is inclusive and BEFORE exclusive, both day-granular.
	uids, err := cl.SearchRange(time.Date(2026, 9, 20, 0, 0, 0, 0, time.UTC), time.Date(2026, 9, 22, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("SearchRange: %v", err)
	}
	if len(uids) != 2 || !containsUID(uids, in1) || !containsUID(uids, in2) {
		t.Fatalf("SearchRange = %v, want [%d %d]", uids, in1, in2)
	}
}

func containsUID(uids []uint32, want uint32) bool {
	for _, u := range uids {
		if u == want {
			return true
		}
	}
	return false
}

func TestFetchRangeStoresAllInRangeWithoutWatermarkOrAuthState(t *testing.T) {
	ts := startTestServer(t)
	for i := range 5 {
		ts.seedMessageAt(t, rawMessageSubject(fmt.Sprintf("m%d", i)), time.Date(2026, 9, 20, 9, i, 0, 0, time.UTC))
	}
	ts.seedMessageAt(t, rawMessageSubject("outside"), time.Date(2026, 9, 25, 9, 0, 0, 0, time.UTC))
	database := db.OpenTestDB(t)
	syncer, acct := newTestSyncer(t, database, ts)
	syncer.appConfig.Imap.MaxMessagesPerSync = 2 // batch size only: the range is not capped
	if err := database.SetEmailAccountAuthState(acct.ID, "error", "prior"); err != nil {
		t.Fatal(err)
	}

	n, err := syncer.FetchRange(context.Background(),
		time.Date(2026, 9, 20, 0, 0, 0, 0, time.UTC), time.Date(2026, 9, 22, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("FetchRange: %v", err)
	}
	if n != 5 {
		t.Fatalf("saved = %d, want 5", n)
	}
	msgs, err := database.ImapMessagesSyncedAfter(acct.ID, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 5 {
		t.Fatalf("stored %d, want 5", len(msgs))
	}
	if msgs[0].UIDValidity == 0 {
		t.Fatal("rows must carry the dialed UIDVALIDITY")
	}
	lastUID, uidValidity, err := database.GetImapWatermark(acct.ID)
	if err != nil {
		t.Fatal(err)
	}
	if lastUID != 0 || uidValidity != 0 {
		t.Fatalf("watermark = %d/%d, want untouched 0/0", lastUID, uidValidity)
	}
	got, err := database.GetEmailAccount(acct.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != "error" || got.Error != "prior" {
		t.Fatalf("auth state = %q/%q, want untouched error/prior", got.Status, got.Error)
	}
	if syncer.AccountID() != acct.ID {
		t.Fatalf("AccountID() = %d, want %d", syncer.AccountID(), acct.ID)
	}
}

func TestSyncFirstSyncFrom(t *testing.T) {
	ts := startTestServer(t)
	database := db.OpenTestDB(t)
	syncer, _ := newTestSyncer(t, database, ts)

	before := time.Now()
	if _, err := syncer.Sync(context.Background()); err != nil { // empty mailbox: still a first sync
		t.Fatalf("Sync: %v", err)
	}
	from, ok := syncer.FirstSyncFrom()
	if !ok {
		t.Fatal("a successful first sync (no watermark) must report FirstSyncFrom")
	}
	want := before.AddDate(0, 0, -syncer.appConfig.Imap.InitialHistoryDays)
	if d := from.Sub(want); d < -time.Second || d > time.Second {
		t.Fatalf("FirstSyncFrom = %v, want ≈ %v", from, want)
	}

	// The first sync recorded UIDVALIDITY: the next one is incremental.
	if _, err := syncer.Sync(context.Background()); err != nil {
		t.Fatalf("second Sync: %v", err)
	}
	if _, ok := syncer.FirstSyncFrom(); ok {
		t.Fatal("an incremental sync is not a first sync")
	}
}

func TestSyncUIDValidityResetIsNotAFirstSync(t *testing.T) {
	ts := startTestServer(t)
	ts.seedMessage(t, simpleRawMessage)
	database := db.OpenTestDB(t)
	syncer, acct := newTestSyncer(t, database, ts)
	// A stale UIDVALIDITY that cannot match the server's: Sync resyncs from
	// scratch, but the account already had history — no backfill.
	if err := database.SetImapWatermark(acct.ID, 7, 4242424242); err != nil {
		t.Fatal(err)
	}
	if _, err := syncer.Sync(context.Background()); err != nil {
		t.Fatalf("Sync: %v", err)
	}
	if _, ok := syncer.FirstSyncFrom(); ok {
		t.Fatal("a UIDVALIDITY-reset resync must not count as a first sync")
	}
}

// Backfilled mail keeps its own date as synced_at, so the inbox detector's
// synced_at cursor (ImapMessagesSyncedAfter) never sees it as new mail; a row
// the forward Sync stores is still stamped now.
func TestFetchRangeSyncedAtIsTheMessagesOwnDate(t *testing.T) {
	ts := startTestServer(t)
	for i := range 3 {
		ts.seedMessageAt(t, rawMessageSubject(fmt.Sprintf("old%d", i)), time.Date(2026, 9, 20, 9, i, 0, 0, time.UTC))
	}
	database := db.OpenTestDB(t)
	syncer, acct := newTestSyncer(t, database, ts)
	cursor := time.Now().Add(-time.Minute).UTC().Format(time.RFC3339)

	if _, err := syncer.FetchRange(context.Background(),
		time.Date(2026, 9, 20, 0, 0, 0, 0, time.UTC), time.Date(2026, 9, 22, 0, 0, 0, 0, time.UTC)); err != nil {
		t.Fatalf("FetchRange: %v", err)
	}
	rows, err := database.ImapMessagesSyncedAfter(acct.ID, cursor)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Fatalf("backfilled rows visible to the inbox cursor: %d", len(rows))
	}

	ts.seedMessage(t, simpleRawMessage) // arrives now; the old ones sit outside Sync's 7-day window
	if _, err := syncer.Sync(context.Background()); err != nil {
		t.Fatalf("Sync: %v", err)
	}
	rows, err = database.ImapMessagesSyncedAfter(acct.ID, cursor)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Subject != "Hello" {
		t.Fatalf("rows after Sync = %+v, want only Hello", rows)
	}
}

func TestBackfillSyncedAtFallsBackToRangeStart(t *testing.T) {
	from := time.Date(2026, 9, 20, 0, 0, 0, 0, time.UTC)
	if got := backfillSyncedAt("", from); got != "2026-09-20T00:00:00Z" {
		t.Fatalf("empty date: got %q", got)
	}
	if got := backfillSyncedAt("2026-09-21T08:00:00Z", from); got != "2026-09-21T08:00:00Z" {
		t.Fatalf("own date: got %q", got)
	}
}
