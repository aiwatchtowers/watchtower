package gmail

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// rangeMux serves n inbox messages (r0..r{n-1}, one second apart) plus one
// promotions message, and records every list query.
func rangeMux(n int, queries *[]string, mu *sync.Mutex) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		*queries = append(*queries, r.URL.Query().Get("q"))
		mu.Unlock()
		ids := `{"id":"promo"}`
		for i := n - 1; i >= 0; i-- { // newest first, like Gmail
			ids += fmt.Sprintf(`,{"id":"r%d"}`, i)
		}
		fmt.Fprintf(w, `{"messages":[%s]}`, ids)
	})
	mux.HandleFunc("/users/me/messages/", func(w http.ResponseWriter, r *http.Request) {
		id := r.URL.Path[len("/users/me/messages/"):]
		if id == "promo" {
			fmt.Fprint(w, `{"id":"promo","threadId":"tp","labelIds":["INBOX","CATEGORY_PROMOTIONS"],
              "snippet":"promo","internalDate":"1758300000000","payload":{"headers":[]}}`)
			return
		}
		var i int
		if _, err := fmt.Sscanf(id, "r%d", &i); err != nil {
			http.NotFound(w, r)
			return
		}
		fmt.Fprintf(w, `{"id":"r%d","threadId":"t%d","labelIds":["INBOX"],"snippet":"s",
          "internalDate":"%d","payload":{"headers":[{"name":"Subject","value":"Hi"},
          {"name":"From","value":"a@example.com"}],"parts":[{"mimeType":"text/plain","body":{"data":""}}]}}`,
			i, i, (int64(1758300000)+int64(i))*1000)
	})
	return mux
}

func TestFetchRange_StoresAllInRangeWithoutWatermarkOrAuthState(t *testing.T) {
	var queries []string
	var mu sync.Mutex
	s, database, accountID := newTestSyncerForMux(t, rangeMux(5, &queries, &mu))
	s.cfg.Gmail.MaxMessagesPerSync = 2 // the range fetch ignores the per-cycle cap
	if err := database.SetGoogleAccountAuthState(accountID, "error", "prior"); err != nil {
		t.Fatal(err)
	}

	from := time.Date(2026, 9, 19, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 9, 21, 0, 0, 0, 0, time.UTC)
	n, err := s.FetchRange(context.Background(), from, to)
	if err != nil {
		t.Fatal(err)
	}
	if n != 5 {
		t.Fatalf("saved = %d, want 5 (uncapped, promo skipped)", n)
	}
	want := fmt.Sprintf("in:inbox after:%d before:%d", from.Unix(), to.Unix())
	if len(queries) != 1 || queries[0] != want {
		t.Fatalf("queries = %q, want [%q]", queries, want)
	}
	rows, err := database.GmailMessagesSyncedAfter(accountID, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 5 {
		t.Fatalf("stored %d rows, want 5", len(rows))
	}
	wm, err := database.GetGmailAccountWatermark(accountID)
	if err != nil {
		t.Fatal(err)
	}
	if wm != 0 {
		t.Fatalf("watermark = %v, want 0 (a range fetch never moves it)", wm)
	}
	acc, err := database.GetGoogleAccount(accountID)
	if err != nil {
		t.Fatal(err)
	}
	if acc.Status != "error" || acc.Error != "prior" {
		t.Fatalf("auth state = %q/%q, want untouched error/prior", acc.Status, acc.Error)
	}
	if _, ok := s.FirstSyncFrom(); ok {
		t.Fatal("a range fetch is not a first sync")
	}
	if s.AccountID() != accountID {
		t.Fatalf("AccountID() = %d, want %d", s.AccountID(), accountID)
	}
}

func TestFetchRange_RevokedAuthStaysMatchable(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	})
	s, database, accountID := newTestSyncerForMux(t, mux)
	// NewClient's token exchange succeeded inside newTestSyncerForMux; the
	// mid-request re-auth now fails the way a revoked grant does.
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprint(w, `{"error":"invalid_grant"}`)
	}))
	t.Cleanup(tokenSrv.Close)
	googleTokenEndpoint = tokenSrv.URL // newTestSyncerForMux's cleanup restores it
	_, err := s.FetchRange(context.Background(), time.Unix(1758200000, 0), time.Unix(1758300000, 0))
	if !errors.Is(err, ErrAuthRevoked) {
		t.Fatalf("err = %v, want ErrAuthRevoked", err)
	}
	acc, gerr := database.GetGoogleAccount(accountID)
	if gerr != nil {
		t.Fatal(gerr)
	}
	if acc.Status != "ok" {
		t.Fatalf("status = %q, want ok (a range fetch records no auth state)", acc.Status)
	}
}

