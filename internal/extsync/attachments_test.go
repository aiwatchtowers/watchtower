package extsync

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// fakeExtractor reads the whole body and answers "text of <name>" (ok), or
// the status configured for the name. supported limits Supports (nil = all).
type fakeExtractor struct {
	mu        sync.Mutex
	calls     map[string]int
	status    map[string]string
	supported map[string]bool // media types
	onExtract func()
}

func newFakeExtractor() *fakeExtractor {
	return &fakeExtractor{calls: map[string]int{}, status: map[string]string{}}
}

func (x *fakeExtractor) Extract(_ context.Context, _, name string, r io.Reader) ([]Section, string, error) {
	x.mu.Lock()
	x.calls[name]++
	status, hook := x.status[name], x.onExtract
	x.mu.Unlock()
	if hook != nil {
		hook()
	}
	if _, err := io.ReadAll(r); err != nil {
		return nil, "", fmt.Errorf("fake extractor: reading: %w", err)
	}
	if status != "" {
		return nil, status, nil
	}
	return []Section{{Text: "text of " + name}}, "ok", nil
}

func (x *fakeExtractor) Supports(mediaType, _ string) bool {
	return x.supported == nil || x.supported[mediaType]
}

func (x *fakeExtractor) callCount(name string) int {
	x.mu.Lock()
	defer x.mu.Unlock()
	return x.calls[name]
}

// manualClock only moves when told to.
type manualClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *manualClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *manualClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

// attachmentRow is the stored state of one attachment.
type attachmentRow struct {
	kind, parent, status, mediaType string
	version                         int
	size                            int64
	sections                        []Section
}

func loadAttachment(t *testing.T, d *db.DB, sourceID int64, id string) (attachmentRow, bool) {
	t.Helper()
	var r attachmentRow
	var sections string
	err := d.QueryRow(`SELECT kind, parent_ext_id, extract_status, media_type, version, size_bytes, sections_json
		FROM ext_documents WHERE source_id = ? AND ext_id = ?`, sourceID, id).
		Scan(&r.kind, &r.parent, &r.status, &r.mediaType, &r.version, &r.size, &sections)
	if errors.Is(err, sql.ErrNoRows) {
		return r, false
	}
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(sections), &r.sections))
	return r, true
}

var t0 = time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)

func newAttachmentEngine(t *testing.T, x Extractor) (*db.DB, db.ExtSource, *fakeFetcher, *Engine) {
	t.Helper()
	d, src := newSourceDB(t)
	f := newFake()
	f.addPage("p1", 1, t0)
	e := New(d, Options{Extractor: x})
	e.SetFetcher(src.JiraAccountID, f)
	return d, src, f, e
}

func TestAttachmentExtractedWithParent(t *testing.T) {
	x := newFakeExtractor()
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "notes.txt", "text/plain", []byte("hello"), -1)

	_, err := e.Run(context.Background())
	require.NoError(t, err)
	row, ok := loadAttachment(t, d, src.ID, "a1")
	require.True(t, ok)
	assert.Equal(t, attachmentRow{kind: "attachment", parent: "p1", status: "ok", mediaType: "text/plain",
		version: 1, size: 5, sections: []Section{{Text: "text of notes.txt"}}}, row)
	assert.Equal(t, 1, f.downloadCount("a1"))
	assert.NotEmpty(t, loadSource(t, d).AttachmentCursor, "the attachments stream advances its own cursor")
}

func TestAttachmentVersionGate(t *testing.T) {
	x := newFakeExtractor()
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "notes.txt", "text/plain", []byte("hello"), -1)

	for range 2 {
		_, err := e.Run(context.Background())
		require.NoError(t, err)
	}
	assert.Equal(t, 1, f.fetchCount("a1"), "an unchanged version is never re-fetched")
	assert.Equal(t, 1, f.downloadCount("a1"))

	f.mutate("a1", 2, t0.Add(time.Hour))
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 2, f.fetchCount("a1"))
	assert.Equal(t, 2, f.downloadCount("a1"))
	row, _ := loadAttachment(t, d, src.ID, "a1")
	assert.Equal(t, 2, row.version)
}

