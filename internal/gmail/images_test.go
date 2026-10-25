package gmail

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

var (
	inlinePNG     = []byte("\x89PNG\r\n\x1a\n inline logo bytes")
	attachmentJPG = []byte("\xff\xd8\xff attached photo bytes")
)

func b64(b []byte) string { return base64.URLEncoding.EncodeToString(b) }

// imageMessageJSON is a multipart/mixed message: a multipart/related body
// (text/plain + an inline PNG with a Content-ID and no filename, its data
// inline) and an attached JPEG served through attachments.get. attID is
// the attachment id this response carries (Gmail's ids are not stable).
func imageMessageJSON(id, internalMS, from, body, attID string) string {
	return fmt.Sprintf(`{"id":%q,"threadId":"t-%s","labelIds":["INBOX"],"snippet":"s","internalDate":%q,
	  "payload":{"partId":"","mimeType":"multipart/mixed","headers":[{"name":"From","value":%q},{"name":"Subject","value":"Pics"}],
	    "parts":[
	      {"partId":"0","mimeType":"multipart/related","parts":[
	        {"partId":"0.0","mimeType":"text/plain","body":{"size":%d,"data":%q}},
	        {"partId":"0.1","mimeType":"image/png","filename":"","headers":[{"name":"Content-ID","value":"<logo@example.com>"},{"name":"Content-Disposition","value":"inline"}],
	          "body":{"size":%d,"data":%q}}]},
	      {"partId":"1","mimeType":"image/jpeg","filename":"photo.jpg","headers":[{"name":"Content-Disposition","value":"attachment; filename=\"photo.jpg\""}],
	        "body":{"size":%d,"attachmentId":%q}}]}}`,
		id, id, internalMS, from, len(body), b64([]byte(body)), len(inlinePNG), b64(inlinePNG), len(attachmentJPG), attID)
}

// gmailTestServer serves messages from mux and a token endpoint, pointing
// the package at both for the test.
func gmailTestServer(t *testing.T, mux *http.ServeMux) *Client {
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
	c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// attachmentServer answers message m1 with a fresh attachment id per
// messages.get, and attachments.get only for the id of the latest response.
func attachmentServer(t *testing.T, internalMS, from, body string) (*http.ServeMux, *atomic.Int32) {
	t.Helper()
	var gets atomic.Int32
	mux := http.NewServeMux()
	mux.HandleFunc("/users/me/messages/m1", func(w http.ResponseWriter, r *http.Request) {
		n := gets.Add(1)
		fmt.Fprint(w, imageMessageJSON("m1", internalMS, from, body, fmt.Sprintf("att-%d", n)))
	})
	mux.HandleFunc("/users/me/messages/m1/attachments/", func(w http.ResponseWriter, r *http.Request) {
		want := fmt.Sprintf("att-%d", gets.Load())
		if !strings.HasSuffix(r.URL.Path, "/"+want) {
			http.Error(w, `{"error":{"code":404}}`, http.StatusNotFound)
			return
		}
		fmt.Fprintf(w, `{"size":%d,"data":%q}`, len(attachmentJPG), b64(attachmentJPG))
	})
	return mux, &gets
}

func TestGetMessage_ListsImageParts(t *testing.T) {
	mux, _ := attachmentServer(t, "1720519200000", "a@example.com", "hello")
	c := gmailTestServer(t, mux)

	m, err := c.GetMessage(context.Background(), "m1")
	if err != nil {
		t.Fatal(err)
	}
	if m.BodyText != "hello" {
		t.Errorf("body = %q", m.BodyText)
	}
	want := []ImagePart{
		{PartID: "0.1", MediaType: "image/png", ContentID: "logo@example.com", Size: int64(len(inlinePNG))},
		{PartID: "1", Filename: "photo.jpg", MediaType: "image/jpeg", Size: int64(len(attachmentJPG))},
	}
	if fmt.Sprint(m.Images) != fmt.Sprint(want) {
		t.Fatalf("images = %+v, want %+v", m.Images, want)
	}
}

func TestGetImagePart_InlineAndAttachment(t *testing.T) {
	mux, gets := attachmentServer(t, "1720519200000", "a@example.com", "hello")
	c := gmailTestServer(t, mux)
	ctx := context.Background()

	read := func(partID string, limit int64) ([]byte, error) {
		rc, err := c.GetImagePart(ctx, "m1", partID, limit)
		if err != nil {
			return nil, err
		}
		defer rc.Close()
		return io.ReadAll(rc)
	}
	got, err := read("0.1", 1<<20)
	if err != nil || string(got) != string(inlinePNG) {
		t.Fatalf("inline part = %q, %v", got, err)
	}
	// The attachment id comes from the same messages.get response: an id
	// from an earlier response would 404 here.
	_, _ = c.GetMessage(ctx, "m1")
	got, err = read("1", 1<<20)
	if err != nil || string(got) != string(attachmentJPG) {
		t.Fatalf("attachment part = %q, %v", got, err)
	}
	if gets.Load() != 3 {
		t.Errorf("messages.get calls = %d, want 3 (one per read, one listing)", gets.Load())
	}
	if _, err := read("0.0", 1<<20); !errors.Is(err, ErrImagePartGone) {
		t.Errorf("a text part: err = %v, want ErrImagePartGone", err)
	}
	if _, err := read("9", 1<<20); !errors.Is(err, ErrImagePartGone) {
		t.Errorf("a missing part: err = %v, want ErrImagePartGone", err)
	}
	if _, err := read("1", 4); !errors.Is(err, ErrImagePartTooLarge) {
		t.Errorf("over the limit: err = %v, want ErrImagePartTooLarge", err)
	}
	if _, err := c.GetImagePart(ctx, "gone", "1", 1<<20); !errors.Is(err, ErrImagePartGone) {
		t.Errorf("a deleted message: err = %v, want ErrImagePartGone", err)
	}
}

// mediaRows returns the media rows of kind on gmail parents.
func mediaRows(t *testing.T, d *db.DB, kind string) []string {
	t.Helper()
	rows, err := d.Query(`SELECT locator || '|' || name || '|' || media_type || '|' || size_bytes || '|' || from_owner || '|' || content_at
		FROM media_items WHERE parent_kind = 'gmail' AND kind = ? ORDER BY locator`, kind)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			t.Fatal(err)
		}
		out = append(out, s)
	}
	return out
}

