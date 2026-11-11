package gmail

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/db"
)

// catchUpServer is a fake Gmail API for CatchUpSent: it lists ids under any
// query (recording each), serves every id as a sent message dated a minute
// apart from two hours ago, and lets a test answer one id differently.
type catchUpServer struct {
	mu       sync.Mutex
	queries  []string
	requests atomic.Int32
	ids      []string
	labels   map[string]string                           // id → labelIds JSON; default ["SENT"]
	answer   func(id string, w http.ResponseWriter) bool // true = handled
	base     time.Time
}

func newCatchUpServer(ids ...string) *catchUpServer {
	return &catchUpServer{ids: ids, labels: map[string]string{}, base: time.Now().Add(-2 * time.Hour).Truncate(time.Second)}
}

func (c *catchUpServer) date(i int) time.Time { return c.base.Add(-time.Duration(i) * time.Minute) }

func (c *catchUpServer) mux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		c.requests.Add(1)
		c.mu.Lock()
		c.queries = append(c.queries, r.URL.Query().Get("q"))
		c.mu.Unlock()
		list := ""
		for i, id := range c.ids {
			if i > 0 {
				list += ","
			}
			list += fmt.Sprintf(`{"id":%q}`, id)
		}
		fmt.Fprintf(w, `{"messages":[%s]}`, list)
	})
	mux.HandleFunc("/users/me/messages/", func(w http.ResponseWriter, r *http.Request) {
		c.requests.Add(1)
		id := r.URL.Path[len("/users/me/messages/"):]
		c.mu.Lock()
		answer := c.answer
		c.mu.Unlock()
		if answer != nil && answer(id, w) {
			return
		}
		for i, known := range c.ids {
			if known != id {
				continue
			}
			labels := c.labels[known]
			if labels == "" {
				labels = `["SENT"]`
			}
			fmt.Fprintf(w, `{"id":%q,"threadId":"thr-%s","labelIds":%s,"snippet":"s","internalDate":"%d",
              "payload":{"headers":[{"name":"From","value":"owner@example.com"},{"name":"To","value":"colleague-a@example.com"},
              {"name":"Subject","value":"Re: plan"}]}}`, known, known, labels, c.date(i).UnixMilli())
			return
		}
		http.NotFound(w, r)
	})
	return mux
}

func (c *catchUpServer) setAnswer(f func(id string, w http.ResponseWriter) bool) {
	c.mu.Lock()
	c.answer = f
	c.mu.Unlock()
}

// newCatchUpSyncer is a syncer over srv whose account already synced once
// (watermark an hour ago) and has no sent catch-up stamp.
func newCatchUpSyncer(t *testing.T, srv *catchUpServer) (*Syncer, *db.DB, int64, float64) {
	t.Helper()
	s, database, accountID := newTestSyncerForMux(t, srv.mux())
	wm := float64(time.Now().Add(-time.Hour).Unix())
	if err := database.SetGmailAccountWatermark(accountID, wm); err != nil {
		t.Fatal(err)
	}
	return s, database, accountID, wm
}

func assertCatchUpStamp(t *testing.T, database *db.DB, accountID int64, want string) {
	t.Helper()
	got, err := database.GmailSentCatchUpAt(accountID)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("sent catch-up stamp = %q, want %q", got, want)
	}
}

func assertWatermark(t *testing.T, database *db.DB, accountID int64, want float64) {
	t.Helper()
	got, err := database.GetGmailAccountWatermark(accountID)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("watermark = %v, want %v (the catch-up never moves it)", got, want)
	}
}

