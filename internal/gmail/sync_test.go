package gmail

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"unicode/utf8"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

func TestSyncFiltersAndUpserts(t *testing.T) {
	// messages: m1 normal, m2 promotions (must be skipped)
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"messages":[{"id":"m1"},{"id":"m2"}]}`)
	})
	mux.HandleFunc("/users/me/messages/m1", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"id":"m1","threadId":"t1","labelIds":["INBOX","UNREAD"],"snippet":"s",
          "internalDate":"1720519200000","payload":{"headers":[{"name":"Subject","value":"Hi"},
          {"name":"From","value":"a@x.com"}],"parts":[{"mimeType":"text/plain","body":{"data":""}}]}}`)
	})
	mux.HandleFunc("/users/me/messages/m2", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"id":"m2","threadId":"t2","labelIds":["INBOX","CATEGORY_PROMOTIONS"],
          "snippet":"promo","internalDate":"1720519300000","payload":{"headers":[]}}`)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"access_token":"at"}`)
	}))
	defer tokenSrv.Close()
	oldBase, oldTok := gmailAPIBase, googleTokenEndpoint
	gmailAPIBase, googleTokenEndpoint = srv.URL, tokenSrv.URL
	defer func() { gmailAPIBase, googleTokenEndpoint = oldBase, oldTok }()

	database := db.OpenTestDB(t)
	if err := database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test.slack.com"}); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
	accountID, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	if err != nil {
		t.Fatalf("seeding google account: %v", err)
	}
	cfg := &config.Config{}
	cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 100, MaxBodyBytes: 51200}
	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	s := NewSyncer(c, database, cfg, nil, accountID)
	n, err := s.Sync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("want 1 synced (promotions skipped), got %d", n)
	}
	rows, err := database.GmailMessagesSyncedAfter(accountID, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(rows) != 1 || rows[0].ID != "m1" {
		t.Fatalf("stored rows: %+v", rows)
	}
}