func syncImageMailbox(t *testing.T, internal time.Time, from string, startAt time.Time) *db.DB {
	t.Helper()
	body := "See https://example.com/report and http://example.org/a?b=c and www.example.net/x"
	mux, _ := attachmentServer(t, fmt.Sprint(internal.UnixMilli()), from, body)
	mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"messages":[{"id":"m1"}]}`)
	})
	c := gmailTestServer(t, mux)
	d := db.OpenTestDB(t)
	if err := d.SetMediaStartAt(startAt); err != nil {
		t.Fatal(err)
	}
	acct, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "Me@example.com", Label: "A"})
	if err != nil {
		t.Fatal(err)
	}
	cfg := &config.Config{}
	cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 100, MaxBodyBytes: 51200}
	if n, err := NewSyncer(c, d, cfg, nil, acct).Sync(context.Background()); err != nil || n != 1 {
		t.Fatalf("sync = %d, %v", n, err)
	}
	return d
}

func TestGmailSync_RecordsImagesNeverLinks(t *testing.T) {
	at := time.Now().Add(-time.Hour).Truncate(time.Second).UTC()
	d := syncImageMailbox(t, at, "Me <me@example.com>", at.Add(-time.Hour))

	ts := at.Format("2006-01-02T15:04:05Z")
	want := []string{
		fmt.Sprintf("part:0.1|cid:logo@example.com|image/png|%d|1|%s", len(inlinePNG), ts),
		fmt.Sprintf("part:1|photo.jpg|image/jpeg|%d|1|%s", len(attachmentJPG), ts),
	}
	if got := mediaRows(t, d, "image"); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("image rows = %v, want %v", got, want)
	}
	if got := mediaRows(t, d, "link"); len(got) != 0 {
		t.Fatalf("mail links are never recorded, got %v", got)
	}
}

func TestMailMedia_OldMailNotRecorded(t *testing.T) {
	at := time.Now().Add(-48 * time.Hour).UTC()
	d := syncImageMailbox(t, at, "Colleague <a@example.com>", time.Now().Add(-time.Hour))
	if got := mediaRows(t, d, "image"); len(got) != 0 {
		t.Fatalf("mail older than the start mark records nothing, got %v", got)
	}
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM gmail_messages`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("the message itself is stored: %d, %v", n, err)
	}
}