func storedIDs(t *testing.T, database *db.DB, accountID int64) map[string]db.GmailMessage {
	t.Helper()
	rows, err := database.GmailMessagesSyncedAfter(accountID, "2000-01-01T00:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]db.GmailMessage{}
	for _, r := range rows {
		out[r.ID] = r
	}
	return out
}

func TestCatchUpSent_StoresOwnDateAndStamps(t *testing.T) {
	srv := newCatchUpServer("s1", "s2", "s3")
	s, database, accountID, wm := newCatchUpSyncer(t, srv)
	now := time.Now().UTC().Truncate(time.Second)

	n, err := s.CatchUpSent(context.Background(), now)
	if err != nil {
		t.Fatal(err)
	}
	if n != 3 {
		t.Fatalf("stored = %d, want 3", n)
	}
	if want := fmt.Sprintf("in:sent after:%d", now.Add(-7*24*time.Hour).Unix()); len(srv.queries) != 1 || srv.queries[0] != want {
		t.Fatalf("queries = %q, want [%q]", srv.queries, want)
	}
	rows := storedIDs(t, database, accountID)
	if len(rows) != 3 {
		t.Fatalf("stored rows = %d, want 3", len(rows))
	}
	for id, r := range rows {
		if r.SyncedAt != r.InternalDate {
			t.Fatalf("row %s synced_at = %q, want its own date %q", id, r.SyncedAt, r.InternalDate)
		}
	}
	assertCatchUpStamp(t, database, accountID, now.Format(time.RFC3339))
	assertWatermark(t, database, accountID, wm)
}

func TestCatchUpSent_NoopWhenStampedOrFresh(t *testing.T) {
	srv := newCatchUpServer("s1")
	s, database, accountID, _ := newCatchUpSyncer(t, srv)
	if err := database.SetGmailSentCatchUpAt(accountID, time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	if n, err := s.CatchUpSent(context.Background(), time.Now()); n != 0 || err != nil {
		t.Fatalf("stamped: CatchUpSent = %d, %v; want 0, nil", n, err)
	}
	if got := srv.requests.Load(); got != 0 {
		t.Fatalf("stamped: %d HTTP requests, want 0", got)
	}

	fresh, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "alias@example.com", Label: "B"})
	if err != nil {
		t.Fatal(err)
	}
	s2 := NewSyncer(s.client, database, s.cfg, nil, fresh)
	if n, err := s2.CatchUpSent(context.Background(), time.Now()); n != 0 || err != nil {
		t.Fatalf("watermark 0: CatchUpSent = %d, %v; want 0, nil", n, err)
	}
	if got := srv.requests.Load(); got != 0 {
		t.Fatalf("watermark 0: %d HTTP requests, want 0", got)
	}
	assertCatchUpStamp(t, database, fresh, "")
}

func TestCatchUpSent_ErrorLeavesStampAndWatermark(t *testing.T) {
	srv := newCatchUpServer("s1", "s2", "s3")
	s, database, accountID, wm := newCatchUpSyncer(t, srv)
	srv.setAnswer(func(id string, w http.ResponseWriter) bool {
		if id != "s2" {
			return false
		}
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprint(w, `{"error":"bad"}`)
		return true
	})

	if _, err := s.CatchUpSent(context.Background(), time.Now()); err == nil {
		t.Fatal("want the fetch error")
	}
	assertCatchUpStamp(t, database, accountID, "")
	assertWatermark(t, database, accountID, wm)

	srv.setAnswer(nil)
	now := time.Now().UTC().Truncate(time.Second)
	if _, err := s.CatchUpSent(context.Background(), now); err != nil {
		t.Fatal(err)
	}
	assertCatchUpStamp(t, database, accountID, now.Format(time.RFC3339))
	assertWatermark(t, database, accountID, wm)
	if rows := storedIDs(t, database, accountID); len(rows) != 3 {
		t.Fatalf("stored rows = %d, want 3", len(rows))
	}
}

