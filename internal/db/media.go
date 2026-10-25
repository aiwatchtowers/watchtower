package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"
)

// Media items (migration 00156): images and web links found on synced
// content, described by the daemon's media pass. No bytes are ever stored;
// a row hangs off exactly one parent by a cascading foreign key.

// mediaTimeLayout is the layout of media_items.content_at and
// media_state.start_at (UTC, second precision; the strftime of 00156).
const mediaTimeLayout = "2006-01-02T15:04:05Z"

// MediaErrorClasses are the only values media_items.error may hold — never
// a URL, query, header, body or raw error text. media.ErrorClasses
// re-exports this list.
var MediaErrorClasses = []string{
	"timeout", "refused", "not_found", "too_large", "unsupported", "bad_output",
	"model_error", "open_failed", "convert_failed", "canceled", "other",
}

// ContextQueryer is what the media accessors that may run inside a caller's
// transaction need; *sql.Tx, *DB and extsync's Queryer satisfy it.
type ContextQueryer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// MediaParent names the synced content a media item was found on. Kind is
// slack, confluence, gmail or imap; only that kind's fields are read. Chat
// and target items are recorded by SQL triggers, never through RecordMedia.
type MediaParent struct {
	Kind                           string
	SlackChannelID, SlackTS        string // namespaced "<account>:<channel>"
	ExtSourceID                    int64
	ExtID                          string
	GmailAccountID                 int64
	GmailMessageID                 string
	IMAPAccountID, IMAPUIDValidity int64
	IMAPUID                        int64
	ContentAt                      time.Time
	FromOwner                      bool
}

// Key is the parent's media_items.parent_key ("" for an unknown kind).
func (p MediaParent) Key() string {
	switch p.Kind {
	case "slack":
		return "slack:" + p.SlackChannelID + ":" + p.SlackTS
	case "confluence":
		return "ext:" + strconv.FormatInt(p.ExtSourceID, 10) + ":" + p.ExtID
	case "gmail":
		return "gmail:" + strconv.FormatInt(p.GmailAccountID, 10) + ":" + p.GmailMessageID
	case "imap":
		return "imap:" + strconv.FormatInt(p.IMAPAccountID, 10) + ":" +
			strconv.FormatInt(p.IMAPUIDValidity, 10) + ":" + strconv.FormatInt(p.IMAPUID, 10)
	}
	return ""
}

// Scope is the dedupe scope: the parent's account ("slack:<account prefix
// of the namespaced channel>", "gmail:<acct>", "imap:<acct>",
// "ext:<source_id>"); "" for an unknown kind.
func (p MediaParent) Scope() string {
	switch p.Kind {
	case "slack":
		acct, _, _ := strings.Cut(p.SlackChannelID, ":")
		return "slack:" + acct
	case "confluence":
		return "ext:" + strconv.FormatInt(p.ExtSourceID, 10)
	case "gmail":
		return "gmail:" + strconv.FormatInt(p.GmailAccountID, 10)
	case "imap":
		return "imap:" + strconv.FormatInt(p.IMAPAccountID, 10)
	}
	return ""
}

// parentColumns returns the parent kind's FK columns and their values.
func (p MediaParent) parentColumns() ([]string, []any) {
	switch p.Kind {
	case "slack":
		return []string{"slack_channel_id", "slack_ts"}, []any{p.SlackChannelID, p.SlackTS}
	case "confluence":
		return []string{"ext_source_id", "ext_id"}, []any{p.ExtSourceID, p.ExtID}
	case "gmail":
		return []string{"gmail_account_id", "gmail_message_id"}, []any{p.GmailAccountID, p.GmailMessageID}
	case "imap":
		return []string{"imap_account_id", "imap_uidvalidity", "imap_uid"},
			[]any{p.IMAPAccountID, p.IMAPUIDValidity, p.IMAPUID}
	}
	return nil, nil
}

// MediaFound is one image or link a discovery found on a parent. Status
// empty means pending; only "skipped_type" is accepted otherwise.
type MediaFound struct {
	Kind, Locator, FetchURL, Name, MediaType, Anchor, ContentKey, Status string
	Size                                                                 int64
}

