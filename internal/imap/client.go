package imap

import (
	"bytes"
	"fmt"
	"io"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/emersion/go-message/mail"
)

// snippetLen mirrors gmail.Message's ~200-char preview convention.
const snippetLen = 200

// Client wraps an authenticated, folder-selected IMAP connection to one
// mailbox. Not safe for concurrent use — mirrors gmail.Client.
type Client struct {
	c      *imapclient.Client
	folder string
}

// Dial connects, authenticates, and selects cfg.Folder (defaulting to INBOX).
// Returns the mailbox's UIDVALIDITY alongside the client — callers must reset
// their stored watermark if this differs from the last-seen value, since UIDs
// are only meaningful within one UIDVALIDITY epoch.
func Dial(cfg AccountConfig, auth Authenticator) (client *Client, uidValidity uint32, err error) {
	addr := fmt.Sprintf("%s:%d", cfg.Host, cfg.Port)

	var c *imapclient.Client
	switch cfg.Security {
	case SecuritySSL, "":
		c, err = imapclient.DialTLS(addr, nil)
	case SecurityStartTLS:
		c, err = imapclient.DialStartTLS(addr, nil)
	case SecurityNone:
		c, err = imapclient.DialInsecure(addr, nil)
	default:
		return nil, 0, fmt.Errorf("imap: unknown security mode %q", cfg.Security)
	}
	if err != nil {
		return nil, 0, fmt.Errorf("imap: dial %s: %w", addr, err)
	}

	if err := auth.Authenticate(c); err != nil {
		_ = c.Close()
		return nil, 0, err
	}

	folder := cfg.Folder
	if folder == "" {
		folder = "INBOX"
	}
	data, err := c.Select(folder, nil).Wait()
	if err != nil {
		_ = c.Close()
		return nil, 0, fmt.Errorf("imap: select %s: %w", folder, err)
	}

	return &Client{c: c, folder: folder}, data.UIDValidity, nil
}

// Close closes the underlying connection.
func (cl *Client) Close() error {
	return cl.c.Close()
}

// SearchNewSince returns the UIDs of every message with UID > lastUID in the
// selected folder (order is not guaranteed by IMAP; callers sort if needed) —
// a cheap UID-only FETCH (no envelope/flags/body fetched) on the "N:*" range.
// This deliberately uses FETCH rather than SEARCH: a UID SEARCH whose range
// start exceeds the mailbox's current highest UID resolves "*" dynamically
// and can spuriously match already-seen UIDs on at least one widely-used test
// server implementation, whereas a plain ranged FETCH does not have this
// failure mode. Callers sort, cap to a per-cycle maximum, and only then pass
// the surviving subset to FetchUIDs — see Syncer.Sync, which mirrors
// gmail.Syncer's two-phase list-then-fetch shape so a capped cycle never pays
// for a full fetch of messages it's about to discard. Used once an account
// has a watermark — see SearchSince for the first-ever sync.
func (cl *Client) SearchNewSince(lastUID uint32) ([]uint32, error) {
	var uidSet imap.UIDSet
	uidSet.AddRange(imap.UID(lastUID+1), 0) // "N:*"
	cmd := cl.c.Fetch(uidSet, &imap.FetchOptions{UID: true})
	var uids []uint32
	for {
		data := cmd.Next()
		if data == nil {
			break
		}
		buf, err := data.Collect()
		if err != nil {
			_ = cmd.Close()
			return nil, fmt.Errorf("imap: listing new since uid %d: %w", lastUID, err)
		}
		if buf.UID == 0 {
			continue
		}
		uids = append(uids, uint32(buf.UID))
	}
	if err := cmd.Close(); err != nil {
		return nil, fmt.Errorf("imap: listing new since uid %d: %w", lastUID, err)
	}
	return uids, nil
}

// SearchSince returns the UIDs of messages received on or after since, found
// via SEARCH so a mailbox's entire history isn't pulled over the wire on the
// first sync (unlike SearchNewSince, whose "N:*" range would mean "1:*" —
// everything — when lastUID is still 0). Mirrors Gmail's newer_than:Nd
// initial backfill. Like SearchNewSince, this is the cheap phase — no
// envelope/flags/body is fetched; see FetchUIDs for the expensive phase.
func (cl *Client) SearchSince(since time.Time) ([]uint32, error) {
	data, err := cl.c.UIDSearch(&imap.SearchCriteria{Since: since}, nil).Wait()
	if err != nil {
		return nil, fmt.Errorf("imap: search since %s: %w", since.Format("2006-01-02"), err)
	}
	return uidsToUint32s(data.AllUIDs()), nil
}

