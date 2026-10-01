package extsync

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
)

// maxDownload caps an attachment download (global constraint, 25 MiB). It
// mirrors extract.MaxDownload, which extsync cannot import.
const maxDownload = 25 << 20

// maxExtractAttempts bounds the tries of an attachment whose download or
// extraction failed transiently, or whose OCR could not run: the first
// failure is attempt 1 and both kinds share the budget.
const maxExtractAttempts = 3

// Extraction statuses (the ext_documents.extract_status CHECK). The engine
// writes skipped_type, too_large and a transient failed itself; the rest
// come from the Extractor.
const (
	extractSkippedType = "skipped_type"
	extractTooLarge    = "too_large"
	extractFailed      = "failed"
	extractOCRPending  = "ocr_pending"
	extractOCRMissing  = "ocr_unavailable"
)

var validExtractStatus = map[string]bool{
	"ok": true, extractSkippedType: true, extractTooLarge: true,
	extractOCRPending: true, extractOCRMissing: true, extractFailed: true,
}

// extractDeadline bounds one attachment's extraction step as a whole (a
// variable so tests can shrink it). The cycle budget only stops new
// launches, and the extractor's per-step timeouts stack: the PDF helper
// (60s), a cold OCR-helper signature check (2 codesign calls, 20s each),
// then up to 5 OCR batches (60s each, MaxOCRPages/10), each helper run
// with a 5s kill grace — 7m10s. 8 minutes covers that worst case of a
// large but healthy scan with margin; past it the attachment is a
// transient failure (attempts++) and the batch moves on. The download is
// not under it — the HTTP client's own timeout bounds that (ruling R14).
// TestExtractDeadlineCoversTheOCRWorstCase derives the bound from the
// extractor's constants.
var extractDeadline = 8 * time.Minute

// reextractBatchSize is how many rows one revisit chunk handles between
// budget checks (a variable so tests can shrink it).
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
	// transient: the download or extraction failed for this attachment
	// only; stored failed with extract_attempts+1 and retried later.
	transient bool
}

// degraded reports an outcome that is retried later and must not replace
// the text a stored row already has: a transient failure, or OCR that
// could not run (ocr_pending).
func (x extraction) degraded() bool {
	return x.transient || x.status == extractOCRPending
}

// processAttachmentBatch applies one attachments batch and returns the new
// cursor. When the budget stops the fan-out mid-batch, only the processed
// prefix is committed: the cursor moves to the prefix's max modification
// time and the stored token is cleared (a provider token cannot be pinned
// to a partial page), so the next cycle re-lists from the cursor — the
// version gate makes the already-written refs free. The gate also skips a
// version already tried and pending (see staleAttachmentRefs): its retries
// belong to revisitAttachments.
func (e *Engine) processAttachmentBatch(ctx context.Context, p pass, bt batch) (string, error) {
	stale, err := staleAttachmentRefs(ctx, e.db, p.src.ID, bt.refs)
	if err != nil {
		return "", err
	}
	var cursor string
	done, err := e.applyAttachments(ctx, p, stale, func(q Queryer, done int) error {
		var cerr error
		cursor, bt, cerr = cutBatch(bt, stale, done)
		if cerr != nil {
			return cerr
		}
		return saveBatchState(ctx, q, p, bt, cursor)
	})
	if err != nil {
		return "", err
	}
	if done < len(stale) {
		p.st.Incomplete = true
	}
	p.st.Unchanged += len(bt.refs) - done
	return cursor, nil
}

// cutBatch returns the cursor and batch state to commit when done of the
// batch's stale refs were processed: the whole batch, or the refs listed
// before the first unprocessed stale ref, with no token.
func cutBatch(bt batch, stale []ItemRef, done int) (string, batch, error) {
	if done < len(stale) {
		first := stale[done].ExtID
		pos := 0
		for pos < len(bt.refs) && bt.refs[pos].ExtID != first {
			pos++
		}
		bt.refs, bt.token, bt.backfillDone = bt.refs[:pos], "", false
	}
	cursor, err := advanceCursor(bt.cursor, bt.refs)
	return cursor, bt, err
}

