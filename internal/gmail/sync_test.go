package gmail

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

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
