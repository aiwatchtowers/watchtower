package media

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"testing"
	"time"

	goimap "github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapserver"
	"github.com/emersion/go-imap/v2/imapserver/imapmemserver"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/gmail"
	"watchtower/internal/imap"
)

// gmailImage stores Gmail message msgID of a fresh account-scoped mail with
// one image part (name = filename or cid:<id>) and returns its item id.
func (e *env) gmailImage(acct int64, msgID, locator, name string, data []byte) int64 {
	e.t.Helper()
	e.op.data[locator] = data
	m := db.GmailMessage{ID: msgID, ThreadID: "t-" + msgID, FromEmail: "a@example.com", ToJSON: "[]", CcJSON: "[]",
		LabelsJSON: "[]", InternalDate: time.Now().UTC().Format(time.RFC3339), SyncedAt: time.Now().UTC().Format(time.RFC3339)}
	require.NoError(e.t, e.d.UpsertGmailMessageMedia(context.Background(), acct, m, false,
		[]db.MediaFound{{Kind: "image", Locator: locator, Name: name, MediaType: "image/png", Size: int64(len(data))}}))
	var id int64
	require.NoError(e.t, e.d.QueryRow(`SELECT id FROM media_items WHERE gmail_message_id = ? AND locator = ?`, msgID, locator).Scan(&id))
	return id
}

func TestMailJunk_SignatureLogoSkipped(t *testing.T) {
	e := newEnv(t)
	e.p.Openers["gmail"] = e.op
	acct, err := e.d.CreateGoogleAccount(db.GoogleAccount{Email: "me@example.com", Label: "A"})
	require.NoError(t, err)

	logo := noisePNG(t, 56, 56, 1) // ~12 KiB
	require.Less(t, len(logo), 30<<10)
	require.Greater(t, len(logo), 8<<10)
	shot := noisePNG(t, 230, 230, 2) // ~200 KiB
	require.Greater(t, len(shot), 150<<10)

	first := e.gmailImage(acct, "m1", "part:1", "image001.png", logo)
	second := e.gmailImage(acct, "m2", "part:2", "image001.png", logo)
	inline := e.gmailImage(acct, "m3", "part:3", "cid:sig@example.com", noisePNG(t, 56, 56, 3))
	screenshot := e.gmailImage(acct, "m4", "part:4", "screenshot.png", shot)
	bigInline := e.gmailImage(acct, "m5", "part:5", "cid:paste@example.com", noisePNG(t, 230, 230, 4))
	// An inline part with a filename too: junk on first sight.
	namedInline := e.gmailImage(acct, "m6", "part:6", "cid:sig2@example.com image002.png", noisePNG(t, 56, 56, 5))

	st := e.run()

	assert.Equal(t, "ok", e.row(first).Status, "the first mail's image is described")
	assert.Equal(t, "skipped_junk", e.row(second).Status, "the same bytes on another mail are a signature logo")
	assert.Equal(t, e.row(first).ContentKey, e.row(second).ContentKey)
	assert.Equal(t, "skipped_junk", e.row(inline).Status, "a small inline (Content-ID) image")
	assert.True(t, strings.HasPrefix(e.row(inline).ContentKey, "sha256:"))
	assert.Equal(t, "ok", e.row(screenshot).Status, "an attached 200 KiB screenshot is described")
	assert.Equal(t, "ok", e.row(bigInline).Status, "an inline image over 30 KiB is described")
	assert.Equal(t, "skipped_junk", e.row(namedInline).Status, "a small inline image with a filename")
	assert.Equal(t, "gmail", e.row(screenshot).KBSource)
	imgCalls, _ := e.gen.calls()
	assert.Equal(t, 3, imgCalls)
	assert.Equal(t, 3, st.Skipped)
}

func TestMailJunk_SameParentIsNoRepeat(t *testing.T) {
	e := newEnv(t)
	acct, err := e.d.CreateGoogleAccount(db.GoogleAccount{Email: "me@example.com", Label: "A"})
	require.NoError(t, err)
	a := e.gmailImage(acct, "m1", "part:1", "a.png", nil)
	e.exec(`UPDATE media_items SET content_key = 'sha256:abc' WHERE id = ?`, a)
	p := db.MediaParent{Kind: "gmail", GmailAccountID: acct, GmailMessageID: "m1"}
	it := db.MediaItem{ID: a + 100, ParentKind: "gmail", ParentKey: p.Key(), Scope: p.Scope(), Name: "b.png"}

	junk, err := MailJunk(context.Background(), e.d, it, 50<<10, "abc")
	require.NoError(t, err)
	assert.False(t, junk, "a duplicate inside one mail is no signature")
	it.ParentKey = "gmail:" + strconv.FormatInt(acct, 10) + ":m2"
	junk, err = MailJunk(context.Background(), e.d, it, 50<<10, "abc")
	require.NoError(t, err)
	assert.True(t, junk)
	it.Scope = "gmail:" + strconv.FormatInt(acct+1, 10)
	junk, err = MailJunk(context.Background(), e.d, it, 50<<10, "abc")
	require.NoError(t, err)
	assert.False(t, junk, "bytes seen in another account are no repeat")
}