func TestCatchUpSent_SkipsNoiseLabels(t *testing.T) {
	srv := newCatchUpServer("s1", "promo")
	srv.labels["promo"] = `["SENT","CATEGORY_PROMOTIONS"]`
	s, database, accountID, _ := newCatchUpSyncer(t, srv)

	n, err := s.CatchUpSent(context.Background(), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	rows := storedIDs(t, database, accountID)
	if n != 1 || len(rows) != 1 || rows["s1"].ID == "" {
		t.Fatalf("stored %d (%v), want only s1", n, rows)
	}
}

func TestCatchUpSent_GoneMessageSkipped(t *testing.T) {
	srv := newCatchUpServer("s1", "gone", "s3")
	s, database, accountID, _ := newCatchUpSyncer(t, srv)
	srv.setAnswer(func(id string, w http.ResponseWriter) bool {
		if id != "gone" {
			return false
		}
		w.WriteHeader(http.StatusNotFound)
		return true
	})
	now := time.Now().UTC().Truncate(time.Second)

	n, err := s.CatchUpSent(context.Background(), now)
	if err != nil {
		t.Fatalf("a message deleted between list and fetch is skipped, got %v", err)
	}
	rows := storedIDs(t, database, accountID)
	if n != 2 || len(rows) != 2 || rows["gone"].ID != "" {
		t.Fatalf("stored %d (%v), want s1 and s3", n, rows)
	}
	assertCatchUpStamp(t, database, accountID, now.Format(time.RFC3339))
}

func TestCatchUpSent_GivesUpAfterThreeFailures(t *testing.T) {
	srv := newCatchUpServer("s1", "bad")
	s, database, accountID, wm := newCatchUpSyncer(t, srv)
	srv.setAnswer(func(id string, w http.ResponseWriter) bool {
		if id != "bad" {
			return false
		}
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprint(w, `{"error":"invalid"}`)
		return true
	})

	for call := 1; call <= 2; call++ {
		if _, err := s.CatchUpSent(context.Background(), time.Now()); err == nil {
			t.Fatalf("call %d: want the fetch error", call)
		}
		assertCatchUpStamp(t, database, accountID, "")
	}
	third := time.Now().UTC().Truncate(time.Second)
	if _, err := s.CatchUpSent(context.Background(), third); err == nil {
		t.Fatal("call 3: want the fetch error")
	}
	assertCatchUpStamp(t, database, accountID, third.Format(time.RFC3339))

	before := srv.requests.Load()
	if n, err := s.CatchUpSent(context.Background(), time.Now()); n != 0 || err != nil {
		t.Fatalf("call 4: CatchUpSent = %d, %v; want 0, nil", n, err)
	}
	if got := srv.requests.Load(); got != before {
		t.Fatalf("call 4 made %d HTTP requests, want 0", got-before)
	}
	assertWatermark(t, database, accountID, wm)
}

func TestCatchUpSent_TransientFailuresNeverGiveUp(t *testing.T) {
	srv := newCatchUpServer("s1", "flaky")
	s, database, accountID, wm := newCatchUpSyncer(t, srv)
	modes := []string{"429", "503", "drop", "429", "503"}
	for call, mode := range modes {
		srv.setAnswer(func(id string, w http.ResponseWriter) bool {
			if id != "flaky" {
				return false
			}
			switch mode {
			case "429":
				w.WriteHeader(http.StatusTooManyRequests)
			case "503":
				w.WriteHeader(http.StatusServiceUnavailable)
			case "drop":
				conn, _, err := w.(http.Hijacker).Hijack()
				if err == nil {
					_ = conn.Close()
				}
			}
			return true
		})
		if _, err := s.CatchUpSent(context.Background(), time.Now()); err == nil {
			t.Fatalf("call %d (%s): want the fetch error", call+1, mode)
		}
		assertCatchUpStamp(t, database, accountID, "")
	}

	srv.setAnswer(nil)
	now := time.Now().UTC().Truncate(time.Second)
	if _, err := s.CatchUpSent(context.Background(), now); err != nil {
		t.Fatal(err)
	}
	if rows := storedIDs(t, database, accountID); rows["flaky"].ID == "" {
		t.Fatal("the healthy pass did not store the once-flaky message")
	}
	assertCatchUpStamp(t, database, accountID, now.Format(time.RFC3339))
	assertWatermark(t, database, accountID, wm)
}

func TestCatchUpCountsFailure(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		want bool
	}{
		{"400", fmt.Errorf("fetch message x: %w", &StatusError{Code: http.StatusBadRequest}), true},
		{"404 wrapped in another error", fmt.Errorf("upsert x: %w", &StatusError{Code: http.StatusNotFound}), true},
		{"decoding", fmt.Errorf("fetch message x: %w", fmt.Errorf("decoding message: %w", errors.New("unexpected end of JSON input"))), true},
		{"429", fmt.Errorf("fetch message x: %w", &StatusError{Code: http.StatusTooManyRequests}), false},
		{"500", &StatusError{Code: http.StatusInternalServerError}, false},
		{"503", fmt.Errorf("fetch message x: %w", &StatusError{Code: http.StatusServiceUnavailable}), false},
		{"403 rate limit", fmt.Errorf("fetch message x: %w", &StatusError{Code: http.StatusForbidden, Body: `{"reason":"rateLimitExceeded"}`}), false},
		{"net.OpError", fmt.Errorf("fetch message x: %w", &net.OpError{Op: "dial", Err: errors.New("connection refused")}), false},
		{"unexpected EOF", fmt.Errorf("reading response: %w", io.ErrUnexpectedEOF), false},
		{"canceled", fmt.Errorf("fetch message x: %w", context.Canceled), false},
		{"deadline", fmt.Errorf("fetch message x: %w", context.DeadlineExceeded), false},
		{"auth revoked", fmt.Errorf("fetch message x: %w", ErrAuthRevoked), false},
		{"url.Error", fmt.Errorf("fetch message x: %w", &url.Error{Op: "Get", URL: "https://gmail.example.com", Err: errors.New("tls handshake timeout")}), false},
	} {
		if got := catchUpCountsFailure(tc.err); got != tc.want {
			t.Errorf("%s: catchUpCountsFailure = %v, want %v", tc.name, got, tc.want)
		}
	}
}
