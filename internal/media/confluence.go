package media

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"log"
	"slices"
	"strings"
	"sync"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/extsync"
	"watchtower/internal/media/linkrule"
)

// Confluence media: a page's inline images (attachments of the page by file
// name, or external image URLs) and links, and an image attachment's own
// image, all recorded by the extsync engine through ConfluenceRecorder in
// the item's write transaction.

// confluenceAttachmentWait is how long an inline image waits for its
// attachment's document to be synced (the attachments stream runs after
// the pages stream and a cycle budget may cut between them) before it ends
// unreachable.
var confluenceAttachmentWait = 24 * time.Hour

// ConfluenceRecorder is the extsync engine's media seam (Options.Media) for
// Confluence: refs replace the document's image and link rows. External
// image URLs and links are checked again with Fetchable against the synced
// sources, the connected sites and denyHosts (DenyHosts(cfg)), and a link's
// content key is its normalized URL; anything Fetchable refuses is not
// recorded. Content older than media_state.start_at records nothing. When
// an attachment's image row is replaced (a new version, or no longer an
// image), the page's inline image of it ("att:<title>") is reset to
// pending in the same transaction, so it copies the new description.
func ConfluenceRecorder(denyHosts []string) extsync.MediaRecorder {
	return func(ctx context.Context, q extsync.Queryer, sourceID int64, extID string, refs []extsync.MediaRef, contentAt time.Time) error {
		p := db.MediaParent{Kind: "confluence", ExtSourceID: sourceID, ExtID: extID, ContentAt: contentAt}
		before, err := attachmentImageLocators(ctx, q, p.Key())
		if err != nil {
			return err
		}
		var refused map[string]bool
		found := make([]db.MediaFound, 0, len(refs))
		for _, r := range refs {
			f := db.MediaFound{Kind: r.Kind, Locator: r.Locator, Name: r.Name, Anchor: r.Anchor}
			if r.Kind == "link" || strings.HasPrefix(r.Locator, "url:") {
				if refused == nil {
					var err error
					if refused, err = RefusedHosts(ctx, q, denyHosts); err != nil {
						return err
					}
				}
				norm, ok := linkrule.Fetchable(r.URL, refused)
				if !ok {
					continue
				}
				f.Locator, f.FetchURL = "url:"+norm, r.URL
				if r.Kind == "link" {
					f.ContentKey = f.Locator
				}
			}
			found = append(found, f)
		}
		if _, err := db.RecordMedia(ctx, q, p, found, "image", "link"); err != nil {
			return err
		}
		if len(before) == 0 {
			return nil
		}
		after, err := attachmentImageLocators(ctx, q, p.Key())
		if err != nil {
			return err
		}
		for _, loc := range before {
			if !slices.Contains(after, loc) {
				return resetInlineImage(ctx, q, sourceID, extID)
			}
		}
		return nil
	}
}

