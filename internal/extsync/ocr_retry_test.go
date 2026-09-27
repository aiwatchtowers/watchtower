package extsync

import (
	"context"
	"database/sql"
	"errors"
	"io"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ocrExtractor answers from a per-name queue of statuses (the last one
// repeats; empty = ok). ok → "text of <name>", ocr_pending → the partial
// text "partial <name>", anything else → no sections. hasOCR drives
// OCRCapable.
type ocrExtractor struct {
	mu     sync.Mutex
	hasOCR bool
	queue  map[string][]string
	calls  map[string]int
}

func newOCRExtractor(hasOCR bool) *ocrExtractor {
	return &ocrExtractor{hasOCR: hasOCR, queue: map[string][]string{}, calls: map[string]int{}}
}

func (x *ocrExtractor) HasOCR(context.Context) bool {
	x.mu.Lock()
	defer x.mu.Unlock()
	return x.hasOCR
}

func (x *ocrExtractor) set(hasOCR bool, name string, statuses ...string) {
	x.mu.Lock()
	defer x.mu.Unlock()
	x.hasOCR = hasOCR
	x.queue[name] = statuses
}

func (x *ocrExtractor) Extract(_ context.Context, _, name string, r io.Reader) ([]Section, string, error) {
	if _, err := io.ReadAll(r); err != nil {
		return nil, "", err
	}
	x.mu.Lock()
	defer x.mu.Unlock()
	x.calls[name]++
	status := "ok"
	if q := x.queue[name]; len(q) > 0 {
		status = q[0]
		if len(q) > 1 {
			x.queue[name] = q[1:]
		}
	}
	switch status {
	case "ok":
		return []Section{{Text: "text of " + name}}, status, nil
	case "ocr_pending":
		return []Section{{Text: "partial " + name}}, status, nil
	}
	return nil, status, nil
}

// TestOCRPendingRetriedNextCycle: OCR that could not run stores the text it
// has (ocr_pending, attempt 1), is not retried in the same pass, and the
// next cycle's retry stores the full text with attempts reset.
func TestOCRPendingRetriedNextCycle(t *testing.T) {
	x := newOCRExtractor(true)
	x.set(true, "scan.png", "ocr_pending", "ok")
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "scan.png", "image/png", []byte("img"), -1)

	_, err := e.Run(context.Background())
	require.NoError(t, err)
	row, ok := loadAttachment(t, d, src.ID, "a1")
	require.True(t, ok)
	assert.Equal(t, "ocr_pending", row.status)
	assert.Equal(t, []Section{{Text: "partial scan.png"}}, row.sections)
	assert.Equal(t, 1, extractAttempts(t, d, src.ID, "a1"), "the first OCR failure is attempt 1")
	assert.Equal(t, 1, f.downloadCount("a1"), "not retried in the pass that failed")

	_, err = e.Run(context.Background())
	require.NoError(t, err)
	row, _ = loadAttachment(t, d, src.ID, "a1")
	assert.Equal(t, "ok", row.status)
	assert.Equal(t, []Section{{Text: "text of scan.png"}}, row.sections)
	assert.Equal(t, 0, extractAttempts(t, d, src.ID, "a1"))
	assert.Equal(t, 2, f.downloadCount("a1"))
}

// TestOCRPendingCappedAtThreeAttempts: a scan whose OCR keeps failing is
// tried 3 times in all (the first extraction included), then left alone.
func TestOCRPendingCappedAtThreeAttempts(t *testing.T) {
	x := newOCRExtractor(true)
	x.set(true, "scan.png", "ocr_pending")
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "scan.png", "image/png", []byte("img"), -1)

	for want := 1; want <= 3; want++ {
		_, err := e.Run(context.Background())
		require.NoError(t, err)
		assert.Equal(t, want, f.downloadCount("a1"))
		assert.Equal(t, want, extractAttempts(t, d, src.ID, "a1"))
	}
	for range 2 {
		_, err := e.Run(context.Background())
		require.NoError(t, err)
	}
	assert.Equal(t, 3, f.downloadCount("a1"), "no retry after 3 attempts")
	row, _ := loadAttachment(t, d, src.ID, "a1")
	assert.Equal(t, "ocr_pending", row.status)
	assert.Equal(t, []Section{{Text: "partial scan.png"}}, row.sections, "the partial text stays searchable")
}