// MediaItem is one media_items row. The parent columns hold their zero
// value when NULL; ParentKind says which are set.
type MediaItem struct {
	ID                                         int64
	Kind, ParentKind, ParentKey                string
	SlackChannelID, SlackTS                    string
	ExtSourceID                                int64
	ExtID                                      string
	GmailAccountID                             int64
	GmailMessageID                             string
	IMAPAccountID, IMAPUIDValidity, IMAPUID    int64
	ChatAttachmentID, TargetImageID            int64
	Anchor, Locator, FetchURL, Name, MediaType string
	SizeBytes                                  int64
	ContentKey, Scope                          string
	FromOwner                                  bool
	ContentAt                                  string // RFC 3339 UTC, second precision
	Status                                     string
	Attempts                                   int
	Error                                      string // a MediaErrorClasses value or ""
	Title, Body, ImageText                     string
	Keys                                       []string
	KBSource, KBRef                            string
	DiscoveredAt, DescribedAt                  string
}

// MediaCursor is a position in ListPendingMedia's order (from_owner DESC,
// id). The zero value (ID 0) starts from the beginning.
type MediaCursor struct {
	FromOwner bool
	ID        int64
}

// MediaResult is the outcome FinishMedia stores. An empty ContentKey, Kind
// or KBRef keeps the stored value (KBRef keeps KBSource with it); ErrorClass is "" or a MediaErrorClasses value.
type MediaResult struct {
	Status, ContentKey, Kind, Title, Body, ImageText, ErrorClass string
	Keys                                                         []string
	KBSource, KBRef                                              string
}

func mediaTime(t time.Time) string { return t.UTC().Format(mediaTimeLayout) }

func readMediaStartAt(ctx context.Context, q ContextQueryer) (time.Time, error) {
	var s string
	if err := q.QueryRowContext(ctx, `SELECT start_at FROM media_state WHERE id = 1`).Scan(&s); err != nil {
		return time.Time{}, fmt.Errorf("reading media start_at: %w", err)
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}, fmt.Errorf("parsing media start_at %q: %w", s, err)
	}
	return t, nil
}

// MediaStartAt is the moment before which no content is recorded or
// described (media_state.start_at).
func (db *DB) MediaStartAt() (time.Time, error) {
	return readMediaStartAt(context.Background(), db)
}

// SetMediaStartAt moves media_state.start_at (second precision, UTC).
func (db *DB) SetMediaStartAt(t time.Time) error {
	if _, err := db.Exec(`INSERT INTO media_state (id, start_at) VALUES (1, ?)
		ON CONFLICT (id) DO UPDATE SET start_at = excluded.start_at`, mediaTime(t)); err != nil {
		return fmt.Errorf("setting media start_at: %w", err)
	}
	return nil
}

// RecordMedia records the media found on parent p. Content older than
// media_state.start_at records nothing. New (parent_key, kind, locator)
// rows are inserted; an existing row keeps its status and description.
// For each kind in replaceKinds, the parent's rows of that kind not in
// found are deleted (the parent was edited). It returns the rows inserted.
func RecordMedia(ctx context.Context, q ContextQueryer, p MediaParent, found []MediaFound, replaceKinds ...string) (int, error) {
	key, scope := p.Key(), p.Scope()
	if key == "" {
		return 0, fmt.Errorf("recording media: unknown parent kind %q", p.Kind)
	}
	if p.ContentAt.IsZero() {
		return 0, fmt.Errorf("recording media on %s: content time is not set", key)
	}
	for _, f := range found {
		if f.Kind != "image" && f.Kind != "link" {
			return 0, fmt.Errorf("recording media on %s: unknown kind %q", key, f.Kind)
		}
		if f.Locator == "" {
			return 0, fmt.Errorf("recording media on %s: empty locator", key)
		}
		if f.Status != "" && f.Status != "skipped_type" {
			return 0, fmt.Errorf("recording media on %s: status %q is not recordable", key, f.Status)
		}
	}
	start, err := readMediaStartAt(ctx, q)
	if err != nil {
		return 0, err
	}
	if p.ContentAt.Before(start) {
		return 0, nil
	}
	cols, vals := p.parentColumns()
	insert := `INSERT INTO media_items (kind, parent_kind, parent_key, ` + strings.Join(cols, ", ") +
		`, anchor, locator, fetch_url, name, media_type, size_bytes, content_key, scope, from_owner, content_at, status)
		VALUES (?, ?, ?` + strings.Repeat(", ?", len(cols)) + `, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (parent_key, kind, locator) DO NOTHING`
	contentAt := mediaTime(p.ContentAt)
	inserted := 0
	for _, f := range found {
		status := f.Status
		if status == "" {
			status = "pending"
		}
		args := append([]any{f.Kind, p.Kind, key}, vals...)
		args = append(args, f.Anchor, f.Locator, f.FetchURL, f.Name, f.MediaType, f.Size, f.ContentKey,
			scope, p.FromOwner, contentAt, status)
		res, err := q.ExecContext(ctx, insert, args...)
		if err != nil {
			return inserted, fmt.Errorf("recording media %s on %s: %w", f.Kind, key, err)
		}
		n, _ := res.RowsAffected()
		inserted += int(n)
	}
	for _, kind := range replaceKinds {
		del := `DELETE FROM media_items WHERE parent_key = ? AND kind = ?`
		args := []any{key, kind}
		var keep []string
		for _, f := range found {
			if f.Kind == kind {
				keep = append(keep, "?")
				args = append(args, f.Locator)
			}
		}
		if len(keep) > 0 {
			del += ` AND locator NOT IN (` + strings.Join(keep, ", ") + `)`
		}
		if _, err := q.ExecContext(ctx, del, args...); err != nil {
			return inserted, fmt.Errorf("replacing media %s on %s: %w", kind, key, err)
		}
	}
	return inserted, nil
}