// attachmentImageLocators lists the attachment image locators recorded on
// parentKey ("attachment:v<N>"; none on a page).
func attachmentImageLocators(ctx context.Context, q extsync.Queryer, parentKey string) ([]string, error) {
	rows, err := q.QueryContext(ctx, `SELECT locator FROM media_items
		WHERE parent_key = ? AND kind = 'image' AND locator LIKE 'attachment:%'`, parentKey)
	if err != nil {
		return nil, fmt.Errorf("media: reading images of %s: %w", parentKey, err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var l string
		if err := rows.Scan(&l); err != nil {
			return nil, fmt.Errorf("media: reading images of %s: %w", parentKey, err)
		}
		out = append(out, l)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("media: reading images of %s: %w", parentKey, err)
	}
	return out, nil
}

// resetInlineImage makes the inline image of attachment attID on its page
// ("att:<title>") pending again with nothing carried over, so the pass
// resolves it afresh.
func resetInlineImage(ctx context.Context, q extsync.Queryer, sourceID int64, attID string) error {
	var page, title string
	err := q.QueryRowContext(ctx, `SELECT parent_ext_id, title FROM ext_documents WHERE source_id = ? AND ext_id = ?`,
		sourceID, attID).Scan(&page, &title)
	if errors.Is(err, sql.ErrNoRows) || page == "" {
		return nil
	}
	if err != nil {
		return fmt.Errorf("media: reading attachment %s: %w", attID, err)
	}
	pageKey := db.MediaParent{Kind: "confluence", ExtSourceID: sourceID, ExtID: page}.Key()
	if _, err := q.ExecContext(ctx, `UPDATE media_items SET status = 'pending', attempts = 0, error = '',
			content_key = '', title = '', body = '', image_text = '', keys_json = '[]',
			kb_source = '', kb_ref = '', described_at = ''
		WHERE parent_key = ? AND kind = 'image' AND locator = ?`, pageKey, "att:"+title); err != nil {
		return fmt.Errorf("media: resetting the inline image of %s: %w", attID, err)
	}
	return nil
}

// ConfluenceOpener opens an image attachment's own item (locator
// "attachment:v<N>") through its source's account fetcher — the one the
// external sync uses, so its client and token refresh are shared — after
// re-reading the attachment's metadata (gone or no longer visible is
// ErrGone, above limit is ErrTooLarge). An inline "att:" image is resolved
// by ConfluenceResolver and an external "url:" image fetched by the pass's
// web fetcher; neither reaches an opener, and anything else is ErrGone.
type ConfluenceOpener struct {
	DB       *db.DB
	Fetchers map[int64]extsync.Fetcher // by jira_accounts.id
}

func (o ConfluenceOpener) Open(ctx context.Context, it db.MediaItem, limit int64) (io.ReadCloser, string, error) {
	if it.ParentKind != "confluence" || !strings.HasPrefix(it.Locator, "attachment:v") {
		return nil, "", ErrGone
	}
	var acct sql.NullInt64
	var parent string
	err := o.DB.QueryRowContext(ctx, `SELECT s.jira_account_id, d.parent_ext_id
		FROM ext_documents d JOIN ext_sources s ON s.id = d.source_id
		WHERE d.source_id = ? AND d.ext_id = ? AND d.kind = 'attachment'`, it.ExtSourceID, it.ExtID).Scan(&acct, &parent)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, "", ErrGone
	}
	if err != nil {
		return nil, "", fmt.Errorf("media: reading attachment %s: %w", it.ExtID, err)
	}
	f := o.Fetchers[acct.Int64]
	if !acct.Valid || f == nil {
		return nil, "", fmt.Errorf("media: no Confluence client for the source of attachment %s", it.ExtID)
	}
	att, err := f.Fetch(ctx, extsync.Container{}, extsync.ItemRef{Kind: extsync.KindAttachment, ExtID: it.ExtID, ParentID: parent})
	if err != nil {
		return nil, "", confluenceErr(err)
	}
	if att == nil {
		return nil, "", ErrGone
	}
	if att.Size > limit {
		return nil, "", ErrTooLarge
	}
	body, err := f.Download(ctx, att, limit)
	if err != nil {
		return nil, "", confluenceErr(err)
	}
	return confluenceBody{body}, att.MediaType, nil
}

// confluenceErr maps the extsync outcomes onto the opener's: gone and too
// large; anything else is a failed attempt as it is.
func confluenceErr(err error) error {
	switch {
	case errors.Is(err, extsync.ErrGone):
		return ErrGone
	case errors.Is(err, extsync.ErrTooLarge):
		return ErrTooLarge
	}
	return err
}

// confluenceBody maps a read past the download cap onto ErrTooLarge.
type confluenceBody struct{ rc io.ReadCloser }

func (b confluenceBody) Read(p []byte) (int, error) {
	n, err := b.rc.Read(p)
	if err != nil && errors.Is(err, extsync.ErrTooLarge) {
		err = ErrTooLarge
	}
	return n, err
}

func (b confluenceBody) Close() error { return b.rc.Close() }

