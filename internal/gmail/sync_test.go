package gmail

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
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
	cfg := &config.Config{}
	cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 100, MaxBodyBytes: 51200}
	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	s := NewSyncer(c, database, cfg, nil)
	n, err := s.Sync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("want 1 synced (promotions skipped), got %d", n)
	}
	rows, err := database.GmailMessagesSyncedAfter("2000-01-01T00:00:00Z")
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
	cfg := &config.Config{}
	cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 100, MaxBodyBytes: 51200}
	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	s := NewSyncer(c, database, cfg, nil)
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
	rows, err := database.GmailMessagesSyncedAfter("2000-01-01T00:00:00Z")
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
		newFetched = true
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
	cfg := &config.Config{}
	cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 1, MaxBodyBytes: 51200}
	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	s := NewSyncer(c, database, cfg, nil)
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
	rows, err := database.GmailMessagesSyncedAfter("2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(rows) != 1 || rows[0].ID != "mOld" {
		t.Fatalf("expected only the oldest message stored, got: %+v", rows)
	}
	watermark, err := database.GetGmailLastInternalDate()
	if err != nil {
		t.Fatalf("watermark: %v", err)
	}
	if watermark != float64(oldUnix) {
		t.Fatalf("watermark = %v, want %v (oldest processed, not newest)", watermark, oldUnix)
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
	cfg := &config.Config{}
	cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 100, MaxBodyBytes: 7}
	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	s := NewSyncer(c, database, cfg, nil)
	if _, err := s.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	rows, err := database.GmailMessagesSyncedAfter("2000-01-01T00:00:00Z")
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
	if err := database.SetGmailLastInternalDate(1700000000); err != nil {
		t.Fatalf("seeding watermark: %v", err)
	}
	cfg := &config.Config{}
	cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 100, MaxBodyBytes: 51200}
	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatalf("new client: %v", err)
	}
	s := NewSyncer(c, database, cfg, nil)
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