const mediaItemColumns = `id, kind, parent_kind, parent_key,
	COALESCE(slack_channel_id, ''), COALESCE(slack_ts, ''), COALESCE(ext_source_id, 0), COALESCE(ext_id, ''),
	COALESCE(gmail_account_id, 0), COALESCE(gmail_message_id, ''),
	COALESCE(imap_account_id, 0), COALESCE(imap_uidvalidity, 0), COALESCE(imap_uid, 0),
	COALESCE(chat_attachment_id, 0), COALESCE(target_image_id, 0),
	anchor, locator, fetch_url, name, media_type, size_bytes, content_key, scope, from_owner, content_at,
	status, attempts, error, title, body, image_text, keys_json, kb_source, kb_ref, discovered_at, described_at`

func scanMediaItem(row interface{ Scan(dest ...any) error }) (MediaItem, error) {
	var it MediaItem
	var keys string
	err := row.Scan(&it.ID, &it.Kind, &it.ParentKind, &it.ParentKey,
		&it.SlackChannelID, &it.SlackTS, &it.ExtSourceID, &it.ExtID,
		&it.GmailAccountID, &it.GmailMessageID,
		&it.IMAPAccountID, &it.IMAPUIDValidity, &it.IMAPUID,
		&it.ChatAttachmentID, &it.TargetImageID,
		&it.Anchor, &it.Locator, &it.FetchURL, &it.Name, &it.MediaType, &it.SizeBytes, &it.ContentKey,
		&it.Scope, &it.FromOwner, &it.ContentAt,
		&it.Status, &it.Attempts, &it.Error, &it.Title, &it.Body, &it.ImageText, &keys,
		&it.KBSource, &it.KBRef, &it.DiscoveredAt, &it.DescribedAt)
	if err != nil {
		return it, err
	}
	if err := json.Unmarshal([]byte(keys), &it.Keys); err != nil {
		return it, fmt.Errorf("media item %d: keys_json: %w", it.ID, err)
	}
	return it, nil
}

// ListPendingMedia returns up to limit rows the describe pass works:
// status 'pending' (plus 'unavailable' when visionOK, an image waiting for
// a vision-capable provider) with content_at >= start_at, after the
// cursor in (from_owner DESC, id) order — the owner's own items first.
func (db *DB) ListPendingMedia(ctx context.Context, visionOK bool, after MediaCursor, limit int) ([]MediaItem, error) {
	if limit <= 0 {
		return nil, fmt.Errorf("listing pending media: limit %d is not positive", limit)
	}
	q := `SELECT ` + mediaItemColumns + ` FROM media_items
		WHERE (status = 'pending' OR (? AND status = 'unavailable'))
		  AND content_at >= (SELECT start_at FROM media_state WHERE id = 1)`
	args := []any{visionOK}
	if after.ID > 0 {
		q += ` AND (from_owner < ? OR (from_owner = ? AND id > ?))`
		args = append(args, after.FromOwner, after.FromOwner, after.ID)
	}
	q += ` ORDER BY from_owner DESC, id LIMIT ?`
	args = append(args, limit)
	rows, err := db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("listing pending media: %w", err)
	}
	defer rows.Close()
	var out []MediaItem
	for rows.Next() {
		it, err := scanMediaItem(rows)
		if err != nil {
			return nil, fmt.Errorf("listing pending media: %w", err)
		}
		out = append(out, it)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing pending media: %w", err)
	}
	return out, nil
}

// FindDescribedMedia returns an 'ok' row with contentKey in scope — a
// description the pass may copy — or nil. Bytes seen in another account
// are never matched.
func (db *DB) FindDescribedMedia(ctx context.Context, contentKey, scope string) (*MediaItem, error) {
	if contentKey == "" {
		return nil, nil
	}
	row := db.QueryRowContext(ctx, `SELECT `+mediaItemColumns+` FROM media_items
		WHERE content_key = ? AND scope = ? AND status = 'ok' ORDER BY id LIMIT 1`, contentKey, scope)
	it, err := scanMediaItem(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("finding described media %s: %w", contentKey, err)
	}
	return &it, nil
}

