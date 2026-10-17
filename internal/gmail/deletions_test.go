package gmail

import (
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
)

type listRecorder struct {
	mu      sync.Mutex
	queries []string
}

func (r *listRecorder) add(q string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.queries = append(r.queries, q)
}

func (r *listRecorder) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.queries)
}

func seedMail(t *testing.T, d *db.DB, acct int64, ids ...string) {
	t.Helper()
	for _, id := range ids {
		m := db.GmailMessage{ID: id, ThreadID: "th-" + id, InternalDate: "2026-10-10T10:00:00Z",
			ToJSON: "[]", CcJSON: "[]", LabelsJSON: "[]", SyncedAt: "2026-10-10T10:00:00Z"}
		if err := d.UpsertGmailMessage(acct, m); err != nil {
			t.Fatal(err)
		}
	}
}

func countMail(t *testing.T, d *db.DB, acct int64) int {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM gmail_messages WHERE account_id = ?`, acct).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func listMux(rec *listRecorder, listed []string, before func()) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		q, _ := url.QueryUnescape(r.URL.Query().Get("q"))
		rec.add(q)
		if before != nil {
			before()
		}
		var parts []string
		for _, id := range listed {
			parts = append(parts, fmt.Sprintf(`{"id":%q}`, id))
		}
		fmt.Fprintf(w, `{"messages":[%s]}`, strings.Join(parts, ","))
	})
	return mux
}

func TestCheckDeletions_RemovesUnlistedMessage(t *testing.T) {
	rec := &listRecorder{}
	s, d, acct := newTestSyncerForMux(t, listMux(rec, []string{"m1", "m2", "m3"}, nil))
	seedMail(t, d, acct, "m1", "m2", "m3", "m4")
	n, err := s.CheckDeletions(t.Context(), time.Now())
	if err != nil || n != 1 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	if countMail(t, d, acct) != 3 {
		t.Fatal("m4 should be gone")
	}
	q := rec.queries[0]
	if !strings.Contains(q, "-in:trash -in:spam") || strings.Contains(q, "in:inbox") {
		t.Fatalf("query %q", q)
	}
}

func TestCheckDeletions_RunsOncePerDay(t *testing.T) {
	rec := &listRecorder{}
	s, d, acct := newTestSyncerForMux(t, listMux(rec, []string{"m1"}, nil))
	seedMail(t, d, acct, "m1")
	now := time.Now()
	if _, err := s.CheckDeletions(t.Context(), now); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CheckDeletions(t.Context(), now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if rec.count() != 1 {
		t.Fatalf("lists after 1h: %d", rec.count())
	}
	if _, err := s.CheckDeletions(t.Context(), now.Add(25*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if rec.count() != 2 {
		t.Fatalf("lists after 25h: %d", rec.count())
	}
}

func TestCheckDeletions_EmptyListingDeletesNothing(t *testing.T) {
	rec := &listRecorder{}
	s, d, acct := newTestSyncerForMux(t, listMux(rec, nil, nil))
	seedMail(t, d, acct, "m1", "m2", "m3")
	n, err := s.CheckDeletions(t.Context(), time.Now())
	if err != nil || n != 0 || countMail(t, d, acct) != 3 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	if at, _ := d.GmailDeletionsCheckedAt(acct); at.IsZero() {
		t.Fatal("stamp expected")
	}
}

func TestCheckDeletions_OverHalfDeletesNothing(t *testing.T) {
	rec := &listRecorder{}
	s, d, acct := newTestSyncerForMux(t, listMux(rec, []string{"m1"}, nil))
	seedMail(t, d, acct, "m1", "m2", "m3", "m4")
	n, err := s.CheckDeletions(t.Context(), time.Now())
	if err != nil || n != 0 || countMail(t, d, acct) != 4 {
		t.Fatalf("n=%d err=%v", n, err)
	}
}

func TestCheckDeletions_ListErrorKeepsRowsAndRetries(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	})
	s, d, acct := newTestSyncerForMux(t, mux)
	seedMail(t, d, acct, "m1", "m2")
	n, err := s.CheckDeletions(t.Context(), time.Now())
	if err == nil || n != 0 || countMail(t, d, acct) != 2 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	if at, _ := d.GmailDeletionsCheckedAt(acct); !at.IsZero() {
		t.Fatal("no stamp expected")
	}
}

func TestCheckDeletions_ReadsStoredSetBeforeListing(t *testing.T) {
	rec := &listRecorder{}
	var s *Syncer
	var d *db.DB
	var acct int64
	mux := listMux(rec, []string{"m1", "m2", "m3"}, func() { seedMail(t, d, acct, "mNew") })
	s, d, acct = newTestSyncerForMux(t, mux)
	seedMail(t, d, acct, "m1", "m2", "m3")
	if n, err := s.CheckDeletions(t.Context(), time.Now()); err != nil || n != 0 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	if countMail(t, d, acct) != 4 {
		t.Fatal("mail arriving during the listing must survive")
	}
}

func TestCheckDeletions_ScopedToAccount(t *testing.T) {
	rec := &listRecorder{}
	s, d, acct := newTestSyncerForMux(t, listMux(rec, []string{"m1", "m2", "m3"}, nil))
	other, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "b@example.com", Label: "B"})
	if err != nil {
		t.Fatal(err)
	}
	seedMail(t, d, acct, "m1", "m2", "m3", "m4")
	seedMail(t, d, other, "m4", "x1")
	if n, err := s.CheckDeletions(t.Context(), time.Now()); err != nil || n != 1 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	if countMail(t, d, other) != 2 {
		t.Fatal("other account touched")
	}
}