// ConfluenceResolver resolves a page's inline image ("att:<filename>") to
// the item of the attachment it names: the attachment document under the
// same page with that title (Confluence keeps file names unique per page)
// and its one image item (its current version's). That item is copied when ok and waited
// for while pending; an attachment without an item (older than the start
// mark, or not an image) is ErrGone, and so is one still not synced
// confluenceAttachmentWait after the page's image was found (an unreadable
// discovery time keeps it waiting). Any other row is no reference.
type ConfluenceResolver struct {
	DB     *db.DB
	Now    func() time.Time // nil = time.Now
	Logger *log.Logger      // nil = no log
}

// badDiscoveredAt logs an unreadable discovered_at once per process.
var badDiscoveredAt sync.Once

func (r ConfluenceResolver) Resolve(ctx context.Context, it db.MediaItem) (*db.MediaItem, error) {
	file, inline := strings.CutPrefix(it.Locator, "att:")
	if it.ParentKind != "confluence" || !inline {
		return nil, nil
	}
	var attID string
	err := r.DB.QueryRowContext(ctx, `SELECT ext_id FROM ext_documents
		WHERE source_id = ? AND parent_ext_id = ? AND kind = 'attachment' AND title = ?
		ORDER BY modified_at DESC, ext_id LIMIT 1`, it.ExtSourceID, it.ExtID, file).Scan(&attID)
	if errors.Is(err, sql.ErrNoRows) {
		if r.waiting(it) {
			return &db.MediaItem{Status: "pending"}, nil
		}
		return nil, ErrGone
	}
	if err != nil {
		return nil, fmt.Errorf("media: resolving inline image of %s: %w", it.ExtID, err)
	}
	parent := db.MediaParent{Kind: "confluence", ExtSourceID: it.ExtSourceID, ExtID: attID}
	target, err := r.DB.LastMediaItem(ctx, parent.Key(), "image")
	if err != nil {
		return nil, err
	}
	if target == nil {
		return nil, ErrGone
	}
	return target, nil
}

// waiting reports an inline image found less than
// confluenceAttachmentWait ago.
func (r ConfluenceResolver) waiting(it db.MediaItem) bool {
	found, err := time.Parse(time.RFC3339, it.DiscoveredAt)
	if err != nil {
		badDiscoveredAt.Do(func() {
			if r.Logger != nil {
				r.Logger.Printf("media: item %d: unreadable discovered_at; its inline image keeps waiting", it.ID)
			}
		})
		return true
	}
	now := time.Now
	if r.Now != nil {
		now = r.Now
	}
	return now().Sub(found) < confluenceAttachmentWait
}

// ConfluenceRelinkHook is the pass's AfterDescribed hook for Confluence:
// once an image of a page or attachment is described, the document's links
// are re-recorded from its stored text, which now carries the image's
// text and keys (extsync.RelinkDocument: never the model's own title or
// description), in one short write transaction. Link rows never feed the
// links — a fetched page's summary is not the document's content.
func ConfluenceRelinkHook(d *db.DB, relink extsync.RelinkFunc) func(ctx context.Context, it db.MediaItem) error {
	return func(ctx context.Context, it db.MediaItem) error {
		if it.ParentKind != "confluence" || it.Kind != "image" || relink == nil {
			return nil
		}
		tx, err := d.BeginTx(ctx, nil)
		if err != nil {
			return fmt.Errorf("media: relinking %s: %w", it.ExtID, err)
		}
		defer func() { _ = tx.Rollback() }()
		var provider string
		err = tx.QueryRowContext(ctx, `SELECT provider FROM ext_sources WHERE id = ?`, it.ExtSourceID).Scan(&provider)
		if errors.Is(err, sql.ErrNoRows) {
			return nil // the source is gone, and its documents with it
		}
		if err != nil {
			return fmt.Errorf("media: relinking %s: %w", it.ExtID, err)
		}
		if err := extsync.RelinkDocument(ctx, tx, relink, provider, it.ExtSourceID, it.ExtID); err != nil {
			return err
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("media: relinking %s: %w", it.ExtID, err)
		}
		return nil
	}
}
