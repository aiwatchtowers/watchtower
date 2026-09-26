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

func TestAttachmentDownloadErrorFailsTheBatch(t *testing.T) {
	x := newFakeExtractor()
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "notes.txt", "text/plain", []byte("hello"), -1)
	f.downloadErr["a1"] = errors.New("connection reset")

	_, err := e.Run(context.Background())
	require.Error(t, err)
	_, ok := loadAttachment(t, d, src.ID, "a1")
	assert.False(t, ok)
	assert.Empty(t, loadSource(t, d).AttachmentCursor, "a failed batch does not advance the cursor")
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
