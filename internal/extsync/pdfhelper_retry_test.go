package extsync_test

import (
	"bytes"
	"context"
	"log"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/extract"
	"watchtower/internal/extsync"
)

// pdfRow reads the PDF attachment's extraction status and attempt count.
func pdfRow(t *testing.T, d *db.DB) (status string, attempts int) {
	t.Helper()
	require.NoError(t, d.QueryRow(`SELECT extract_status, extract_attempts FROM ext_documents WHERE ext_id = 'a-pdf'`).
		Scan(&status, &attempts))
	return status, attempts
}

// newPDFHelperEngine wires a real extract.Extractor running helper as its
// PDF helper, logging into logs.
func newPDFHelperEngine(t *testing.T, helper []string, logs *bytes.Buffer) (*db.DB, *extract.Extractor, *extsync.Engine) {
	t.Helper()
	d := db.OpenTestDB(t)
	acct := db.SeedTestJiraAccount(t, d)
	_, err := d.CreateExtSource("confluence", acct, "ENG", "1", "Engineering")
	require.NoError(t, err)
	logger := log.New(logs, "", 0)
	x := &extract.Extractor{TempDir: filepath.Join(t.TempDir(), "extract"), PDFHelper: helper, Logger: logger}
	e := extsync.New(d, extsync.Options{Extractor: x, Logger: logger})
	e.SetFetcher(acct, newExt03Fetcher(t))
	return d, x, e
}

// A PDF helper that crashes (non-zero exit) is a transient failure, not a
// verdict on the file: the row is failed with one attempt, the helper's
// stderr reaches the log, and the next cycle retries it.
func TestPDFHelperCrashIsRetried(t *testing.T) {
	var logs bytes.Buffer
	crash := []string{"/bin/sh", "-c", "echo helper blew up >&2; exit 3", "sh"}
	d, x, e := newPDFHelperEngine(t, crash, &logs)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	status, attempts := pdfRow(t, d)
	assert.Equal(t, "failed", status)
	assert.Equal(t, 1, attempts, "a crash counts as an attempt, to be retried")
	assert.Contains(t, logs.String(), "helper blew up", "the helper's stderr is not discarded")

	x.PDFHelper = nil // the helper recovers (parsed in process)
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	status, attempts = pdfRow(t, d)
	assert.Equal(t, "ocr_unavailable", status, "retried on the next cycle: mixed.pdf parsed, its scan page awaits OCR")
	assert.Zero(t, attempts)
}

// Malformed helper output is a verdict: failed with no attempt, never
// retried, and logged.
func TestPDFHelperGarbageIsFinal(t *testing.T) {
	var logs bytes.Buffer
	d, x, e := newPDFHelperEngine(t, []string{"/bin/echo", "not json"}, &logs)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	status, attempts := pdfRow(t, d)
	assert.Equal(t, "failed", status)
	assert.Zero(t, attempts)
	assert.Contains(t, logs.String(), "malformed output")

	x.PDFHelper = nil // would succeed, were it retried
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	status, _ = pdfRow(t, d)
	assert.Equal(t, "failed", status, "a final failure is not retried")
}
