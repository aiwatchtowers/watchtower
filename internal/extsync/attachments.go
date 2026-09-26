package extsync

import (
	"context"
	"errors"
	"fmt"

	"golang.org/x/sync/errgroup"
)

// maxDownload caps an attachment download (global constraint, 25 MiB). It
// mirrors extract.MaxDownload, which extsync cannot import.
const maxDownload = 25 << 20

// Extraction statuses (the ext_documents.extract_status CHECK). The engine
// writes skipped_type and too_large itself; the rest come from the
// Extractor.
const (
	extractSkippedType = "skipped_type"
	extractTooLarge    = "too_large"
	extractFailed      = "failed"
)

var validExtractStatus = map[string]bool{
	"ok": true, extractSkippedType: true, extractTooLarge: true,
	"ocr_pending": true, "ocr_unavailable": true, extractFailed: true,
}

// reextractBatchSize is how many skipped_type rows one re-extraction chunk
// handles between budget checks (a variable so tests can shrink it).
var reextractBatchSize = 20

// attachmentsStream enumerates changed attachments
// (attachment_cursor/attachment_token): version gate, Fetch (metadata),
// Download, Extract, and only the extracted text is written — the bytes
// are never stored (EXT-03).
var attachmentsStream = streamSpec{name: streamAttachments, kind: KindAttachment, apply: (*Engine).processAttachmentBatch}

// extraction is the outcome of one attachment's download + extraction.
type extraction struct {
	sections []Section
	status   string
	gone     bool // Download reported ErrGone: delete the row
}

// processAttachmentBatch applies one attachments batch and returns the new
// cursor.
func (e *Engine) processAttachmentBatch(ctx context.Context, p pass, bt batch) (string, error) {
	stale, err := staleRefs(ctx, e.db, p.src.ID, bt.refs)
	if err != nil {
		return "", err
	}
	cursor, err := advanceCursor(bt.cursor, bt.refs)
	if err != nil {
		return "", err
	}
	err = e.applyAttachments(ctx, p, stale, func(q Queryer) error {
		return saveBatchState(ctx, q, p, bt, cursor)
	})
	if err != nil {
		return "", err
	}
	p.st.Unchanged += len(bt.refs) - len(stale)
	return cursor, nil
}

// applyAttachments fetches, downloads and extracts refs (up to
// fetchConcurrency in flight per step), then writes the rows and runs
// inTx in one transaction.
func (e *Engine) applyAttachments(ctx context.Context, p pass, refs []ItemRef, inTx func(q Queryer) error) error {
	items, err := fetchAll(ctx, p.f, p.c, refs)
	if err != nil {
		return err
	}
	results, err := e.extractAll(ctx, p.f, items)
	if err != nil {
		return err
	}
	for i, r := range results {
		switch {
		case items[i] == nil:
		case r.gone:
			items[i] = nil // deleted like a Fetch that found it gone
		default:
			items[i].Sections = r.sections
		}
	}
	st := Stats{}
	err = e.withTx(ctx, func(q Queryer) error {
		if err := writeItems(ctx, q, p.src.ID, refs, items, e.opts.Now(), &st); err != nil {
			return err
		}
		for i, it := range items {
			if it == nil {
				continue
			}
			if err := setExtractStatus(ctx, q, p.src.ID, it.Ref.ExtID, results[i].status); err != nil {
				return err
			}
		}
		return inTx(q)
	})
	if err != nil {
		return err
	}
	p.st.add(st)
	collectUsers(p.users, items, nil)
	return nil
}

// extractAll runs extractOne for every fetched item with up to
// fetchConcurrency in flight; results are in item order.
func (e *Engine) extractAll(ctx context.Context, f Fetcher, items []*Item) ([]extraction, error) {
	out := make([]extraction, len(items))
	g, gctx := errgroup.WithContext(ctx)
	g.SetLimit(fetchConcurrency)
	for i, it := range items {
		if it == nil {
			continue
		}
		g.Go(func() error {
			r, err := e.extractOne(gctx, f, it)
			out[i] = r
			return err
		})
	}
	if err := g.Wait(); err != nil {
		return nil, err
	}
	return out, nil
}

