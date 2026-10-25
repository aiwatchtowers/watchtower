package imap

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
)

var (
	logoPNG  = []byte("\x89PNG\r\n\x1a\n inline signature logo")
	photoJPG = []byte("\xff\xd8\xff an attached photo")
	smallGIF = []byte("GIF89a a small inline gif")
)

// imageRawMessage is multipart/mixed: alternative (text/plain, related
// (text/html, inline PNG with a Content-ID)), an attached JPEG, a PDF, and
// an inline GIF with a filename and a Content-ID.
func imageRawMessage(from string) string {
	enc := func(b []byte) string { return base64.StdEncoding.EncodeToString(b) }
	return strings.ReplaceAll(fmt.Sprintf(`From: %s
To: me@example.com
Subject: Pictures
Date: Mon, 09 Jul 2026 09:00:00 +0000
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="mix"

--mix
Content-Type: multipart/alternative; boundary="alt"

--alt
Content-Type: text/plain; charset=utf-8

See https://example.com/unsubscribe?u=1 and the pictures.
--alt
Content-Type: multipart/related; boundary="rel"

--rel
Content-Type: text/html; charset=utf-8

<p>See <a href="https://example.com/x">this</a><img src="cid:logo@example.com"></p>
--rel
Content-Type: image/png
Content-Transfer-Encoding: base64
Content-ID: <logo@example.com>
Content-Disposition: inline

%s
--rel--
--alt--
--mix
Content-Type: image/jpeg; name="photo.jpg"
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="photo.jpg"

%s
--mix
Content-Type: application/pdf
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="doc.pdf"

JVBERi0=
--mix
Content-Type: image/gif
Content-Transfer-Encoding: base64
Content-ID: <gif@example.com>
Content-Disposition: inline; filename="small.gif"

%s
--mix--
`, from, enc(logoPNG), enc(photoJPG), enc(smallGIF)), "\n", "\r\n")
}

func TestIMAPImageParts_WalkOrder(t *testing.T) {
	raw := []byte(imageRawMessage("Alice <alice@example.com>"))
	text, images := parseMIME(raw)
	if !strings.HasPrefix(text, "See https://example.com/unsubscribe") {
		t.Errorf("text = %q", text)
	}
	want := []ImagePart{
		{Index: 0, MediaType: "image/png", ContentID: "logo@example.com", Size: int64(len(logoPNG))},
		{Index: 1, Filename: "photo.jpg", MediaType: "image/jpeg", Size: int64(len(photoJPG))},
		{Index: 2, Filename: "small.gif", MediaType: "image/gif", ContentID: "gif@example.com", Size: int64(len(smallGIF))},
	}
	if fmt.Sprint(images) != fmt.Sprint(want) {
		t.Fatalf("images = %+v, want %+v", images, want)
	}
	for i, b := range [][]byte{logoPNG, photoJPG, smallGIF} {
		got, err := ImagePartAt(raw, i, 1<<20)
		if err != nil || string(got) != string(b) {
			t.Errorf("ImagePartAt(%d) = %q, %v", i, got, err)
		}
	}
	if _, err := ImagePartAt(raw, 3, 1<<20); !errors.Is(err, ErrImagePartGone) {
		t.Errorf("index past the last image: err = %v", err)
	}
	if _, err := ImagePartAt(raw, 1, 4); !errors.Is(err, ErrMessageTooLarge) {
		t.Errorf("over the limit: err = %v", err)
	}
}

func TestIMAPFetchRaw(t *testing.T) {
	ts := startTestServer(t)
	raw := imageRawMessage("Alice <alice@example.com>")
	uid := ts.seedMessage(t, raw)
	host, port := ts.hostPort(t)
	client, _, err := Dial(AccountConfig{Host: host, Port: port, Security: SecurityNone, Folder: "INBOX"},
		PasswordAuth{Username: testUsername, Password: testPassword})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = client.Close() }()

	got, err := client.FetchRaw(uid, 1<<20)
	if err != nil || string(got) != raw {
		t.Fatalf("FetchRaw = %d bytes, %v", len(got), err)
	}
	if _, err := client.FetchRaw(uid, 16); !errors.Is(err, ErrMessageTooLarge) {
		t.Errorf("over the limit: err = %v", err)
	}
	if _, err := client.FetchRaw(uid+10, 1<<20); !errors.Is(err, ErrMessageGone) {
		t.Errorf("a missing uid: err = %v", err)
	}
}

func TestIMAPSync_RecordsImagesNeverLinks(t *testing.T) {
	ts := startTestServer(t)
	uid := ts.seedMessage(t, imageRawMessage("Me <me@example.com>"))
	database := db.OpenTestDB(t)
	if err := database.SetMediaStartAt(time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	syncer, acct := newTestSyncer(t, database, ts)
	if _, err := syncer.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	rows, err := database.Query(`SELECT kind || '|' || locator || '|' || name || '|' || media_type || '|' || from_owner || '|' || imap_uid
		FROM media_items WHERE parent_kind = 'imap' AND imap_account_id = ? ORDER BY locator`, acct.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			t.Fatal(err)
		}
		got = append(got, s)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	want := []string{
		fmt.Sprintf("image|img:0|cid:logo@example.com|image/png|1|%d", uid),
		fmt.Sprintf("image|img:1|photo.jpg|image/jpeg|1|%d", uid),
		fmt.Sprintf("image|img:2|cid:gif@example.com small.gif|image/gif|1|%d", uid),
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("media rows = %v, want %v (images only, no links)", got, want)
	}
}