// TestSyncPaginatesWithoutLoss verifies that Sync walks Gmail's nextPageToken
// across multiple list pages instead of only looking at the first page, and
// that the second page's request actually carries the pageToken from the
// first page's response.
func TestSyncPaginatesWithoutLoss(t *testing.T) {
	var sawPageToken string
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		if tok := r.URL.Query().Get("pageToken"); tok != "" {
			sawPageToken = tok
			fmt.Fprint(w, `{"messages":[{"id":"p2"}]}`)
			return
		}
		fmt.Fprint(w, `{"messages":[{"id":"p1"}],"nextPageToken":"tok2"}`)
	})
	mux.HandleFunc("/users/me/messages/p1", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"id":"p1","threadId":"t1","labelIds":["INBOX"],"snippet":"s1",
          "internalDate":"1700000000000","payload":{"headers":[{"name":"Subject","value":"P1"}]}}`)
	})
	mux.HandleFunc("/users/me/messages/p2", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"id":"p2","threadId":"t2","labelIds":["INBOX"],"snippet":"s2",
          "internalDate":"1700003600000","payload":{"headers":[{"name":"Subject","value":"P2"}]}}`)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"access_token":"at"}`)
	}))
	defer tokenSrv.Close()
	oldBase, oldTok := gmailAPIBase, googleTokenEndpoint
	gmailAPIBase, googleTokenEndpoint = srv.URL, tokenSrv.URL
	defer func() { gmailAPIBase, googleTokenEndpoint = oldBase, oldTok }()

	database := db.OpenTestDB(t)
	if err := database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test.slack.com"}); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
	accountID, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	if err != nil {
		t.Fatalf("seeding google account: %v", err)
	}
	cfg := &config.Config{}
	cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 100, MaxBodyBytes: 51200}
	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	s := NewSyncer(c, database, cfg, nil, accountID)
	n, err := s.Sync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("want 2 synced across both pages, got %d", n)
	}
	if sawPageToken != "tok2" {
		t.Fatalf("second list request did not carry pageToken from first page, got %q", sawPageToken)
	}
	rows, err := database.GmailMessagesSyncedAfter(accountID, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("stored rows: %+v", rows)
	}
}

// TestSyncCapProcessesOldestFirst proves the no-data-loss property: when more
// messages exist than MaxMessagesPerSync, Sync processes the OLDEST ones
// first (not newest) and advances the watermark only to that oldest
// message's internalDate — so the next cycle's after:<watermark> query picks
// up the remainder instead of it being silently skipped.
func TestSyncCapProcessesOldestFirst(t *testing.T) {
	const oldUnix = 1700000000 // T1
	const newUnix = 1700003600 // T2, one hour later
	newFetched := false
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		// Gmail returns newest-first.
		fmt.Fprint(w, `{"messages":[{"id":"mNew"},{"id":"mOld"}]}`)
	})
	mux.HandleFunc("/users/me/messages/mOld", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"id":"mOld","threadId":"t1","labelIds":["INBOX"],"snippet":"old",
          "internalDate":"%d000","payload":{"headers":[{"name":"Subject","value":"Old"}]}}`, oldUnix)
	})
	mux.HandleFunc("/users/me/messages/mNew", func(w http.ResponseWriter, r *http.Request) {
		newFetched = newFetched || r.URL.Query().Get("format") == "full" // a minimal date lookup is not a fetch
		fmt.Fprintf(w, `{"id":"mNew","threadId":"t2","labelIds":["INBOX"],"snippet":"new",
          "internalDate":"%d000","payload":{"headers":[{"name":"Subject","value":"New"}]}}`, newUnix)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"access_token":"at"}`)
	}))
	defer tokenSrv.Close()
	oldBase, oldTok := gmailAPIBase, googleTokenEndpoint
	gmailAPIBase, googleTokenEndpoint = srv.URL, tokenSrv.URL
	defer func() { gmailAPIBase, googleTokenEndpoint = oldBase, oldTok }()

	database := db.OpenTestDB(t)
	if err := database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test.slack.com"}); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
	accountID, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	if err != nil {
		t.Fatalf("seeding google account: %v", err)
	}
	cfg := &config.Config{}
	cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 1, MaxBodyBytes: 51200}
	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	s := NewSyncer(c, database, cfg, nil, accountID)
	n, err := s.Sync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("want 1 synced (cap=1), got %d", n)
	}
	if newFetched {
		t.Fatal("newer message was fetched despite the cap — should process oldest first only")
	}
	rows, err := database.GmailMessagesSyncedAfter(accountID, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(rows) != 1 || rows[0].ID != "mOld" {
		t.Fatalf("expected only the oldest message stored, got: %+v", rows)
	}
	watermark, err := database.GetGmailAccountWatermark(accountID)
	if err != nil {
		t.Fatalf("watermark: %v", err)
	}
	if watermark != float64(oldUnix) {
		t.Fatalf("watermark = %v, want %v (oldest processed, not newest)", watermark, oldUnix)
	}
}

// TestSyncNoLossWhenBacklogExceedsCap is the regression test for the
// residual data-loss bug: capping the *list* phase at
// maxMsgs*listFetchMultiplier meant that once the real backlog since the
// watermark exceeded that inflated cap, Gmail's newest-first list would
// never even return the oldest ids — they'd be truncated away before the
// oldest-first sort/processing-cap logic ever saw them, and the watermark
// would advance past a tail that was never fetched. This proves the fix:
// listing is uncapped (paginates to exhaustion) and only the processing
// phase is capped, so no backlog size can cause permanent loss — the next
// cycle's after:<watermark> query always recovers exactly the remainder.
func TestSyncNoLossWhenBacklogExceedsCap(t *testing.T) {
	const t1Unix = 1700000000 // oldest
	const t2Unix = 1700003600
	const t3Unix = 1700007200 // newest

	var m3Fetched bool
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query().Get("q")
		if strings.Contains(q, "after:") {
			// Second sync: watermark has advanced to T2, so the server-side
			// window narrows to just the remainder (T3).
			fmt.Fprint(w, `{"messages":[{"id":"m3"}]}`)
			return
		}
		// First sync (initial backfill, no watermark yet): Gmail returns
		// newest-first, paginated across 3 single-message pages, with no
		// maxResults-driven truncation — proving the list phase collects
		// the whole window regardless of MaxMessagesPerSync.
		switch r.URL.Query().Get("pageToken") {
		case "":
			fmt.Fprint(w, `{"messages":[{"id":"m3"}],"nextPageToken":"tok2"}`)
		case "tok2":
			fmt.Fprint(w, `{"messages":[{"id":"m2"}],"nextPageToken":"tok3"}`)
		case "tok3":
			fmt.Fprint(w, `{"messages":[{"id":"m1"}]}`)
		default:
			t.Fatalf("unexpected pageToken %q", r.URL.Query().Get("pageToken"))
		}
	})
	mux.HandleFunc("/users/me/messages/m1", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"id":"m1","threadId":"t1","labelIds":["INBOX"],"snippet":"m1",
          "internalDate":"%d000","payload":{"headers":[{"name":"Subject","value":"M1"}]}}`, t1Unix)
	})
	mux.HandleFunc("/users/me/messages/m2", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"id":"m2","threadId":"t2","labelIds":["INBOX"],"snippet":"m2",
          "internalDate":"%d000","payload":{"headers":[{"name":"Subject","value":"M2"}]}}`, t2Unix)
	})
	mux.HandleFunc("/users/me/messages/m3", func(w http.ResponseWriter, r *http.Request) {
		m3Fetched = m3Fetched || r.URL.Query().Get("format") == "full" // a minimal date lookup is not a fetch
		fmt.Fprintf(w, `{"id":"m3","threadId":"t3","labelIds":["INBOX"],"snippet":"m3",
          "internalDate":"%d000","payload":{"headers":[{"name":"Subject","value":"M3"}]}}`, t3Unix)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"access_token":"at"}`)
	}))
	defer tokenSrv.Close()
	oldBase, oldTok := gmailAPIBase, googleTokenEndpoint
	gmailAPIBase, googleTokenEndpoint = srv.URL, tokenSrv.URL
	defer func() { gmailAPIBase, googleTokenEndpoint = oldBase, oldTok }()

	database := db.OpenTestDB(t)
	if err := database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test.slack.com"}); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
	accountID, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	if err != nil {
		t.Fatalf("seeding google account: %v", err)
	}
	cfg := &config.Config{}
	cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 2, MaxBodyBytes: 51200}
	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	var logBuf strings.Builder
	logger := log.New(&logBuf, "", 0)
	s := NewSyncer(c, database, cfg, logger, accountID)

	// First sync: backlog of 3 exceeds MaxMessagesPerSync=2. Oldest two
	// (m1, m2) must be stored; m3 must NOT be fetched this cycle (it's the
	// remainder deferred to next cycle, proving the cap only bites the
	// processing phase — the list phase already saw all 3 via pagination).
	n, err := s.Sync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("first sync: want 2 stored (cap=2), got %d", n)
	}
	if m3Fetched {
		t.Fatal("first sync: m3 (remainder beyond cap) was fetched — should be deferred to next cycle")
	}
	if !strings.Contains(logBuf.String(), "exceed cap") {
		t.Fatalf("first sync: expected truncation log, got log output: %q", logBuf.String())
	}
	watermark, err := database.GetGmailAccountWatermark(accountID)
	if err != nil {
		t.Fatalf("watermark: %v", err)
	}
	if watermark != float64(t2Unix) {
		t.Fatalf("first sync: watermark = %v, want %v (oldest-of-cap processed, T2)", watermark, t2Unix)
	}

	// Second sync: the narrowed after:<watermark> query recovers exactly the
	// deferred remainder (m3) — no data loss regardless of the original
	// backlog size.
	n, err = s.Sync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("second sync: want 1 stored (the deferred remainder), got %d", n)
	}
	if !m3Fetched {
		t.Fatal("second sync: m3 should have been fetched now")
	}

	rows, err := database.GmailMessagesSyncedAfter(accountID, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(rows) != 3 {
		t.Fatalf("want all 3 messages eventually stored across both syncs, got %d: %+v", len(rows), rows)
	}
	finalWatermark, err := database.GetGmailAccountWatermark(accountID)
	if err != nil {
		t.Fatalf("final watermark: %v", err)
	}
	if finalWatermark != float64(t3Unix) {
		t.Fatalf("final watermark = %v, want %v", finalWatermark, t3Unix)
	}
}

