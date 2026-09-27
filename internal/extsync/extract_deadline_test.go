package extsync_test

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/extract"
	"watchtower/internal/extsync"
)

// TestExtractDeadlineCoversTheOCRWorstCase: the extraction deadline must not
// cut a large but healthy scan (ruling R14). Its worst case is derived from
// the extractor's own bounds — one PDF helper run plus every OCR batch the
// page cap allows, each helper run with its 5 s kill grace (exec WaitDelay)
// — so raising any of them without the deadline fails here.
func TestExtractDeadlineCoversTheOCRWorstCase(t *testing.T) {
	const killGrace = 5 * time.Second
	batches := (extract.MaxOCRPages + extract.OCRBatchPages - 1) / extract.OCRBatchPages
	runs := time.Duration(batches + 1)
	worst := extract.PDFHelperTimeout + extract.OCRTimeout*time.Duration(batches) + killGrace*runs
	assert.GreaterOrEqual(t, extsync.ExtractDeadline, worst, "worst case %s", worst)
}