// TestOCRPendingSharesTheAttemptBudget: a transient download failure and
// OCR failures count against the same 3 attempts.
func TestOCRPendingSharesTheAttemptBudget(t *testing.T) {
	x := newOCRExtractor(true)
	x.set(true, "scan.png", "ocr_pending")
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "scan.png", "image/png", []byte("img"), -1)
	f.downloadErr["a1"] = errors.New("request timed out")

	_, err := e.Run(context.Background())
	require.NoError(t, err)
	delete(f.downloadErr, "a1")
	for range 4 {
		_, err = e.Run(context.Background())
		require.NoError(t, err)
	}
	assert.Equal(t, 3, f.downloadCount("a1"))
	assert.Equal(t, 3, extractAttempts(t, d, src.ID, "a1"))
}

// TestOCRUnavailableNeverDownloadedWithoutOCR: while no OCR is wired, an
// ocr_unavailable row is never downloaded again — nor with an extractor
// that cannot say whether it has OCR.
func TestOCRUnavailableNeverDownloadedWithoutOCR(t *testing.T) {
	x := newOCRExtractor(false)
	x.set(false, "scan.png", "ocr_unavailable")
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "scan.png", "image/png", []byte("img"), -1)
	for range 3 {
		_, err := e.Run(context.Background())
		require.NoError(t, err)
	}
	assert.Equal(t, 1, f.downloadCount("a1"))
	row, _ := loadAttachment(t, d, src.ID, "a1")
	assert.Equal(t, "ocr_unavailable", row.status)
	assert.Equal(t, 0, extractAttempts(t, d, src.ID, "a1"))

	plain := newFakeExtractor() // no HasOCR at all
	e2 := New(d, Options{Extractor: plain})
	e2.SetFetcher(src.JiraAccountID, f)
	_, err := e2.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, f.downloadCount("a1"), "an extractor without OCRCapable never retries it")
}

// TestOCRUnavailableRetriedOnceOCRArrives: once the extractor has OCR, the
// rows stored while it had none are downloaded and recognized.
func TestOCRUnavailableRetriedOnceOCRArrives(t *testing.T) {
	x := newOCRExtractor(false)
	x.set(false, "scan.png", "ocr_unavailable")
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "scan.png", "image/png", []byte("img"), -1)
	_, err := e.Run(context.Background())
	require.NoError(t, err)

	x.set(true, "scan.png", "ok")
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	row, _ := loadAttachment(t, d, src.ID, "a1")
	assert.Equal(t, "ok", row.status)
	assert.Equal(t, []Section{{Text: "text of scan.png"}}, row.sections)
	assert.Equal(t, 2, f.downloadCount("a1"))

	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 2, f.downloadCount("a1"), "an ok row is not revisited")
}

// TestOCRUnavailableThenPendingCountsFromOne: a row revisited because OCR
// arrived whose OCR then fails starts the attempt budget at 1.
func TestOCRUnavailableThenPendingCountsFromOne(t *testing.T) {
	x := newOCRExtractor(false)
	x.set(false, "scan.png", "ocr_unavailable")
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "scan.png", "image/png", []byte("img"), -1)
	_, err := e.Run(context.Background())
	require.NoError(t, err)

	x.set(true, "scan.png", "ocr_pending")
	for range 5 {
		_, err = e.Run(context.Background())
		require.NoError(t, err)
	}
	assert.Equal(t, 4, f.downloadCount("a1"), "1 without OCR + 3 attempts with it")
	assert.Equal(t, 3, extractAttempts(t, d, src.ID, "a1"))
}