// extractOne downloads one attachment and extracts its text. No extractor,
// a type the extractor does not support, or a size above maxDownload are
// decided without a download. Too large and gone are outcomes; any other
// download, read or extraction failure is an error that fails the batch
// (retried next cycle).
func (e *Engine) extractOne(ctx context.Context, f Fetcher, it *Item) (extraction, error) {
	x := e.opts.Extractor
	if x == nil || !supports(x, it) {
		return extraction{status: extractSkippedType}, nil
	}
	if it.Size > maxDownload {
		return extraction{status: extractTooLarge}, nil
	}
	rc, err := f.Download(ctx, it, maxDownload)
	if r, done := downloadOutcome(err); done {
		return r, nil
	}
	if err != nil {
		return extraction{}, fmt.Errorf("extsync: downloading attachment %s: %w", it.Ref.ExtID, err)
	}
	defer rc.Close()
	secs, status, err := x.Extract(ctx, it.MediaType, it.Title, rc)
	if errors.Is(err, ErrTooLarge) {
		return extraction{status: extractTooLarge}, nil
	}
	if err != nil {
		return extraction{}, fmt.Errorf("extsync: extracting attachment %s: %w", it.Ref.ExtID, err)
	}
	if !validExtractStatus[status] {
		e.opts.Logger.Printf("attachment %s: extractor returned unknown status %q; recording failed", it.Ref.ExtID, status)
		return extraction{status: extractFailed}, nil
	}
	return extraction{sections: secs, status: status}, nil
}

// downloadOutcome maps the Download errors that are outcomes rather than
// failures: ErrGone and ErrTooLarge.
func downloadOutcome(err error) (extraction, bool) {
	switch {
	case errors.Is(err, ErrGone):
		return extraction{gone: true}, true
	case errors.Is(err, ErrTooLarge):
		return extraction{status: extractTooLarge}, true
	}
	return extraction{}, false
}

// supports asks the extractor whether it handles it's type; an extractor
// that cannot say is assumed to handle everything.
func supports(x Extractor, it *Item) bool {
	ts, ok := x.(TypeSupporter)
	return !ok || ts.Supports(it.MediaType, it.Title)
}

// setExtractStatus records a fresh extraction of extID: its status, with
// the OCR retry count reset.
func setExtractStatus(ctx context.Context, q Queryer, sourceID int64, extID, status string) error {
	if _, err := q.ExecContext(ctx, `UPDATE ext_documents SET extract_status = ?, extract_attempts = 0
		WHERE source_id = ? AND ext_id = ?`, status, sourceID, extID); err != nil {
		return fmt.Errorf("extsync: recording extraction of %s: %w", extID, err)
	}
	return nil
}

// reextractSkipped re-extracts, once, the attachments stored as
// skipped_type whose type the extractor now supports — rows written while
// no Extractor was wired. The delta never re-lists them (their version did
// not change), so they are found locally. A re-extracted row leaves
// skipped_type for good (Supports ⇔ Extract never answers skipped_type),
// so each row is handled once. Chunks of reextractBatchSize, the budget
// checked before each.
func (e *Engine) reextractSkipped(ctx context.Context, p pass, b *budget) error {
	ts, ok := e.opts.Extractor.(TypeSupporter)
	if !ok {
		return nil
	}
	refs, err := skippedAttachments(ctx, e.db, p.src.ID, ts)
	if err != nil {
		return err
	}
	for start := 0; start < len(refs); start += reextractBatchSize {
		if b.over() {
			p.st.Incomplete = true
			return nil
		}
		chunk := refs[start:min(start+reextractBatchSize, len(refs))]
		if err := e.applyAttachments(ctx, p, chunk, func(Queryer) error { return nil }); err != nil {
			return err
		}
	}
	return nil
}

// skippedAttachments lists the skipped_type attachments of sourceID whose
// type ts supports, as refs for a re-fetch.
func skippedAttachments(ctx context.Context, q Queryer, sourceID int64, ts TypeSupporter) ([]ItemRef, error) {
	rows, err := q.QueryContext(ctx, `SELECT ext_id, version, modified_at, parent_ext_id, media_type, title
		FROM ext_documents WHERE source_id = ? AND kind = 'attachment' AND extract_status = ?
		ORDER BY ext_id`, sourceID, extractSkippedType)
	if err != nil {
		return nil, fmt.Errorf("extsync: listing skipped attachments: %w", err)
	}
	defer rows.Close()
	var out []ItemRef
	for rows.Next() {
		var r ItemRef
		var modified, mediaType, title string
		if err := rows.Scan(&r.ExtID, &r.Version, &modified, &r.ParentID, &mediaType, &title); err != nil {
			return nil, fmt.Errorf("extsync: scanning skipped attachment: %w", err)
		}
		if !ts.Supports(mediaType, title) {
			continue
		}
		r.Kind = KindAttachment
		r.Modified, _ = parseCursor(modified) // informational only; the fetch brings the real one
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("extsync: listing skipped attachments: %w", err)
	}
	return out, nil
}