// TestTruncateUTF8DoesNotSplitRune verifies the body-truncation helper backs
// off to the last valid rune boundary instead of slicing mid-rune when the
// byte cap lands inside a multibyte UTF-8 sequence.
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

// TestSyncTruncatesBodyOnRuneBoundary is an end-to-end check that Sync's
// stored body_text is always valid UTF-8 even when MaxBodyBytes lands in the
// middle of a multibyte rune in the real fetched message body.
func TestSyncTruncatesBodyOnRuneBoundary(t *testing.T) {
	rawBody := strings.Repeat("é", 6) // 12 bytes
	encoded := base64.URLEncoding.EncodeToString([]byte(rawBody))

	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"messages":[{"id":"mb"}]}`)
	})
	mux.HandleFunc("/users/me/messages/mb", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"id":"mb","threadId":"tb","labelIds":["INBOX"],"snippet":"s",
          "internalDate":"1720519200000","payload":{"headers":[{"name":"Subject","value":"Multibyte"}],
          "parts":[{"mimeType":"text/plain","body":{"data":%q}}]}}`, encoded)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"access_token":"at"}`)
	}))
	defer tokenSrv.Close()
	oldBase, oldTok := gmailAPIBase, googleTokenEndpoint
	gmailAPIBase, googleTokenEndpoint = srv.URL, tokenSrv.URL
	defer func() { gmailAPIBase, googleTokenEndpoint = oldBase, oldTok }()

	database := db.OpenTestDB(t)
	if err := database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test.slack.com"}); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
	accountID, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	if err != nil {
		t.Fatalf("seeding google account: %v", err)
	}
	cfg := &config.Config{}
	cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 100, MaxBodyBytes: 7}
	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	s := NewSyncer(c, database, cfg, nil, accountID)
	if _, err := s.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	rows, err := database.GmailMessagesSyncedAfter(accountID, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("stored rows: %+v", rows)
	}
	if !utf8.ValidString(rows[0].BodyText) {
		t.Fatalf("stored body_text %q is not valid UTF-8", rows[0].BodyText)
	}
}

// TestSyncNarrowsQueryWithAfterOnceWatermarkIsSet verifies that once a
// watermark exists, Sync switches the list query from the initial
// newer_than: backfill window to a server-side after:<unixSeconds> filter,
// which both narrows the window (fixing the data-loss cap interaction) and
// cuts wasted GetMessage quota on already-seen mail.
func TestSyncNarrowsQueryWithAfterOnceWatermarkIsSet(t *testing.T) {
	var sawQuery string
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		sawQuery = r.URL.Query().Get("q")
		fmt.Fprint(w, `{"messages":[]}`)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"access_token":"at"}`)
	}))
	defer tokenSrv.Close()
	oldBase, oldTok := gmailAPIBase, googleTokenEndpoint
	gmailAPIBase, googleTokenEndpoint = srv.URL, tokenSrv.URL
	defer func() { gmailAPIBase, googleTokenEndpoint = oldBase, oldTok }()

	database := db.OpenTestDB(t)
	if err := database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test.slack.com"}); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
	accountID, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	if err != nil {
		t.Fatalf("seeding google account: %v", err)
	}
	if err := database.SetGmailAccountWatermark(accountID, 1700000000); err != nil {
		t.Fatalf("seeding watermark: %v", err)
	}
	cfg := &config.Config{}
	cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 100, MaxBodyBytes: 51200}
	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	s := NewSyncer(c, database, cfg, nil, accountID)
	if _, err := s.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(sawQuery, "after:1700000000") {
		t.Fatalf("query = %q, want it to contain after:1700000000", sawQuery)
	}
	if strings.Contains(sawQuery, "newer_than:") {
		t.Fatalf("query = %q, should not fall back to newer_than: once a watermark exists", sawQuery)
	}
}