// applyAttachments fetches refs (up to fetchConcurrency in flight),
// downloads and extracts them one at a time (no new item started once the
// budget is spent), then writes the processed prefix and runs inTx in one
// transaction. It returns how many refs were processed.
func (e *Engine) applyAttachments(ctx context.Context, p pass, refs []ItemRef, inTx func(q Queryer, done int) error) (int, error) {
	items, err := fetchAll(ctx, p.f, p.c, refs)
	if err != nil {
		return 0, err
	}
	results, done, err := e.extractAll(ctx, p, items)
	if err != nil {
		return 0, err
	}
	refs, items, results = refs[:done], items[:done], results[:done]
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
		if err := writeAttachmentItems(ctx, q, p.src.ID, refs, items, results, p.revisit, e.opts.Now(), &st); err != nil {
			return err
		}
		if err := writeExtractions(ctx, q, p, items, results); err != nil {
			return err
		}
		if err := e.relinkDocs(ctx, q, p.src.Provider, p.src.ID, refIDs(refs)); err != nil {
			return err
		}
		return inTx(q, done)
	})
	if err != nil {
		return 0, err
	}
	p.st.add(st)
	collectUsers(p.users, items, nil)
	return done, nil
}

// writeAttachmentItems writes the fetched attachments, except that a
// degraded outcome for a row already stored leaves that row's content
// alone — its text, and the version that text belongs to — so search keeps
// the last good text while the retry is pending. The revisit re-fetches
// such a row by id, so it still gets the new version. The try that spends
// the last attempt (a revisit at maxExtractAttempts-1) on a new version
// writes that version with whatever it got instead: no retry is left, and
// the old text belongs to a version that no longer exists, so the partial
// text of an ocr_pending result (or none, for a failure) replaces it. A
// try of the stored version itself never overwrites its text.
func writeAttachmentItems(ctx context.Context, q Queryer, sourceID int64, refs []ItemRef, items []*Item, results []extraction, revisit bool, now time.Time, st *Stats) error {
	var ids []string
	for i, it := range items {
		if it != nil && results[i].degraded() {
			ids = append(ids, it.Ref.ExtID)
		}
	}
	stored, err := storedAttempts(ctx, q, sourceID, ids)
	if err != nil {
		return err
	}
	var wrefs []ItemRef
	var witems []*Item
	for i, it := range items {
		if it != nil && results[i].degraded() {
			if a, ok := stored[it.Ref.ExtID]; ok && !a.lastTry(it.Ref.Version, revisit) {
				continue
			}
		}
		wrefs, witems = append(wrefs, refs[i]), append(witems, it)
	}
	return writeItems(ctx, q, sourceID, wrefs, witems, now, st)
}

// storedAttempt is a stored attachment row's version and attempt count.
type storedAttempt struct{ version, attempts int }

// lastTry reports whether a degraded try of version spends the row's last
// attempt on a version other than the stored one. Only a revisit counts on
// from the stored attempts; a delta try of a newly listed version starts
// at 1.
func (a storedAttempt) lastTry(version int, revisit bool) bool {
	return revisit && version != a.version && a.attempts+1 >= maxExtractAttempts
}