// FetchUIDs fetches full envelope+flags+internaldate+body for exactly the
// given UIDs — the expensive phase, called only after the caller has already
// sorted and capped a cheap SearchNewSince/SearchSince result, so a large
// backlog's discarded tail is never fetched over the wire at all.
func (cl *Client) FetchUIDs(uids []uint32) ([]Message, error) {
	if len(uids) == 0 {
		return nil, nil
	}
	var uidSet imap.UIDSet
	nums := make([]imap.UID, len(uids))
	for i, u := range uids {
		nums[i] = imap.UID(u)
	}
	uidSet.AddNum(nums...)
	return cl.fetchUIDSet(uidSet)
}

// uidsToUint32s converts a SEARCH response's UIDs to the plain []uint32 the
// rest of this package (sorting, capping, Message.UID) works with.
func uidsToUint32s(uids []imap.UID) []uint32 {
	out := make([]uint32, len(uids))
	for i, u := range uids {
		out[i] = uint32(u)
	}
	return out
}

func (cl *Client) fetchUIDSet(uidSet imap.UIDSet) ([]Message, error) {
	fetchOptions := &imap.FetchOptions{
		UID:          true,
		Envelope:     true,
		Flags:        true,
		InternalDate: true,
		// Peek: true avoids the standard IMAP side effect where fetching a
		// body section implicitly marks the message \Seen — a read-only
		// sync must not mutate the mailbox's read state.
		BodySection: []*imap.FetchItemBodySection{{Peek: true}},
	}

	cmd := cl.c.Fetch(uidSet, fetchOptions)
	var out []Message
	for {
		data := cmd.Next()
		if data == nil {
			break
		}
		buf, err := data.Collect()
		if err != nil {
			_ = cmd.Close()
			return nil, fmt.Errorf("imap: collecting fetch response: %w", err)
		}
		if buf.UID == 0 {
			continue
		}
		out = append(out, messageFromBuffer(buf))
	}
	if err := cmd.Close(); err != nil {
		return nil, fmt.Errorf("imap: fetch %s: %w", cl.folder, err)
	}
	return out, nil
}

func messageFromBuffer(buf *imapclient.FetchMessageBuffer) Message {
	m := Message{UID: uint32(buf.UID), IsUnread: true}
	for _, f := range buf.Flags {
		if f == imap.FlagSeen {
			m.IsUnread = false
		}
	}
	if !buf.InternalDate.IsZero() {
		m.InternalDate = buf.InternalDate.UTC().Format(time.RFC3339)
	}
	if buf.Envelope != nil {
		m.Subject = buf.Envelope.Subject
		if m.InternalDate == "" && !buf.Envelope.Date.IsZero() {
			m.InternalDate = buf.Envelope.Date.UTC().Format(time.RFC3339)
		}
		if len(buf.Envelope.From) > 0 {
			m.FromEmail = buf.Envelope.From[0].Addr()
			m.FromName = buf.Envelope.From[0].Name
		}
		for _, a := range buf.Envelope.To {
			if addr := a.Addr(); addr != "" {
				m.To = append(m.To, addr)
			}
		}
		for _, a := range buf.Envelope.Cc {
			if addr := a.Addr(); addr != "" {
				m.Cc = append(m.Cc, addr)
			}
		}
	}
	if raw := buf.FindBodySection(&imap.FetchItemBodySection{}); raw != nil {
		m.BodyText = extractPlainText(raw)
		// truncateUTF8 (sync.go) backs off to the last valid rune boundary — a
		// raw byte slice here could split a multibyte character and store
		// invalid UTF-8 in imap_messages.snippet.
		m.Snippet = truncateUTF8(m.BodyText, snippetLen)
	}
	return m
}

// extractPlainText walks the MIME tree for the first inline text/plain part.
// Any parse failure (unknown charset, malformed MIME) falls back to an empty
// body rather than failing the whole sync — the subject/snippet still carry
// enough signal for triage.
func extractPlainText(raw []byte) string {
	r, err := mail.CreateReader(bytes.NewReader(raw))
	if r == nil {
		return ""
	}
	defer func() { _ = r.Close() }()
	_ = err // CreateReader returns a usable Reader alongside unknown-charset errors

	for {
		part, err := r.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			break
		}
		inline, ok := part.Header.(*mail.InlineHeader)
		if !ok {
			continue
		}
		ct, _, _ := inline.ContentType()
		if ct != "" && ct != "text/plain" {
			continue
		}
		body, err := io.ReadAll(part.Body)
		if err != nil {
			continue
		}
		return string(body)
	}
	return ""
}