// TestTransientFailureOnNewVersionKeepsOldText (carried item d): a new
// version whose download fails keeps the previous version's text and
// version — search never loses the good text — and the retry fetches the
// new version.
func TestTransientFailureOnNewVersionKeepsOldText(t *testing.T) {
	x := newFakeExtractor()
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "one.txt", "text/plain", []byte("1"), -1)
	_, err := e.Run(context.Background())
	require.NoError(t, err)

	f.mutate("a1", 2, t0.Add(time.Hour))
	f.find("a1").item.Title = "one-v2.txt"
	f.downloadErr["a1"] = errors.New("request timed out")
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	row, _ := loadAttachment(t, d, src.ID, "a1")
	assert.Equal(t, "failed", row.status)
	assert.Equal(t, 1, extractAttempts(t, d, src.ID, "a1"))
	assert.Equal(t, []Section{{Text: "text of one.txt"}}, row.sections, "the old text stays searchable")
	assert.Equal(t, 1, row.version, "the row stays at the version its text belongs to")
	assert.Equal(t, formatTime(t0.Add(time.Hour)), loadSource(t, d).AttachmentCursor, "the cursor still moves on")

	delete(f.downloadErr, "a1")
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	row, _ = loadAttachment(t, d, src.ID, "a1")
	assert.Equal(t, "ok", row.status)
	assert.Equal(t, 2, row.version, "the retry fetched the new version")
	assert.Equal(t, []Section{{Text: "text of one-v2.txt"}}, row.sections)
	assert.Equal(t, 0, extractAttempts(t, d, src.ID, "a1"))
}

// TestDegradedNewVersionCappedAcrossRuns (fix round 1, finding 1): a new
// version that keeps failing is re-listed by every pass's cursor overlap,
// yet it gets exactly 3 tries — the stream does not re-process a row whose
// pending version it already tried — and nothing is downloaded after the
// third, however many runs follow. The old text stays throughout.
func TestDegradedNewVersionCappedAcrossRuns(t *testing.T) {
	x := newFakeExtractor()
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "one.txt", "text/plain", []byte("1"), -1)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	require.Equal(t, 1, f.downloadCount("a1"))

	f.mutate("a1", 2, t0.Add(time.Hour))
	f.downloadErr["a1"] = errors.New("request timed out")
	var attempts []int
	for range 6 {
		_, err = e.Run(context.Background())
		require.NoError(t, err)
		attempts = append(attempts, extractAttempts(t, d, src.ID, "a1"))
	}
	assert.Equal(t, []int{1, 2, 3, 3, 3, 3}, attempts)
	assert.Equal(t, 1+3, f.downloadCount("a1"), "no download after the third try")
	row, _ := loadAttachment(t, d, src.ID, "a1")
	assert.Equal(t, "failed", row.status)
	assert.Equal(t, 1, row.version)
	assert.Equal(t, []Section{{Text: "text of one.txt"}}, row.sections)
}

// TestDegradedCappedRowTakesALaterVersion: after the cap, a newer version
// is listed as changed and gets a fresh budget; its success replaces the
// old text.
func TestDegradedCappedRowTakesALaterVersion(t *testing.T) {
	x := newFakeExtractor()
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "one.txt", "text/plain", []byte("1"), -1)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	f.mutate("a1", 2, t0.Add(time.Hour))
	f.downloadErr["a1"] = errors.New("request timed out")
	for range 4 {
		_, err = e.Run(context.Background())
		require.NoError(t, err)
	}
	require.Equal(t, 3, extractAttempts(t, d, src.ID, "a1"))

	f.mutate("a1", 3, t0.Add(2*time.Hour))
	f.find("a1").item.Title = "one-v3.txt"
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, extractAttempts(t, d, src.ID, "a1"), "a new version starts a new budget")
	delete(f.downloadErr, "a1")
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	row, _ := loadAttachment(t, d, src.ID, "a1")
	assert.Equal(t, "ok", row.status)
	assert.Equal(t, 3, row.version)
	assert.Equal(t, []Section{{Text: "text of one-v3.txt"}}, row.sections)
	assert.Equal(t, 0, extractAttempts(t, d, src.ID, "a1"))
	assert.NotContains(t, loadMeta(t, d, src.ID, "a1"), "pending_version", "a success clears the pending marker")
}