// TestSyncTwoAccountsIsolated proves per-account isolation: syncing account A
// must not touch account B's watermark, and every message A's sync stores
// must carry account_id = A (enforced here by scoping the read through
// GmailMessagesSyncedAfter(accountID, ...), which filters on account_id).
func TestSyncTwoAccountsIsolated(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"messages":[{"id":"m1"}]}`)
	})
	mux.HandleFunc("/users/me/messages/m1", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"id":"m1","threadId":"t1","labelIds":["INBOX"],"snippet":"s",
          "internalDate":"1720519200000","payload":{"headers":[{"name":"Subject","value":"Hi"}]}}`)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"access_token":"at"}`)
	}))
	defer tokenSrv.Close()
	oldBase, oldTok := gmailAPIBase, googleTokenEndpoint
	gmailAPIBase, googleTokenEndpoint = srv.URL, tokenSrv.URL
	defer func() { gmailAPIBase, googleTokenEndpoint = oldBase, oldTok }()

	database := db.OpenTestDB(t)
	if err := database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test.slack.com"}); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
	accountA, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	if err != nil {
		t.Fatalf("seeding google account A: %v", err)
	}
	accountB, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "b@x.com", Label: "B"})
	if err != nil {
		t.Fatalf("seeding google account B: %v", err)
	}
	cfg := &config.Config{}
	cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 100, MaxBodyBytes: 51200}
	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	s := NewSyncer(c, database, cfg, nil, accountA)
	n, err := s.Sync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("want 1 synced for account A, got %d", n)
	}

	bWatermark, err := database.GetGmailAccountWatermark(accountB)
	if err != nil {
		t.Fatalf("account B watermark: %v", err)
	}
	if bWatermark != 0 {
		t.Fatalf("account B watermark = %v, want 0 (untouched by A's sync)", bWatermark)
	}

	aRows, err := database.GmailMessagesSyncedAfter(accountA, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("account A query: %v", err)
	}
	if len(aRows) != 1 || aRows[0].ID != "m1" {
		t.Fatalf("account A rows: %+v", aRows)
	}

	bRows, err := database.GmailMessagesSyncedAfter(accountB, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("account B query: %v", err)
	}
	if len(bRows) != 0 {
		t.Fatalf("account B rows should be empty (A's sync must not leak into B), got: %+v", bRows)
	}
}

// TestSyncAuthErrorMarksOnlyOwnAccount proves an auth failure syncing account
// A records revoked status only on A's google_accounts row, leaving B's
// status untouched.
func TestSyncAuthErrorMarksOnlyOwnAccount(t *testing.T) {
	tokenCalls := 0
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tokenCalls++
		if tokenCalls == 1 {
			// NewClient's initial token exchange must succeed so the Syncer
			// can be constructed; the failure is simulated on Sync's
			// mid-request re-auth below.
			fmt.Fprint(w, `{"access_token":"at"}`)
			return
		}
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprint(w, `{"error":"invalid_grant"}`)
	}))
	defer tokenSrv.Close()

	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	oldBase, oldTok := gmailAPIBase, googleTokenEndpoint
	gmailAPIBase, googleTokenEndpoint = srv.URL, tokenSrv.URL
	defer func() { gmailAPIBase, googleTokenEndpoint = oldBase, oldTok }()

	database := db.OpenTestDB(t)
	if err := database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test.slack.com"}); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
	accountA, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	if err != nil {
		t.Fatalf("seeding google account A: %v", err)
	}
	accountB, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "b@x.com", Label: "B"})
	if err != nil {
		t.Fatalf("seeding google account B: %v", err)
	}
	cfg := &config.Config{}
	cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 100, MaxBodyBytes: 51200}
	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	s := NewSyncer(c, database, cfg, nil, accountA)
	_, err = s.Sync(context.Background())
	if !errors.Is(err, ErrAuthRevoked) {
		t.Fatalf("Sync error = %v, want ErrAuthRevoked", err)
	}

	accA, err := database.GetGoogleAccount(accountA)
	if err != nil {
		t.Fatalf("get account A: %v", err)
	}
	if accA.Status != "revoked" {
		t.Fatalf("account A status = %q, want %q", accA.Status, "revoked")
	}

	accB, err := database.GetGoogleAccount(accountB)
	if err != nil {
		t.Fatalf("get account B: %v", err)
	}
	if accB.Status != "ok" {
		t.Fatalf("account B status = %q, want %q (untouched by A's auth failure)", accB.Status, "ok")
	}
}

// TestRecordAuthResultSkipsCancelledContext guards the daemon-shutdown path:
// when the sync's own context is cancelled (SIGTERM), the resulting HTTP
// error is a shutdown artifact, not an auth problem, and must not flip a
// healthy account into "error".
func TestRecordAuthResultSkipsCancelledContext(t *testing.T) {
	database := db.OpenTestDB(t)
	accountID, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	if err != nil {
		t.Fatalf("seeding google account: %v", err)
	}
	s := NewSyncer(nil, database, &config.Config{}, nil, accountID)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	s.recordAuthResult(ctx, errors.New("gmail GET /users/me/messages: terminated signal received"))

	acc, err := database.GetGoogleAccount(accountID)
	if err != nil {
		t.Fatalf("get account: %v", err)
	}
	if acc.Status != "ok" {
		t.Fatalf("account status = %q, want %q (cancelled ctx must not flip auth state)", acc.Status, "ok")
	}
	if acc.Error != "" {
		t.Fatalf("account error = %q, want empty", acc.Error)
	}
}

// TestRecordAuthResultLiveContext pins the existing behavior on a live
// context: a generic error records "error", and a subsequent nil result
// clears it back to "ok".
func TestRecordAuthResultLiveContext(t *testing.T) {
	database := db.OpenTestDB(t)
	accountID, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	if err != nil {
		t.Fatalf("seeding google account: %v", err)
	}
	s := NewSyncer(nil, database, &config.Config{}, nil, accountID)

	s.recordAuthResult(context.Background(), errors.New("boom"))
	acc, err := database.GetGoogleAccount(accountID)
	if err != nil {
		t.Fatalf("get account: %v", err)
	}
	if acc.Status != "error" {
		t.Fatalf("account status = %q, want %q", acc.Status, "error")
	}
	if !strings.Contains(acc.Error, "boom") {
		t.Fatalf("account error = %q, want it to contain %q", acc.Error, "boom")
	}

	s.recordAuthResult(context.Background(), nil)
	acc, err = database.GetGoogleAccount(accountID)
	if err != nil {
		t.Fatalf("get account: %v", err)
	}
	if acc.Status != "ok" {
		t.Fatalf("account status = %q, want %q after nil result", acc.Status, "ok")
	}
	if acc.Error != "" {
		t.Fatalf("account error = %q, want empty after nil result", acc.Error)
	}
}

// TestSyncStopsWatermarkAtFirstFailureButStillStoresLaterMessages ports the
// IMAP guard of the same name. Messages are processed oldest-first, so a
// transient failure on a middle message must freeze the watermark at the last
// message actually stored before it: advancing past the gap makes that message
// permanently unreachable, because the next cycle's after:<watermark> query and
// the already-seen filter both exclude it.
func TestSyncStopsWatermarkAtFirstFailureButStillStoresLaterMessages(t *testing.T) {
	const t1Unix = 1700000000 // oldest, stored
	const t2Unix = 1700003600 // middle, fetch fails
	const t3Unix = 1700007200 // newest, stored

	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		// Gmail returns newest-first; the syncer reverses to oldest-first.
		fmt.Fprint(w, `{"messages":[{"id":"m3"},{"id":"m2"},{"id":"m1"}]}`)
	})
	mux.HandleFunc("/users/me/messages/m1", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"id":"m1","threadId":"t1","labelIds":["INBOX"],"snippet":"one",
          "internalDate":"%d000","payload":{"headers":[{"name":"Subject","value":"One"}]}}`, t1Unix)
	})
	mux.HandleFunc("/users/me/messages/m2", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"error":"backend error"}`, http.StatusInternalServerError)
	})
	mux.HandleFunc("/users/me/messages/m3", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"id":"m3","threadId":"t3","labelIds":["INBOX"],"snippet":"three",
          "internalDate":"%d000","payload":{"headers":[{"name":"Subject","value":"Three"}]}}`, t3Unix)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"access_token":"at"}`)
	}))
	defer tokenSrv.Close()
	oldBase, oldTok := gmailAPIBase, googleTokenEndpoint
	gmailAPIBase, googleTokenEndpoint = srv.URL, tokenSrv.URL
	defer func() { gmailAPIBase, googleTokenEndpoint = oldBase, oldTok }()

	database := db.OpenTestDB(t)
	if err := database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test.slack.com"}); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
	accountID, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	if err != nil {
		t.Fatalf("seeding google account: %v", err)
	}
	cfg := &config.Config{}
	cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 100, MaxBodyBytes: 51200}
	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	s := NewSyncer(c, database, cfg, nil, accountID)

	n, err := s.Sync(context.Background())
	if err != nil {
		t.Fatalf("Sync: %v", err) // a per-message failure stays a nil return
	}
	if n != 2 {
		t.Fatalf("want 2 stored (m1 and m3), got %d", n)
	}

	watermark, err := database.GetGmailAccountWatermark(accountID)
	if err != nil {
		t.Fatalf("watermark: %v", err)
	}
	// Stop below the failure, not at m3: the lost message's date is unknown
	// and could share m1's second, so the watermark holds one second below it.
	if watermark != float64(t1Unix-1) {
		t.Errorf("watermark = %v, want %v (stop below the failure's possible second, not %v)", watermark, t1Unix-1, t3Unix)
	}

	rows, err := database.GmailMessagesSyncedAfter(accountID, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("query gmail_messages: %v", err)
	}
	stored := map[string]bool{}
	for _, r := range rows {
		stored[r.ID] = true
	}
	if !stored["m3"] {
		t.Error("want m3 stored (later successes in the batch still persist) despite the watermark not advancing past it")
	}
	if stored["m2"] {
		t.Error("m2 must not be stored — its fetch failed")
	}
	if len(rows) != 2 {
		t.Errorf("want exactly 2 stored rows, got %d: %+v", len(rows), rows)
	}
}

// newTestSyncerForMux wires the shared Gmail/token httptest fakes around mux
// and returns a syncer with its own temp database and account.
func newTestSyncerForMux(t *testing.T, mux *http.ServeMux) (*Syncer, *db.DB, int64) {
	t.Helper()
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"access_token":"at"}`)
	}))
	t.Cleanup(tokenSrv.Close)
	oldBase, oldTok := gmailAPIBase, googleTokenEndpoint
	gmailAPIBase, googleTokenEndpoint = srv.URL, tokenSrv.URL
	t.Cleanup(func() { gmailAPIBase, googleTokenEndpoint = oldBase, oldTok })

	database := db.OpenTestDB(t)
	if err := database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test.slack.com"}); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
	accountID, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", Label: "A"})
	if err != nil {
		t.Fatalf("seeding google account: %v", err)
	}
	cfg := &config.Config{}
	cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 100, MaxBodyBytes: 51200}
	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	return NewSyncer(c, database, cfg, nil, accountID), database, accountID
}