func TestAttachmentAboveCapIsTooLargeWithoutDownload(t *testing.T) {
	x := newFakeExtractor()
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "huge.pdf", "application/pdf", []byte("x"), maxDownload+1)

	_, err := e.Run(context.Background())
	require.NoError(t, err)
	row, ok := loadAttachment(t, d, src.ID, "a1")
	require.True(t, ok)
	assert.Equal(t, "too_large", row.status)
	assert.Empty(t, row.sections)
	assert.Equal(t, 0, f.downloadCount("a1"), "Download is never called above the cap")
	assert.Equal(t, 0, x.callCount("huge.pdf"))
}

func TestAttachmentNilExtractorSkippedType(t *testing.T) {
	d, src, f, e := newAttachmentEngine(t, nil)
	f.addAttachment("a1", "p1", 1, t0, "notes.txt", "text/plain", []byte("hello"), -1)

	_, err := e.Run(context.Background())
	require.NoError(t, err)
	row, ok := loadAttachment(t, d, src.ID, "a1")
	require.True(t, ok)
	assert.Equal(t, "skipped_type", row.status)
	assert.Equal(t, "p1", row.parent)
	assert.Equal(t, 0, f.downloadCount("a1"))
}

func TestAttachmentUnsupportedTypeNotDownloaded(t *testing.T) {
	x := newFakeExtractor()
	x.supported = map[string]bool{"text/plain": true}
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("z1", "p1", 1, t0, "bundle.zip", "application/zip", []byte("PK"), -1)

	_, err := e.Run(context.Background())
	require.NoError(t, err)
	row, _ := loadAttachment(t, d, src.ID, "z1")
	assert.Equal(t, "skipped_type", row.status)
	assert.Equal(t, 0, f.downloadCount("z1"))
}

func TestAttachmentTooLargeDuringRead(t *testing.T) {
	x := newFakeExtractor()
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "big.txt", "text/plain", []byte("partial"), 10)
	f.readErr["a1"] = fmt.Errorf("body: %w", ErrTooLarge)

	_, err := e.Run(context.Background())
	require.NoError(t, err)
	row, ok := loadAttachment(t, d, src.ID, "a1")
	require.True(t, ok)
	assert.Equal(t, "too_large", row.status)
	assert.Empty(t, row.sections)
}

func TestAttachmentDownloadTooLargeUpfront(t *testing.T) {
	x := newFakeExtractor()
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "big.txt", "text/plain", []byte("x"), 1)
	f.downloadErr["a1"] = fmt.Errorf("content-length: %w", ErrTooLarge)

	_, err := e.Run(context.Background())
	require.NoError(t, err)
	row, _ := loadAttachment(t, d, src.ID, "a1")
	assert.Equal(t, "too_large", row.status)
	assert.Equal(t, 0, x.callCount("big.txt"))
}

// TestAttachmentGoneOnDownload: an attachment deleted between Fetch and
// Download is gone (its row deleted), not an error that would block the
// batch every cycle.
func TestAttachmentGoneOnDownload(t *testing.T) {
	x := newFakeExtractor()
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "notes.txt", "text/plain", []byte("hello"), -1)
	f.addAttachment("a2", "p1", 1, t0, "new.txt", "text/plain", []byte("new"), -1)
	f.downloadErr["a2"] = fmt.Errorf("download: %w", ErrGone) // never stored
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	_, ok := loadAttachment(t, d, src.ID, "a1")
	require.True(t, ok)
	_, ok = loadAttachment(t, d, src.ID, "a2")
	assert.False(t, ok, "a new attachment gone at download is not stored")

	f.mutate("a1", 2, t0.Add(time.Hour))
	f.downloadErr["a1"] = fmt.Errorf("download: %w", ErrGone)
	st, err := e.Run(context.Background())
	require.NoError(t, err, "gone is not an error")
	_, ok = loadAttachment(t, d, src.ID, "a1")
	assert.False(t, ok, "the stored row of an attachment gone at download is deleted")
	assert.Positive(t, st.Deleted)
	cur := loadSource(t, d)
	assert.Equal(t, "ok", cur.Status)
	assert.Equal(t, formatTime(t0.Add(time.Hour)), cur.AttachmentCursor, "the cursor moves past the gone attachment")
}

