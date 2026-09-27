package extract

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func scanPagesN(n int) ([]pdfPage, []int) {
	pages := make([]pdfPage, n)
	scans := make([]int, n)
	for i := range pages {
		pages[i] = pdfPage{Index: i, Scan: true}
		scans[i] = i
	}
	return pages, scans
}

// TestOCRRunsInPageBatches (fix round 1, finding 2): up to 50 scan pages
// are sent in calls of at most 10 pages — each with its own helper timeout
// — never in one all-or-nothing call.
func TestOCRRunsInPageBatches(t *testing.T) {
	var calls [][]int
	ocr := ocrFunc(func(_ context.Context, _ string, pages []int) (map[int]string, error) {
		calls = append(calls, append([]int(nil), pages...))
		got := map[int]string{}
		for _, p := range pages {
			got[p] = fmt.Sprintf("page %d text", p)
		}
		return got, nil
	})
	pages, scans := scanPagesN(MaxOCRPages)
	failed, err := recognizeScans(context.Background(), ocr, "/tmp/x.pdf", pages, scans, discardLog)
	require.NoError(t, err)
	assert.False(t, failed)
	require.Len(t, calls, 5, "50 pages = 5 calls of 10")
	for _, c := range calls {
		assert.LessOrEqual(t, len(c), ocrBatchPages)
	}
	assert.Equal(t, "page 49 text", pages[49].Text)
	assert.Equal(t, StatusOK, pdfStatus(pages, scans, true, failed))
}

// TestOCRBatchTimeoutKeepsTheOtherBatches: one batch timing out loses only
// its own pages; the rest are recognized and the attachment is ocr_pending
// only because some scan page still has no text.
func TestOCRBatchTimeoutKeepsTheOtherBatches(t *testing.T) {
	ocr := ocrFunc(func(_ context.Context, _ string, pages []int) (map[int]string, error) {
		if pages[0] == 10 {
			return nil, errors.New("ocr helper timed out after 1m0s")
		}
		got := map[int]string{}
		for _, p := range pages {
			got[p] = "words"
		}
		return got, nil
	})
	pages, scans := scanPagesN(25)
	failed, err := recognizeScans(context.Background(), ocr, "/tmp/x.pdf", pages, scans, discardLog)
	require.NoError(t, err)
	assert.True(t, failed)
	for i, p := range pages {
		if i >= 10 && i < 20 {
			assert.Empty(t, p.Text, "page %d was in the failed batch", i)
		} else {
			assert.Equal(t, "words", p.Text, "page %d", i)
		}
	}
	assert.Equal(t, StatusOCRPending, pdfStatus(pages, scans, true, failed))
	assert.Len(t, pageSections(pages), 15, "the recognized pages are kept")
}

// TestOCRBatchFailureWithTextLayerIsOK: a failed batch whose pages all
// kept a (short) text layer leaves no scan page empty, so the row is ok.
func TestOCRBatchFailureWithTextLayerIsOK(t *testing.T) {
	ocr := ocrFunc(func(context.Context, string, []int) (map[int]string, error) {
		return nil, errors.New("helper crashed")
	})
	pages, scans := scanPagesN(3)
	for i := range pages {
		pages[i].Text = "short"
	}
	failed, err := recognizeScans(context.Background(), ocr, "/tmp/x.pdf", pages, scans, discardLog)
	require.NoError(t, err)
	assert.True(t, failed)
	assert.Equal(t, StatusOK, pdfStatus(pages, scans, true, failed))
}

// TestOCRBatchesStopOnCancel: a cancelled ctx aborts the remaining batches
// and is returned.
func TestOCRBatchesStopOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	ocr := ocrFunc(func(context.Context, string, []int) (map[int]string, error) {
		calls++
		cancel()
		return nil, context.Canceled
	})
	pages, scans := scanPagesN(30)
	_, err := recognizeScans(ctx, ocr, "/tmp/x.pdf", pages, scans, discardLog)
	require.ErrorIs(t, err, context.Canceled)
	assert.Equal(t, 1, calls)
}

// TestHelperArgsEmptyPages (finding 7): a non-nil empty page list never
// becomes `--pages ""`, and Recognize makes no call for it.
func TestHelperArgsEmptyPages(t *testing.T) {
	assert.Equal(t, []string{"/tmp/x.pdf"}, helperArgs("/tmp/x.pdf", []int{}))
	helper, args := fakeHelper(t, `echo '{"pages":[]}'`)
	got, err := NewHelperOCR(helper, 0).Recognize(context.Background(), "/tmp/x.pdf", []int{})
	require.NoError(t, err)
	assert.Empty(t, got)
	assert.NoFileExists(t, args, "the helper was not run")
}