// MediaItemAt returns the row of parentKey with kind and locator, or nil.
func (db *DB) MediaItemAt(ctx context.Context, parentKey, kind, locator string) (*MediaItem, error) {
	it, err := scanMediaItem(db.QueryRowContext(ctx, `SELECT `+mediaItemColumns+` FROM media_items
		WHERE parent_key = ? AND kind = ? AND locator = ?`, parentKey, kind, locator))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading media item %s %s on %s: %w", kind, locator, parentKey, err)
	}
	return &it, nil
}

// LastMediaItem returns the newest row of parentKey with kind, or nil.
func (db *DB) LastMediaItem(ctx context.Context, parentKey, kind string) (*MediaItem, error) {
	it, err := scanMediaItem(db.QueryRowContext(ctx, `SELECT `+mediaItemColumns+` FROM media_items
		WHERE parent_key = ? AND kind = ? ORDER BY id DESC LIMIT 1`, parentKey, kind))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading media %s on %s: %w", kind, parentKey, err)
	}
	return &it, nil
}

// getMediaItem reads one row by id.
func (db *DB) getMediaItem(ctx context.Context, id int64) (*MediaItem, error) {
	it, err := scanMediaItem(db.QueryRowContext(ctx, `SELECT `+mediaItemColumns+` FROM media_items WHERE id = ?`, id))
	if err != nil {
		return nil, fmt.Errorf("reading media item %d: %w", id, err)
	}
	return &it, nil
}

func checkMediaErrorClass(class string) error {
	if !slices.Contains(MediaErrorClasses, class) {
		// the refused value is not echoed: it may be raw error text
		return errors.New("media error is not a known error class")
	}
	return nil
}

// FinishMedia stores the pass's result for item id in one autocommit.
// A class outside MediaErrorClasses is refused and nothing is written.
func (db *DB) FinishMedia(ctx context.Context, id int64, r MediaResult) error {
	if r.ErrorClass != "" {
		if err := checkMediaErrorClass(r.ErrorClass); err != nil {
			return fmt.Errorf("finishing media item %d: %w", id, err)
		}
	}
	keys := r.Keys
	if keys == nil {
		keys = []string{}
	}
	keysJSON, err := json.Marshal(keys)
	if err != nil {
		return fmt.Errorf("finishing media item %d: %w", id, err)
	}
	res, err := db.ExecContext(ctx, `UPDATE media_items SET
			status = ?,
			content_key = CASE WHEN ? = '' THEN content_key ELSE ? END,
			kind = CASE WHEN ? = '' THEN kind ELSE ? END,
			title = ?, body = ?, image_text = ?, error = ?, keys_json = ?,
			kb_source = CASE WHEN ? = '' THEN kb_source ELSE ? END,
			kb_ref = CASE WHEN ? = '' THEN kb_ref ELSE ? END,
			described_at = ?
		WHERE id = ?`,
		r.Status, r.ContentKey, r.ContentKey, r.Kind, r.Kind,
		r.Title, r.Body, r.ImageText, r.ErrorClass, string(keysJSON),
		r.KBRef, r.KBSource, r.KBRef, r.KBRef, mediaTime(time.Now()), id)
	if err != nil {
		return fmt.Errorf("finishing media item %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("finishing media item %d: %w", id, sql.ErrNoRows)
	}
	return nil
}

// FailMedia counts one failed attempt of item id, storing the error class, in
// one autocommit; the attempt that reaches maxAttempts ends the row
// 'failed' (final = true), never retried. A class outside
// MediaErrorClasses is refused and nothing is written.
func (db *DB) FailMedia(ctx context.Context, id int64, class string, maxAttempts int) (bool, error) {
	if err := checkMediaErrorClass(class); err != nil {
		return false, fmt.Errorf("failing media item %d: %w", id, err)
	}
	var final bool
	err := db.QueryRowContext(ctx, `UPDATE media_items SET
			attempts = attempts + 1,
			error = ?,
			status = CASE WHEN attempts + 1 >= ? THEN 'failed' ELSE status END
		WHERE id = ?
		RETURNING status = 'failed'`, class, maxAttempts, id).Scan(&final)
	if err != nil {
		return false, fmt.Errorf("failing media item %d: %w", id, err)
	}
	return final, nil
}