func loadMeta(t *testing.T, d interface {
	QueryRow(string, ...any) *sql.Row
}, sourceID int64, id string) string {
	t.Helper()
	var meta string
	require.NoError(t, d.QueryRow(`SELECT meta_json FROM ext_documents WHERE source_id = ? AND ext_id = ?`,
		sourceID, id).Scan(&meta))
	return meta
}

// TestOCRPendingOnNewVersionKeepsOldText: OCR failing on a new version of
// an already-recognized scan keeps the recognized text until a retry
// succeeds.
func TestOCRPendingOnNewVersionKeepsOldText(t *testing.T) {
	x := newOCRExtractor(true)
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 1, t0, "scan.png", "image/png", []byte("img"), -1)
	_, err := e.Run(context.Background())
	require.NoError(t, err)

	f.mutate("a1", 2, t0.Add(time.Hour))
	x.set(true, "scan.png", "ocr_pending", "ok")
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	row, _ := loadAttachment(t, d, src.ID, "a1")
	assert.Equal(t, "ocr_pending", row.status)
	assert.Equal(t, []Section{{Text: "text of scan.png"}}, row.sections)
	assert.Equal(t, 1, row.version)

	_, err = e.Run(context.Background())
	require.NoError(t, err)
	row, _ = loadAttachment(t, d, src.ID, "a1")
	assert.Equal(t, "ok", row.status)
	assert.Equal(t, 2, row.version)
}

// TestTransientFailureOnNewAttachmentStoresRow: with no previous row there
// is nothing to keep — the row is stored at its version with no text, so
// the delta does not re-list it and the revisit retries it.
func TestTransientFailureOnNewAttachmentStoresRow(t *testing.T) {
	x := newFakeExtractor()
	d, src, f, e := newAttachmentEngine(t, x)
	f.addAttachment("a1", "p1", 3, t0, "one.txt", "text/plain", []byte("1"), -1)
	f.downloadErr["a1"] = errors.New("request timed out")
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	row, ok := loadAttachment(t, d, src.ID, "a1")
	require.True(t, ok)
	assert.Equal(t, 3, row.version)
	assert.Empty(t, row.sections)
	assert.Equal(t, "failed", row.status)
}

// sweepExtractor records SweepStale calls.
type sweepExtractor struct {
	*fakeExtractor
	mu    sync.Mutex
	calls []time.Time
}

func (x *sweepExtractor) SweepStale(now time.Time) (int, error) {
	x.mu.Lock()
	defer x.mu.Unlock()
	x.calls = append(x.calls, now)
	return 0, nil
}

// TestEngineSweepsTempFilesEachRun (carried item c): every Run and
// RunSource first sweeps the extractor's crash leftovers.
func TestEngineSweepsTempFilesEachRun(t *testing.T) {
	x := &sweepExtractor{fakeExtractor: newFakeExtractor()}
	clock := &manualClock{t: t0}
	d, src := newSourceDB(t)
	f := newFake()
	e := New(d, Options{Extractor: x, Now: clock.Now})
	e.SetFetcher(src.JiraAccountID, f)

	_, err := e.Run(context.Background())
	require.NoError(t, err)
	clock.advance(time.Hour)
	_, err = e.RunSource(context.Background(), loadSource(t, d))
	require.NoError(t, err)
	assert.Equal(t, []time.Time{t0, t0.Add(time.Hour)}, x.calls)
}
