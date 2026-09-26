package gmail

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestClientListAndGet(t *testing.T) {
	bodyB64 := base64.URLEncoding.EncodeToString([]byte("hello body"))
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("q") == "" {
			t.Error("missing q")
		}
		fmt.Fprint(w, `{"messages":[{"id":"m1","threadId":"t1"}]}`)
	})
	mux.HandleFunc("/users/me/messages/m1", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"id":"m1","threadId":"t1","labelIds":["INBOX","UNREAD"],
            "snippet":"prev","internalDate":"1720519200000",
            "payload":{"headers":[
                {"name":"From","value":"Alice <a@x.com>"},
                {"name":"To","value":"me@x.com"},
                {"name":"Cc","value":"c@x.com"},
                {"name":"Subject","value":"Hi"}],
              "parts":[{"mimeType":"text/plain","body":{"data":%q}}]}}`, bodyB64)
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

	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatal(err)
	}
	ids, err := c.ListInboxMessageIDs(context.Background(), "in:inbox newer_than:7d", 100)
	if err != nil || len(ids) != 1 || ids[0] != "m1" {
		t.Fatalf("ids=%v err=%v", ids, err)
	}
	m, err := c.GetMessage(context.Background(), "m1")
	if err != nil {
		t.Fatal(err)
	}
	if m.FromEmail != "a@x.com" || m.FromName != "Alice" {
		t.Errorf("from parse: %+v", m)
	}
	if len(m.To) != 1 || m.To[0] != "me@x.com" {
		t.Errorf("to parse: %+v", m.To)
	}
	if len(m.Cc) != 1 || m.Cc[0] != "c@x.com" {
		t.Errorf("cc parse: %+v", m.Cc)
	}
	if m.Subject != "Hi" || m.BodyText != "hello body" {
		t.Errorf("subject/body: %+v", m)
	}
	if !m.IsUnread {
		t.Error("unread flag not set")
	}
	if m.InternalDate == "" {
		t.Error("internalDate not parsed")
	}
	if m.Permalink != "https://mail.google.com/mail/u/0/#inbox/m1" {
		t.Errorf("permalink: %v", m.Permalink)
	}
}