// storedAttempts reads the version and attempt count of the attachments
// already stored under sourceID, in one query.
func storedAttempts(ctx context.Context, q Queryer, sourceID int64, ids []string) (map[string]storedAttempt, error) {
	out := make(map[string]storedAttempt, len(ids))
	if len(ids) == 0 {
		return out, nil
	}
	args := make([]any, 0, len(ids)+1)
	args = append(args, sourceID)
	for _, id := range ids {
		args = append(args, id)
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",")
	rows, err := q.QueryContext(ctx, `SELECT ext_id, version, extract_attempts FROM ext_documents
		WHERE source_id = ? AND ext_id IN (`+placeholders+`)`, args...)
	if err != nil {
		return nil, fmt.Errorf("extsync: reading attachment attempts: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var a storedAttempt
		if err := rows.Scan(&id, &a.version, &a.attempts); err != nil {
			return nil, fmt.Errorf("extsync: scanning attachment attempts: %w", err)
		}
		out[id] = a
	}
	return out, rows.Err()
}

// writeExtractions records each written attachment's extraction status. A
// degraded outcome counts an attempt and waits for a later cycle.
func writeExtractions(ctx context.Context, q Queryer, p pass, items []*Item, results []extraction) error {
	for i, it := range items {
		if it == nil {
			continue
		}
		r, id := results[i], it.Ref.ExtID
		status := r.status
		if r.transient {
			status = extractFailed
		}
		var err error
		if r.degraded() {
			err = recordAttempt(ctx, q, p.src.ID, id, status, it.Ref.Version, !p.revisit)
			p.retried[id] = true
		} else {
			err = setExtractStatus(ctx, q, p.src.ID, id, status)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

// extractAll runs extractOne for the fetched items one at a time, in
// order. Extraction may run the PDF and OCR helpers for minutes and the
// daemon cycle is serial, so items are never extracted concurrently: the
// cycle overshoots its budget by at most one attachment. Once the budget is
// spent no further item is started — the first one always is, so a batch
// always progresses; done is the length of the processed prefix and
// results are in item order.
func (e *Engine) extractAll(ctx context.Context, p pass, items []*Item) ([]extraction, int, error) {
	out := make([]extraction, len(items))
	for i, it := range items {
		if i > 0 && p.budget != nil && p.budget.over() {
			return out, i, nil
		}
		if it == nil {
			continue
		}
		r, err := e.extractOne(ctx, p.f, it)
		if err != nil {
			return nil, 0, err
		}
		out[i] = r
	}
	return out, len(items), nil
}

// extractOne downloads one attachment and extracts its text. No extractor,
// a type the extractor does not support, or a size above maxDownload are
// decided without a download. Gone and too large are outcomes. Any other
// failure of this one attachment (a download that times out, a network
// error, a temp-file error) is a transient failure recorded on its row,
// never a batch error: only an auth/consent failure or a cancelled ctx
// aborts the batch.
//
// The extraction step runs under extractDeadline; hitting it is this
// attachment's transient failure, while a cancellation of ctx itself still
// aborts the batch (attachmentFailure checks the caller's ctx, not the
// deadline's).
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
		return e.attachmentFailure(ctx, it, "downloading", err)
	}
	defer rc.Close()
	return e.extractBody(ctx, x, it, rc)
}

// extractBody runs the extractor on a downloaded body under
// extractDeadline; failures are classified against the caller's ctx.
func (e *Engine) extractBody(ctx context.Context, x Extractor, it *Item, body io.Reader) (extraction, error) {
	actx, cancel := context.WithTimeout(ctx, extractDeadline)
	defer cancel()
	secs, status, err := x.Extract(actx, it.MediaType, it.Title, body)
	if errors.Is(err, ErrTooLarge) {
		return extraction{status: extractTooLarge}, nil
	}
	if err != nil {
		return e.attachmentFailure(ctx, it, "extracting", err)
	}
	if !validExtractStatus[status] {
		e.opts.Logger.Printf("attachment %s: extractor returned unknown status %q; recording failed", it.Ref.ExtID, status)
		return extraction{status: extractFailed}, nil
	}
	return extraction{sections: secs, status: status}, nil
}

// attachmentFailure classifies a download/extraction error: auth, consent
// and a cancelled ctx abort the batch; anything else is this attachment's
// transient failure.
func (e *Engine) attachmentFailure(ctx context.Context, it *Item, what string, err error) (extraction, error) {
	if ctx.Err() != nil || isExpected(err) {
		return extraction{}, fmt.Errorf("extsync: %s attachment %s: %w", what, it.Ref.ExtID, err)
	}
	e.opts.Logger.Printf("attachment %s: %s failed (will retry): %v", it.Ref.ExtID, what, err)
	return extraction{status: extractFailed, transient: true}, nil
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

// hasOCR asks the extractor whether OCR is available; one that cannot say
// has none (controller ruling R2).
func hasOCR(ctx context.Context, x Extractor) bool {
	c, ok := x.(OCRCapable)
	return ok && c.HasOCR(ctx)
}

// supports asks the extractor whether it handles it's type; an extractor
// that cannot say is assumed to handle everything.
func supports(x Extractor, it *Item) bool {
	ts, ok := x.(TypeSupporter)
	return !ok || ts.Supports(it.MediaType, it.Title)
}

// setExtractStatus records a fresh extraction of extID: its status, with
// the retry count reset. A content failure the extractor reports (a
// corrupt file) is final: attempts 0, never retried.
func setExtractStatus(ctx context.Context, q Queryer, sourceID int64, extID, status string) error {
	if _, err := q.ExecContext(ctx, `UPDATE ext_documents SET extract_status = ?, extract_attempts = 0
		WHERE source_id = ? AND ext_id = ?`, status, sourceID, extID); err != nil {
		return fmt.Errorf("extsync: recording extraction of %s: %w", extID, err)
	}
	return nil
}

// revisitAttachments re-fetches and re-extracts, after the streams, the
// stored attachment rows the delta never re-lists (their version did not
// change):
//   - skipped_type rows whose type the extractor now supports — written
//     while no Extractor was wired; each is handled once, since Supports ⇔
//     Extract never answers skipped_type;
//   - degraded rows (failed or ocr_pending, 0 < extract_attempts < 3) from
//     an earlier cycle — rows that degraded in this pass wait for the next
//     one, so each gets at most one try per cycle and 3 in all;
//   - ocr_unavailable rows, only while the extractor reports HasOCR — never
//     downloaded otherwise; each is handled once, since an extractor with
//     OCR never answers ocr_unavailable.
//
// Chunks of reextractBatchSize, the budget checked before each; a chunk
// the budget cuts commits its processed prefix.
func (e *Engine) revisitAttachments(ctx context.Context, p pass, b *budget) error {
	if e.opts.Extractor == nil {
		return nil
	}
	p.revisit = true
	refs, err := revisitRefs(ctx, e.db, p.src.ID, e.opts.Extractor, p.retried)
	if err != nil {
		return err
	}
	for start := 0; start < len(refs); start += reextractBatchSize {
		if b.over() {
			p.st.Incomplete = true
			return nil
		}
		chunk := refs[start:min(start+reextractBatchSize, len(refs))]
		done, err := e.applyAttachments(ctx, p, chunk, func(Queryer, int) error { return nil })
		if err != nil {
			return err
		}
		if done < len(chunk) {
			p.st.Incomplete = true
			return nil
		}
	}
	return nil
}

// revisitRefs lists the attachment rows revisitAttachments handles, as refs
// for a re-fetch, skipping the ids in exclude.
func revisitRefs(ctx context.Context, q Queryer, sourceID int64, x Extractor, exclude map[string]bool) ([]ItemRef, error) {
	rows, err := q.QueryContext(ctx, `SELECT ext_id, version, modified_at, parent_ext_id, media_type, title, extract_status
		FROM ext_documents WHERE source_id = ? AND kind = 'attachment'
		  AND (extract_status = ?
		    OR (extract_status IN (?, ?) AND extract_attempts > 0 AND extract_attempts < ?)
		    OR (extract_status = ? AND ? AND extract_attempts < ?))
		ORDER BY ext_id`, sourceID, extractSkippedType, extractFailed, extractOCRPending, maxExtractAttempts,
		extractOCRMissing, hasOCR(ctx, x), maxExtractAttempts)
	if err != nil {
		return nil, fmt.Errorf("extsync: listing attachments to revisit: %w", err)
	}
	defer rows.Close()
	ts, _ := x.(TypeSupporter)
	var out []ItemRef
	for rows.Next() {
		var r ItemRef
		var modified, mediaType, title, status string
		if err := rows.Scan(&r.ExtID, &r.Version, &modified, &r.ParentID, &mediaType, &title, &status); err != nil {
			return nil, fmt.Errorf("extsync: scanning attachment to revisit: %w", err)
		}
		if exclude[r.ExtID] || (status == extractSkippedType && (ts == nil || !ts.Supports(mediaType, title))) {
			continue
		}
		r.Kind = KindAttachment
		r.Modified, _ = parseCursor(strings.TrimSpace(modified)) // informational; the fetch brings the real one
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("extsync: listing attachments to revisit: %w", err)
	}
	return out, nil
}