func TestMailJunk_RepeatScopedByAccount(t *testing.T) {
	e := newEnv(t)
	e.p.Openers["gmail"] = e.op
	e.p.Openers["imap"] = e.op
	gacct, err := e.d.CreateGoogleAccount(db.GoogleAccount{Email: "me@example.com", Label: "A"})
	require.NoError(t, err)
	iacct, err := e.d.CreateEmailAccount(db.EmailAccount{Provider: "imap", EmailAddress: "me@example.org",
		Host: "127.0.0.1", Port: 993, Security: "ssl", Folder: "INBOX"})
	require.NoError(t, err)
	img := noisePNG(t, 56, 56, 1)
	g := e.gmailImage(gacct, "m1", "part:1", "image001.png", img)
	e.op.data["img:0"] = img
	m := db.ImapMessage{AccountID: iacct, UID: 7, UIDValidity: 1, FromEmail: "a@example.com", ToJSON: "[]", CcJSON: "[]",
		InternalDate: time.Now().UTC().Format(time.RFC3339)}
	require.NoError(t, e.d.UpsertImapMessageMedia(context.Background(), m, m.InternalDate, false,
		[]db.MediaFound{{Kind: "image", Locator: "img:0", Name: "image001.png", MediaType: "image/png"}}))
	var i int64
	require.NoError(t, e.d.QueryRow(`SELECT id FROM media_items WHERE parent_kind = 'imap'`).Scan(&i))

	e.run()

	assert.Equal(t, "ok", e.row(g).Status)
	assert.Equal(t, "ok", e.row(i).Status, "the same bytes in another account are described, not junk")
	imgCalls, _ := e.gen.calls()
	assert.Equal(t, 2, imgCalls)
}

func TestPipeline_SourceOffWaitsWithoutAttempt(t *testing.T) {
	e := newEnv(t)
	img := noisePNG(t, 64, 64, 1)
	id := e.image("1:C1", "1758000000.000100", "F1", img)
	e.op.errs["F1"] = fmt.Errorf("account: %w", ErrSourceOff)

	st := e.run()
	r := e.row(id)
	assert.Equal(t, "pending", r.Status, "the row waits as it is")
	assert.Equal(t, 0, r.Attempts, "no attempt is spent")
	assert.Empty(t, r.Error)
	assert.Equal(t, 0, st.Failed)
	pending, err := e.p.HasPending(context.Background())
	require.NoError(t, err)
	assert.False(t, pending, "a waiting row keeps no cycle busy")

	e.p.Now = func() time.Time { return time.Now().Add(mediaWaitRetry + time.Minute) }
	pending, err = e.p.HasPending(context.Background())
	require.NoError(t, err)
	assert.True(t, pending, "listed again once the wait is over")
	delete(e.op.errs, "F1")
	e.run()
	assert.Equal(t, "ok", e.row(id).Status, "described once the source is back")
}

type fakeGmailSource struct {
	data []byte
	err  error
	got  string
}

func (f *fakeGmailSource) GetImagePart(_ context.Context, messageID, partID string, _ int64) (io.ReadCloser, error) {
	f.got = messageID + "/" + partID
	if f.err != nil {
		return nil, f.err
	}
	return io.NopCloser(bytes.NewReader(f.data)), nil
}

func TestGmailOpener_MapsErrors(t *testing.T) {
	src := &fakeGmailSource{data: []byte("img")}
	var asked int64
	o := GmailOpener{Client: func(_ context.Context, acct int64) (GmailImageSource, error) { asked = acct; return src, nil }}
	it := db.MediaItem{ParentKind: "gmail", GmailAccountID: 7, GmailMessageID: "m1", Locator: "part:0.1", MediaType: "image/png"}

	rc, mt, err := o.Open(context.Background(), it, 1<<20)
	require.NoError(t, err)
	b, _ := io.ReadAll(rc)
	assert.Equal(t, "img", string(b))
	assert.Equal(t, "image/png", mt)
	assert.Equal(t, int64(7), asked)
	assert.Equal(t, "m1/0.1", src.got)

	src.err = fmt.Errorf("wrapped: %w", gmail.ErrImagePartGone)
	_, _, err = o.Open(context.Background(), it, 1<<20)
	assert.ErrorIs(t, err, ErrGone)
	src.err = gmail.ErrImagePartTooLarge
	_, _, err = o.Open(context.Background(), it, 1<<20)
	assert.ErrorIs(t, err, ErrTooLarge)
	off := GmailOpener{Client: func(context.Context, int64) (GmailImageSource, error) { return nil, ErrSourceOff }}
	_, _, err = off.Open(context.Background(), it, 1<<20)
	assert.ErrorIs(t, err, ErrSourceOff, "an off source passes through to the pass")
	it.Locator = "img:0"
	_, _, err = o.Open(context.Background(), it, 1<<20)
	assert.ErrorIs(t, err, ErrGone)
}