// TestSyncDeliberateSkipsDoNotStallWatermark is the inverse of the
// stop-at-first-failure guard: the two skips that are *correct* non-storage —
// a noise-labelled message and an already-seen one — must NOT freeze the
// watermark. Both fixtures put the skipped message BEFORE a stored one in
// oldest-first order, so treating the skip as a loss would be observable:
// the watermark would stay behind the newest stored message, and since the
// same message is skipped on every cycle the account would stop ingesting
// mail permanently while still reporting success.
func TestSyncDeliberateSkipsDoNotStallWatermark(t *testing.T) {
	const oldUnix = 1700000000 // skipped
	const newUnix = 1700003600 // stored, one hour later

	t.Run("noise label", func(t *testing.T) {
		mux := http.NewServeMux()
		mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
			fmt.Fprint(w, `{"messages":[{"id":"mNew"},{"id":"mPromo"}]}`) // newest-first
		})
		mux.HandleFunc("/users/me/messages/mPromo", func(w http.ResponseWriter, r *http.Request) {
			fmt.Fprintf(w, `{"id":"mPromo","threadId":"t1","labelIds":["INBOX","CATEGORY_PROMOTIONS"],
              "snippet":"promo","internalDate":"%d000","payload":{"headers":[]}}`, oldUnix)
		})
		mux.HandleFunc("/users/me/messages/mNew", func(w http.ResponseWriter, r *http.Request) {
			fmt.Fprintf(w, `{"id":"mNew","threadId":"t2","labelIds":["INBOX"],"snippet":"new",
              "internalDate":"%d000","payload":{"headers":[{"name":"Subject","value":"New"}]}}`, newUnix)
		})
		s, database, accountID := newTestSyncerForMux(t, mux)

		n, err := s.Sync(context.Background())
		if err != nil {
			t.Fatalf("Sync: %v", err)
		}
		if n != 1 {
			t.Fatalf("want 1 stored (the promo message is filtered), got %d", n)
		}
		watermark, err := database.GetGmailAccountWatermark(accountID)
		if err != nil {
			t.Fatalf("watermark: %v", err)
		}
		if watermark != float64(newUnix) {
			t.Errorf("watermark = %v, want %v — a noise-label skip is deliberate non-storage, it must not freeze the watermark", watermark, newUnix)
		}
	})

	t.Run("already seen", func(t *testing.T) {
		mux := http.NewServeMux()
		mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
			fmt.Fprint(w, `{"messages":[{"id":"mNew"},{"id":"mOld"}]}`) // newest-first
		})
		mux.HandleFunc("/users/me/messages/mOld", func(w http.ResponseWriter, r *http.Request) {
			fmt.Fprintf(w, `{"id":"mOld","threadId":"t1","labelIds":["INBOX"],"snippet":"old",
              "internalDate":"%d000","payload":{"headers":[{"name":"Subject","value":"Old"}]}}`, oldUnix)
		})
		mux.HandleFunc("/users/me/messages/mNew", func(w http.ResponseWriter, r *http.Request) {
			fmt.Fprintf(w, `{"id":"mNew","threadId":"t2","labelIds":["INBOX"],"snippet":"new",
              "internalDate":"%d000","payload":{"headers":[{"name":"Subject","value":"New"}]}}`, newUnix)
		})
		s, database, accountID := newTestSyncerForMux(t, mux)
		// mOld sits at the watermark, so the already-seen filter skips it.
		if err := database.SetGmailAccountWatermark(accountID, float64(oldUnix)); err != nil {
			t.Fatalf("seeding watermark: %v", err)
		}

		n, err := s.Sync(context.Background())
		if err != nil {
			t.Fatalf("Sync: %v", err)
		}
		if n != 1 {
			t.Fatalf("want 1 stored (mOld is already seen), got %d", n)
		}
		watermark, err := database.GetGmailAccountWatermark(accountID)
		if err != nil {
			t.Fatalf("watermark: %v", err)
		}
		if watermark != float64(newUnix) {
			t.Errorf("watermark = %v, want %v — an already-seen skip is deliberate non-storage, it must not freeze the watermark", watermark, newUnix)
		}
	})
}