func TestSync_FirstSyncFrom(t *testing.T) {
	var queries []string
	var mu sync.Mutex
	s, database, accountID := newTestSyncerForMux(t, rangeMux(0, &queries, &mu)) // only the promo: nothing stored

	before := time.Now()
	if _, err := s.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	from, ok := s.FirstSyncFrom()
	if !ok {
		t.Fatal("a successful list with watermark 0 is a first sync, even when nothing was stored")
	}
	want := before.AddDate(0, 0, -s.cfg.Gmail.InitialHistoryDays)
	if d := from.Sub(want); d < -time.Second || d > time.Second {
		t.Fatalf("FirstSyncFrom = %v, want ≈ %v", from, want)
	}

	if err := database.SetGmailAccountWatermark(accountID, 1758300000); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.FirstSyncFrom(); ok {
		t.Fatal("a sync with a watermark is not a first sync")
	}
}

func TestSync_FirstSyncFromFalseOnListFailure(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	})
	s, _, _ := newTestSyncerForMux(t, mux)
	if _, err := s.Sync(context.Background()); err == nil {
		t.Fatal("want a list error")
	}
	if _, ok := s.FirstSyncFrom(); ok {
		t.Fatal("a failed list is not a first sync")
	}
}

// Backfilled mail keeps its own date as synced_at, so the inbox detector's
// synced_at cursor (GmailMessagesSyncedAfter) never sees it as new mail;
// a row the forward Sync stores is still stamped now.
func TestFetchRange_SyncedAtIsTheMessagesOwnDate(t *testing.T) {
	var queries []string
	var mu sync.Mutex
	s, database, accountID := newTestSyncerForMux(t, rangeMux(5, &queries, &mu))
	cursor := time.Now().Add(-time.Minute).UTC().Format(time.RFC3339)

	if _, err := s.FetchRange(context.Background(), time.Unix(1758200000, 0), time.Unix(1758400000, 0)); err != nil {
		t.Fatal(err)
	}
	rows, err := database.GmailMessagesSyncedAfter(accountID, cursor)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Fatalf("backfilled rows visible to the inbox cursor: %d", len(rows))
	}
	all, err := database.GmailMessagesSyncedAfter(accountID, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 5 {
		t.Fatalf("stored %d rows, want 5", len(all))
	}
	for _, r := range all {
		if r.SyncedAt != r.InternalDate {
			t.Fatalf("row %s synced_at = %q, want its internal date %q", r.ID, r.SyncedAt, r.InternalDate)
		}
	}

	// The forward Sync stores the two messages past the watermark with now.
	if err := database.SetGmailAccountWatermark(accountID, 1758300002); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	rows, err = database.GmailMessagesSyncedAfter(accountID, cursor)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[0].ID != "r3" || rows[1].ID != "r4" {
		t.Fatalf("rows after Sync = %+v, want r3 and r4", rows)
	}
}

func TestBackfillSyncedAtFallsBackToRangeStart(t *testing.T) {
	from := time.Date(2026, 9, 20, 0, 0, 0, 0, time.FixedZone("x", 3600))
	if got := backfillSyncedAt("", from); got != "2026-09-19T23:00:00Z" {
		t.Fatalf("empty date: got %q", got)
	}
	if got := backfillSyncedAt("garbage", from); got != "2026-09-19T23:00:00Z" {
		t.Fatalf("bad date: got %q", got)
	}
	if got := backfillSyncedAt("2026-09-21T10:00:00+02:00", from); got != "2026-09-21T08:00:00Z" {
		t.Fatalf("own date: got %q", got)
	}
}
