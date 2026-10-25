package media

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/gmail"
	"watchtower/internal/imap"
)

// Mail images (Gmail and IMAP). Mail links are never recorded, fetched or
// summarized; only image parts are described.

const (
	// mailInlineJunkMax: an inline image (Content-ID, recorded with the
	// name cid:<id>) of at most this many bytes is a signature logo or an
	// avatar.
	mailInlineJunkMax = 30 << 10
	// maxMailMessage caps the raw IMAP message held in memory to reach one
	// image part (attachments beside the image count too).
	maxMailMessage = 2 * maxMediaDownload
)

// MailJunk reports whether a mail image is junk: an inline image (a part
// with a Content-ID, recorded with the name "cid:<id>" or
// "cid:<id> <filename>", see the Gmail/IMAP discovery) of at most 30 KiB,
// or bytes (sha, the hex sha256 of the downloaded bytes) already on an item
// of another mail parent of the same account (scope) — the signature logo
// every mail of a sender carries.
func MailJunk(ctx context.Context, q db.ContextQueryer, it db.MediaItem, size int64, sha string) (bool, error) {
	if strings.HasPrefix(it.Name, "cid:") && size <= mailInlineJunkMax {
		return true, nil
	}
	var one int
	err := q.QueryRowContext(ctx, `SELECT 1 FROM media_items
		WHERE content_key = ? AND scope = ? AND parent_kind IN ('gmail', 'imap') AND parent_key <> ? LIMIT 1`,
		"sha256:"+sha, it.Scope, it.ParentKey).Scan(&one)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return false, nil
	case err != nil:
		return false, fmt.Errorf("media: mail junk check of item %d: %w", it.ID, err)
	}
	return true, nil
}

// GmailImageSource reads one image part of a message (*gmail.Client).
type GmailImageSource interface {
	GetImagePart(ctx context.Context, messageID, partID string, limit int64) (io.ReadCloser, error)
}

// GmailOpener opens Gmail image parts (locator part:<partID>) through the
// account's client; the part is found afresh in the message each time.
type GmailOpener struct {
	Client func(ctx context.Context, accountID int64) (GmailImageSource, error)
}

func (o GmailOpener) Open(ctx context.Context, it db.MediaItem, limit int64) (io.ReadCloser, string, error) {
	partID, ok := strings.CutPrefix(it.Locator, "part:")
	if !ok {
		return nil, "", ErrGone
	}
	c, err := o.Client(ctx, it.GmailAccountID)
	if err != nil {
		return nil, "", err
	}
	rc, err := c.GetImagePart(ctx, it.GmailMessageID, partID, limit)
	switch {
	case errors.Is(err, gmail.ErrImagePartGone):
		return nil, "", ErrGone
	case errors.Is(err, gmail.ErrImagePartTooLarge):
		return nil, "", ErrTooLarge
	case err != nil:
		return nil, "", err
	}
	return rc, it.MediaType, nil
}

// IMAPMessageSource reads raw messages of the account's folder
// (*imap.Client).
type IMAPMessageSource interface {
	FetchRaw(uid uint32, limit int64) ([]byte, error)
	Close() error
}

// IMAPOpener opens IMAP image parts (locator img:<index>): it dials the
// account afresh for every image (one connection and login per item — the
// pass is sequential and mail images are few; a failed login there updates
// the account's auth state as the syncer's does), refuses a folder whose UIDVALIDITY changed since the row
// was recorded (ErrGone: its UIDs mean other messages now), fetches the raw
// message into memory and walks to the index-th image part.
type IMAPOpener struct {
	Dial func(ctx context.Context, accountID int64) (src IMAPMessageSource, uidValidity uint32, err error)
}

func (o IMAPOpener) Open(ctx context.Context, it db.MediaItem, limit int64) (io.ReadCloser, string, error) {
	n, ok := strings.CutPrefix(it.Locator, "img:")
	index, err := strconv.Atoi(n)
	if !ok || err != nil || index < 0 {
		return nil, "", ErrGone
	}
	c, validity, err := o.Dial(ctx, it.IMAPAccountID)
	if err != nil {
		return nil, "", err
	}
	defer func() { _ = c.Close() }()
	stop := context.AfterFunc(ctx, func() { _ = c.Close() }) // the IMAP client takes no context
	defer stop()
	if int64(validity) != it.IMAPUIDValidity {
		return nil, "", ErrGone
	}
	raw, err := c.FetchRaw(uint32(it.IMAPUID), maxMailMessage)
	if err == nil {
		var data []byte
		if data, err = imap.ImagePartAt(raw, index, limit); err == nil {
			return io.NopCloser(bytes.NewReader(data)), it.MediaType, nil
		}
	}
	switch {
	case errors.Is(err, imap.ErrMessageGone), errors.Is(err, imap.ErrImagePartGone):
		return nil, "", ErrGone
	case errors.Is(err, imap.ErrMessageTooLarge):
		return nil, "", ErrTooLarge
	}
	if ctx.Err() != nil {
		return nil, "", ctx.Err()
	}
	return nil, "", err
}