// TestSyncNoiseSkipAdvancesWatermark pins that a noise-labelled message the
// syncer deliberately drops still moves the watermark past itself: otherwise
// every promo/social message newer than the last stored one is listed and
// re-fetched (format=full) on every cycle, and a window whose oldest
// MaxMessagesPerSync ids are all noise never advances at all. The message is
// still not stored. A noise message AFTER a lost one must not advance past the
// gap (the stalled rule applies to every advance, not only stored messages).
func TestSyncNoiseSkipAdvancesWatermark(t *testing.T) {
	const realUnix = 1700000000  // stored
	const promoUnix = 1700003600 // noise, newest

	realMsg := func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, `{"id":"mReal","threadId":"t1","labelIds":["INBOX"],"snippet":"real",
          "internalDate":"%d000","payload":{"headers":[{"name":"Subject","value":"Real"}]}}`, realUnix)
	}
	promo := func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, `{"id":"mPromo","threadId":"t2","labelIds":["INBOX","CATEGORY_SOCIAL"],
          "snippet":"promo","internalDate":"%d000","payload":{"headers":[]}}`, promoUnix)
	}

	t.Run("noise newest advances", func(t *testing.T) {
		mux := http.NewServeMux()
		mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
			fmt.Fprint(w, `{"messages":[{"id":"mPromo"},{"id":"mReal"}]}`) // newest-first
		})
		mux.HandleFunc("/users/me/messages/mReal", realMsg)
		mux.HandleFunc("/users/me/messages/mPromo", promo)
		s, database, accountID := newTestSyncerForMux(t, mux)

		n, err := s.Sync(context.Background())
		if err != nil {
			t.Fatalf("Sync: %v", err)
		}
		if n != 1 {
			t.Fatalf("want 1 stored (the social message is filtered), got %d", n)
		}
		watermark, err := database.GetGmailAccountWatermark(accountID)
		if err != nil {
			t.Fatalf("watermark: %v", err)
		}
		if watermark != float64(promoUnix) {
			t.Errorf("watermark = %v, want %v — a skipped noise message must still move the watermark past itself", watermark, promoUnix)
		}
		rows, err := database.GmailMessagesSyncedAfter(accountID, "2000-01-01T00:00:00Z")
		if err != nil {
			t.Fatalf("query gmail_messages: %v", err)
		}
		for _, r := range rows {
			if r.ID == "mPromo" {
				t.Error("noise message must not be stored")
			}
		}
	})

	t.Run("noise after a loss does not advance past the gap", func(t *testing.T) {
		mux := http.NewServeMux()
		mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
			fmt.Fprint(w, `{"messages":[{"id":"mPromo"},{"id":"mFail"},{"id":"mReal"}]}`)
		})
		mux.HandleFunc("/users/me/messages/mReal", realMsg)
		mux.HandleFunc("/users/me/messages/mFail", func(w http.ResponseWriter, r *http.Request) {
			http.Error(w, `{"error":"backend error"}`, http.StatusInternalServerError)
		})
		mux.HandleFunc("/users/me/messages/mPromo", promo)
		s, database, accountID := newTestSyncerForMux(t, mux)

		if _, err := s.Sync(context.Background()); err != nil {
			t.Fatalf("Sync: %v", err)
		}
		watermark, err := database.GetGmailAccountWatermark(accountID)
		if err != nil {
			t.Fatalf("watermark: %v", err)
		}
		// The lost message's date is unknown and may share realUnix, so the
		// watermark holds one second below it; re-listing realUnix only
		// re-upserts the already-stored message.
		if watermark != float64(realUnix-1) {
			t.Errorf("watermark = %v, want %v — must stop below the lost message's possible second", watermark, realUnix-1)
		}
	})
}