func extractAttempts(t *testing.T, d *db.DB, sourceID int64, id string) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT extract_attempts FROM ext_documents WHERE source_id = ? AND ext_id = ?`,
		sourceID, id).Scan(&n))
	return n
}

// TestAttachmentPersistentFailureDoesNotBlock: one attachment whose download
// always fails is recorded failed with attempts+1 while the rest of the
// batch lands, the cursor advances and the daily reconcile still runs; the
// row is retried once per later cycle until 3 attempts, then left alone.
func TestAttachmentPersistentFailureDoesNotBlock(t *testing.T) {
	x := newFakeExtractor()
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "one.txt", "text/plain", []byte("1"), -1)
	f.addAttachment("a2", "p1", 1, t0.Add(time.Minute), "two.txt", "text/plain", []byte("2"), -1)
	f.addAttachment("a3", "p1", 1, t0.Add(2*time.Minute), "three.txt", "text/plain", []byte("3"), -1)
	f.downloadErr["a2"] = errors.New("request timed out")

	_, err := e.Run(context.Background())
	require.NoError(t, err)
	for _, id := range []string{"a1", "a3"} {
		row, ok := loadAttachment(t, d, src.ID, id)
		require.True(t, ok, id)
		assert.Equal(t, "ok", row.status, id)
	}
	row, ok := loadAttachment(t, d, src.ID, "a2")
	require.True(t, ok)
	assert.Equal(t, "failed", row.status)
	assert.Equal(t, 1, extractAttempts(t, d, src.ID, "a2"))
	assert.Equal(t, 1, f.downloadCount("a2"), "a row that failed in this pass waits for the next cycle")
	cur := loadSource(t, d)
	assert.Equal(t, formatTime(t0.Add(2*time.Minute)), cur.AttachmentCursor, "the cursor moves past the failure")
	assert.NotEmpty(t, cur.LastReconcileAt, "the reconcile still runs")
	assert.Equal(t, "ok", cur.Status)

	for want := 2; want <= 3; want++ {
		_, err = e.Run(context.Background())
		require.NoError(t, err)
		assert.Equal(t, want, f.downloadCount("a2"), "retried once per cycle")
		assert.Equal(t, want, extractAttempts(t, d, src.ID, "a2"))
	}
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 3, f.downloadCount("a2"), "no retry after 3 attempts")
	assert.Equal(t, 1, f.downloadCount("a1"), "healthy rows are never revisited")
}

func TestAttachmentRetrySucceeds(t *testing.T) {
	x := newFakeExtractor()
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "one.txt", "text/plain", []byte("1"), -1)
	f.readErr["a1"] = errors.New("connection reset mid-body") // an extraction read error is per-attachment too
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	row, _ := loadAttachment(t, d, src.ID, "a1")
	require.Equal(t, "failed", row.status)

	delete(f.readErr, "a1")
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	row, _ = loadAttachment(t, d, src.ID, "a1")
	assert.Equal(t, "ok", row.status)
	assert.Equal(t, []Section{{Text: "text of one.txt"}}, row.sections)
	assert.Equal(t, 0, extractAttempts(t, d, src.ID, "a1"))
}

// TestAttachmentAuthErrorStillAborts: an auth failure is not a per-
// attachment failure — the batch aborts and the source records it.
func TestAttachmentAuthErrorStillAborts(t *testing.T) {
	x := newFakeExtractor()
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "one.txt", "text/plain", []byte("1"), -1)
	f.downloadErr["a1"] = fmt.Errorf("download: %w", ErrAuthRevoked)

	_, err := e.Run(context.Background())
	require.NoError(t, err, "Run records revoked instead of returning it")
	_, ok := loadAttachment(t, d, src.ID, "a1")
	assert.False(t, ok)
	cur := loadSource(t, d)
	assert.Equal(t, "revoked", cur.Status)
	assert.Empty(t, cur.AttachmentCursor)
}

// TestAttachmentBudgetCommitsProcessedPrefix: when the budget runs out
// mid-batch, no further download starts; the processed prefix is
// committed with the cursor at its max and no token, and later cycles
// finish the rest without downloading anything twice.
func TestAttachmentBudgetCommitsProcessedPrefix(t *testing.T) {
	d, src := newSourceDB(t)
	f := newFake()
	f.pageSize = 20
	f.addPage("p1", 1, t0)
	for i := range 8 {
		f.addAttachment(fmt.Sprintf("a%d", i), "p1", 1, t0.Add(time.Duration(i+1)*time.Minute),
			fmt.Sprintf("n%d.txt", i), "text/plain", []byte("x"), -1)
	}
	clock := &stepClock{t: t0, step: 10 * time.Second}
	e := New(d, Options{Extractor: newFakeExtractor(), Budget: 70 * time.Second, Now: clock.Now})
	e.SetFetcher(src.JiraAccountID, f)

	st, err := e.Run(context.Background())
	require.NoError(t, err)
	require.True(t, st.Incomplete)
	stored := countStatus(t, d, src.ID, "ok")
	require.Greater(t, stored, 0)
	require.Less(t, stored, 8, "the budget cut the batch")
	for i := range stored {
		_, ok := loadAttachment(t, d, src.ID, fmt.Sprintf("a%d", i))
		assert.True(t, ok, "a prefix is committed: a%d", i)
	}
	cur := loadSource(t, d)
	assert.Equal(t, formatTime(t0.Add(time.Duration(stored)*time.Minute)), cur.AttachmentCursor, "cursor = the prefix's max")
	assert.Empty(t, cur.AttachmentToken, "a partial page stores no token")

	for range 10 {
		if countStatus(t, d, src.ID, "ok") == 8 {
			break
		}
		_, err = e.Run(context.Background())
		require.NoError(t, err)
	}
	assert.Equal(t, 8, countStatus(t, d, src.ID, "ok"))
	for i := range 8 {
		assert.Equal(t, 1, f.downloadCount(fmt.Sprintf("a%d", i)), "a%d downloaded once", i)
	}
}

func TestAttachmentExtractorStatusStored(t *testing.T) {
	x := newFakeExtractor()
	x.status["broken.docx"] = "failed"
	x.status["scan.png"] = "ocr_unavailable"
	x.status["weird.bin"] = "not-a-status"
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "broken.docx", "application/x", []byte("x"), -1)
	f.addAttachment("a2", "p1", 1, t0, "scan.png", "image/png", []byte("x"), -1)
	f.addAttachment("a3", "p1", 1, t0, "weird.bin", "application/y", []byte("x"), -1)

	_, err := e.Run(context.Background())
	require.NoError(t, err)
	for id, want := range map[string]string{"a1": "failed", "a2": "ocr_unavailable", "a3": "failed"} {
		row, ok := loadAttachment(t, d, src.ID, id)
		require.True(t, ok, id)
		assert.Equal(t, want, row.status, id)
	}
}

// TestAttachmentReextractsSkippedOnceExtractorArrives: rows stored as
// skipped_type while no extractor was wired are re-extracted once an
// extractor that supports their type is present — never re-listed by the
// delta, so the engine finds them itself; unsupported types stay skipped
// and are never downloaded.
func TestAttachmentReextractsSkippedOnceExtractorArrives(t *testing.T) {
	d, src, f, e := newAttachmentEngine(t, nil)
	f.addAttachment("a1", "p1", 1, t0, "notes.txt", "text/plain", []byte("hello"), -1)
	f.addAttachment("z1", "p1", 1, t0, "bundle.zip", "application/zip", []byte("PK"), -1)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	row, _ := loadAttachment(t, d, src.ID, "a1")
	require.Equal(t, "skipped_type", row.status)

	x := newFakeExtractor()
	x.supported = map[string]bool{"text/plain": true}
	e2 := New(d, Options{Extractor: x})
	e2.SetFetcher(src.JiraAccountID, f)
	_, err = e2.Run(context.Background())
	require.NoError(t, err)
	row, _ = loadAttachment(t, d, src.ID, "a1")
	assert.Equal(t, "ok", row.status)
	assert.Equal(t, []Section{{Text: "text of notes.txt"}}, row.sections)
	zrow, _ := loadAttachment(t, d, src.ID, "z1")
	assert.Equal(t, "skipped_type", zrow.status)
	assert.Equal(t, 1, f.downloadCount("a1"))
	assert.Equal(t, 0, f.downloadCount("z1"))

	_, err = e2.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, f.downloadCount("a1"), "re-extraction happens once")
	assert.Equal(t, 2, f.fetchCount("a1"))
}

func TestReextractRespectsBudget(t *testing.T) {
	d, src, f, e := newAttachmentEngine(t, nil)
	for i := range 5 {
		f.addAttachment(fmt.Sprintf("a%d", i), "p1", 1, t0, fmt.Sprintf("n%d.txt", i), "text/plain", []byte("x"), -1)
	}
	_, err := e.Run(context.Background())
	require.NoError(t, err)

	old := reextractBatchSize
	reextractBatchSize = 2
	t.Cleanup(func() { reextractBatchSize = old })
	clock := &manualClock{t: t0}
	x := newFakeExtractor()
	x.onExtract = func() { clock.advance(time.Minute) }
	e2 := New(d, Options{Extractor: x, Budget: 90 * time.Second, Now: clock.Now})
	e2.SetFetcher(src.JiraAccountID, f)

	st, err := e2.Run(context.Background())
	require.NoError(t, err)
	assert.True(t, st.Incomplete, "the budget cuts the re-extraction")
	assert.Equal(t, 2, countStatus(t, d, src.ID, "ok"), "one chunk of two, then the budget is spent")

	for range 3 {
		_, err = e2.Run(context.Background())
		require.NoError(t, err)
	}
	assert.Equal(t, 5, countStatus(t, d, src.ID, "ok"))
}

func countStatus(t *testing.T, d *db.DB, sourceID int64, status string) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM ext_documents WHERE source_id = ? AND kind = 'attachment' AND extract_status = ?`,
		sourceID, status).Scan(&n))
	return n
}