// imapMemServer is an in-process IMAP server (no TLS, loopback) with one
// INBOX holding raw; it returns the address and the message's UID.
func imapMemServer(t *testing.T, raw string) (imap.AccountConfig, imap.Authenticator, uint32) {
	t.Helper()
	mem := imapmemserver.New()
	user := imapmemserver.NewUser("u", "p")
	require.NoError(t, user.Create("INBOX", nil))
	mem.AddUser(user)
	data, err := user.Append("INBOX", literal{bytes.NewReader([]byte(raw))}, &goimap.AppendOptions{Time: time.Now()})
	require.NoError(t, err)
	srv := imapserver.New(&imapserver.Options{
		NewSession: func(*imapserver.Conn) (imapserver.Session, *imapserver.GreetingData, error) {
			return mem.NewSession(), nil, nil
		},
		InsecureAuth: true,
		Caps:         goimap.CapSet{goimap.CapIMAP4rev1: {}, goimap.CapIMAP4rev2: {}},
	})
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() { _ = srv.Close(); _ = ln.Close() })
	host, port, err := net.SplitHostPort(ln.Addr().String())
	require.NoError(t, err)
	p, err := strconv.Atoi(port)
	require.NoError(t, err)
	return imap.AccountConfig{Host: host, Port: p, Security: imap.SecurityNone, Folder: "INBOX"},
		imap.PasswordAuth{Username: "u", Password: "p"}, uint32(data.UID)
}

type literal struct{ *bytes.Reader }

func (l literal) Size() int64 { return l.Reader.Size() }

func TestIMAPOpener_UIDValidityChangedIsGone(t *testing.T) {
	img := []byte("\x89PNG\r\n\x1a\n the attached image")
	raw := strings.ReplaceAll(`From: a@example.com
To: me@example.com
Subject: Pic
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="b"

--b
Content-Type: text/plain

Hello.
--b
Content-Type: image/png
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="a.png"

`+base64.StdEncoding.EncodeToString(img)+`
--b--
`, "\n", "\r\n")
	cfg, auth, uid := imapMemServer(t, raw)
	dials := 0
	var validity uint32
	o := IMAPOpener{Dial: func(_ context.Context, acct int64) (IMAPMessageSource, uint32, error) {
		dials++
		require.Equal(t, int64(3), acct)
		c, v, err := imap.Dial(cfg, auth)
		validity = v
		return c, v, err
	}}
	ctx := context.Background()
	it := db.MediaItem{ParentKind: "imap", IMAPAccountID: 3, IMAPUID: int64(uid), Locator: "img:0", MediaType: "image/png"}

	// Learn the folder's UIDVALIDITY, then open with it recorded.
	_, _, _ = o.Open(ctx, it, 1<<20)
	it.IMAPUIDValidity = int64(validity)
	rc, _, err := o.Open(ctx, it, 1<<20)
	require.NoError(t, err)
	got, _ := io.ReadAll(rc)
	assert.Equal(t, img, got)

	_, _, err = o.Open(ctx, db.MediaItem{IMAPAccountID: 3, IMAPUID: int64(uid), IMAPUIDValidity: it.IMAPUIDValidity, Locator: "img:1"}, 1<<20)
	assert.ErrorIs(t, err, ErrGone, "no second image part")
	_, _, err = o.Open(ctx, db.MediaItem{IMAPAccountID: 3, IMAPUID: int64(uid) + 5, IMAPUIDValidity: it.IMAPUIDValidity, Locator: "img:0"}, 1<<20)
	assert.ErrorIs(t, err, ErrGone, "the message was expunged")
	_, _, err = o.Open(ctx, it, 4)
	assert.ErrorIs(t, err, ErrTooLarge)

	it.IMAPUIDValidity++
	_, _, err = o.Open(ctx, it, 1<<20)
	assert.ErrorIs(t, err, ErrGone, "a changed UIDVALIDITY means the UID names another message")

	before := dials
	_, _, err = o.Open(ctx, db.MediaItem{Locator: "part:1"}, 1<<20)
	assert.ErrorIs(t, err, ErrGone)
	assert.Equal(t, before, dials, "a foreign locator never dials")
	assert.False(t, errors.Is(err, ErrTooLarge))
}