// A noise message advances maxSeen to second s0, then a real message in the
// same second is lost: the watermark must not stay on s0, or the next
// cycle's after:s0 query excludes the lost message for good.
func TestSyncNoiseThenLossInTheSameSecond(t *testing.T) {
	const s0 = 1700000000
	var failOnce atomic.Bool
	failOnce.Store(true)
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Query().Get("q"), fmt.Sprintf("after:%d", s0)) {
			fmt.Fprint(w, `{"messages":[]}`) // after:s0 excludes both
			return
		}
		fmt.Fprint(w, `{"messages":[{"id":"mLost"},{"id":"mNoise"}]}`) // newest-first
	})
	mux.HandleFunc("/users/me/messages/mNoise", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, `{"id":"mNoise","threadId":"t1","labelIds":["INBOX","CATEGORY_PROMOTIONS"],
	          "snippet":"promo","internalDate":"%d000","payload":{"headers":[]}}`, s0)
	})
	mux.HandleFunc("/users/me/messages/mLost", func(w http.ResponseWriter, _ *http.Request) {
		if failOnce.Swap(false) {
			http.Error(w, `{"error":"backend error"}`, http.StatusInternalServerError)
			return
		}
		fmt.Fprintf(w, `{"id":"mLost","threadId":"t2","labelIds":["INBOX"],"snippet":"real",
	          "internalDate":"%d000","payload":{"headers":[{"name":"Subject","value":"Real"}]}}`, s0)
	})
	s, _, _ := newTestSyncerForMux(t, mux)

	if _, err := s.Sync(context.Background()); err != nil {
		t.Fatalf("first Sync: %v", err)
	}
	n, err := s.Sync(context.Background())
	if err != nil {
		t.Fatalf("second Sync: %v", err)
	}
	if n != 1 {
		t.Fatalf("the message lost in the noise's second must be stored on the next cycle, got %d stored", n)
	}
}