// blockingExtractor never finishes extracting the attachment named block
// until its ctx ends — a stuck parser or helper.
type blockingExtractor struct {
	*fakeExtractor
	block string
}

func (x blockingExtractor) Extract(ctx context.Context, mediaType, name string, r io.Reader) ([]Section, string, error) {
	if name == x.block {
		<-ctx.Done()
		return nil, "", ctx.Err()
	}
	return x.fakeExtractor.Extract(ctx, mediaType, name, r)
}

// TestExtractDeadlineCoversTheOCRWorstCase: PDF helper 60s + 5 OCR batches
// of 60s = 6 min; the deadline must not cut a large but healthy scan
// (ruling R14).
func TestExtractDeadlineCoversTheOCRWorstCase(t *testing.T) {
	assert.GreaterOrEqual(t, extractDeadline, 6*time.Minute+30*time.Second)
}

// TestAttachmentDeadlineIsTransientFailure: one attachment whose
// extraction takes past extractDeadline is cut off and recorded as a
// transient failure (attempts+1) — never a batch error — and its siblings
// still land.
func TestAttachmentDeadlineIsTransientFailure(t *testing.T) {
	old := extractDeadline
	extractDeadline = 50 * time.Millisecond
	t.Cleanup(func() { extractDeadline = old })

	x := blockingExtractor{fakeExtractor: newFakeExtractor(), block: "stuck.pdf"}
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "stuck.pdf", "application/pdf", []byte("1"), -1)
	f.addAttachment("a2", "p1", 1, t0.Add(time.Minute), "two.txt", "text/plain", []byte("2"), -1)

	done := make(chan error, 1)
	go func() {
		_, err := e.Run(context.Background())
		done <- err
	}()
	select {
	case err := <-done:
		require.NoError(t, err)
	case <-time.After(10 * time.Second):
		t.Fatal("the stuck attachment was never cut off")
	}

	row, ok := loadAttachment(t, d, src.ID, "a1")
	require.True(t, ok)
	assert.Equal(t, "failed", row.status)
	assert.Equal(t, 1, extractAttempts(t, d, src.ID, "a1"))
	row, ok = loadAttachment(t, d, src.ID, "a2")
	require.True(t, ok)
	assert.Equal(t, "ok", row.status)
	assert.Equal(t, "ok", loadSource(t, d).Status)
}