// capTieMux serves a mailbox whose list honours after:<unix> (strictly newer)
// and answers newest-first; msgs is oldest-first. failMinimal makes the
// format=minimal GET the syncer uses for the cut-off message fail.
func capTieMux(t *testing.T, msgs []capTieMsg, failMinimal bool) *http.ServeMux {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		var after int64 = -1
		if q := r.URL.Query().Get("q"); strings.Contains(q, "after:") {
			_, err := fmt.Sscanf(q[strings.Index(q, "after:"):], "after:%d", &after)
			if err != nil {
				t.Errorf("parsing query %q: %v", q, err)
			}
		}
		var ids []string
		for i := len(msgs) - 1; i >= 0; i-- {
			if msgs[i].unix > after {
				ids = append(ids, fmt.Sprintf(`{"id":%q}`, msgs[i].id))
			}
		}
		fmt.Fprintf(w, `{"messages":[%s]}`, strings.Join(ids, ","))
	})
	for _, m := range msgs {
		mux.HandleFunc("/users/me/messages/"+m.id, func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Query().Get("format") == "minimal" {
				if failMinimal {
					http.Error(w, `{"error":"backend error"}`, http.StatusInternalServerError)
					return
				}
				// Gmail documents format=minimal as "id and labels only", so
				// the date must be asked for with an explicit fields projection.
				if r.URL.Query().Get("fields") != "internalDate" {
					fmt.Fprintf(w, `{"id":%q,"labelIds":["INBOX"]}`, m.id)
					return
				}
				fmt.Fprintf(w, `{"internalDate":"%d000"}`, m.unix)
				return
			}
			labels := `"INBOX"`
			if m.noise {
				labels += `,"CATEGORY_PROMOTIONS"`
			}
			fmt.Fprintf(w, `{"id":%q,"threadId":"t-%s","labelIds":[%s],"snippet":"s",
              "internalDate":"%d000","payload":{"headers":[{"name":"Subject","value":%q}]}}`, m.id, m.id, labels, m.unix, m.id)
		})
	}
	return mux
}

type capTieMsg struct {
	id    string
	unix  int64
	noise bool
}

// TestSyncCapTieDoesNotLoseSameSecondMessage: when the processing cap cuts
// the oldest-first list between two messages sharing one second, the
// watermark must stay strictly below that second — otherwise the next
// cycle's after:<watermark> query and the already-seen filter both exclude
// the cut-off message forever. Both a processed noise message and a stored
// real one sit at the tied second. If the cut-off message's date cannot be
// read, the watermark stays one second below the last processed one.
func TestSyncCapTieDoesNotLoseSameSecondMessage(t *testing.T) {
	const early, tie = 1700000000, 1700003600
	msgs := []capTieMsg{
		{id: "m1", unix: early},
		{id: "mPromo", unix: tie, noise: true},
		{id: "m3", unix: tie},
		{id: "mCut", unix: tie}, // first message past the cap
	}
	for _, failMinimal := range []bool{false, true} {
		t.Run(fmt.Sprintf("cutoff lookup fails=%v", failMinimal), func(t *testing.T) {
			s, database, accountID := newTestSyncerForMux(t, capTieMux(t, msgs, failMinimal))
			s.cfg.Gmail.MaxMessagesPerSync = 3

			if _, err := s.Sync(context.Background()); err != nil {
				t.Fatalf("first Sync: %v", err)
			}
			watermark, err := database.GetGmailAccountWatermark(accountID)
			if err != nil {
				t.Fatalf("watermark: %v", err)
			}
			if watermark != float64(tie-1) {
				t.Fatalf("watermark = %v, want %v — must stay below the second the cap cut", watermark, tie-1)
			}
			if _, err := s.Sync(context.Background()); err != nil {
				t.Fatalf("second Sync: %v", err)
			}
			rows, err := database.GmailMessagesSyncedAfter(accountID, "2000-01-01T00:00:00Z")
			if err != nil {
				t.Fatalf("query: %v", err)
			}
			stored := map[string]bool{}
			for _, r := range rows {
				stored[r.ID] = true
			}
			if !stored["mCut"] || !stored["m3"] || !stored["m1"] || stored["mPromo"] {
				t.Fatalf("stored = %v, want m1, m3 and the cut-off mCut, never the promo", stored)
			}
		})
	}
}

// A stored message and a message whose upsert fails in the same second: the
// watermark must hold below that second so the failed one is retried.
func TestSyncUpsertLossHoldsWatermarkBelowItsSecond(t *testing.T) {
	const s0 = 1700000000
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"messages":[{"id":"mB"},{"id":"mA"}]}`) // newest-first
	})
	for _, id := range []string{"mA", "mB"} {
		mux.HandleFunc("/users/me/messages/"+id, func(w http.ResponseWriter, _ *http.Request) {
			fmt.Fprintf(w, `{"id":%q,"threadId":"t-%s","labelIds":["INBOX"],"snippet":"s",
          "internalDate":"%d000","payload":{"headers":[{"name":"Subject","value":%q}]}}`, id, id, s0, id)
		})
	}
	s, database, accountID := newTestSyncerForMux(t, mux)
	if _, err := database.Exec(`CREATE TRIGGER fail_mb BEFORE INSERT ON gmail_messages
		WHEN NEW.id = 'mB' BEGIN SELECT RAISE(ABORT, 'injected'); END`); err != nil {
		t.Fatal(err)
	}

	if _, err := s.Sync(context.Background()); err != nil {
		t.Fatalf("Sync: %v", err)
	}
	watermark, err := database.GetGmailAccountWatermark(accountID)
	if err != nil {
		t.Fatalf("watermark: %v", err)
	}
	if watermark != float64(s0-1) {
		t.Fatalf("watermark = %v, want %v — a same-second upsert loss must not be excluded next cycle", watermark, s0-1)
	}
}
